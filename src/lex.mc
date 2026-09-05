// lex.mc — transliteration of stage0/lex.c: mutable token table and
// incremental lexer. The lexer delivers one token per call (lex_next); the parser keeps
// a lookahead of 1, so a #token registered now already applies to the
// next lexeme. --dump-tokens runs the lexer alone, without the parser, so it does not
// process #token or #include — each directive just becomes a T_DIR token.
//
// Same functions, same order, same table in the same insertion order and ids.
// No struct: Token, TokEnt and OpenFile are flat records (TOK_*, TE_*, OF_*).
// Layouts (8-byte fields, in the order of stage0/mc.h's structs):
//   TokEnt   { text, len, word, id }                       — 32 B
//   Token    { id, start, len, val, line, file }            — 48 B
//   OpenFile { cp, cend, line, name }                       — 32 B
// Depends on arena.mc (xalloc, cstrlen, str_eq, mem_eq, buf_*, out_*, die,
// die2, err_at, read_file).
// err_at(file, line, msg) is the same as arena.mc/stage0: the file comes from
// lex_file() (top of the #include stack) or from the token itself, as in stage0.
//
// M23: MAXTOK / MAXOPEN / MAXINC / MAXINCPATH are gone -- the token table, the
// #include stack, the once-only list and the extra roots are arena blocks that
// double on demand (arena.mc grow()). `#include` nesting is no longer capped
// either: the once-only list is what makes a cycle impossible, not the depth.
// M21's substitution slots are parallel to that stack, so they follow it
// (lex_push_mem grows them with it); MAXSUBST stays, because it bounds ONE
// frame's substitutions and is an error threshold, not a table that scales
// with the program -- like MAXDEPTH in parse.mc.

#define MAXSUBST 16                   // M21: substitutions bound to one frame

// ---- untabled token ids (mc.h enum) ----
#define T_EOF   0
#define T_IDENT 1
#define T_INT   2
#define T_CHAR  3
#define T_STR   4
#define T_DIR   5
#define T_HOLE  6

// ---- known directives, in list order: val of a T_DIR token ----
#define D_INCLUDE 0
#define D_DEFINE  1
#define D_TOKEN   2
#define D_INFIX   3
#define D_PREFIX  4
#define D_RULE    5
#define D_SECTION 6
#define D_OPCODE  7
#define D_DYLIB   8       // M12: at the end of the list, so as not to renumber the earlier ones
#define D_EMBED   9       // M15: same reason -- appended, never inserted

// ---- core ids: 256 onward, in tok_init's fixed insertion order ----
#define K_U8       256
#define K_U16      257
#define K_U32      258
#define K_U64      259
#define K_I64      260
#define K_UPTR     261
#define K_VOID     262
#define K_IF       263
#define K_ELSE     264
#define K_LOOP     265
#define K_BREAK    266
#define K_CONTINUE 267
#define K_RETURN   268
#define K_EXTERN   269
#define K_LPAR     270
#define K_RPAR     271
#define K_LBRACE   272
#define K_RBRACE   273
#define K_LBRACK   274
#define K_RBRACK   275
#define K_COMMA    276
#define K_SEMI     277
#define K_ADD      278
#define K_SUB      279
#define K_MUL      280
#define K_DIV      281
#define K_MOD      282
#define K_AND      283
#define K_OR       284
#define K_XOR      285
#define K_TILDE    286
#define K_SHL      287
#define K_SHR      288
#define K_EQ       289
#define K_NE       290
#define K_LT       291
#define K_LE       292
#define K_GT       293
#define K_GE       294
#define K_ANDAND   295
#define K_OROR     296
#define K_BANG     297
#define K_ASSIGN   298
#define K_COLON    299       // only #rule uses this: `stmt:`
#define K_ARROW    300       // only #rule uses this: `=>`
#define K_DOT      301       // M44: only `#include <pack/file.mc>` uses this

// ---- TokEnt: { text, len, word, id } ----
#define TE_TEXT 0
#define TE_LEN  8
#define TE_WORD 16
#define TE_ID   24
#define TE_SIZE 32

// ---- Token: { id, start, len, val, line, file } ----
#define TOK_ID    0
#define TOK_START 8
#define TOK_LEN   16
#define TOK_VAL   24
#define TOK_LINE  32
#define TOK_FILE  40
#define TOK_SIZE  48

// ---- OpenFile: { cp, cend, line, name } ----
#define OF_CP   0
#define OF_CEND 8
#define OF_LINE 16
#define OF_NAME 24
#define OF_SIZE 32

uptr toktab;                          // M23: grows by doubling (arena.mc grow())
i64 tokcap = 0;
i64 ntok = 0;

uptr cp;                              // current file's cursor
uptr cend;                            // current file's end
i64  cline = 0;

// file stack: the top is the one being read; the ones below keep where they stopped
uptr fstack;
uptr fvirt;                           // M15: 1 = this level came from the bundle
i64 opencap = 0;
i64 nopen = 0;

// ---- M21: hygienic substitution, per lexer frame ----
// The entries of the frame that is ABOUT to be pushed live in slot `nopen` --
// the index the new frame will get -- so p_push_source needs no code at all to
// bind them, and lex_pop clears the slot it vacates. One slot more than the
// frame stack's capacity, because the pending slot of a full stack is index
// `opencap`; lex_push_mem re-sizes these four with fstack (M23), so they are
// always (opencap + 1) slots of MAXSUBST entries.
// sub_to == 0 marks an integer substitution, whose value is in sub_val.
uptr sub_from;
uptr sub_to;
uptr sub_val;
uptr sub_n;
uptr inclist;                         // already-included paths, in order
i64  inccap = 0;
uptr incpath;                         // M14: extra roots, in registration order
i64  incpathcap = 0;
i64  nincpath = 0;
i64 ninc = 0;

// ---- TokEnt accessors ----
uptr te_at(i64 i)   { return toktab + i * TE_SIZE; }
uptr te_text(uptr e) { return ld64(e + TE_TEXT); }
i64  te_len(uptr e)  { return ld64(e + TE_LEN); }
i64  te_word(uptr e) { return ld64(e + TE_WORD); }
i64  te_id(uptr e)   { return ld64(e + TE_ID); }
void set_te_text(uptr e, uptr v) { st64(e + TE_TEXT, v); }
void set_te_len(uptr e, i64 v)   { st64(e + TE_LEN, v); }
void set_te_word(uptr e, i64 v)  { st64(e + TE_WORD, v); }
void set_te_id(uptr e, i64 v)    { st64(e + TE_ID, v); }

// ---- Token accessors ----
i64  tok_id(uptr t)    { return ld64(t + TOK_ID); }
uptr tok_start(uptr t) { return ld64(t + TOK_START); }
i64  tok_len(uptr t)   { return ld64(t + TOK_LEN); }
i64  tok_val(uptr t)   { return ld64(t + TOK_VAL); }
i64  tok_line(uptr t)  { return ld64(t + TOK_LINE); }
uptr tok_file(uptr t)  { return ld64(t + TOK_FILE); }
void set_tok_id(uptr t, i64 v)     { st64(t + TOK_ID, v); }
void set_tok_start(uptr t, uptr v) { st64(t + TOK_START, v); }
void set_tok_len(uptr t, i64 v)    { st64(t + TOK_LEN, v); }
void set_tok_val(uptr t, i64 v)    { st64(t + TOK_VAL, v); }
void set_tok_line(uptr t, i64 v)   { st64(t + TOK_LINE, v); }
void set_tok_file(uptr t, uptr v)  { st64(t + TOK_FILE, v); }

// ---- OpenFile and include-list accessors ----
uptr of_at(i64 i)   { return fstack + i * OF_SIZE; }
uptr of_cp(uptr f)   { return ld64(f + OF_CP); }
uptr of_cend(uptr f) { return ld64(f + OF_CEND); }
i64  of_line(uptr f) { return ld64(f + OF_LINE); }
uptr of_name(uptr f) { return ld64(f + OF_NAME); }
void set_of_cp(uptr f, uptr v)   { st64(f + OF_CP, v); }
void set_of_cend(uptr f, uptr v) { st64(f + OF_CEND, v); }
void set_of_line(uptr f, i64 v)  { st64(f + OF_LINE, v); }
void set_of_name(uptr f, uptr v) { st64(f + OF_NAME, v); }

uptr inc_at(i64 i)            { return ld64(inclist + i * 8); }
void set_inc_at(i64 i, uptr v) { st64(inclist + i * 8, v); }
uptr ip_at(i64 i)             { return ld64(incpath + i * 8); }
void set_ip_at(i64 i, uptr v) { st64(incpath + i * 8, v); }

// ---- character classification ----
i64 is_alpha(i64 c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
i64 is_digit(i64 c) { return c >= '0' && c <= '9'; }
i64 is_alnum(i64 c) { return is_alpha(c) || is_digit(c); }

i64 hex_val(i64 c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// ---- token table: insertion order, ids starting at 256 ----
i64 tok_add(uptr text, i64 len) {
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        uptr e = te_at(i);
        if (te_len(e) == len && mem_eq(te_text(e), text, len)) return te_id(e);
        i = i + 1;
    }
    if (len <= 0) die("empty lexeme");
    toktab = grow(T_TOKENS, toktab, ntok, &tokcap, TE_SIZE);
    uptr ne = te_at(ntok);
    set_te_text(ne, text);
    set_te_len(ne, len);
    set_te_word(ne, is_alpha(ld8(text)));
    set_te_id(ne, 256 + ntok);
    ntok = ntok + 1;
    return 256 + ntok - 1;
}

uptr tok_text(i64 id) {
    if (id == T_IDENT) return "IDENT";
    if (id == T_INT)   return "INT";
    if (id == T_CHAR)  return "CHAR";
    if (id == T_STR)   return "STR";
    if (id == T_DIR)   return "DIR";
    if (id == T_HOLE)  return "HOLE";
    if (id == T_EOF)   return "EOF";
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        if (te_id(te_at(i)) == id) return te_text(te_at(i));
        i = i + 1;
    }
    return "?";
}

// stage0's `core[]` list is an initialized array of pointers; the core has no
// such thing, so the insertion order becomes a sequence of calls. Same
// order, same ids: K_U8 = 256 through K_ASSIGN = 298.
void tok_init() {
    tok_add("u8", 2);
    tok_add("u16", 3);
    tok_add("u32", 3);
    tok_add("u64", 3);
    tok_add("i64", 3);
    tok_add("uptr", 4);
    tok_add("void", 4);
    tok_add("if", 2);
    tok_add("else", 4);
    tok_add("loop", 4);
    tok_add("break", 5);
    tok_add("continue", 8);
    tok_add("return", 6);
    tok_add("extern", 6);
    tok_add("(", 1);
    tok_add(")", 1);
    tok_add("{", 1);
    tok_add("}", 1);
    tok_add("[", 1);
    tok_add("]", 1);
    tok_add(",", 1);
    tok_add(";", 1);
    tok_add("+", 1);
    tok_add("-", 1);
    tok_add("*", 1);
    tok_add("/", 1);
    tok_add("%", 1);
    tok_add("&", 1);
    tok_add("|", 1);
    tok_add("^", 1);
    tok_add("~", 1);
    tok_add("<<", 2);
    tok_add(">>", 2);
    tok_add("==", 2);
    tok_add("!=", 2);
    tok_add("<", 1);
    tok_add("<=", 2);
    tok_add(">", 1);
    tok_add(">=", 2);
    tok_add("&&", 2);
    tok_add("||", 2);
    tok_add("!", 1);
    tok_add("=", 1);
    tok_add(":", 1);         // only #rule uses this; at the end so as not to renumber
    tok_add("=>", 2);
    // M44: `.` exists only so that `#include <geo/geo.mc>` can be spelled. The
    // lexer does not tokenize `<name>` -- do_directive reassembles the lexemes
    // between `<` and `>` (src/parse.mc), and without this entry the `.` in a
    // file name is `unexpected character`. Appended LAST, after every lexeme
    // the frozen stage0/lex.c registers, so no existing id moves: K_U8..K_EXTERN
    // stay 256..269 and every punctuation keeps the id it had. Nothing in the
    // language uses it -- there is no member access -- so --dump-tokens is
    // unchanged for every file that has no bare `.` outside a string, a comment
    // or a number, which is every file check-lex compares.
    tok_add(".", 1);
}

// identifier: only matches word=true entries
i64 word_id(uptr s, i64 len) {
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        uptr e = te_at(i);
        if (te_word(e) && te_len(e) == len && mem_eq(te_text(e), s, len)) return te_id(e);
        i = i + 1;
    }
    return -1;
}

// punctuation/operator: longest prefix, linear and deterministic scan
i64 punct_id(uptr s, i64 avail, uptr plen) {
    i64 best = -1;
    i64 blen = 0;
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        uptr e = te_at(i);
        if (te_word(e) || te_len(e) > avail || te_len(e) <= blen) { i = i + 1; continue; }
        if (mem_eq(te_text(e), s, te_len(e))) {
            best = te_id(e);
            blen = te_len(e);
        }
        i = i + 1;
    }
    st64(plen, blen);
    return best;
}

// stage0's dir_names[]: an initialized array of pointers does not exist in the core,
// so the linear search becomes explicit comparisons — same order, same indices.
i64 dir_index(uptr s, i64 nl) {
    if (nl == 7 && mem_eq("include", s, 7)) return D_INCLUDE;
    if (nl == 6 && mem_eq("define", s, 6))  return D_DEFINE;
    if (nl == 5 && mem_eq("token", s, 5))   return D_TOKEN;
    if (nl == 5 && mem_eq("infix", s, 5))   return D_INFIX;
    if (nl == 6 && mem_eq("prefix", s, 6))  return D_PREFIX;
    if (nl == 4 && mem_eq("rule", s, 4))    return D_RULE;
    if (nl == 7 && mem_eq("section", s, 7)) return D_SECTION;
    if (nl == 6 && mem_eq("opcode", s, 6))  return D_OPCODE;
    if (nl == 5 && mem_eq("dylib", s, 5))   return D_DYLIB;
    if (nl == 5 && mem_eq("embed", s, 5))   return D_EMBED;
    return -1;
}

// ---- file stack ----
#define MAXSEG 64

// normalizes . and .. lexically (without touching the filesystem), so that two paths
// naming the same file become the same string and once-only works
uptr path_norm(uptr p) {
    i64 sb[MAXSEG];                    // start of each segment
    i64 sl[MAXSEG];                    // size of each segment
    i64 nseg = 0;
    i64 n = cstrlen(p);
    i64 i = 0;
    i64 abs = ld8(p) == '/';
    loop {
        if (i >= n) break;
        loop {
            if (i >= n) break;
            if (ld8(p + i) != '/') break;
            i = i + 1;
        }
        i64 b = i;
        loop {
            if (i >= n) break;
            if (ld8(p + i) == '/') break;
            i = i + 1;
        }
        i64 l = i - b;
        if (l == 0 || (l == 1 && ld8(p + b) == '.')) continue;
        i64 up = l == 2 && ld8(p + b) == '.' && ld8(p + b + 1) == '.';
        uptr pb = sb + (nseg - 1) * 8;     // last segment; only read if nseg > 0
        i64 prev_up = nseg && ld64(sl + (nseg - 1) * 8) == 2
                      && ld8(p + ld64(pb)) == '.' && ld8(p + ld64(pb) + 1) == '.';
        i64 drop = 0;                  // the C ternary becomes an explicit if
        if (up) {
            if (nseg) { if (!prev_up) drop = 1; }
            else if (abs) drop = 1;
        }
        if (drop) {
            if (nseg) nseg = nseg - 1;
            continue;
        }
        if (nseg == MAXSEG) die2("path with too many segments", p);
        st64(sb + nseg * 8, b);
        st64(sl + nseg * 8, l);
        nseg = nseg + 1;
    }
    uptr s = xalloc(n + 2);
    i64 w = 0;
    if (abs) { st8(s + w, '/'); w = w + 1; }
    i64 k = 0;
    loop {
        if (k >= nseg) break;
        if (k) { st8(s + w, '/'); w = w + 1; }
        i64 j = 0;
        loop {
            if (j >= ld64(sl + k * 8)) break;
            st8(s + w, ld8(p + ld64(sb + k * 8) + j));
            w = w + 1;
            j = j + 1;
        }
        k = k + 1;
    }
    if (w == 0) { st8(s + w, '.'); w = w + 1; }
    st8(s + w, 0);
    return s;
}

// joins the base directory with rel and normalizes; an absolute path ignores the base
uptr path_join(uptr base, uptr rel) {
    i64 cut = 0;
    i64 bl = cstrlen(base);
    i64 rl = cstrlen(rel);
    if (ld8(rel) == '/') bl = 0;
    i64 i = 0;
    loop {
        if (i >= bl) break;
        if (ld8(base + i) == '/') cut = i + 1;
        i = i + 1;
    }
    uptr s = xalloc(cut + rl + 1);
    i = 0;
    loop {
        if (i >= cut) break;
        st8(s + i, ld8(base + i));
        i = i + 1;
    }
    i = 0;
    loop {
        if (i >= rl) break;
        st8(s + cut + i, ld8(rel + i));
        i = i + 1;
    }
    st8(s + cut + rl, 0);
    return path_norm(s);
}

// pushes a source that is already in memory. `virt` marks the level as coming
// from the bundle, which is what tells lex_include to resolve the file's own
// relative includes by name instead of by path (M15).
void lex_push_mem(uptr name, uptr src, i64 len, i64 virt, i64 line) {
    i64 oc = opencap;
    fstack = grow(T_OPENS, fstack, nopen, &opencap, OF_SIZE);
    if (opencap != oc) {
        fvirt = grow_to(fvirt, nopen, opencap, 8);
        // M21 + M23: one slot per frame plus the pending one, copied INCLUDING
        // slot `nopen` -- the substitutions p_subst_name already left there for
        // the frame this push is about to create.
        i64 keep = nopen + 1;
        if (sub_n == 0) keep = 0;      // first allocation: nothing to preserve
        sub_n = grow_to(sub_n, keep, opencap + 1, 8);
        sub_from = grow_to(sub_from, keep * MAXSUBST, (opencap + 1) * MAXSUBST, 8);
        sub_to = grow_to(sub_to, keep * MAXSUBST, (opencap + 1) * MAXSUBST, 8);
        sub_val = grow_to(sub_val, keep * MAXSUBST, (opencap + 1) * MAXSUBST, 8);
    }
    if (nopen) {
        uptr prev = of_at(nopen - 1);
        set_of_cp(prev, cp);
        set_of_cend(prev, cend);
        set_of_line(prev, cline);
    }
    set_of_name(of_at(nopen), name);
    st64(fvirt + nopen * 8, virt);
    nopen = nopen + 1;
    cp = src;
    cend = src + len;
    cline = 1;
}

void lex_push(uptr path, i64 line) {
    i64 len = 0;
    uptr src = read_file(path, &len);
    lex_push_mem(path, src, len, 0, line);
}

void lex_pop() {
    nopen = nopen - 1;
    st64(sub_n + nopen * 8, 0);        // M21: the frame's substitutions die with it
    uptr top = of_at(nopen - 1);
    cp = of_cp(top);
    cend = of_cend(top);
    cline = of_line(top);
}

uptr lex_file() {
    if (nopen) return of_name(of_at(nopen - 1));
    return "?";
}

// ---- M15: the bundle, reached through one function pointer ----
// The lexer must not depend on src/bundle.mc: src/lexdump.mc and src/astdump.mc
// include the lexer (and the parser) without the bundle, and check-lex/check-ast
// compile them with mc0. So main.mc registers `bundle_open` here before the
// first lex_init, and everything the lexer knows about the bundle is this
// pointer. With nothing registered, every bundled include simply fails.
//
//   uptr bundle_open(uptr name, i64 base, uptr pcanon, uptr plen)
//     returns the source (NUL-terminated, cached) or 0 if the name is not
//     bundled; *pcanon receives the canonical name, *plen its length.
uptr bopen_fn = 0;

void lex_set_bundle(uptr openfn) { bopen_fn = openfn; }

// ---- M44: `<name>` is a LIBRARY, not only the bundle ----
// The amendment's A1: `<name>` stops meaning "a name the binary ships" and
// starts meaning "a library that is not in my tree" -- resolved from the lock,
// from the bundle, or from the installed copy of the compiler's own package, in
// that order (A3), and never from the working directory. Quotes are unchanged.
//
// The second pointer is registered by src/core_build.mc, exactly as the bundle's
// is registered by src/core_bundle.mc, so the lexer still depends on nothing:
// src/lexdump.mc and src/astdump.mc keep compiling with mc0.
//
//   uptr libs_open(uptr name, i64 stage, uptr pcanon, uptr plen)
//     stage 0 = the LOCK road (a package mc.lock pins), stage 1 = the installed
//     `mc` package under <libs>/mc/v<version>/. Returns the source or 0; on a
//     hit *pcanon receives the once-only key -- for a file served from disk that
//     is its normalised path, the same key lex_include would record for it.
uptr lopen_fn = 0;

void lex_set_libs(uptr openfn) { lopen_fn = openfn; }

// ---- package roots and the closure rule (A6) ----
// A file under a package root may include or #embed: its own tree (quotes),
// `<...>` names the bundle or the installed `mc` package answers, and
// `<dep/...>` for a dep the package's own lock row names. Everything else is
// refused. Roots are registered from the lock by src/deps.mc, never from a
// list a project writes.
#define RT_NAME 0            // the package name, as the lock spells it
#define RT_DIR  8            // its directory, normalised, with a trailing '/'
#define RT_SIZE 16

uptr pkg_roots = 0;
i64  npkgroot = 0;
uptr pkg_edges = 0;                   // pairs (from root, to root), two i64 each
i64  npkgedge = 0;

uptr rt_at(i64 i)   { return pkg_roots + i * RT_SIZE; }
uptr rt_name(i64 i) { return ld64(rt_at(i) + RT_NAME); }
uptr rt_dir(i64 i)  { return ld64(rt_at(i) + RT_DIR); }

// Both tables are sized ONCE and never grow: a project's dependency graph is
// known in full -- it is the lock -- before the first root is registered, so
// there is nothing to double and no growth event to report. That is M17's
// argument for MAXTARGETS with an exact count in place of a ceiling, which is
// also why neither table needs an arena tag of its own.
void lex_pkg_reserve(i64 nroots, i64 nedges) {
    pkg_roots = xalloc(nroots * RT_SIZE + RT_SIZE);
    pkg_edges = xalloc(nedges * 16 + 16);
    npkgroot = 0;
    npkgedge = 0;
}

void lex_add_root(uptr name, uptr dir) {
    st64(rt_at(npkgroot) + RT_NAME, name);
    st64(rt_at(npkgroot) + RT_DIR, dir);
    npkgroot = npkgroot + 1;
}

void lex_add_edge(i64 from, i64 to) {
    st64(pkg_edges + npkgedge * 16, from);
    st64(pkg_edges + npkgedge * 16 + 8, to);
    npkgedge = npkgedge + 1;
}

// A root is registered by NAME when the lock is read and given its DIRECTORY
// when the tree it names has been found -- vendored, installed or replaced. The
// edges are known from the lock alone, so they are complete before the first
// directory exists, and nothing resolves an include in between.
void lex_set_root_dir(i64 i, uptr dir) { st64(rt_at(i) + RT_DIR, dir); }

i64  lex_root_count()      { return npkgroot; }
uptr lex_root_name(i64 i)  { return rt_name(i); }
uptr lex_root_dir(i64 i)   { return rt_dir(i); }

// the longest registered root that is a string prefix of `path`, -1 if none.
// Longest and not first, so a package vendored inside another package's tree
// would still be attributed to itself.
i64 lex_root_of(uptr path) {
    i64 best = -1;
    i64 bl = 0;
    i64 pl = cstrlen(path);
    i64 i = 0;
    loop {
        if (i >= npkgroot) break;
        uptr d = rt_dir(i);
        if (d != 0) {                  // 0 between the lock and the resolution
            i64 n = cstrlen(d);
            if (n > bl && pl >= n && mem_eq(path, d, n)) { best = i; bl = n; }
        }
        i = i + 1;
    }
    return best;
}

// the root whose name is the first path component of `name`, -1 if none
i64 lex_root_first(uptr name) {
    i64 n = 0;
    loop {
        i64 c = ld8(name + n);
        if (c == 0 || c == '/') break;
        n = n + 1;
    }
    i64 i = 0;
    loop {
        if (i >= npkgroot) break;
        uptr r = rt_name(i);
        if (cstrlen(r) == n && mem_eq(r, name, n)) return i;
        i = i + 1;
    }
    return -1;
}

i64 lex_edge(i64 from, i64 to) {
    i64 i = 0;
    loop {
        if (i >= npkgedge) break;
        if (ld64(pkg_edges + i * 16) == from && ld64(pkg_edges + i * 16 + 8) == to) return 1;
        i = i + 1;
    }
    return 0;
}

// `from` is the file that wrote the directive: 1 when it may reach root `to`
i64 lex_may_reach(uptr from, i64 to) {
    i64 r = lex_root_of(from);
    if (r < 0) return 1;               // not inside a package: the project itself
    if (r == to) return 1;             // its own tree
    return lex_edge(r, to);
}

// `package geo reaches outside its tree: <what>`, at the offending line of the
// file that wrote the directive. One text for #include and for #embed, and for
// the quote form and the angle form: the rule is about what a package reads,
// not about how it spelled it.
void lex_pkg_refuse(uptr from, uptr what, i64 line) {
    i64 r = lex_root_of(from);
    err_at2(from, line,
            tm_cat(tm_cat("package ", rt_name(r)), " reaches outside its tree"), what);
}

// the quote form: a resolved path a file under a package root may not read
void lex_closed(uptr from, uptr path, i64 line) {
    if (npkgroot == 0) return;
    i64 r = lex_root_of(from);
    if (r < 0) return;
    if (lex_root_of(path) == r) return;
    lex_pkg_refuse(from, path, line);
}

// ---- M14: extra search roots for #include "x" ([include].paths in mc.toml) ----
// Each root is a DIRECTORY stored with a trailing '/', so path_join can treat it
// as "a file inside it" and reuse the same normalization. They are tried in the
// order they were registered, only after the includer's own directory fails --
// so a project never shadows a relative include that already resolved.
// With no root registered (every path except `mc build`) nincpath is 0 and
// lex_include does exactly what it did before, with no extra syscall.
void lex_add_include_path(uptr dir) {
    incpath = grow(T_INCPATH, incpath, nincpath, &incpathcap, 8);
    set_ip_at(nincpath, dir);
    nincpath = nincpath + 1;
}

// 1 if the file can be opened for reading.
//
// `open` returns a C `int`, so the failure is -1 in the low 32 bits and the
// bits above it are UNSPECIFIED -- the hazard M42 wrote down and M45 fixed at
// every other call site (read_file, write_file, sysroot.mc, waitpid). This one
// was left, and it is not theoretical: on the GitHub runners (glibc 2.39,
// kernel 6.17) a failing `open` hands back 0x00000000ffffffff, so `fd < 0` was
// false for a file that does not exist and this function answered "readable"
// for every missing path. The observed shape was `mc build` on a fresh tree
// dying with `mc: cannot open: .../build/.mc-usage.toml` -- lex_readable said
// the file was there, read_file (which does narrow) disagreed. c_int() is the
// narrowing.
i64 lex_readable(uptr path) {
    i64 fd = c_int(open(path, O_RDONLY, 0));
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

void lex_init(uptr path) {
    nopen = 0;
    ninc = 0;
    path = path_norm(path);
    inclist = grow(T_INCLUDES, inclist, ninc, &inccap, 8);
    set_inc_at(ninc, path);            // the root also counts for once-only
    ninc = ninc + 1;
    lex_push(path, 0);
}

// resolves rel against a GIVEN file's directory and, if that file does not
// exist, against each [include].paths root, in order. #embed uses the same
// function, so `#embed x "f"` and `#include "f"` always find the same file.
uptr lex_find_path_from(uptr file, uptr rel) {
    uptr path = path_join(file, rel);
    if (nincpath != 0 && !lex_readable(path)) {
        i64 k = 0;
        loop {
            if (k >= nincpath) break;
            uptr alt = path_join(ip_at(k), rel);
            if (lex_readable(alt)) { path = alt; break; }
            k = k + 1;
        }
    }
    return path;
}

// the same, against the file being lexed right now. #include may use it: the
// directive is handled while its own string is still the current token, so the
// top of the stack is still the includer.
uptr lex_find_path(uptr rel) { return lex_find_path_from(of_name(of_at(nopen - 1)), rel); }

// once-only: the list holds paths and bundled names in the same table, in the
// order they were first seen
i64 lex_seen(uptr key) {
    i64 i = 0;
    loop {
        if (i >= ninc) break;
        if (str_eq(inc_at(i), key)) return 1;
        i = i + 1;
    }
    return 0;
}

void lex_remember(uptr key, i64 line) {
    inclist = grow(T_INCLUDES, inclist, ninc, &inccap, 8);
    set_inc_at(ninc, key);
    ninc = ninc + 1;
}

// drops a trailing `.mc`: inside the bundle a module is `mc/lex`, not `mc/lex.mc`
uptr lex_strip_mc(uptr p) {
    i64 n = cstrlen(p);
    if (n > 3 && ld8(p + n - 3) == '.' && ld8(p + n - 2) == 'm' && ld8(p + n - 1) == 'c')
        return xstrdup(p, n - 3);
    return p;
}

// M15: pushes a bundled file. -1 = the name is not in the bundle, 0 = already
// included, 1 = pushed. `base` allows the last-component fallback, which only a
// relative include inside a bundled file may use.
i64 lex_include_bundled(uptr name, i64 base, i64 line) {
    if (bopen_fn == 0) return -1;
    u8 canon[8];
    st64(canon, 0);
    i64 len = 0;
    uptr src = callp(bopen_fn, name, base, canon, &len);
    if (src == 0) return -1;
    uptr key = ld64(canon);
    if (lex_seen(key)) return 0;
    lex_remember(key, line);
    lex_push_mem(key, src, len, 1, line);
    return 1;
}

// `#embed x "f"` written inside `file`, when `file` came from the BUNDLE. A
// bundled name ("embed_demo", "mc/core") is a name and not a directory, so
// path_join + read_file would look for a file that does not exist and report a
// misleading `cannot open`. The payload goes through the bundle exactly the way
// lex_include sends a relative `#include` there: join + normalize + drop `.mc`,
// with the last-component fallback. `file` is bundled iff the bundle serves it
// under that exact name -- the source is already inflated and cached, so the
// test costs a linear scan of the index. Returns 0 for a real path: do_embed
// then reads from the filesystem, unchanged.
uptr lex_embed_bundled(uptr file, uptr rel, uptr plen, i64 line) {
    if (bopen_fn == 0) return 0;
    u8 canon[8];
    st64(canon, 0);
    i64 flen = 0;
    if (callp(bopen_fn, file, 0, canon, &flen) == 0) return 0;
    uptr bn = lex_strip_mc(path_join(file, rel));
    uptr src = callp(bopen_fn, bn, 1, canon, plen);
    if (src == 0) err_at2(file, line, "unknown bundled include", bn);
    return src;
}

// M44: the same for a file served from DISK -- a locked package (stage 0) or
// the installed `mc` package (stage 1). The frame is NOT virtual: what came off
// the filesystem resolves its own relative includes as paths, which is what
// makes an installed <mc/core> behave exactly like src/core.mc.
i64 lex_include_libs(uptr name, i64 stage, i64 line) {
    if (lopen_fn == 0) return -1;
    u8 canon[8];
    st64(canon, 0);
    i64 len = 0;
    uptr src = callp(lopen_fn, name, stage, canon, &len);
    if (src == 0) return -1;
    uptr key = ld64(canon);
    if (lex_seen(key)) return 0;
    lex_remember(key, line);
    lex_push_mem(key, src, len, 0, line);
    return 1;
}

// M15/M44: `#include <name>`. Three steps (M44 § A3), still with no fallback to
// the working directory -- `<name>` means "a library that is not in my tree",
// and which library that is depends only on (this binary, this lock, the
// installed packages), never on where `mc` was run from.
//
//   1. the LOCK: a package mc.lock pins. Skipped when the file asking is itself
//      inside a package that did not declare this one as a dependency -- so a
//      package that includes <float> gets the bundle's, not a project's
//      override it never asked for.
//   2. the BUNDLE, unchanged. A full binary answers here for every name it
//      ships, which is what makes a project with no lock byte for byte what it
//      was before this milestone.
//   3. the installed `mc` package, reached only on a bundle miss -- which for a
//      binary that carries the blob means a name nobody ships.
//
// A trailing `.mc` is dropped first, so `<geo/geo.mc>` and `<geo/geo>` are one
// name, exactly as `<mc/core>` and a relative "core.mc" inside the bundle are.
i64 lex_include_name(uptr name, i64 line) {
    name = lex_strip_mc(name);
    i64 t = lex_root_first(name);
    uptr from = lex_file();
    i64 r = -1;
    if (t >= 0 && lex_may_reach(from, t)) r = lex_include_libs(name, 0, line);
    if (r >= 0) return r;
    r = lex_include_bundled(name, 0, line);
    if (r >= 0) return r;
    r = lex_include_libs(name, 1, line);
    if (r >= 0) return r;
    // The name IS a locked package and nothing answered: say why, instead of
    // reporting a bundled name that was never going to be there.
    if (t >= 0 && !lex_may_reach(from, t)) lex_pkg_refuse(from, name, line);
    err_at2(from, line, "unknown bundled include", name);
    return -1;
}

// #include "x": resolves rel against the current file's directory and, if that
// file does not exist, against each [include].paths root, in order; then
// pushes. 0 = already included.
// M15: inside a bundled file there is no directory to resolve against -- the
// name is joined, normalized, stripped of `.mc` and looked up in the bundle
// (with the last-component fallback). That is what makes core.mc's own
// `#include "arena.mc"` work identically from src/ and from `<mc/core>`.
i64 lex_include(uptr rel, i64 line) {
    if (nopen && ld64(fvirt + (nopen - 1) * 8)) {
        uptr bn = lex_strip_mc(path_join(of_name(of_at(nopen - 1)), rel));
        i64 r = lex_include_bundled(bn, 1, line);
        if (r >= 0) return r;
    }
    uptr from = of_name(of_at(nopen - 1));
    uptr path = lex_find_path(rel);
    lex_closed(from, path, line);      // M44: a package reads its own tree only
    if (lex_seen(path)) return 0;
    lex_remember(path, line);
    lex_push(path, line);
    return 1;
}

// M44: the once-only list, read after the parse -- that is what turns a
// package's [package].files into a real boundary instead of documentation
// (src/deps.mc, deps_check_files). It holds paths and bundled names in the
// order they were first seen; the entry point is index 0.
i64  lex_inc_count()   { return ninc; }
uptr lex_inc_at(i64 i) { return inc_at(i); }

// ---- lexer ----

void skip_space() {
    loop {
        loop {
            if (cp >= cend) break;
            i64 c = ld8(cp);
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
            if (c == '\n') cline = cline + 1;
            cp = cp + 1;
        }
        if (cp + 1 < cend && ld8(cp) == '/' && ld8(cp + 1) == '/') {
            loop {
                if (cp >= cend) break;
                if (ld8(cp) == '\n') break;
                cp = cp + 1;
            }
            continue;
        }
        if (cp + 1 < cend && ld8(cp) == '/' && ld8(cp + 1) == '*') {
            i64 open_line = cline;
            cp = cp + 2;
            loop {
                if (cp + 1 >= cend) break;
                if (ld8(cp) == '*' && ld8(cp + 1) == '/') break;
                if (ld8(cp) == '\n') cline = cline + 1;
                cp = cp + 1;
            }
            if (cp + 1 >= cend) err_at(lex_file(), open_line, "unterminated comment");
            cp = cp + 2;
            continue;
        }
        return;
    }
}

// reads one literal character, decoding escapes. \0 is forbidden in a string:
// __cstring and S_CSTRING_LITERALS, and ld merges literals at the first NUL.
i64 read_char(i64 in_str) {
    if (cp >= cend) err_at(lex_file(), cline, "unterminated literal");
    i64 c = ld8(cp);
    cp = cp + 1;
    if (c == '\n') { cline = cline + 1; return c; }
    if (c != '\\') return c;
    if (cp >= cend) err_at(lex_file(), cline, "unterminated escape");
    i64 e = ld8(cp);
    cp = cp + 1;
    if (e == 'n')  return '\n';
    if (e == 't')  return '\t';
    if (e == 'r')  return '\r';
    if (e == '0')  {
        if (in_str) err_at(lex_file(), cline, "\\0 not allowed in string");
        return 0;
    }
    if (e == '\\') return '\\';
    if (e == '\'') return '\'';
    if (e == '"')  return '"';
    err_at(lex_file(), cline, "unknown escape");
    return 0;
}

void lex_number(uptr t) {
    u64 v = 0;
    if (ld8(cp) == '0' && cp + 1 < cend && (ld8(cp + 1) == 'x' || ld8(cp + 1) == 'X')) {
        cp = cp + 2;
        if (cp >= cend || hex_val(ld8(cp)) < 0) err_at(lex_file(), cline, "invalid hexadecimal");
        loop {
            if (cp >= cend) break;
            if (hex_val(ld8(cp)) < 0) break;
            v = v * 16 + hex_val(ld8(cp));
            cp = cp + 1;
        }
    } else {
        loop {
            if (cp >= cend) break;
            if (!is_digit(ld8(cp))) break;
            v = v * 10 + (ld8(cp) - '0');
            cp = cp + 1;
        }
    }
    set_tok_id(t, T_INT);
    set_tok_val(t, v);
}

void lex_string(uptr t) {
    u8 b[BUF_SIZE];
    buf_init(b);
    cp = cp + 1;                       // opening quote
    loop {
        if (cp >= cend) break;
        if (ld8(cp) == '"') break;
        buf_u8(b, read_char(1));
    }
    if (cp >= cend) err_at(tok_file(t), tok_line(t), "unterminated string");
    cp = cp + 1;
    buf_u8(b, 0);                      // sentinel; len does not count it
    set_tok_id(t, T_STR);
    set_tok_start(t, buf_p(b));
    set_tok_len(t, buf_len(b) - 1);
}

void lex_directive(uptr t) {
    cp = cp + 1;                       // #
    uptr ns = cp;
    loop {
        if (cp >= cend) break;
        if (!is_alnum(ld8(cp))) break;
        cp = cp + 1;
    }
    i64 nl = cp - ns;
    i64 d = dir_index(ns, nl);
    if (d < 0) err_at(tok_file(t), tok_line(t), "unknown directive");
    set_tok_id(t, T_DIR);
    set_tok_val(t, d);
}

// $1 / $2 -> val = number; $name -> val = -1; $$name -> val = -2 (gensym, reserved only)
void lex_hole(uptr t) {
    cp = cp + 1;
    i64 gensym = 0;
    if (cp < cend && ld8(cp) == '$') { cp = cp + 1; gensym = 1; }
    if (cp < cend && is_digit(ld8(cp))) {
        i64 v = 0;
        loop {
            if (cp >= cend) break;
            if (!is_digit(ld8(cp))) break;
            v = v * 10 + (ld8(cp) - '0');
            cp = cp + 1;
        }
        set_tok_val(t, v);
    } else if (cp < cend && is_alpha(ld8(cp))) {
        loop {
            if (cp >= cend) break;
            if (!is_alnum(ld8(cp))) break;
            cp = cp + 1;
        }
        set_tok_val(t, -1);
    } else {
        err_at(tok_file(t), tok_line(t), "invalid hole");
    }
    if (gensym) set_tok_val(t, -2);
    set_tok_id(t, T_HOLE);
}

// ---- M21: hygienic substitution (docs/specs/M21.md, 2.5) ----
// A module registers substitutions and then pushes the source they apply to:
// the entries accumulate in the slot the next frame will occupy, the push binds
// them by construction and the pop discards them, so nested instantiations are
// independent. They are applied ONLY in lex_next's identifier branch, by exact
// lexeme -- which is what makes them unable to reach inside a string, a comment
// or part of a name (`T_tag` is one identifier and is not `T` followed by
// `_tag`). p_subst_int hands over a T_INT token, so a substituted bound folds in
// parse_dim like any other constant.
void p_subst_reset() { st64(sub_n + nopen * 8, 0); }

void subst_add(uptr from, uptr to, i64 v) {
    i64 n = ld64(sub_n + nopen * 8);
    if (n == MAXSUBST) err_at(lex_file(), cline, "too many substitutions");
    i64 k = nopen * MAXSUBST + n;
    st64(sub_from + k * 8, from);
    st64(sub_to + k * 8, to);
    st64(sub_val + k * 8, v);
    st64(sub_n + nopen * 8, n + 1);
}

// `from` becomes the name `to`, resolved through word_id: a type alias or a word
// taught by syntax/syntax_stmt arrives with the right token id, not as T_IDENT.
void p_subst_name(uptr from, uptr to) { subst_add(from, to, 0); }
// `from` becomes a T_INT token with the value `v`
void p_subst_int(uptr from, i64 v)    { subst_add(from, 0, v); }

// applies the current frame's substitutions to the identifier just lexed;
// 1 if one matched. Linear, in registration order: docs/determinism.md, rule 1.
i64 subst_apply(uptr t) {
    if (nopen == 0) return 0;
    i64 base = (nopen - 1) * MAXSUBST;
    i64 n = ld64(sub_n + (nopen - 1) * 8);
    i64 i = 0;
    loop {
        if (i >= n) break;
        uptr f = ld64(sub_from + (base + i) * 8);
        if (cstrlen(f) == tok_len(t) && mem_eq(f, tok_start(t), tok_len(t))) {
            uptr to = ld64(sub_to + (base + i) * 8);
            if (to == 0) {
                set_tok_id(t, T_INT);
                set_tok_val(t, ld64(sub_val + (base + i) * 8));
                return 1;
            }
            i64 ln = cstrlen(to);
            set_tok_start(t, to);            // the lexeme becomes the replacement
            set_tok_len(t, ln);
            i64 wid = word_id(to, ln);
            if (wid >= 0) set_tok_id(t, wid);
            else          set_tok_id(t, T_IDENT);
            return 1;
        }
        i = i + 1;
    }
    return 0;
}

void lex_next(uptr t) {
    skip_space();
    loop {                             // end of an #include
        if (cp < cend) break;
        if (nopen <= 1) break;
        lex_pop();
        skip_space();
    }
    set_tok_line(t, cline);
    set_tok_val(t, 0);
    set_tok_start(t, cp);
    set_tok_len(t, 0);
    set_tok_file(t, lex_file());
    if (cp >= cend) {
        set_tok_id(t, T_EOF);
        set_tok_start(t, "EOF");
        set_tok_len(t, 3);
        return;
    }

    if (is_digit(ld8(cp))) {
        lex_number(t);
        set_tok_len(t, cp - tok_start(t));
        return;
    }
    if (is_alpha(ld8(cp))) {
        loop {
            if (cp >= cend) break;
            if (!is_alnum(ld8(cp))) break;
            cp = cp + 1;
        }
        set_tok_len(t, cp - tok_start(t));
        if (subst_apply(t)) return;          // M21: only here, and by whole lexeme
        i64 wid = word_id(tok_start(t), tok_len(t));
        if (wid >= 0) set_tok_id(t, wid);
        else          set_tok_id(t, T_IDENT);
        return;
    }
    if (ld8(cp) == '\'') {
        cp = cp + 1;
        set_tok_val(t, read_char(0));
        if (cp >= cend || ld8(cp) != '\'') err_at(tok_file(t), tok_line(t), "unterminated char literal");
        cp = cp + 1;
        set_tok_id(t, T_CHAR);
        set_tok_len(t, cp - tok_start(t));
        return;
    }
    if (ld8(cp) == '"') { lex_string(t); return; }        // start points into the arena
    if (ld8(cp) == '#') { lex_directive(t); set_tok_len(t, cp - tok_start(t)); return; }
    if (ld8(cp) == '$') { lex_hole(t);      set_tok_len(t, cp - tok_start(t)); return; }

    i64 plen = 0;
    i64 pid = punct_id(cp, cend - cp, &plen);
    if (pid < 0) err_at(tok_file(t), tok_line(t), "unexpected character");
    cp = cp + plen;
    set_tok_len(t, plen);
    set_tok_id(t, pid);
}

// ---- dump ----
void dump_escaped(uptr s, i64 len) {
    out_str(1, "\"");
    i64 i = 0;
    loop {
        if (i >= len) break;
        i64 c = ld8(s + i);
        if (c == '\n')      out_str(1, "\\n");
        else if (c == '\t') out_str(1, "\\t");
        else if (c == '\r') out_str(1, "\\r");
        else if (c == 0)    out_str(1, "\\0");
        else if (c == '\\') out_str(1, "\\\\");
        else if (c == '"')  out_str(1, "\\\"");
        else                out_bytes(1, s + i, 1);
        i = i + 1;
    }
    out_str(1, "\"");
}

// one line per token: LINE ID TEXT (INT/CHAR print the value)
void dump_tokens() {
    u8 t[TOK_SIZE];
    loop {
        lex_next(t);
        out_num(1, tok_line(t)); out_str(1, " "); out_num(1, tok_id(t)); out_str(1, " ");
        if (tok_id(t) == T_INT || tok_id(t) == T_CHAR) out_num(1, tok_val(t));
        else if (tok_id(t) == T_STR)                   dump_escaped(tok_start(t), tok_len(t));
        else                                           out_bytes(1, tok_start(t), tok_len(t));
        out_str(1, "\n");
        if (tok_id(t) == T_EOF) return;
    }
}
