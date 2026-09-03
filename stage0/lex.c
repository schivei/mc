/* lex.c — tabela de tokens mutavel e lexer incremental.
 * O lexer entrega um token por chamada (lex_next); o parser guarda um
 * lookahead de 1, de modo que um #token registrado agora ja vale para o
 * proximo lexema. --dump-tokens roda o lexer puro, sem parser, e portanto
 * nao processa #token — documentado na spec do M1. */
#include "mc.h"

#define MAXTOK 512
#define MAXOPEN 16            /* profundidade maxima de #include */
#define MAXINC  256           /* arquivos ja incluidos (once-only) */
static TokEnt toktab[MAXTOK];
static int ntok;

static const u8 *cp, *cend;   /* cursor e fim do arquivo atual */
static int cline;

/* pilha de arquivos: o topo e o que esta sendo lido; os de baixo guardam onde pararam */
typedef struct { const u8 *cp, *cend; int line; const char *name; } OpenFile;
static OpenFile fstack[MAXOPEN]; static int nopen;
static const char *inclist[MAXINC]; static int ninc;   /* caminhos ja incluidos, em ordem */

static bool is_alpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool is_digit(int c) { return c >= '0' && c <= '9'; }
static bool is_alnum(int c) { return is_alpha(c) || is_digit(c); }
static int  hex_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* ---- tabela de tokens: ordem de insercao, ids a partir de 256 ---- */
int tok_add(const char *text, int len) {
    for (int i = 0; i < ntok; i++)
        if (toktab[i].len == len && mem_eq(toktab[i].text, text, (size_t)len)) return toktab[i].id;
    if (len <= 0) die("lexema vazio");
    if (ntok == MAXTOK) die("tabela de tokens cheia");
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
        "==", "!=", "<", "<=", ">", ">=", "&&", "||", "!", "=", 0 };
    for (int i = 0; core[i]; i++) tok_add(core[i], (int)cstrlen(core[i]));
}

/* identificador: so casa com entradas word=true */
static int word_id(const u8 *s, int len) {
    for (int i = 0; i < ntok; i++)
        if (toktab[i].word && toktab[i].len == len && mem_eq(toktab[i].text, s, (size_t)len))
            return toktab[i].id;
    return -1;
}

/* pontuacao/operador: maior prefixo, varredura linear e determinista */
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

/* ---- pilha de arquivos ---- */
/* junta o diretorio de base com rel; caminho absoluto passa direto */
static const char *path_join(const char *base, const char *rel) {
    if (rel[0] == '/') return rel;
    size_t cut = 0, bl = cstrlen(base), rl = cstrlen(rel);
    for (size_t i = 0; i < bl; i++) if (base[i] == '/') cut = i + 1;
    char *s = xalloc(cut + rl + 1);
    for (size_t i = 0; i < cut; i++) s[i] = base[i];
    for (size_t i = 0; i < rl; i++) s[cut + i] = rel[i];
    s[cut + rl] = 0;
    return s;
}

static void lex_push(const char *path, int line) {
    if (nopen == MAXOPEN) err_at(line, "includes aninhados demais");
    if (nopen) { fstack[nopen - 1].cp = cp; fstack[nopen - 1].cend = cend;
                 fstack[nopen - 1].line = cline; }
    size_t len = 0;
    const u8 *src = read_file(path, &len);
    fstack[nopen].name = path; nopen++;
    cp = src; cend = src + len; cline = 1;
    src_name = path;
}

static void lex_pop(void) {
    nopen--;
    cp = fstack[nopen - 1].cp; cend = fstack[nopen - 1].cend;
    cline = fstack[nopen - 1].line; src_name = fstack[nopen - 1].name;
}

const char *lex_file(void) { return nopen ? fstack[nopen - 1].name : src_name; }

void lex_init(const char *path) {
    nopen = 0; ninc = 0;
    inclist[ninc++] = path;                    /* o raiz tambem conta para o once-only */
    lex_push(path, 0);
}

bool lex_include(const char *rel, int line) {
    const char *path = path_join(fstack[nopen - 1].name, rel);
    for (int i = 0; i < ninc; i++) if (str_eq(inclist[i], path)) return false;
    if (ninc == MAXINC) err_at(line, "includes demais");
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
            if (cp + 1 >= cend) err_at(open_line, "comentario nao terminado");
            cp += 2;
            continue;
        }
        return;
    }
}

/* le um caractere de literal, decodificando escape */
static i64 read_char(void) {
    if (cp >= cend) err_at(cline, "literal nao terminado");
    u8 c = *cp++;
    if (c == '\n') { cline++; return c; }
    if (c != '\\') return c;
    if (cp >= cend) err_at(cline, "escape nao terminado");
    u8 e = *cp++;
    if (e == 'n')  return '\n';
    if (e == 't')  return '\t';
    if (e == 'r')  return '\r';
    if (e == '0')  return 0;
    if (e == '\\') return '\\';
    if (e == '\'') return '\'';
    if (e == '"')  return '"';
    err_at(cline, "escape desconhecido");
}

static void lex_number(Token *t) {
    u64 v = 0;
    if (cp[0] == '0' && cp + 1 < cend && (cp[1] == 'x' || cp[1] == 'X')) {
        cp += 2;
        if (cp >= cend || hex_val(*cp) < 0) err_at(cline, "hexadecimal invalido");
        while (cp < cend && hex_val(*cp) >= 0) { v = v * 16 + (u64)hex_val(*cp); cp++; }
    } else {
        while (cp < cend && is_digit(*cp)) { v = v * 10 + (u64)(*cp - '0'); cp++; }
    }
    t->id = T_INT; t->val = (i64)v;
}

static void lex_string(Token *t) {
    Buf b = {0};
    cp++;                                  /* aspas de abertura */
    while (cp < cend && *cp != '"') buf_u8(&b, (u8)read_char());
    if (cp >= cend) err_at(t->line, "string nao terminada");
    cp++;
    buf_u8(&b, 0);                         /* sentinela; o len nao a conta */
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
    err_at(t->line, "diretiva desconhecida");
}

/* $1 / $2 -> val = numero; $nome -> val = -1; $$nome -> val = -2 (gensym, so reservado) */
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
        err_at(t->line, "buraco invalido");
    }
    if (gensym) t->val = -2;
    t->id = T_HOLE;
}

void lex_next(Token *t) {
    skip_space();
    while (cp >= cend && nopen > 1) { lex_pop(); skip_space(); }   /* fim de um #include */
    t->line = cline; t->val = 0; t->start = cp; t->len = 0;
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
        t->val = read_char();
        if (cp >= cend || *cp != '\'') err_at(t->line, "char literal nao terminado");
        cp++;
        t->id = T_CHAR; t->len = (int)(cp - t->start);
        return;
    }
    if (*cp == '"')  { lex_string(t);    return; }             /* start aponta para a arena */
    if (*cp == '#')  { lex_directive(t); t->len = (int)(cp - t->start); return; }
    if (*cp == '$')  { lex_hole(t);      t->len = (int)(cp - t->start); return; }

    int plen = 0;
    int id = punct_id(cp, (int)(cend - cp), &plen);
    if (id < 0) err_at(t->line, "caractere inesperado");
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

/* uma linha por token: LINHA ID TEXTO (INT/CHAR imprimem o valor) */
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
