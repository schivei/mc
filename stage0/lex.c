/* lex.c — mutable token table and incremental lexer.
 * The lexer delivers one token per call (lex_next); the parser keeps a
 * lookahead of 1, so a #token registered now already applies to the
 * next lexeme. --dump-tokens runs the lexer alone, without the parser, and
 * therefore does not process #token — documented in the M1 spec. */
#include "mc.h"

#define MAXTOK 2048
#define MAXOPEN 16            /* maximum #include nesting depth */
#define MAXINC  256           /* files already included (once-only) */
static TokEnt toktab[MAXTOK];
static int ntok;

static const u8 *cp, *cend;   /* cursor and end of the current file */
static int cline;

/* file stack: the top is the one being read; the ones below keep where they stopped */
typedef struct { const u8 *cp, *cend; int line; const char *name; } OpenFile;
static OpenFile fstack[MAXOPEN]; static int nopen;
static const char *inclist[MAXINC]; static int ninc;   /* paths already included, in order */

static bool is_alpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool is_digit(int c) { return c >= '0' && c <= '9'; }
static bool is_alnum(int c) { return is_alpha(c) || is_digit(c); }
static int  hex_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* ---- token table: insertion order, ids starting at 256 ---- */
int tok_add(const char *text, int len) {
    for (int i = 0; i < ntok; i++)
        if (toktab[i].len == len && mem_eq(toktab[i].text, text, (size_t)len)) return toktab[i].id;
    if (len <= 0) die("empty lexeme");
    if (ntok == MAXTOK) die("token table full");
    toktab[ntok].text = text;
    toktab[ntok].len  = len;
    toktab[ntok].word = is_alpha((u8)text[0]);
    toktab[ntok].id   = 256 + ntok;
    ntok++;
    return 256 + ntok - 1;
}

const char *tok_text(int id) {
    if (id == T_IDENT) return "IDENT";
    if (id == T_INT)   return "INT";
    if (id == T_CHAR)  return "CHAR";
    if (id == T_STR)   return "STR";
    if (id == T_DIR)   return "DIR";
    if (id == T_HOLE)  return "HOLE";
    if (id == T_EOF)   return "EOF";
    for (int i = 0; i < ntok; i++) if (toktab[i].id == id) return toktab[i].text;
    return "?";
}

void tok_init(void) {
    static const char *core[] = {
        "u8", "u16", "u32", "u64", "i64", "uptr", "void",
        "if", "else", "loop", "break", "continue", "return", "extern",
        "(", ")", "{", "}", "[", "]", ",", ";",
        "+", "-", "*", "/", "%", "&", "|", "^", "~", "<<", ">>",
        "==", "!=", "<", "<=", ">", ">=", "&&", "||", "!", "=",
        ":", "=>", 0 };                    /* only #rule uses these; at the end so they do not renumber */
    for (int i = 0; core[i]; i++) tok_add(core[i], (int)cstrlen(core[i]));
}

/* identifier: only matches entries with word=true */
static int word_id(const u8 *s, int len) {
    for (int i = 0; i < ntok; i++)
        if (toktab[i].word && toktab[i].len == len && mem_eq(toktab[i].text, s, (size_t)len))
            return toktab[i].id;
    return -1;
}

/* punctuation/operator: longest prefix, linear and deterministic scan */
static int punct_id(const u8 *s, int avail, int *plen) {
    int best = -1, blen = 0;
    for (int i = 0; i < ntok; i++) {
        if (toktab[i].word || toktab[i].len > avail || toktab[i].len <= blen) continue;
        if (mem_eq(toktab[i].text, s, (size_t)toktab[i].len)) {
            best = toktab[i].id; blen = toktab[i].len;
        }
    }
    *plen = blen;
    return best;
}

static const char *dir_names[] = { "include", "define", "token", "infix",
                                   "prefix", "rule", "section", "opcode", 0 };

/* ---- file stack ---- */
/* normalizes . and .. lexically (without touching the filesystem), so that two paths
 * naming the same file become the same string and once-only works */
#define MAXSEG 64
static const char *path_norm(const char *p) {
    int sb[MAXSEG], sl[MAXSEG], nseg = 0;      /* start and length of each segment */
    size_t n = cstrlen(p), i = 0;
    bool abs = p[0] == '/';
    while (i < n) {
        while (i < n && p[i] == '/') i++;
        size_t b = i;
        while (i < n && p[i] != '/') i++;
        int l = (int)(i - b);
        if (l == 0 || (l == 1 && p[b] == '.')) continue;
        bool up = l == 2 && p[b] == '.' && p[b + 1] == '.';
        bool prev_up = nseg && sl[nseg - 1] == 2 && p[sb[nseg - 1]] == '.'
                       && p[sb[nseg - 1] + 1] == '.';
        if (up && (nseg ? !prev_up : abs)) { if (nseg) nseg--; continue; }
        if (nseg == MAXSEG) die2("path with too many segments", p);
        sb[nseg] = (int)b; sl[nseg] = l; nseg++;
    }
    char *s = xalloc(n + 2);
    size_t w = 0;
    if (abs) s[w++] = '/';
    for (int k = 0; k < nseg; k++) {
        if (k) s[w++] = '/';
        for (int j = 0; j < sl[k]; j++) s[w++] = p[sb[k] + j];
    }
    if (w == 0) s[w++] = '.';
    s[w] = 0;
    return s;
}

/* joins the base directory with rel and normalizes; an absolute path ignores the base */
static const char *path_join(const char *base, const char *rel) {
    size_t cut = 0, bl = cstrlen(base), rl = cstrlen(rel);
    if (rel[0] == '/') bl = 0;
    else for (size_t i = 0; i < bl; i++) if (base[i] == '/') cut = i + 1;
    char *s = xalloc(cut + rl + 1);
    for (size_t i = 0; i < cut; i++) s[i] = base[i];
    for (size_t i = 0; i < rl; i++) s[cut + i] = rel[i];
    s[cut + rl] = 0;
    return path_norm(s);
}

static void lex_push(const char *path, int line) {
    if (nopen == MAXOPEN) err_at(lex_file(), line, "too many nested includes");
    if (nopen) { fstack[nopen - 1].cp = cp; fstack[nopen - 1].cend = cend;
                 fstack[nopen - 1].line = cline; }
    size_t len = 0;
    const u8 *src = read_file(path, &len);
    fstack[nopen].name = path; nopen++;
    cp = src; cend = src + len; cline = 1;
}

static void lex_pop(void) {
    nopen--;
    cp = fstack[nopen - 1].cp; cend = fstack[nopen - 1].cend;
    cline = fstack[nopen - 1].line;
}

const char *lex_file(void) { return nopen ? fstack[nopen - 1].name : "?"; }

void lex_init(const char *path) {
    nopen = 0; ninc = 0;
    path = path_norm(path);
    inclist[ninc++] = path;                    /* the root also counts for once-only */
    lex_push(path, 0);
}

bool lex_include(const char *rel, int line) {
    const char *path = path_join(fstack[nopen - 1].name, rel);
    for (int i = 0; i < ninc; i++) if (str_eq(inclist[i], path)) return false;
    if (ninc == MAXINC) err_at(lex_file(), line, "too many includes");
    inclist[ninc++] = path;
    lex_push(path, line);
    return true;
}

/* ---- lexer ---- */

static void skip_space(void) {
    for (;;) {
        while (cp < cend && (*cp == ' ' || *cp == '\t' || *cp == '\r' || *cp == '\n')) {
            if (*cp == '\n') cline++;
            cp++;
        }
        if (cp + 1 < cend && cp[0] == '/' && cp[1] == '/') {
            while (cp < cend && *cp != '\n') cp++;
            continue;
        }
        if (cp + 1 < cend && cp[0] == '/' && cp[1] == '*') {
            int open_line = cline;
            cp += 2;
            while (cp + 1 < cend && !(cp[0] == '*' && cp[1] == '/')) {
                if (*cp == '\n') cline++;
                cp++;
            }
            if (cp + 1 >= cend) err_at(lex_file(), open_line, "unterminated comment");
            cp += 2;
            continue;
        }
        return;
    }
}

/* reads a literal character, decoding an escape. \0 is forbidden in a string:
 * __cstring is S_CSTRING_LITERALS and ld merges literals at the first NUL. */
static i64 read_char(bool in_str) {
    if (cp >= cend) err_at(lex_file(), cline, "unterminated literal");
    u8 c = *cp++;
    if (c == '\n') { cline++; return c; }
    if (c != '\\') return c;
    if (cp >= cend) err_at(lex_file(), cline, "unterminated escape");
    u8 e = *cp++;
    if (e == 'n')  return '\n';
    if (e == 't')  return '\t';
    if (e == 'r')  return '\r';
    if (e == '0')  { if (in_str) err_at(lex_file(), cline, "\\0 not allowed in string");
                     return 0; }
    if (e == '\\') return '\\';
    if (e == '\'') return '\'';
    if (e == '"')  return '"';
    err_at(lex_file(), cline, "unknown escape");
}

static void lex_number(Token *t) {
    u64 v = 0;
    if (cp[0] == '0' && cp + 1 < cend && (cp[1] == 'x' || cp[1] == 'X')) {
        cp += 2;
        if (cp >= cend || hex_val(*cp) < 0) err_at(lex_file(), cline, "invalid hexadecimal");
        while (cp < cend && hex_val(*cp) >= 0) { v = v * 16 + (u64)hex_val(*cp); cp++; }
    } else {
        while (cp < cend && is_digit(*cp)) { v = v * 10 + (u64)(*cp - '0'); cp++; }
    }
    t->id = T_INT; t->val = (i64)v;
}

static void lex_string(Token *t) {
    Buf b = {0};
    cp++;                                  /* opening quote */
    while (cp < cend && *cp != '"') buf_u8(&b, (u8)read_char(true));
    if (cp >= cend) err_at(t->file, t->line, "unterminated string");
    cp++;
    buf_u8(&b, 0);                         /* sentinel; len does not count it */
    t->id = T_STR; t->start = b.p; t->len = (int)b.len - 1;
}

static void lex_directive(Token *t) {
    cp++;                                  /* # */
    const u8 *ns = cp;
    while (cp < cend && is_alnum(*cp)) cp++;
    int nl = (int)(cp - ns);
    for (int i = 0; dir_names[i]; i++)
        if ((int)cstrlen(dir_names[i]) == nl && mem_eq(dir_names[i], ns, (size_t)nl)) {
            t->id = T_DIR; t->val = i;
            return;
        }
    err_at(t->file, t->line, "unknown directive");
}

/* $1 / $2 -> val = number; $name -> val = -1; $$name -> val = -2 (gensym, reserved only) */
static void lex_hole(Token *t) {
    cp++;
    bool gensym = false;
    if (cp < cend && *cp == '$') { cp++; gensym = true; }
    if (cp < cend && is_digit(*cp)) {
        i64 v = 0;
        while (cp < cend && is_digit(*cp)) { v = v * 10 + (*cp - '0'); cp++; }
        t->val = v;
    } else if (cp < cend && is_alpha(*cp)) {
        while (cp < cend && is_alnum(*cp)) cp++;
        t->val = -1;
    } else {
        err_at(t->file, t->line, "invalid hole");
    }
    if (gensym) t->val = -2;
    t->id = T_HOLE;
}

void lex_next(Token *t) {
    skip_space();
    while (cp >= cend && nopen > 1) { lex_pop(); skip_space(); }   /* end of an #include */
    t->line = cline; t->val = 0; t->start = cp; t->len = 0; t->file = lex_file();
    if (cp >= cend) { t->id = T_EOF; t->start = (const u8 *)"EOF"; t->len = 3; return; }

    if (is_digit(*cp))  { lex_number(t);    t->len = (int)(cp - t->start); return; }
    if (is_alpha(*cp))  {
        while (cp < cend && is_alnum(*cp)) cp++;
        t->len = (int)(cp - t->start);
        int id = word_id(t->start, t->len);
        t->id = id >= 0 ? id : T_IDENT;
        return;
    }
    if (*cp == '\'') {
        cp++;
        t->val = read_char(false);
        if (cp >= cend || *cp != '\'') err_at(t->file, t->line, "unterminated char literal");
        cp++;
        t->id = T_CHAR; t->len = (int)(cp - t->start);
        return;
    }
    if (*cp == '"')  { lex_string(t);    return; }             /* start points into the arena */
    if (*cp == '#')  { lex_directive(t); t->len = (int)(cp - t->start); return; }
    if (*cp == '$')  { lex_hole(t);      t->len = (int)(cp - t->start); return; }

    int plen = 0;
    int id = punct_id(cp, (int)(cend - cp), &plen);
    if (id < 0) err_at(t->file, t->line, "unexpected character");
    cp += plen; t->len = plen; t->id = id;
}

/* ---- dump ---- */
static void dump_escaped(const u8 *s, int len) {
    out_str(1, "\"");
    for (int i = 0; i < len; i++) {
        u8 c = s[i];
        if (c == '\n')      out_str(1, "\\n");
        else if (c == '\t') out_str(1, "\\t");
        else if (c == '\r') out_str(1, "\\r");
        else if (c == 0)    out_str(1, "\\0");
        else if (c == '\\') out_str(1, "\\\\");
        else if (c == '"')  out_str(1, "\\\"");
        else                out_bytes(1, &c, 1);
    }
    out_str(1, "\"");
}

/* one line per token: LINE ID TEXT (INT/CHAR print the value) */
void dump_tokens(void) {
    Token t;
    for (;;) {
        lex_next(&t);
        out_num(1, t.line); out_str(1, " "); out_num(1, t.id); out_str(1, " ");
        if (t.id == T_INT || t.id == T_CHAR) out_num(1, t.val);
        else if (t.id == T_STR)              dump_escaped(t.start, t.len);
        else                                 out_bytes(1, t.start, (size_t)t.len);
        out_str(1, "\n");
        if (t.id == T_EOF) return;
    }
}
