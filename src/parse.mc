// parse.mc — transliteration of stage0/parse.c: recursive descent for
// declarations/statements and table-driven Pratt for expressions. The
// infix/prefix tables are arrays in insertion order, searched linearly: that is
// what #infix/#prefix mutate. Same functions, same names, same order.
// Line and file always travel together: whoever keeps `line` keeps `fl`, otherwise
// the error for a construct that starts inside an #include cites the wrong file.
//
// No struct: each C table becomes a flat block with #define offsets +
// accessors. Layouts derived from stage0/mc.h (current C version):
//
//   C: typedef struct { int tok, prec; bool right; int tmpl; } InfixEnt;
//      INF_TOK 0  INF_PREC 8  INF_RIGHT 16  INF_TMPL 24     -> INF_SIZE 32
//   C: typedef struct { int tok, tmpl; } PrefixEnt;
//      PRF_TOK 0  PRF_TMPL 8                                -> PRF_SIZE 16
//   C: typedef struct { const char *name; i64 val; } DefEnt;
//      DE_NAME 0  DE_VAL 8                                  -> DE_SIZE 16
//   C: typedef struct { const char *name; int nparams, tmpl; } OpcEnt;
//      OE_NAME 0  OE_NP 8  OE_TMPL 16                       -> OE_SIZE 24
//   C: typedef struct { const char *seg, *sect; u32 flags, align; } SecEnt;
//      SE_SEG 0  SE_SECT 8  SE_FLAGS 16  SE_ALIGN 24        -> SE_SIZE 32
//
// Prefix names differ from the spec's (IN_*/PR_*) because IN_* is already the
// intrinsics enum in gen_arm64 and SEC_* is already Section's layout in macho.mc.
//
// C's forward declarations (parse_expr, parse_unary, parse_block) are not
// needed: the top of the .mc registers every signature before the bodies.
//
// M12 (Tier 3): parse_top and parse_stmt first consult hooks.mc's
// `syntax`/`syntax_stmt` tables and call the handler with callp; type_of_token
// falls back to `type_alias` aliases; `#dylib` registers the dylib for the
// following `extern` declarations. The API a handler uses is in the "public
// parser API" section, right before "---- top level ----".
//
// Depends on arena.mc (xalloc, xstrdup, cstrlen, str_eq, mem_eq, die),
// on lex.mc (Token, lex_next, lex_include, tok_add, ids K_*/T_*/D_*),
// on ast.mc (nodes, fold over them, err_node, type_width), on arena.mc (err_at),
// on macho.mc (sec_new and the R_* that defs_init registers as internal constants)
// and on hooks.mc (syntax_find/syntax_stmt_find/alias_find — empty tables when
// nobody has taught anything, so parsing is exactly the stage0 one).

#define MAXOPS    128
// 512, not 256: the transliteration to .mc spends ~104 #defines just on the
// offsets of the flat layouts (in C they are struct fields, zero cost), and
// src/mc.mc reaches 319 constants. stage0/parse.c has the same value.
#define MAXDEFS   512
#define MAXOPCS   64
#define MAXDYLIBS 8                   // #dylib: ordinal = index + 2 (libSystem is 1)
#define MAXEXTLIB 256                 // externs with an annotated dylib, by name
#define MAXEXTPAT 32                  // M14: [externs] patterns coming from mc.toml
// MAXSECS and MAXPARAMS live in arena.mc, as they lived in stage0/mc.h: parse.mc
// and gen_arm64.mc share both and a repeated `#define` is an error.

// ---- InfixEnt ----
#define INF_TOK   0
#define INF_PREC  8
#define INF_RIGHT 16
#define INF_TMPL  24
#define INF_SIZE  32

// ---- PrefixEnt ----
#define PRF_TOK  0
#define PRF_TMPL 8
#define PRF_SIZE 16

// ---- DefEnt: #define already folded ----
#define DE_NAME 0
#define DE_VAL  8
#define DE_SIZE 16

// ---- OpcEnt: #opcode with the parameters already swapped for N_HOLE 1 to nparams ----
#define OE_NAME 0
#define OE_NP   8
#define OE_TMPL 16
#define OE_SIZE 24

// ---- SecEnt: #section only registers; the real section is born in gen_sections ----
#define SE_SEG   0
#define SE_SECT  8
#define SE_FLAGS 16
#define SE_ALIGN 24
#define SE_SIZE  32

u8  infixes[MAXOPS * INF_SIZE];
i64 ninfix = 0;
u8  prefixes[MAXOPS * PRF_SIZE];
i64 nprefix = 0;
u8  defs[MAXDEFS * DE_SIZE];
i64 ndefs = 0;
u8  opcs[MAXOPCS * OE_SIZE];
i64 nopcs = 0;
u8  secs[MAXSECS * SE_SIZE];
i64 nsecs = 0;

// parameters of the #opcode being defined right now; outside that nparams is 0
u8  opc_params[MAXPARAMS * 8];
i64 opc_nparams = 0;
i64 cur_sect = 0;                     // current #section + 1; 0 = default section

// ---- #dylib: paths in registration order; the dylib's ordinal in the executable
// is index + 2, because libSystem always occupies 1. `cur_dylib` is the ordinal in
// effect: every `extern` declared after it falls under it, until the next #dylib.
// Linear tables, no hashing: docs/determinism.md, rule 1.
u8  dylibs[MAXDYLIBS * 8];
i64 ndylibs = 0;
i64 cur_dylib = 1;                    // 1 = /usr/lib/libSystem.B.dylib
u8  extlib_name[MAXEXTLIB * 8];
u8  extlib_ord[MAXEXTLIB * 8];
i64 nextlib = 0;
// M14: the same idea by pattern, fed by [externs] in mc.toml. Consulted only
// after the exact table, so `#dylib` in the source always wins.
u8  extpat_name[MAXEXTPAT * 8];
u8  extpat_ord[MAXEXTPAT * 8];
i64 nextpat = 0;

u8 cur[TOK_SIZE];                     // 1-token lookahead

// the unit under construction: parse_unit appends via top_add, and `syntax`
// handlers do too — that is what lets a handler produce several declarations
i64 unit_head = 0;
i64 unit_tail = 0;

// ---- table accessors ----
uptr ie_at(i64 i)     { return infixes + i * INF_SIZE; }
i64  ie_tok(uptr e)   { return ld64(e + INF_TOK); }
i64  ie_prec(uptr e)  { return ld64(e + INF_PREC); }
i64  ie_right(uptr e) { return ld64(e + INF_RIGHT); }
i64  ie_tmpl(uptr e)  { return ld64(e + INF_TMPL); }
void set_ie_tok(uptr e, i64 v)   { st64(e + INF_TOK, v); }
void set_ie_prec(uptr e, i64 v)  { st64(e + INF_PREC, v); }
void set_ie_right(uptr e, i64 v) { st64(e + INF_RIGHT, v); }
void set_ie_tmpl(uptr e, i64 v)  { st64(e + INF_TMPL, v); }

uptr pe_at(i64 i)    { return prefixes + i * PRF_SIZE; }
i64  pe_tok(uptr e)  { return ld64(e + PRF_TOK); }
i64  pe_tmpl(uptr e) { return ld64(e + PRF_TMPL); }
void set_pe_tok(uptr e, i64 v)  { st64(e + PRF_TOK, v); }
void set_pe_tmpl(uptr e, i64 v) { st64(e + PRF_TMPL, v); }

uptr de_at(i64 i)    { return defs + i * DE_SIZE; }
uptr de_name(uptr e) { return ld64(e + DE_NAME); }
i64  de_val(uptr e)  { return ld64(e + DE_VAL); }
void set_de_name(uptr e, uptr v) { st64(e + DE_NAME, v); }
void set_de_val(uptr e, i64 v)   { st64(e + DE_VAL, v); }

uptr oe_at(i64 i)    { return opcs + i * OE_SIZE; }
uptr oe_name(uptr e) { return ld64(e + OE_NAME); }
i64  oe_np(uptr e)   { return ld64(e + OE_NP); }
i64  oe_tmpl(uptr e) { return ld64(e + OE_TMPL); }
void set_oe_name(uptr e, uptr v) { st64(e + OE_NAME, v); }
void set_oe_np(uptr e, i64 v)    { st64(e + OE_NP, v); }
void set_oe_tmpl(uptr e, i64 v)  { st64(e + OE_TMPL, v); }

uptr se_at(i64 i)     { return secs + i * SE_SIZE; }
uptr se_seg(uptr e)   { return ld64(e + SE_SEG); }
uptr se_sect(uptr e)  { return ld64(e + SE_SECT); }
i64  se_flags(uptr e) { return ld64(e + SE_FLAGS); }
i64  se_align(uptr e) { return ld64(e + SE_ALIGN); }
void set_se_seg(uptr e, uptr v)   { st64(e + SE_SEG, v); }
void set_se_sect(uptr e, uptr v)  { st64(e + SE_SECT, v); }
void set_se_flags(uptr e, i64 v)  { st64(e + SE_FLAGS, v); }
void set_se_align(uptr e, i64 v)  { st64(e + SE_ALIGN, v); }

uptr op_at(i64 i)             { return ld64(opc_params + i * 8); }
void set_op_at(i64 i, uptr v) { st64(opc_params + i * 8, v); }

uptr dl_at(i64 i)             { return ld64(dylibs + i * 8); }
void set_dl_at(i64 i, uptr v) { st64(dylibs + i * 8, v); }
uptr xl_name(i64 i)             { return ld64(extlib_name + i * 8); }
void set_xl_name(i64 i, uptr v) { st64(extlib_name + i * 8, v); }
i64  xl_ord(i64 i)              { return ld64(extlib_ord + i * 8); }
void set_xl_ord(i64 i, i64 v)   { st64(extlib_ord + i * 8, v); }
uptr xp_name(i64 i)             { return ld64(extpat_name + i * 8); }
void set_xp_name(i64 i, uptr v) { st64(extpat_name + i * 8, v); }
i64  xp_ord(i64 i)              { return ld64(extpat_ord + i * 8); }
void set_xp_ord(i64 i, i64 v)   { st64(extpat_ord + i * 8, v); }

// ---- lookahead ----
void next() { lex_next(cur); }

void expect(i64 id, uptr msg) {
    if (tok_id(cur) != id) err_at(tok_file(cur), tok_line(cur), msg);
    next();
}

i64 cur_is(uptr s) {
    return tok_len(cur) == cstrlen(s) && mem_eq(tok_start(cur), s, tok_len(cur));
}

// the current token's name, copied into the arena
uptr cur_name() { return xstrdup(tok_start(cur), tok_len(cur)); }

// error for "name expected here". A Tier 3 registration (syntax/syntax_stmt/
// type_alias) reserves the word for the whole program, not just the handler's
// grammar position: if the token that arrived in the name's place is one of
// those words, the collision is the cause and it is worth saying so, instead of a
// "name expected" with no apparent relation to the module that taught the syntax.
void err_name(uptr msg) {
    if (word_is_taught(tok_id(cur)))
        err_at2(tok_file(cur), tok_line(cur),
                "name reserved by syntax/syntax_stmt/type_alias", cur_name());
    err_at(tok_file(cur), tok_line(cur), msg);
}

// ---- Pratt tables ----
i64 infix_find(i64 tok) {
    i64 i = 0;
    loop {
        if (i >= ninfix) break;
        if (ie_tok(ie_at(i)) == tok) return i;
        i = i + 1;
    }
    return -1;
}

i64 prefix_find(i64 tok) {
    i64 i = 0;
    loop {
        if (i >= nprefix) break;
        if (pe_tok(pe_at(i)) == tok) return i;
        i = i + 1;
    }
    return -1;
}

void infix_set(i64 tok, i64 prec, i64 right, i64 tmpl) {
    i64 i = infix_find(tok);
    if (i < 0) {
        if (ninfix == MAXOPS) die("infix table full");
        i = ninfix;
        ninfix = ninfix + 1;
    }
    uptr e = ie_at(i);
    set_ie_tok(e, tok);
    set_ie_prec(e, prec);
    set_ie_right(e, right);
    set_ie_tmpl(e, tmpl);
}

void prefix_set(i64 tok, i64 tmpl) {
    i64 i = prefix_find(tok);
    if (i < 0) {
        if (nprefix == MAXOPS) die("prefix table full");
        i = nprefix;
        nprefix = nprefix + 1;
    }
    uptr e = pe_at(i);
    set_pe_tok(e, tok);
    set_pe_tmpl(e, tmpl);
}

// core precedences: higher binds tighter
void ops_init() {
    infix_set(K_OROR,   1, 0, 0);
    infix_set(K_ANDAND, 2, 0, 0);
    infix_set(K_OR,     3, 0, 0);
    infix_set(K_XOR,    4, 0, 0);
    infix_set(K_AND,    5, 0, 0);
    infix_set(K_EQ,     6, 0, 0); infix_set(K_NE, 6, 0, 0);
    infix_set(K_LT,     7, 0, 0); infix_set(K_LE, 7, 0, 0);
    infix_set(K_GT,     7, 0, 0); infix_set(K_GE, 7, 0, 0);
    infix_set(K_SHL,    8, 0, 0); infix_set(K_SHR, 8, 0, 0);
    infix_set(K_ADD,    9, 0, 0); infix_set(K_SUB, 9, 0, 0);
    infix_set(K_MUL,   10, 0, 0); infix_set(K_DIV, 10, 0, 0);
    infix_set(K_MOD,   10, 0, 0);
    prefix_set(K_SUB, 0); prefix_set(K_TILDE, 0); prefix_set(K_BANG, 0);
    prefix_set(K_AND, 0);              // &x becomes N_ADDR in parse_unary
}

// ---- #define: linear table of already-folded constants ----
i64 def_find(uptr s, i64 len) {
    i64 i = 0;
    loop {
        if (i >= ndefs) break;
        uptr e = de_at(i);
        if (cstrlen(de_name(e)) == len && mem_eq(de_name(e), s, len)) return i;
        i = i + 1;
    }
    return -1;
}

void def_add(uptr name, i64 val, i64 line, uptr fl) {
    if (def_find(name, cstrlen(name)) >= 0) err_at(fl, line, "duplicate #define");
    if (ndefs == MAXDEFS) die("too many defines");
    uptr e = de_at(ndefs);
    set_de_name(e, name);
    set_de_val(e, val);
    ndefs = ndefs + 1;
}

// a #define is already constant everywhere: declaring the same name would hide the
// constant at some points in the source and not others. So it is an error
void check_def() {
    if (def_find(tok_start(cur), tok_len(cur)) >= 0)
        err_at(tok_file(cur), tok_line(cur), "name already defined by #define");
}

// reloc()'s relocation types: internal constants, they need no #include
void defs_init() {
    def_add("UNSIGNED",  R_UNSIGNED,  0, "?");
    def_add("BRANCH26",  R_BRANCH26,  0, "?");
    def_add("PAGE21",    R_PAGE21,    0, "?");
    def_add("PAGEOFF12", R_PAGEOFF12, 0, "?");
}

// ---- #section: only registers; gen_sections creates the sections in the right order ----
i64 sec_pending() { return nsecs; }

i64 sec_make(i64 i) {
    uptr e = se_at(i);
    return sec_new(se_seg(e), se_sect(e), se_flags(e), se_align(e));
}

i64 sec_ent(uptr seg, uptr sect, i64 flags, i64 align) {
    i64 i = 0;
    loop {
        if (i >= nsecs) break;
        uptr e = se_at(i);
        if (str_eq(se_seg(e), seg) && str_eq(se_sect(e), sect)) return i;
        i = i + 1;
    }
    if (nsecs == MAXSECS) die("too many sections");
    uptr ne = se_at(nsecs);
    set_se_seg(ne, seg);
    set_se_sect(ne, sect);
    set_se_flags(ne, flags);
    set_se_align(ne, align);
    nsecs = nsecs + 1;
    return nsecs - 1;
}

// ---- #dylib: one more dylib for the executable; the `.o` + `ld` ignore it ----
// Ordinal = index + 2: in Mach-O's two-level namespace 1 is always
// libSystem, which the executable backend loads regardless.
i64 dylib_count()      { return ndylibs; }
uptr dylib_path(i64 i) { return dl_at(i); }

i64 dylib_add(uptr path) {
    i64 i = 0;
    loop {
        if (i >= ndylibs) break;
        if (str_eq(dl_at(i), path)) return i + 2;
        i = i + 1;
    }
    if (ndylibs == MAXDYLIBS) die("too many dylibs");
    set_dl_at(ndylibs, path);
    ndylibs = ndylibs + 1;
    return ndylibs + 1;
}

// notes which dylib the extern `name` comes from; the last registration of the same name wins
void extern_lib_add(uptr name, i64 ord) {
    if (ord == 1) return;                      // libSystem is the default: it takes no slot
    i64 i = 0;
    loop {
        if (i >= nextlib) break;
        if (str_eq(xl_name(i), name)) { set_xl_ord(i, ord); return; }
        i = i + 1;
    }
    if (nextlib == MAXEXTLIB) die("too many externs with #dylib");
    set_xl_name(nextlib, name);
    set_xl_ord(nextlib, ord);
    nextlib = nextlib + 1;
}

// M14: [externs] in mc.toml — "sqlite3_*" = "sqlite3". The pattern is a whole
// name, or a prefix ending in '*'. Registration order decides ties: the first
// pattern that matches wins, which is the order the keys are written in.
void extern_lib_pattern_add(uptr pat, i64 ord) {
    if (nextpat == MAXEXTPAT) die("too many [externs] patterns");
    set_xp_name(nextpat, pat);
    set_xp_ord(nextpat, ord);
    nextpat = nextpat + 1;
}

// 1 if `name` matches `pat`: identical, or identical up to the '*' that closes
// the pattern. '*' anywhere but at the end is just a literal character.
i64 extern_pat_match(uptr pat, uptr name) {
    i64 i = 0;
    loop {
        i64 c = ld8(pat + i);
        if (c == '*' && ld8(pat + i + 1) == 0) return 1;
        if (c != ld8(name + i)) return 0;
        if (c == 0) return 1;
        i = i + 1;
    }
}

// dylib ordinal of an extern; the exact table (#dylib) first, then the
// [externs] patterns; 1 (libSystem) for every name neither one claims
i64 extern_lib_find(uptr name) {
    i64 i = 0;
    loop {
        if (i >= nextlib) break;
        if (str_eq(xl_name(i), name)) return xl_ord(i);
        i = i + 1;
    }
    i = 0;
    loop {
        if (i >= nextpat) break;
        if (extern_pat_match(xp_name(i), name)) return xp_ord(i);
        i = i + 1;
    }
    return 1;
}

// ---- #opcode: linear table of encoders, in definition order ----
i64 opc_find(uptr name) {
    i64 i = 0;
    loop {
        if (i >= nopcs) break;
        if (str_eq(oe_name(oe_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

// inside a #opcode's template, a parameter's name becomes a numbered N_HOLE
i64 opc_param(uptr s, i64 len) {
    i64 i = 0;
    loop {
        if (i >= opc_nparams) break;
        uptr p = op_at(i);
        if (cstrlen(p) == len && mem_eq(p, s, len)) return i + 1;
        i = i + 1;
    }
    return 0;
}

// #opcode call: the arguments become the template's holes, which is then folded
i64 opc_expand(i64 i, i64 call) {
    i64 holes[MAXPARAMS + 1];
    i64 np = oe_np(oe_at(i));
    i64 k = 0;
    i64 a = nd_a(call);
    loop {
        if (a == 0) break;
        if (k == np) err_node(call, "wrong number of arguments in #opcode");
        k = k + 1;
        st64(holes + k * 8, a);
        a = nd_next(a);
    }
    if (k != np) err_node(call, "wrong number of arguments in #opcode");
    return fold(node_copy_subst(oe_tmpl(oe_at(i)), holes, k));
}

// ---- #rule: linear table of rules, indexed by the token that opens the statement.
// No backtracking: the current token picks the rule and from there every item must
// match. NODE holes (expr/stmt/block) travel via node_copy_subst; NAME holes
// (`ident $x` and the gensym `$$t`) are swapped by pointer identity
// after the copy — that is what lets `$x` appear where the AST stores a name
// (left side of an assignment, local declaration) rather than a node.
//
//   C: enum { IT_LIT, IT_EXPR, IT_STMT, IT_BLOCK, IT_IDENT, IT_GEN };
//      typedef struct { int tok, lead, nitems, nholes, nnames, tmpl;
//                       int items[MAXITEMS]; const char *ph[MAXNAMES]; } RuleEnt;
//      RU_TOK 0  RU_LEAD 8  RU_NITEMS 16  RU_NHOLES 24  RU_NNAMES 32
//      RU_TMPL 40  RU_ITEMS 48 (16*8)  RU_PH 176 (8*8)      -> RU_SIZE 240
#define MAXRULES 32
#define MAXBIND  12               // holes cited by a rule (pattern + gensym)
#define MAXRDEPTH 64              // nesting of a rule inside a template
                                  // (MAXDEPTH is already gen_arm64.mc's expression depth)
#define MAXITEMS 16               // items in a pattern
#define MAXNAMES 8                // name holes (ident $x and $$t) in a rule

#define IT_LIT   0
#define IT_EXPR  1
#define IT_STMT  2
#define IT_BLOCK 3
#define IT_IDENT 4
#define IT_GEN   5

#define RU_TOK    0
#define RU_LEAD   8
#define RU_NITEMS 16
#define RU_NHOLES 24
#define RU_NNAMES 32
#define RU_TMPL   40
#define RU_ITEMS  48
#define RU_PH     176
#define RU_SIZE   240

u8  rules[MAXRULES * RU_SIZE];
i64 nrules = 0;
i64 gensym_n = 0;                 // $g<N> counter: deterministic, never resets
i64 rule_depth = 0;               // rules nested in a template's definition

// holes of the rule being defined right now; bnd_txt keeps the text with the $
u8  bnd_txt[MAXBIND * 8];
u8  bnd_kind[MAXBIND * 8];
u8  bnd_slot[MAXBIND * 8];
i64 nbnd = 0;
i64 rule_def = 0;                 // 1 while do_rule reads the pattern and the template
// pattern under construction: only goes to the table when the definition ends
u8  r_items[MAXITEMS * 8];
i64 r_nitems = 0;
i64 r_nholes = 0;
i64 r_nnames = 0;
i64 r_lead = 0;

uptr nt_names[] = { "lit", "expr", "stmt", "block", "ident" };

// ---- RuleEnt and the auxiliary tables' accessors ----
uptr ru_at(i64 i)      { return rules + i * RU_SIZE; }
i64  ru_tok(uptr r)    { return ld64(r + RU_TOK); }
i64  ru_lead(uptr r)   { return ld64(r + RU_LEAD); }
i64  ru_nitems(uptr r) { return ld64(r + RU_NITEMS); }
i64  ru_nholes(uptr r) { return ld64(r + RU_NHOLES); }
i64  ru_nnames(uptr r) { return ld64(r + RU_NNAMES); }
i64  ru_tmpl(uptr r)   { return ld64(r + RU_TMPL); }
void set_ru_tok(uptr r, i64 v)    { st64(r + RU_TOK, v); }
void set_ru_lead(uptr r, i64 v)   { st64(r + RU_LEAD, v); }
void set_ru_nitems(uptr r, i64 v) { st64(r + RU_NITEMS, v); }
void set_ru_nholes(uptr r, i64 v) { st64(r + RU_NHOLES, v); }
void set_ru_nnames(uptr r, i64 v) { st64(r + RU_NNAMES, v); }
void set_ru_tmpl(uptr r, i64 v)   { st64(r + RU_TMPL, v); }
i64  ru_item(uptr r, i64 k)             { return ld64(r + RU_ITEMS + k * 8); }
void set_ru_item(uptr r, i64 k, i64 v)  { st64(r + RU_ITEMS + k * 8, v); }
uptr ru_ph(uptr r, i64 j)               { return ld64(r + RU_PH + j * 8); }
void set_ru_ph(uptr r, i64 j, uptr v)   { st64(r + RU_PH + j * 8, v); }

uptr bt_at(i64 i)             { return ld64(bnd_txt + i * 8); }
void set_bt_at(i64 i, uptr v) { st64(bnd_txt + i * 8, v); }
i64  bk_at(i64 i)             { return ld64(bnd_kind + i * 8); }
void set_bk_at(i64 i, i64 v)  { st64(bnd_kind + i * 8, v); }
i64  bs_at(i64 i)             { return ld64(bnd_slot + i * 8); }
void set_bs_at(i64 i, i64 v)  { st64(bnd_slot + i * 8, v); }
i64  ri_at(i64 i)             { return ld64(r_items + i * 8); }
void set_ri_at(i64 i, i64 v)  { st64(r_items + i * 8, v); }
uptr nt_name(i64 i)           { return ld64(nt_names + i * 8); }

i64 bnd_find(uptr s, i64 len) {
    i64 i = 0;
    loop {
        if (i >= nbnd) break;
        if (cstrlen(bt_at(i)) == len && mem_eq(bt_at(i), s, len)) return i;
        i = i + 1;
    }
    return -1;
}

// registers the current token's hole ($name or $$name) and returns the index
i64 bnd_add(i64 kind, i64 slot) {
    if (nbnd == MAXBIND) die("too many holes in #rule");
    if (bnd_find(tok_start(cur), tok_len(cur)) >= 0)
        err_at(tok_file(cur), tok_line(cur), "duplicate hole in #rule");
    set_bt_at(nbnd, cur_name());
    set_bk_at(nbnd, kind);
    set_bs_at(nbnd, slot);
    nbnd = nbnd + 1;
    return nbnd - 1;
}

// reserves one more name hole (a pattern's ident or a template's gensym)
i64 name_slot() {
    if (r_nnames == MAXNAMES)
        err_at(tok_file(cur), tok_line(cur), "too many name holes in #rule");
    r_nnames = r_nnames + 1;
    return r_nnames - 1;
}

// one new name per expansion: $g1, $g2, ... in creation order. The `$`
// makes capture impossible by construction: the lexer never forms a T_IDENT with
// `$`, so no name written by the user can collide with a gensym.
uptr gensym_new() {
    u8 tmp[24];
    i64 i = 24;
    gensym_n = gensym_n + 1;
    i64 v = gensym_n;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    uptr s = xalloc(27 - i);
    st8(s, '$');
    st8(s + 1, 'g');
    i64 k = i;
    loop {
        if (k >= 24) break;
        st8(s + 2 + k - i, ld8(tmp + k));
        k = k + 1;
    }
    return s;
}

// name of the pattern's non-terminal; 0 = the current token is not one
i64 nt_kind() {
    i64 i = IT_EXPR;
    loop {
        if (i > IT_IDENT) break;
        if (cur_is(nt_name(i))) return i;
        i = i + 1;
    }
    if (cur_is("type")) err_at(tok_file(cur), tok_line(cur), "nt `type` is out of scope for M9");
    return 0;
}

// the last rule defined for the same opening token wins
i64 rule_find(i64 tok, i64 lead) {
    i64 i = nrules - 1;
    loop {
        if (i < 0) break;
        uptr r = ru_at(i);
        if (ru_tok(r) == tok && ru_lead(r) == lead) return i;
        i = i - 1;
    }
    return -1;
}

// swaps in to[j] for every name that still points at the placeholder ph[j]: this is how
// `ident $x` and `$$t` become real names in the freshly expanded copy
void name_fix(i64 n, uptr ph, uptr to, i64 nn) {
    if (n == 0) return;
    i64 j = 0;
    loop {
        if (j >= nn) break;
        if (nd_name(n) == ld64(ph + j * 8)) { set_nd_name(n, ld64(to + j * 8)); break; }
        j = j + 1;
    }
    name_fix(nd_a(n), ph, to, nn);
    name_fix(nd_b(n), ph, to, nn);
    name_fix(nd_c(n), ph, to, nn);
    name_fix(nd_d(n), ph, to, nn);
    name_fix(nd_next(n), ph, to, nn);
}

// ---- expressions ----
i64 type_of_token(i64 id) {
    if (id == K_U8)   return TY_U8;
    if (id == K_U16)  return TY_U16;
    if (id == K_U32)  return TY_U32;
    if (id == K_U64)  return TY_U64;
    if (id == K_I64)  return TY_I64;
    if (id == K_UPTR) return TY_UPTR;
    if (id == K_VOID) return TY_VOID;
    return alias_find(id);               // Tier 3: type_alias(); -1 if there is none
}

i64 parse_primary() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    if (tok_id(cur) == T_INT || tok_id(cur) == T_CHAR) {
        i64 n = node_new(N_INT, line, fl);
        set_nd_val(n, tok_val(cur));
        set_nd_type(n, TY_I64);
        next();
        return n;
    }
    if (tok_id(cur) == T_STR) {
        uptr s = cur_name();
        i64 n = node_new(N_STR, line, fl);
        set_nd_name(n, s);
        set_nd_val(n, tok_len(cur));
        set_nd_type(n, TY_UPTR);
        next();
        return n;
    }
    if (tok_id(cur) == T_IDENT) {
        i64 hi = opc_param(tok_start(cur), tok_len(cur));   // #opcode parameter: binds first
        if (hi) {
            i64 n = node_new(N_HOLE, line, fl);
            set_nd_val(n, hi);
            next();
            return n;
        }
        i64 di = def_find(tok_start(cur), tok_len(cur));
        if (di >= 0) {                       // #define comes before everything: becomes N_INT
            i64 n = node_new(N_INT, line, fl);
            set_nd_val(n, de_val(de_at(di)));
            set_nd_type(n, TY_I64);
            next();
            return n;
        }
        uptr s = cur_name();
        i64 n = node_new(N_IDENT, line, fl);
        set_nd_name(n, s);
        set_nd_type(n, TY_I64);
        next();
        return n;
    }
    if (tok_id(cur) == T_HOLE) {
        i64 b = bnd_find(tok_start(cur), tok_len(cur));   // hole bound by #rule
        if (b < 0 && tok_val(cur) == 0 - 2) {             // new $$name: template's gensym
            if (!rule_def) err_at(fl, line, "$$name only works in a #rule template");
            b = bnd_add(IT_GEN, name_slot());
        }
        if (b >= 0) {
            if (bk_at(b) == IT_IDENT || bk_at(b) == IT_GEN) {
                i64 ni = node_new(N_IDENT, line, fl);     // name hole
                set_nd_name(ni, bt_at(b));
                set_nd_type(ni, TY_I64);
                next();
                return ni;
            }
            i64 nh = node_new(N_HOLE, line, fl);
            set_nd_val(nh, bs_at(b));
            next();
            return nh;
        }
        if (tok_val(cur) < 0) err_at(fl, line, "hole $name has no rule binding it");
        i64 n = node_new(N_HOLE, line, fl);               // $1/$2 from #infix/#prefix
        set_nd_val(n, tok_val(cur));
        next();
        return n;
    }
    if (tok_id(cur) == K_LPAR) {
        next();
        i64 ty = type_of_token(tok_id(cur));
        if (ty >= 0) {                       // cast: a type word came right after (
            if (ty == TY_VOID) err_at(fl, line, "cast to void");
            next();
            expect(K_RPAR, "expected ) in cast");
            i64 e = parse_unary();
            i64 n = node_new(N_CAST, line, fl);
            set_nd_type(n, ty);
            set_nd_a(n, e);
            return n;
        }
        i64 e = parse_expr(0);
        expect(K_RPAR, "expected ) after expression");
        return e;
    }
    err_at(fl, line, "expression expected");
    return 0;
}

// a call is always by name: N_CALL keeps the name and the argument list in a
i64 parse_call(i64 callee) {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    if (nd_kind(callee) != N_IDENT) err_at(fl, line, "call by name only");
    uptr name = nd_name(callee);
    next();                                  // (
    i64 head = 0;
    i64 tail = 0;
    if (tok_id(cur) != K_RPAR) {
        loop {
            i64 a = parse_expr(0);
            if (tail) set_nd_next(tail, a); else head = a;
            tail = a;
            if (tok_id(cur) != K_COMMA) break;
            next();
        }
    }
    expect(K_RPAR, "expected ) in call");
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, name);
    set_nd_a(c, head);
    set_nd_type(c, TY_I64);
    return c;
}

i64 parse_postfix() {
    i64 n = parse_primary();
    loop {                                   // postfix: binds tighter than everything
        if (tok_id(cur) != K_LPAR) break;
        n = parse_call(n);
    }
    return n;
}

i64 parse_unary() {
    i64 i = prefix_find(tok_id(cur));
    if (i < 0) return parse_postfix();
    i64 tok = tok_id(cur);
    i64 tmpl = pe_tmpl(pe_at(i));
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    next();
    i64 operand = parse_unary();
    if (tmpl) {
        i64 holes[2];
        st64(holes, 0);
        st64(holes + 8, operand);
        return node_copy_subst(tmpl, holes, 1);
    }
    if (tok == K_AND) {                      // &name: address of a local
        if (nd_kind(operand) != N_IDENT) err_at(fl, line, "& expects a name");
        uptr name = nd_name(operand);
        i64 u = node_new(N_ADDR, line, fl);
        set_nd_name(u, name);
        set_nd_type(u, TY_UPTR);
        return u;
    }
    i64 un = node_new(N_UNARY, line, fl);
    set_nd_op(un, tok);
    set_nd_a(un, operand);
    return un;
}

i64 parse_expr(i64 minprec) {
    i64 lhs = parse_unary();
    loop {
        i64 i = infix_find(tok_id(cur));
        if (i < 0) return lhs;
        uptr e = ie_at(i);
        if (ie_prec(e) < minprec) return lhs;
        i64 tok = tok_id(cur);
        i64 prec = ie_prec(e);
        i64 tmpl = ie_tmpl(e);
        i64 right = ie_right(e);
        i64 line = tok_line(cur);
        uptr fl = tok_file(cur);
        next();
        i64 sub = prec + 1;
        if (right) sub = prec;
        i64 rhs = parse_expr(sub);
        if (tmpl) {
            i64 holes[3];
            st64(holes, 0);
            st64(holes + 8, lhs);
            st64(holes + 16, rhs);
            lhs = node_copy_subst(tmpl, holes, 2);
        } else {
            i64 b = node_new(N_BINARY, line, fl);
            set_nd_op(b, tok);
            set_nd_a(b, lhs);
            set_nd_b(b, rhs);
            lhs = b;
        }
    }
}

// ---- constant folding ----
// a and b are u64: that is what makes unsigned `/`, `%` and `>>` use udiv/lsr, the
// same as codegen does when the left operand is not i64
i64 const_bin(i64 op, i64 x, i64 y, i64 type, i64 n) {
    u64 a = x;
    u64 b = y;
    if (op == K_ADD) return a + b;
    if (op == K_SUB) return a - b;
    if (op == K_MUL) return a * b;
    if (op == K_DIV || op == K_MOD) {
        if (y == 0) err_node(n, "division by zero");
        if (type != TY_I64) {                          // mirrors udiv
            if (op == K_DIV) return a / b;
            return a % b;
        }
        if (y == 0 - 1) {                              // avoids INT64_MIN overflow
            if (op == K_DIV) return 0 - a;
            return 0;
        }
        if (op == K_DIV) return x / y;
        return x % y;
    }
    if (op == K_AND) return a & b;
    if (op == K_OR)  return a | b;
    if (op == K_XOR) return a ^ b;
    if (op == K_SHL) return a << (b & 63);
    if (op == K_SHR) {
        if (type == TY_I64) return x >> (y & 63);      // arithmetic
        return a >> (b & 63);                          // logical
    }
    if (op == K_EQ) return x == y;
    if (op == K_NE) return x != y;
    if (op == K_LT) return x <  y;
    if (op == K_LE) return x <= y;
    if (op == K_GT) return x >  y;
    if (op == K_GE) return x >= y;
    if (op == K_ANDAND) return x != 0 && y != 0;
    if (op == K_OROR)   return x != 0 || y != 0;
    err_node(n, "operator without constant folding");
    return 0;
}

// type: a literal is i64; a binary inherits the left operand's; a cast sets its own
void fold_unary(i64 n) {
    i64 a = fold(nd_a(n));
    set_nd_a(n, a);
    set_nd_type(n, nd_type(a));
    if (nd_kind(a) != N_INT) return;
    u64 v = nd_val(a);
    u64 r = 0;
    i64 op = nd_op(n);
    if (op == K_SUB)        r = 0 - v;
    else if (op == K_TILDE) r = ~v;
    else if (op == K_BANG)  { if (v) r = 0; else r = 1; }
    else return;                                   // & does not fold
    set_nd_kind(n, N_INT);
    set_nd_val(n, r);
    set_nd_op(n, 0);
    set_nd_a(n, 0);
}

void fold_binary(i64 n) {
    i64 a = fold(nd_a(n)); set_nd_a(n, a);
    i64 b = fold(nd_b(n)); set_nd_b(n, b);
    set_nd_type(n, nd_type(a));
    if (nd_kind(a) != N_INT || nd_kind(b) != N_INT) return;
    i64 r = const_bin(nd_op(n), nd_val(a), nd_val(b), nd_type(a), n);
    set_nd_kind(n, N_INT);
    set_nd_val(n, r);
    set_nd_op(n, 0);
    set_nd_a(n, 0);
    set_nd_b(n, 0);
}

void fold_cast(i64 n) {
    i64 a = fold(nd_a(n));
    set_nd_a(n, a);
    if (nd_kind(a) != N_INT) return;
    u64 v = nd_val(a);
    i64 t = nd_type(n);
    if (t == TY_U8)       v = v & 0xff;
    else if (t == TY_U16) v = v & 0xffff;
    else if (t == TY_U32) v = v & 0xffffffff;
    set_nd_kind(n, N_INT);
    set_nd_val(n, v);
    set_nd_a(n, 0);                                // type = the cast's own
}

i64 fold(i64 n) {
    if (n == 0) return 0;
    i64 k = nd_kind(n);
    if (k == N_UNARY)       fold_unary(n);
    else if (k == N_BINARY) fold_binary(n);
    else if (k == N_CAST)   fold_cast(n);
    else {
        i64 a = fold(nd_a(n)); set_nd_a(n, a);
        i64 b = fold(nd_b(n)); set_nd_b(n, b);
        i64 c = fold(nd_c(n)); set_nd_c(n, c);
        i64 d = fold(nd_d(n)); set_nd_d(n, d);
    }
    i64 nx = fold(nd_next(n));
    set_nd_next(n, nx);
    return n;
}

// ---- statements ----
// size between [ ]; returns 0 when the brackets come empty (`[]`)
i64 parse_dim(i64 line, uptr fl) {
    next();                                  // [
    i64 nel = 0;
    if (tok_id(cur) != K_RBRACK) {
        i64 e = fold(parse_expr(0));
        if (nd_kind(e) != N_INT || nd_val(e) <= 0)
            err_at(fl, line, "array size must be a positive constant");
        nel = nd_val(e);                     // the count is in i64
    }
    expect(K_RBRACK, "expected ] in the array size");
    return nel;
}

// a name in a declaration: a plain T_IDENT or, inside a #rule template,
// a name hole (`$x` bound to a pattern `ident`, or the gensym `$$t`)
uptr decl_name(uptr msg) {
    if (tok_id(cur) == T_HOLE) {
        i64 b = bnd_find(tok_start(cur), tok_len(cur));
        if (b < 0 && tok_val(cur) == 0 - 2 && rule_def) b = bnd_add(IT_GEN, name_slot());
        if (b >= 0 && (bk_at(b) == IT_IDENT || bk_at(b) == IT_GEN)) {
            uptr p = bt_at(b);
            next();
            return p;
        }
    }
    if (tok_id(cur) != T_IDENT) err_name(msg);
    check_def();
    uptr s = cur_name();
    next();
    return s;
}

// local declaration: type name = expr; | type name; | type name[CONST];
i64 parse_var(i64 line, uptr fl, i64 ty) {
    if (ty == TY_VOID) err_at(fl, line, "local of type void");
    next();                                  // type
    uptr name = decl_name("variable name expected");
    i64 nel = 0;
    i64 init = 0;
    if (tok_id(cur) == K_LBRACK) {
        nel = parse_dim(line, fl);
        if (nel < 1) err_at(fl, line, "array size must be a positive constant");
        if (nel > 4095 || nel * type_width(ty) > 4095)
            err_at(fl, line, "local array too large");
    } else if (tok_id(cur) == K_ASSIGN) {
        next();
        init = parse_expr(0);
    }
    expect(K_SEMI, "expected ; after declaration");
    i64 n = node_new(N_VAR, line, fl);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_a(n, init);
    set_nd_val(n, nel);
    return n;
}

i64 parse_stmt() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    i64 si = syntax_stmt_find(tok_id(cur));      // Tier 3: taught statement
    if (si >= 0) {
        uptr cp0 = cp;                           // lexer cursor before the handler
        uptr t0 = tok_start(cur);                // ... and the token it received
        i64 sn = callp(syntax_stmt_fn_at(si));   // the handler eats the word too
        // a handler that did not advance would return the parser to the same token and
        // would be called again, forever; here that dies with a name and position
        // instead of hanging (top level) or exhausting the arena (statement). The two
        // conditions are needed together: `cp` stops at the end of the file (the word
        // could have been the last token) and the current token becomes T_EOF, with a different start.
        if (cp == cp0 && tok_start(cur) == t0)
            err_at2(fl, line, "syntax_stmt handler consumed no tokens", cur_name());
        // 0 = the handler produced no statement; an empty block takes its place
        // without breaking the sibling list of whoever called it
        if (sn == 0) sn = node_new(N_BLOCK, line, fl);
        return sn;
    }
    i64 ri = rule_find(tok_id(cur), 0);          // does the current token open a rule?
    if (ri >= 0) return rule_expand(ri, 0);
    if (tok_id(cur) == T_HOLE) {                 // loose `$init`/`$b` in the template
        i64 b = bnd_find(tok_start(cur), tok_len(cur));
        if (b >= 0 && (bk_at(b) == IT_STMT || bk_at(b) == IT_BLOCK)) {
            i64 h = node_new(N_HOLE, line, fl);
            set_nd_val(h, bs_at(b));
            next();
            return h;
        }
    }
    if (tok_id(cur) == K_LBRACE) return parse_block();
    i64 ty = type_of_token(tok_id(cur));
    if (ty >= 0) return parse_var(line, fl, ty);
    if (tok_id(cur) == K_IF) {
        next();
        expect(K_LPAR, "expected ( after if");
        i64 c = parse_expr(0);
        expect(K_RPAR, "expected ) after condition");
        i64 t = parse_stmt();
        i64 e = 0;
        if (tok_id(cur) == K_ELSE) { next(); e = parse_stmt(); }
        i64 n = node_new(N_IF, line, fl);
        set_nd_a(n, c);
        set_nd_b(n, t);
        set_nd_c(n, e);
        return n;
    }
    if (tok_id(cur) == K_LOOP) {
        next();
        i64 b = parse_stmt();
        i64 n = node_new(N_LOOP, line, fl);
        set_nd_a(n, b);
        return n;
    }
    if (tok_id(cur) == K_BREAK) {
        next();
        i64 lv = 1;
        if (tok_id(cur) == T_INT) { lv = tok_val(cur); next(); }
        if (lv < 1) err_at(fl, line, "break expects a positive level");
        expect(K_SEMI, "expected ; after break");
        i64 n = node_new(N_BREAK, line, fl);
        set_nd_val(n, lv);
        return n;
    }
    if (tok_id(cur) == K_CONTINUE) {
        next();
        expect(K_SEMI, "expected ; after continue");
        return node_new(N_CONTINUE, line, fl);
    }
    if (tok_id(cur) == K_RETURN) {
        next();
        i64 e = 0;
        if (tok_id(cur) != K_SEMI) e = parse_expr(0);
        expect(K_SEMI, "expected ; after return");
        i64 n = node_new(N_RETURN, line, fl);
        set_nd_a(n, e);
        return n;
    }
    i64 ex = parse_expr(0);
    if (tok_id(cur) == K_ASSIGN) {           // name = expr; (= is not in the infix table)
        if (nd_kind(ex) != N_IDENT)
            err_at(fl, line, "left side of assignment must be a name");
        uptr name = nd_name(ex);
        next();
        i64 v = parse_expr(0);
        expect(K_SEMI, "expected ; after assignment");
        i64 n = node_new(N_ASSIGN, line, fl);
        set_nd_name(n, name);
        set_nd_a(n, v);
        return n;
    }
    // a rule that starts with `ident $x`: the name has already been read as an
    // expression and dispatch is still by literal token (`+=`, `++`), with no backtracking
    ri = rule_find(tok_id(cur), 1);
    if (ri >= 0) {
        if (nd_kind(ex) != N_IDENT) err_at(fl, line, "the rule expected a name on the left");
        return rule_expand(ri, ex);
    }
    expect(K_SEMI, "expected ; after expression");
    i64 st = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(st, ex);
    return st;
}

i64 parse_block() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    expect(K_LBRACE, "expected {");
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (tok_id(cur) == K_RBRACE) break;
        if (tok_id(cur) == T_EOF) err_at(fl, line, "unterminated block");
        i64 s = parse_stmt();
        if (tail) set_nd_next(tail, s); else head = s;
        tail = s;
    }
    next();
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

// matches rule ri's items against the source and returns the expanded template.
// lead != 0 is the N_IDENT that has already been read before the dispatch token.
i64 rule_expand(i64 ri, i64 lead) {
    i64 holes[MAXITEMS + 1];
    i64 to[MAXNAMES];
    uptr r = ru_at(ri);
    i64 nn = ru_nnames(r);
    rule_depth = rule_depth + 1;
    if (rule_depth > MAXRDEPTH) die("too many nested rules");
    i64 j = 0;
    loop {
        if (j >= nn) break;
        st64(to + j * 8, 0);
        j = j + 1;
    }
    if (ru_lead(r)) st64(to, nd_name(lead));
    i64 k = 0;
    loop {
        if (k >= ru_nitems(r)) break;
        i64 it = ru_item(r, k);
        i64 kd = it & 7;
        i64 v = it >> 3;
        if (kd == IT_LIT) {
            if (tok_id(cur) != v)
                err_at2(tok_file(cur), tok_line(cur), "the rule expected", tok_text(v));
            next();
        } else if (kd == IT_IDENT) {
            if (tok_id(cur) != T_IDENT)
                err_at(tok_file(cur), tok_line(cur), "the rule expected a name");
            st64(to + v * 8, cur_name());
            next();
        } else if (kd == IT_EXPR)  st64(holes + v * 8, parse_expr(0));
        else if (kd == IT_STMT)    st64(holes + v * 8, parse_stmt());
        else                       st64(holes + v * 8, parse_block());
        k = k + 1;
    }
    j = 0;
    loop {                                       // the name holes left over
        if (j >= nn) break;                      // are this expansion's $$t
        if (ld64(to + j * 8) == 0) st64(to + j * 8, gensym_new());
        j = j + 1;
    }
    i64 e = node_copy_subst(ru_tmpl(r), holes, ru_nholes(r));
    name_fix(e, r + RU_PH, to, nn);
    rule_depth = rule_depth - 1;
    return e;
}

// #rule stmt: PATTERN => TEMPLATE — the pattern is a flat sequence of literal
// tokens and `nt $name`; the template is a statement parsed here, now, with the
// $names already becoming holes. An identifier used as a literal token becomes
// a reserved keyword on the spot (tok_add).
void do_rule(i64 line, uptr fl) {
    if (tok_id(cur) != T_IDENT) err_at(fl, line, "#rule expects category stmt");
    if (cur_is("expr")) err_at(fl, line, "#rule expr: reserved, not yet supported");
    if (!cur_is("stmt")) err_at(fl, line, "#rule only knows category stmt");
    next();
    expect(K_COLON, "expected : after the #rule category");
    if (nrules == MAXRULES) err_at(fl, line, "too many rules");
    nbnd = 0;
    r_nitems = 0;
    r_nholes = 0;
    r_nnames = 0;
    r_lead = 0;
    rule_def = 1;
    if (tok_id(cur) == T_IDENT && nt_kind() == IT_IDENT) {   // `ident $x` before the token
        next();
        if (tok_id(cur) != T_HOLE || tok_val(cur) != 0 - 1)
            err_at(tok_file(cur), tok_line(cur), "expected $name in the pattern");
        bnd_add(IT_IDENT, name_slot());
        next();
        r_lead = 1;
    }
    loop {
        if (tok_id(cur) == K_ARROW) break;
        if (tok_id(cur) == T_EOF) err_at(fl, line, "#rule without =>");
        if (r_nitems == MAXITEMS) err_at(fl, line, "too many items in the #rule pattern");
        i64 k = 0;
        if (tok_id(cur) == T_IDENT) k = nt_kind();
        i64 it = 0;
        if (k) {
            next();
            if (tok_id(cur) != T_HOLE || tok_val(cur) != 0 - 1)
                err_at(tok_file(cur), tok_line(cur), "expected $name in the pattern");
            i64 slot = 0;
            if (k == IT_IDENT) slot = name_slot();
            else {
                r_nholes = r_nholes + 1;
                slot = r_nholes;
            }
            bnd_add(k, slot);
            next();
            it = k + slot * 8;
        } else {
            // cur_name, not tok_start: a token's lexeme stays stored in the
            // table and tok_text prints it as a string — it must be in the arena
            i64 id = tok_id(cur);
            if (id == T_IDENT) id = tok_add(cur_name(), tok_len(cur));
            next();
            it = IT_LIT + id * 8;
        }
        if (r_nitems == 0 && (it & 7) != IT_LIT)
            err_at(fl, line, "the #rule pattern must open with a literal token");
        set_ri_at(r_nitems, it);
        r_nitems = r_nitems + 1;
    }
    if (r_nitems == 0) err_at(fl, line, "empty #rule pattern");
    // the dispatch literal rules the statement parser: letting `if`, `loop`,
    // `return`, `i64` ... open a rule would hijack the language itself.
    // Punctuation stays free (`ident $x [ expr $i ] = expr $e ;` is legitimate).
    if ((ri_at(0) >> 3) >= K_U8 && (ri_at(0) >> 3) <= K_EXTERN)
        err_at(fl, line, "cannot redefine core keyword");
    next();                                       // =>
    i64 tmpl = parse_stmt();                      // the $names have already become holes
    rule_def = 0;
    uptr r = ru_at(nrules);
    set_ru_tok(r, ri_at(0) >> 3);
    set_ru_lead(r, r_lead);
    set_ru_nitems(r, r_nitems);
    set_ru_nholes(r, r_nholes);
    set_ru_nnames(r, r_nnames);
    set_ru_tmpl(r, tmpl);
    i64 k = 0;
    loop {
        if (k >= r_nitems) break;
        set_ru_item(r, k, ri_at(k));
        k = k + 1;
    }
    i64 i = 0;
    loop {
        if (i >= nbnd) break;
        if (bk_at(i) == IT_IDENT || bk_at(i) == IT_GEN) set_ru_ph(r, bs_at(i), bt_at(i));
        i = i + 1;
    }
    nbnd = 0;
    nrules = nrules + 1;
}

// --dump-rules: one line per rule, in definition order
void dump_rules() {
    i64 i = 0;
    loop {
        if (i >= nrules) break;
        uptr r = ru_at(i);
        out_str(1, "rule ");
        out_num(1, i);
        out_str(1, ": stmt:");
        if (ru_lead(r)) out_str(1, " ident $0");
        i64 k = 0;
        loop {
            if (k >= ru_nitems(r)) break;
            i64 it = ru_item(r, k);
            out_str(1, " ");
            if ((it & 7) == IT_LIT) out_str(1, tok_text(it >> 3));
            else {
                out_str(1, nt_name(it & 7));
                out_str(1, " $");
                out_num(1, it >> 3);
            }
            k = k + 1;
        }
        out_str(1, " => ");
        out_num(1, node_size(ru_tmpl(r)));
        out_str(1, " nodes\n");
        i = i + 1;
    }
}

// a constant from the source, already folded; used by #section's arguments
i64 const_arg(i64 line, uptr fl, uptr msg) {
    i64 e = fold(parse_expr(0));
    if (nd_kind(e) != N_INT) err_at(fl, line, msg);
    return nd_val(e);
}

// #section SEG SECT FLAGS [ALIGN] — current section for the following functions and globals.
// With no arguments it goes back to the default. ALIGN is log2 and defaults to 4
// (16 bytes) when omitted: the same alignment codegen gives __data.
void do_section(i64 line, uptr fl) {
    if (tok_id(cur) != T_IDENT) { cur_sect = 0; return; }
    uptr seg = cur_name();
    next();
    if (tok_id(cur) != T_IDENT)
        err_at(tok_file(cur), tok_line(cur), "#section expects the section name");
    uptr sect = cur_name();
    next();
    i64 flags = const_arg(line, fl, "#section expects constant flags");
    i64 align = 4;
    // only a number, a #define or a parenthesis can start the alignment:
    // none of them start a top-level declaration, so there is no ambiguity
    if (tok_id(cur) == T_INT || tok_id(cur) == T_IDENT || tok_id(cur) == K_LPAR) {
        align = const_arg(line, fl, "#section expects constant alignment");
        if (align < 0 || align > 15) err_at(fl, line, "alignment out of 0..15");
    }
    if (flags < 0 || flags > 0xffffffff) err_at(fl, line, "section flags out of 32 bits");
    cur_sect = sec_ent(seg, sect, (u32) flags, (u32) align) + 1;
}

// #opcode name(p1, ...) EXPR — registers an encoder; it is neither a symbol nor a function.
// The name of a parameter deliberately shadows a #define of the same name: inside
// the template parse_primary consults opc_param before def_find, so the
// parameter wins. That is what is wanted — the template speaks of its own
// arguments — and it only holds until the end of the definition, when opc_nparams goes back to zero.
void do_opcode(i64 line, uptr fl) {
    if (tok_id(cur) != T_IDENT) err_at(fl, line, "#opcode expects a name");
    uptr name = cur_name();
    next();
    expect(K_LPAR, "expected ( in #opcode");
    opc_nparams = 0;
    loop {
        if (tok_id(cur) == K_RPAR) break;
        if (tok_id(cur) != T_IDENT)
            err_at(tok_file(cur), tok_line(cur), "parameter name expected in #opcode");
        if (opc_nparams == MAXPARAMS)
            err_at(tok_file(cur), tok_line(cur), "at most 8 parameters in #opcode");
        set_op_at(opc_nparams, cur_name());
        opc_nparams = opc_nparams + 1;
        next();
        if (tok_id(cur) != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "expected ) in #opcode");
    i64 tmpl = parse_expr(0);                    // the parameters have already become N_HOLE
    i64 np = opc_nparams;
    opc_nparams = 0;                             // outside the definition there is no parameter
    if (opc_find(name) >= 0) err_at(fl, line, "duplicate #opcode");
    if (nopcs == MAXOPCS)    die("too many opcodes");
    uptr e = oe_at(nopcs);
    set_oe_name(e, name);
    set_oe_np(e, np);
    set_oe_tmpl(e, tmpl);
    nopcs = nopcs + 1;
}

// ---- M15: #embed name "path" [lz] ----
// Declares `u8 name[]` with the file's bytes -- or with the LZ stream, when
// `lz` is written -- plus `#define name_size` (bytes in the array) and
// `#define name_raw` (the file's original size). A program decompresses with
//
//     lz_inflate(name, name_size, buf, name_raw);
//
// The path resolves exactly like `#include "x"` (includer's directory, then
// [include].paths). The bytes become a normal global array initializer: one
// N_INT node per byte, which is what glob_place already knows how to write.
// The 16 MiB ceiling is the declared limit; well before it the arena is what
// runs out, since each byte costs one node.
#define EMBED_MAX (16 << 20)

// name + a slice of `sfx`. Two suffixes out of one string literal: the frozen
// stage0/gen_arm64.c has MAXSTRS 512 and the core is a handful of literals
// away from it, so every avoidable one is avoided. See the note in bundle.mc.
uptr p_cat(uptr name, uptr sfx, i64 off, i64 len) {
    i64 ln = cstrlen(name);
    uptr s = xalloc(ln + len + 1);             // the arena comes zeroed: NUL already there
    mem_copy(s, name, ln);
    mem_copy(s + ln, sfx + off, len);
    return s;
}

i64 do_embed(i64 line, uptr fl) {
    if (tok_id(cur) != T_IDENT) err_at(fl, line, "#embed expects NAME \"path\" [lz]");
    uptr name = cur_name();
    next();
    if (tok_id(cur) != T_STR) err_at(fl, line, "#embed expects NAME \"path\" [lz]");
    uptr rel = cur_name();
    next();
    // `lz` compared character by character, again to spend no string literal
    i64 comp = 0;
    if (tok_id(cur) == T_IDENT && tok_len(cur) == 2
        && ld8(tok_start(cur)) == 'l' && ld8(tok_start(cur) + 1) == 'z') { comp = 1; next(); }
    i64 raw = 0;
    // The base is `fl`, the file that WROTE the directive, not the top of the
    // lexer stack: the `lz` lookahead above may already have popped back to the
    // includer. And when that file came from the bundle, so does the payload.
    uptr data = lex_embed_bundled(fl, rel, &raw, line);
    if (data == 0) data = read_file(lex_find_path_from(fl, rel), &raw);
    if (raw == 0 || raw > EMBED_MAX) err_at(fl, line, "#embed file is empty or over 16 MiB");
    i64 len = raw;
    if (comp) {
        uptr d = xalloc(lz_bound(raw) + 16);
        len = lz_deflate(data, raw, d);
        data = d;
    }
    i64 head = 0;
    i64 tail = 0;
    i64 k = 0;
    loop {
        if (k >= len) break;
        i64 e = node_new(N_INT, line, fl);
        set_nd_val(e, ld8(data + k));
        set_nd_type(e, TY_I64);
        if (tail) set_nd_next(tail, e); else head = e;
        tail = e;
        k = k + 1;
    }
    i64 g = node_new(N_GLOBAL, line, fl);
    set_nd_name(g, name);
    set_nd_type(g, TY_U8);
    set_nd_a(g, head);
    set_nd_val(g, len);
    def_add(p_cat(name, "_size_raw", 0, 5), len, line, fl);
    def_add(p_cat(name, "_size_raw", 5, 4), raw, line, fl);
    return g;
}

// ---- supported directives: #include, #define, #token, #infix, #prefix,
// #rule, #section, #opcode, #dylib, #embed ----
void do_directive() {
    i64 d = tok_val(cur);
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    next();
    if (d == D_INCLUDE) {
        // M15: `#include <name>` is served by the bundle inside the binary.
        // The lexer does not tokenize `<name>` specially -- it is `<`, the
        // lexemes of the name and `>`, put back together here. That is on
        // purpose: --dump-tokens stays byte for byte what the frozen
        // stage0/lex.c produces, so check-lex keeps comparing the two.
        if (tok_id(cur) == K_LT) {
            next();
            u8 nb[BUF_SIZE];
            buf_init(nb);
            loop {
                if (tok_id(cur) == K_GT) break;
                if (tok_id(cur) == T_EOF) err_at(fl, line, "unterminated #include <name>");
                buf_put(nb, tok_start(cur), tok_len(cur));
                next();
            }
            buf_u8(nb, 0);
            lex_include_name(buf_p(nb), line);   // still on the `>`, as with the string
            next();
            return;
        }
        if (tok_id(cur) != T_STR) err_at(fl, line, "#include expects a string");
        uptr path = cur_name();
        lex_include(path, line);                 // 0 = already included: carries on
        next();                                  // already in the included file, if there was a push
        return;
    }
    if (d == D_DEFINE) {
        if (tok_id(cur) != T_IDENT) err_at(fl, line, "#define expects a name");
        uptr name = cur_name();
        next();
        i64 e = fold(parse_expr(0));
        if (nd_kind(e) != N_INT) err_at(fl, line, "#define expects a constant expression");
        def_add(name, nd_val(e), line, fl);
        return;
    }
    if (d == D_TOKEN) {
        if (tok_id(cur) != T_STR) err_at(fl, line, "#token expects a string");
        tok_add(tok_start(cur), tok_len(cur));   // bytes stay in the arena
        next();
        return;
    }
    if (d == D_INFIX || d == D_PREFIX) {
        if (tok_id(cur) != T_STR) err_at(fl, line, "directive expects a string");
        i64 tok = tok_add(tok_start(cur), tok_len(cur));
        next();
        i64 prec = 0;
        i64 right = 0;
        if (d == D_INFIX) {
            if (tok_id(cur) != T_INT)
                err_at(tok_file(cur), tok_line(cur), "#infix expects the precedence");
            if (tok_val(cur) < 1 || tok_val(cur) > 100)
                err_at(tok_file(cur), tok_line(cur), "precedence out of 1..100");
            prec = tok_val(cur);
            next();
            if (tok_id(cur) != T_IDENT)
                err_at(tok_file(cur), tok_line(cur), "#infix expects left or right");
            if (cur_is("right")) right = 1;
            else if (!cur_is("left"))
                err_at(tok_file(cur), tok_line(cur), "#infix expects left or right");
            next();
        }
        i64 tmpl = parse_expr(0);                    // $1/$2 become N_HOLE
        if (d == D_INFIX) infix_set(tok, prec, right, tmpl);
        else              prefix_set(tok, tmpl);
        return;
    }
    if (d == D_DYLIB) {
        if (tok_id(cur) != T_STR) err_at(fl, line, "#dylib expects a string");
        uptr path = cur_name();
        next();
        // an empty string goes back to the default: this is how a module that declared
        // externs from another dylib avoids contaminating whatever gets included next
        if (ld8(path) == 0) cur_dylib = 1;
        else                cur_dylib = dylib_add(path);
        return;
    }
    if (d == D_EMBED)   { top_add(do_embed(line, fl)); return; }
    if (d == D_RULE)    { do_rule(line, fl);    return; }
    if (d == D_SECTION) { do_section(line, fl); return; }
    if (d == D_OPCODE)  { do_opcode(line, fl);  return; }
    err_at(fl, line, "directive not yet supported");
}

// ---- public parser API (Tier 3) ----
// What a `syntax`/`syntax_stmt` handler can use. These are fixed names: a
// module that teaches syntax (examples/api/oop.mc, lib/user_syntax_demo.mc) only
// depends on this, on ast.mc's `node_new`/`nd_*`/`set_nd_*`, and on the four
// descent functions that already existed — parse_expr(0), parse_stmt(),
// parse_block() and parse_params(). None of this is new machinery: it is the
// lookahead and the routines the core itself uses, under a stable name. See docs/surface.md.
i64  p_id()   { return tok_id(cur); }        // current token's id
i64  p_val()  { return tok_val(cur); }       // value (T_INT/T_CHAR/T_DIR/T_HOLE)
uptr p_name() { return cur_name(); }         // current lexeme, copied into the arena
i64  p_line() { return tok_line(cur); }
uptr p_file() { return tok_file(cur); }
void p_next() { next(); }
void p_expect(i64 id, uptr msg) { expect(id, msg); }

// consumes the token if it is `id`; 1 if it consumed, 0 if not
i64 p_accept(i64 id) {
    if (tok_id(cur) != id) return 0;
    next();
    return 1;
}

// requires an identifier (that is not the name of a #define), returns it and advances
uptr p_ident() {
    if (tok_id(cur) != T_IDENT) err_at(tok_file(cur), tok_line(cur), "name expected");
    check_def();
    uptr s = cur_name();
    next();
    return s;
}

// requires a type word — from the core or registered by type_alias — and advances
i64 p_type() {
    i64 ty = type_of_token(tok_id(cur));
    if (ty < 0) err_at(tok_file(cur), tok_line(cur), "type expected");
    next();
    return ty;
}

// a loose N_PARAM, for a handler that needs to prepend `self` to a list
i64 param_new(i64 ty, uptr name) {
    i64 p = node_new(N_PARAM, tok_line(cur), tok_file(cur));
    set_nd_type(p, ty);
    set_nd_name(p, name);
    return p;
}

// appends `n` to the end of list `head` (via nd_next) and returns the head
i64 list_append(i64 head, i64 n) {
    if (head == 0) return n;
    i64 t = head;
    loop {
        if (nd_next(t) == 0) break;
        t = nd_next(t);
    }
    set_nd_next(t, n);
    return head;
}

// appends a top-level declaration (or a list of them) to the unit, in the order it
// arrives, already tagged with the #section in effect. This is how a `syntax`
// handler delivers what it produced — parse_top returns 0 in that case.
void top_add(i64 n) {
    if (n == 0) return;
    if (unit_tail) set_nd_next(unit_tail, n); else unit_head = n;
    loop {
        set_nd_sect(n, cur_sect);
        unit_tail = n;
        n = nd_next(n);
        if (n == 0) break;
    }
}

// ---- top level ----
// reads the block of a function whose type, name and parameters the caller has
// already assembled (a handler may have prepended `self` to the list) and returns the
// N_FUNC. The line is the `{`'s; parse_top corrects it to the type's, where the declaration starts.
i64 parse_function(i64 ty, uptr name, i64 params) {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    i64 body = parse_block();
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    set_nd_b(f, body);
    return f;
}

// parameter list, parentheses included; none of them go through the stack
i64 parse_params() {
    expect(K_LPAR, "expected ( in the parameter list");
    i64 head = 0;
    i64 tail = 0;
    i64 n = 0;
    loop {
        if (tok_id(cur) == K_RPAR) break;
        i64 line = tok_line(cur);
        uptr fl = tok_file(cur);
        i64 pty = type_of_token(tok_id(cur));
        if (pty < 0)        err_at(fl, line, "type expected in parameter");
        if (pty == TY_VOID) err_at(fl, line, "parameter of type void");
        next();
        if (tok_id(cur) != T_IDENT) err_name("parameter name expected");
        check_def();
        uptr pname = cur_name();
        next();
        i64 p = node_new(N_PARAM, line, fl);
        set_nd_type(p, pty);
        set_nd_name(p, pname);
        if (tail) set_nd_next(tail, p); else head = p;
        tail = p;
        n = n + 1;
        if (n > MAXPARAMS) err_at(fl, line, "at most 8 parameters");
        if (tok_id(cur) != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "expected ) in the parameter list");
    return head;
}

// extern type name(params); — undefined symbol, resolved by ld
i64 parse_extern() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    next();                                  // extern
    i64 ty = type_of_token(tok_id(cur));
    if (ty < 0) err_at(tok_file(cur), tok_line(cur), "type expected in extern");
    next();
    if (tok_id(cur) != T_IDENT) err_at(tok_file(cur), tok_line(cur), "name expected in extern");
    check_def();
    uptr name = cur_name();
    next();
    i64 params = parse_params();
    expect(K_SEMI, "expected ; after extern");
    extern_lib_add(name, cur_dylib);         // #dylib in effect (1 = libSystem)
    i64 f = node_new(N_EXTERN, line, fl);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    return f;
}

// global array initializer: { c1, c2, ... }, each element a constant or,
// for uptr, a string literal. Returns the list and the count in pn
i64 parse_initlist(i64 line, uptr fl, i64 ty, uptr pn) {
    expect(K_LBRACE, "expected { in the array initializer");
    i64 head = 0;
    i64 tail = 0;
    i64 k = 0;
    loop {
        if (tok_id(cur) == K_RBRACE) break;
        i64 e = fold(parse_expr(0));
        if (nd_kind(e) == N_STR) {
            if (ty != TY_UPTR) err_node(e, "a string only initializes uptr");
        } else if (nd_kind(e) != N_INT) err_node(e, "initializer must be constant");
        if (tail) set_nd_next(tail, e); else head = e;
        tail = e;
        k = k + 1;
        if (tok_id(cur) != K_COMMA) break;
        next();
    }
    expect(K_RBRACE, "expected } in the array initializer");
    if (k == 0) err_at(fl, line, "empty array initializer");
    st64(pn, k);
    return head;
}

// global: type name[N] = { ... }; | type name = CONST; | type name; | type name[CONST];
i64 parse_global(i64 line, uptr fl, i64 ty, uptr name) {
    if (ty == TY_VOID) err_at(fl, line, "global of type void");
    i64 nel = 0;
    i64 count = 0;
    i64 init = 0;
    i64 arr = tok_id(cur) == K_LBRACK;
    if (arr) nel = parse_dim(line, fl);
    if (tok_id(cur) == K_ASSIGN) {
        next();
        if (arr) {
            init = parse_initlist(line, fl, ty, &count);
            if (nel == 0) nel = count;                   // [] = { ... }: N comes from the list
            if (count > nel) err_at(fl, line, "initializer with too many elements");
        } else {
            init = fold(parse_expr(0));
            if (nd_kind(init) != N_INT)
                err_at(fl, line, "global initializer must be constant");
        }
    }
    if (arr && nel <= 0) err_at(fl, line, "array size must be a positive constant");
    if (nel > (1 << 30) / type_width(ty)) err_at(fl, line, "global array too large");
    expect(K_SEMI, "expected ; after the global");
    i64 n = node_new(N_GLOBAL, line, fl);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_a(n, init);
    set_nd_val(n, nel);
    return n;
}

// top level: only the ( after the name separates a function from a global; ; in the body's place is a prototype
i64 parse_top() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    i64 si = syntax_find(tok_id(cur));       // Tier 3: taught top-level declaration
    if (si >= 0) {
        uptr cp0 = cp;                       // lexer cursor before the handler
        uptr t0 = tok_start(cur);            // ... and the token it received
        callp(syntax_fn_at(si));             // the handler eats the word and calls top_add
        if (cp == cp0 && tok_start(cur) == t0)   // did not advance: parse_unit would call again
            err_at2(fl, line, "syntax handler consumed no tokens", cur_name());
        return 0;
    }
    i64 ty = type_of_token(tok_id(cur));
    if (ty < 0) err_at(fl, line, "type expected at top level");
    next();
    if (tok_id(cur) != T_IDENT) err_name("name expected at top level");
    check_def();
    uptr name = cur_name();
    next();
    if (tok_id(cur) != K_LPAR) return parse_global(line, fl, ty, name);
    i64 params = parse_params();
    if (tok_id(cur) == K_SEMI) {
        next();
        i64 p = node_new(N_PROTO, line, fl);
        set_nd_name(p, name);
        set_nd_type(p, ty);
        set_nd_a(p, params);
        return p;
    }
    i64 f = parse_function(ty, name, params);
    set_nd_line(f, line);                    // the declaration starts at the type, not the {
    set_nd_file(f, fl);
    return f;
}

i64 parse_unit() {
    ops_init();
    defs_init();
    next();
    unit_head = 0;
    unit_tail = 0;
    loop {
        if (tok_id(cur) == T_EOF) break;
        if (tok_id(cur) == T_DIR) { do_directive(); continue; }
        if (tok_id(cur) == K_EXTERN) top_add(parse_extern());
        else                         top_add(parse_top());
    }
    return unit_head;
}
