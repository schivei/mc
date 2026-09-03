// parse.mc — transliteracao de stage0/parse.c: descida recursiva para
// declaracoes/statements e Pratt dirigido por tabela para expressoes. As tabelas
// infix/prefix sao arrays em ordem de insercao, buscados linearmente: e o que
// #infix/#prefix mutam. Mesmas funcoes, mesmos nomes, mesma ordem.
// Linha e arquivo andam sempre juntos: quem guarda `line` guarda `fl`, senao o
// erro de um construto que comeca dentro de um #include cita o arquivo errado.
//
// Sem struct: cada tabela do C vira um bloco plano com offsets #define +
// acessoras. Layouts derivados de stage0/mc.h (versao atual do C):
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
// Nomes de prefixo diferentes dos da spec (IN_*/PR_*) porque IN_* ja e o enum de
// intrinsics do gen_arm64 e SEC_* ja e o layout de Section em macho.mc.
//
// As declaracoes adiantadas do C (parse_expr, parse_unary, parse_block) nao sao
// necessarias: o topo do .mc registra todas as assinaturas antes dos corpos.
//
// Depende de arena.mc (xalloc, xstrdup, cstrlen, str_eq, mem_eq, die),
// de lex.mc (Token, lex_next, lex_include, tok_add, ids K_*/T_*/D_*),
// de ast.mc (nos, fold sobre eles, err_node, type_width), de arena.mc (err_at) e de
// macho.mc (sec_new e os R_* que defs_init registra como constantes internas).

#define MAXOPS    128
// 512 e nao 256: a transliteracao para .mc gasta ~104 #define so com os
// offsets dos layouts planos (em C sao campos de struct, custo zero), e
// src/mc.mc chega a 319 constantes. stage0/parse.c tem o mesmo valor.
#define MAXDEFS   512
#define MAXOPCS   64
// MAXSECS e MAXPARAMS vivem em arena.mc, como viviam em stage0/mc.h: parse.mc e
// gen_arm64.mc compartilham os dois e `#define` repetido e erro.

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

// ---- DefEnt: #define ja dobrado ----
#define DE_NAME 0
#define DE_VAL  8
#define DE_SIZE 16

// ---- OpcEnt: #opcode com os parametros ja trocados por N_HOLE de 1 a nparams ----
#define OE_NAME 0
#define OE_NP   8
#define OE_TMPL 16
#define OE_SIZE 24

// ---- SecEnt: #section so registra; a secao real nasce em gen_sections ----
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

// parametros do #opcode sendo definido agora; fora disso nparams e 0
u8  opc_params[MAXPARAMS * 8];
i64 opc_nparams = 0;
i64 cur_sect = 0;                     // #section corrente + 1; 0 = secao default

u8 cur[TOK_SIZE];                     // lookahead de 1 token

// ---- acessoras das tabelas ----
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

// ---- lookahead ----
void next() { lex_next(cur); }

void expect(i64 id, uptr msg) {
    if (tok_id(cur) != id) err_at(tok_file(cur), tok_line(cur), msg);
    next();
}

i64 cur_is(uptr s) {
    return tok_len(cur) == cstrlen(s) && mem_eq(tok_start(cur), s, tok_len(cur));
}

// o nome do token corrente, copiado para a arena
uptr cur_name() { return xstrdup(tok_start(cur), tok_len(cur)); }

// ---- tabelas Pratt ----
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
        if (ninfix == MAXOPS) die("tabela infix cheia");
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
        if (nprefix == MAXOPS) die("tabela prefix cheia");
        i = nprefix;
        nprefix = nprefix + 1;
    }
    uptr e = pe_at(i);
    set_pe_tok(e, tok);
    set_pe_tmpl(e, tmpl);
}

// precedencias do nucleo: maior liga mais forte
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
    prefix_set(K_AND, 0);              // &x vira N_ADDR em parse_unary
}

// ---- #define: tabela linear de constantes ja dobradas ----
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
    if (def_find(name, cstrlen(name)) >= 0) err_at(fl, line, "#define repetido");
    if (ndefs == MAXDEFS) die("defines demais");
    uptr e = de_at(ndefs);
    set_de_name(e, name);
    set_de_val(e, val);
    ndefs = ndefs + 1;
}

// um #define ja e constante em toda parte: declarar o mesmo nome esconderia a
// constante em alguns pontos do fonte e nao em outros. Erro, entao
void check_def() {
    if (def_find(tok_start(cur), tok_len(cur)) >= 0)
        err_at(tok_file(cur), tok_line(cur), "nome ja definido por #define");
}

// tipos de relocacao de reloc(): constantes internas, nao precisam de #include
void defs_init() {
    def_add("UNSIGNED",  R_UNSIGNED,  0, "?");
    def_add("BRANCH26",  R_BRANCH26,  0, "?");
    def_add("PAGE21",    R_PAGE21,    0, "?");
    def_add("PAGEOFF12", R_PAGEOFF12, 0, "?");
}

// ---- #section: so registra; gen_sections cria as secoes na ordem certa ----
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
    if (nsecs == MAXSECS) die("secoes demais");
    uptr ne = se_at(nsecs);
    set_se_seg(ne, seg);
    set_se_sect(ne, sect);
    set_se_flags(ne, flags);
    set_se_align(ne, align);
    nsecs = nsecs + 1;
    return nsecs - 1;
}

// ---- #opcode: tabela linear de encoders, na ordem de definicao ----
i64 opc_find(uptr name) {
    i64 i = 0;
    loop {
        if (i >= nopcs) break;
        if (str_eq(oe_name(oe_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

// dentro do template de um #opcode, o nome de um parametro vira N_HOLE numerado
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

// chamada de #opcode: os argumentos viram os buracos do template, que e dobrado
i64 opc_expand(i64 i, i64 call) {
    i64 holes[MAXPARAMS + 1];
    i64 np = oe_np(oe_at(i));
    i64 k = 0;
    i64 a = nd_a(call);
    loop {
        if (a == 0) break;
        if (k == np) err_node(call, "numero de argumentos errado no #opcode");
        k = k + 1;
        st64(holes + k * 8, a);
        a = nd_next(a);
    }
    if (k != np) err_node(call, "numero de argumentos errado no #opcode");
    return fold(node_copy_subst(oe_tmpl(oe_at(i)), holes, k));
}

// ---- #rule: tabela linear de regras, indexada pelo token que abre o statement.
// Nada de backtracking: o token corrente escolhe a regra e dali cada item tem de
// casar. Buracos de NO (expr/stmt/block) viajam por node_copy_subst; buracos de
// NOME (`ident $x` e o gensym `$$t`) sao trocados por identidade de ponteiro
// depois da copia — e o que permite `$x` aparecer onde a AST guarda um nome
// (esquerda de atribuicao, declaracao de local) e nao um no.
//
//   C: enum { IT_LIT, IT_EXPR, IT_STMT, IT_BLOCK, IT_IDENT, IT_GEN };
//      typedef struct { int tok, lead, nitems, nholes, nnames, tmpl;
//                       int items[MAXITEMS]; const char *ph[MAXNAMES]; } RuleEnt;
//      RU_TOK 0  RU_LEAD 8  RU_NITEMS 16  RU_NHOLES 24  RU_NNAMES 32
//      RU_TMPL 40  RU_ITEMS 48 (16*8)  RU_PH 176 (8*8)      -> RU_SIZE 240
#define MAXRULES 32
#define MAXBIND  12               // buracos citados por uma regra (padrao + gensym)
#define MAXRDEPTH 64              // aninhamento de regra dentro de um template
                                  // (MAXDEPTH ja e a profundidade de expressao em gen_arm64.mc)
#define MAXITEMS 16               // itens de um padrao
#define MAXNAMES 8                // buracos de nome (ident $x e $$t) de uma regra

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
i64 gensym_n = 0;                 // contador de $g<N>: determinista, nunca reinicia
i64 rule_depth = 0;               // regras aninhadas na definicao de um template

// buracos da regra sendo definida agora; bnd_txt guarda o texto com o $
u8  bnd_txt[MAXBIND * 8];
u8  bnd_kind[MAXBIND * 8];
u8  bnd_slot[MAXBIND * 8];
i64 nbnd = 0;
i64 rule_def = 0;                 // 1 enquanto do_rule le o padrao e o template
// padrao em construcao: so vai para a tabela quando a definicao termina
u8  r_items[MAXITEMS * 8];
i64 r_nitems = 0;
i64 r_nholes = 0;
i64 r_nnames = 0;
i64 r_lead = 0;

uptr nt_names[] = { "lit", "expr", "stmt", "block", "ident" };

// ---- acessoras de RuleEnt e das tabelas auxiliares ----
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

// registra o buraco do token corrente ($nome ou $$nome) e devolve o indice
i64 bnd_add(i64 kind, i64 slot) {
    if (nbnd == MAXBIND) die("buracos demais em #rule");
    if (bnd_find(tok_start(cur), tok_len(cur)) >= 0)
        err_at(tok_file(cur), tok_line(cur), "buraco repetido em #rule");
    set_bt_at(nbnd, cur_name());
    set_bk_at(nbnd, kind);
    set_bs_at(nbnd, slot);
    nbnd = nbnd + 1;
    return nbnd - 1;
}

// reserva mais um buraco de nome (ident do padrao ou gensym do template)
i64 name_slot() {
    if (r_nnames == MAXNAMES)
        err_at(tok_file(cur), tok_line(cur), "buracos de nome demais em #rule");
    r_nnames = r_nnames + 1;
    return r_nnames - 1;
}

// um nome novo por expansao: $g1, $g2, ... na ordem em que sao criados. O `$`
// torna a captura impossivel por construcao: o lexer nunca forma um T_IDENT com
// `$`, entao nenhum nome escrito pelo usuario pode colidir com um gensym.
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

// nome de nao-terminal no padrao; 0 = o token corrente nao e um
i64 nt_kind() {
    i64 i = IT_EXPR;
    loop {
        if (i > IT_IDENT) break;
        if (cur_is(nt_name(i))) return i;
        i = i + 1;
    }
    if (cur_is("type")) err_at(tok_file(cur), tok_line(cur), "nt `type` fora do escopo do M9");
    return 0;
}

// a ultima regra definida para o mesmo token de abertura vence
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

// troca por to[j] todo nome que ainda aponta para o placeholder ph[j]: e assim
// que `ident $x` e `$$t` viram nomes de verdade na copia recem-expandida
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

// ---- expressoes ----
i64 type_of_token(i64 id) {
    if (id == K_U8)   return TY_U8;
    if (id == K_U16)  return TY_U16;
    if (id == K_U32)  return TY_U32;
    if (id == K_U64)  return TY_U64;
    if (id == K_I64)  return TY_I64;
    if (id == K_UPTR) return TY_UPTR;
    if (id == K_VOID) return TY_VOID;
    return -1;
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
        i64 hi = opc_param(tok_start(cur), tok_len(cur));   // parametro de #opcode: liga primeiro
        if (hi) {
            i64 n = node_new(N_HOLE, line, fl);
            set_nd_val(n, hi);
            next();
            return n;
        }
        i64 di = def_find(tok_start(cur), tok_len(cur));
        if (di >= 0) {                       // #define vem antes de tudo: vira N_INT
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
        i64 b = bnd_find(tok_start(cur), tok_len(cur));   // buraco ligado por #rule
        if (b < 0 && tok_val(cur) == 0 - 2) {             // $$nome novo: gensym do template
            if (!rule_def) err_at(fl, line, "$$nome so vale no template de #rule");
            b = bnd_add(IT_GEN, name_slot());
        }
        if (b >= 0) {
            if (bk_at(b) == IT_IDENT || bk_at(b) == IT_GEN) {
                i64 ni = node_new(N_IDENT, line, fl);     // buraco de nome
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
        if (tok_val(cur) < 0) err_at(fl, line, "buraco $nome sem regra que o ligue");
        i64 n = node_new(N_HOLE, line, fl);               // $1/$2 do #infix/#prefix
        set_nd_val(n, tok_val(cur));
        next();
        return n;
    }
    if (tok_id(cur) == K_LPAR) {
        next();
        i64 ty = type_of_token(tok_id(cur));
        if (ty >= 0) {                       // cast: apos ( veio palavra de tipo
            if (ty == TY_VOID) err_at(fl, line, "cast para void");
            next();
            expect(K_RPAR, "esperado ) no cast");
            i64 e = parse_unary();
            i64 n = node_new(N_CAST, line, fl);
            set_nd_type(n, ty);
            set_nd_a(n, e);
            return n;
        }
        i64 e = parse_expr(0);
        expect(K_RPAR, "esperado ) apos expressao");
        return e;
    }
    err_at(fl, line, "expressao esperada");
    return 0;
}

// chamada e sempre por nome: N_CALL guarda o nome e a lista de argumentos em a
i64 parse_call(i64 callee) {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    if (nd_kind(callee) != N_IDENT) err_at(fl, line, "chamada so por nome");
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
    expect(K_RPAR, "esperado ) na chamada");
    i64 c = node_new(N_CALL, line, fl);
    set_nd_name(c, name);
    set_nd_a(c, head);
    set_nd_type(c, TY_I64);
    return c;
}

i64 parse_postfix() {
    i64 n = parse_primary();
    loop {                                   // pos-fixo: liga mais forte que tudo
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
    if (tok == K_AND) {                      // &nome: endereco de um local
        if (nd_kind(operand) != N_IDENT) err_at(fl, line, "& espera um nome");
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

// ---- dobra de constantes ----
// a e b sao u64: e o que faz `/`, `%` e `>>` sem sinal usarem udiv/lsr, como o
// codegen faz quando o operando esquerdo nao e i64
i64 const_bin(i64 op, i64 x, i64 y, i64 type, i64 n) {
    u64 a = x;
    u64 b = y;
    if (op == K_ADD) return a + b;
    if (op == K_SUB) return a - b;
    if (op == K_MUL) return a * b;
    if (op == K_DIV || op == K_MOD) {
        if (y == 0) err_node(n, "divisao por zero");
        if (type != TY_I64) {                          // espelha udiv
            if (op == K_DIV) return a / b;
            return a % b;
        }
        if (y == 0 - 1) {                              // evita overflow de INT64_MIN
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
        if (type == TY_I64) return x >> (y & 63);      // aritmetico
        return a >> (b & 63);                          // logico
    }
    if (op == K_EQ) return x == y;
    if (op == K_NE) return x != y;
    if (op == K_LT) return x <  y;
    if (op == K_LE) return x <= y;
    if (op == K_GT) return x >  y;
    if (op == K_GE) return x >= y;
    if (op == K_ANDAND) return x != 0 && y != 0;
    if (op == K_OROR)   return x != 0 || y != 0;
    err_node(n, "operador sem dobra de constante");
    return 0;
}

// tipo: literal e i64; binario herda o do operando esquerdo; cast define o seu
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
    else return;                                   // & nao dobra
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
    set_nd_a(n, 0);                                // type = o do cast
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
// tamanho entre [ ]; devolve 0 quando os colchetes vem vazios (`[]`)
i64 parse_dim(i64 line, uptr fl) {
    next();                                  // [
    i64 nel = 0;
    if (tok_id(cur) != K_RBRACK) {
        i64 e = fold(parse_expr(0));
        if (nd_kind(e) != N_INT || nd_val(e) <= 0)
            err_at(fl, line, "tamanho de array deve ser constante positiva");
        nel = nd_val(e);                     // a conta e em i64
    }
    expect(K_RBRACK, "esperado ] no tamanho do array");
    return nel;
}

// nome numa declaracao: um T_IDENT normal ou, dentro de um template de #rule,
// um buraco de nome (`$x` ligado a um `ident` do padrao, ou o gensym `$$t`)
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
    if (tok_id(cur) != T_IDENT) err_at(tok_file(cur), tok_line(cur), msg);
    check_def();
    uptr s = cur_name();
    next();
    return s;
}

// declaracao de local: tipo nome = expr; | tipo nome; | tipo nome[CONST];
i64 parse_var(i64 line, uptr fl, i64 ty) {
    if (ty == TY_VOID) err_at(fl, line, "local de tipo void");
    next();                                  // tipo
    uptr name = decl_name("nome de variavel esperado");
    i64 nel = 0;
    i64 init = 0;
    if (tok_id(cur) == K_LBRACK) {
        nel = parse_dim(line, fl);
        if (nel < 1) err_at(fl, line, "tamanho de array deve ser constante positiva");
        if (nel > 4095 || nel * type_width(ty) > 4095)
            err_at(fl, line, "array local grande demais");
    } else if (tok_id(cur) == K_ASSIGN) {
        next();
        init = parse_expr(0);
    }
    expect(K_SEMI, "esperado ; apos declaracao");
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
    i64 ri = rule_find(tok_id(cur), 0);          // o token corrente abre uma regra?
    if (ri >= 0) return rule_expand(ri, 0);
    if (tok_id(cur) == T_HOLE) {                 // `$init`/`$b` soltos no template
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
        expect(K_LPAR, "esperado ( apos if");
        i64 c = parse_expr(0);
        expect(K_RPAR, "esperado ) apos a condicao");
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
        if (lv < 1) err_at(fl, line, "break espera um nivel positivo");
        expect(K_SEMI, "esperado ; apos break");
        i64 n = node_new(N_BREAK, line, fl);
        set_nd_val(n, lv);
        return n;
    }
    if (tok_id(cur) == K_CONTINUE) {
        next();
        expect(K_SEMI, "esperado ; apos continue");
        return node_new(N_CONTINUE, line, fl);
    }
    if (tok_id(cur) == K_RETURN) {
        next();
        i64 e = 0;
        if (tok_id(cur) != K_SEMI) e = parse_expr(0);
        expect(K_SEMI, "esperado ; apos return");
        i64 n = node_new(N_RETURN, line, fl);
        set_nd_a(n, e);
        return n;
    }
    i64 ex = parse_expr(0);
    if (tok_id(cur) == K_ASSIGN) {           // nome = expr; (o = nao esta na tabela infix)
        if (nd_kind(ex) != N_IDENT)
            err_at(fl, line, "lado esquerdo da atribuicao deve ser um nome");
        uptr name = nd_name(ex);
        next();
        i64 v = parse_expr(0);
        expect(K_SEMI, "esperado ; apos atribuicao");
        i64 n = node_new(N_ASSIGN, line, fl);
        set_nd_name(n, name);
        set_nd_a(n, v);
        return n;
    }
    // regra que comeca por `ident $x`: o nome ja foi lido como expressao e o
    // despacho continua sendo por token literal (`+=`, `++`), sem backtracking
    ri = rule_find(tok_id(cur), 1);
    if (ri >= 0) {
        if (nd_kind(ex) != N_IDENT) err_at(fl, line, "a regra esperava um nome a esquerda");
        return rule_expand(ri, ex);
    }
    expect(K_SEMI, "esperado ; apos expressao");
    i64 st = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(st, ex);
    return st;
}

i64 parse_block() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    expect(K_LBRACE, "esperado {");
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (tok_id(cur) == K_RBRACE) break;
        if (tok_id(cur) == T_EOF) err_at(fl, line, "bloco nao terminado");
        i64 s = parse_stmt();
        if (tail) set_nd_next(tail, s); else head = s;
        tail = s;
    }
    next();
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

// casa os itens da regra ri contra o fonte e devolve o template expandido.
// lead != 0 e o N_IDENT que ja foi lido antes do token de despacho.
i64 rule_expand(i64 ri, i64 lead) {
    i64 holes[MAXITEMS + 1];
    i64 to[MAXNAMES];
    uptr r = ru_at(ri);
    i64 nn = ru_nnames(r);
    rule_depth = rule_depth + 1;
    if (rule_depth > MAXRDEPTH) die("regras aninhadas demais");
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
                err_at2(tok_file(cur), tok_line(cur), "a regra esperava", tok_text(v));
            next();
        } else if (kd == IT_IDENT) {
            if (tok_id(cur) != T_IDENT)
                err_at(tok_file(cur), tok_line(cur), "a regra esperava um nome");
            st64(to + v * 8, cur_name());
            next();
        } else if (kd == IT_EXPR)  st64(holes + v * 8, parse_expr(0));
        else if (kd == IT_STMT)    st64(holes + v * 8, parse_stmt());
        else                       st64(holes + v * 8, parse_block());
        k = k + 1;
    }
    j = 0;
    loop {                                       // os buracos de nome que sobraram
        if (j >= nn) break;                      // sao os $$t desta expansao
        if (ld64(to + j * 8) == 0) st64(to + j * 8, gensym_new());
        j = j + 1;
    }
    i64 e = node_copy_subst(ru_tmpl(r), holes, ru_nholes(r));
    name_fix(e, r + RU_PH, to, nn);
    rule_depth = rule_depth - 1;
    return e;
}

// #rule stmt: PADRAO => TEMPLATE — o padrao e uma sequencia plana de tokens
// literais e `nt $nome`; o template e um statement parseado aqui, agora, com os
// $nome ja virando buracos. Um identificador usado como token literal vira
// palavra-chave reservada na hora (tok_add).
void do_rule(i64 line, uptr fl) {
    if (tok_id(cur) != T_IDENT) err_at(fl, line, "#rule espera a categoria stmt");
    if (cur_is("expr")) err_at(fl, line, "#rule expr: reservado, ainda nao suportado");
    if (!cur_is("stmt")) err_at(fl, line, "#rule so conhece a categoria stmt");
    next();
    expect(K_COLON, "esperado : apos a categoria do #rule");
    if (nrules == MAXRULES) err_at(fl, line, "regras demais");
    nbnd = 0;
    r_nitems = 0;
    r_nholes = 0;
    r_nnames = 0;
    r_lead = 0;
    rule_def = 1;
    if (tok_id(cur) == T_IDENT && nt_kind() == IT_IDENT) {   // `ident $x` antes do token
        next();
        if (tok_id(cur) != T_HOLE || tok_val(cur) != 0 - 1)
            err_at(tok_file(cur), tok_line(cur), "esperado $nome no padrao");
        bnd_add(IT_IDENT, name_slot());
        next();
        r_lead = 1;
    }
    loop {
        if (tok_id(cur) == K_ARROW) break;
        if (tok_id(cur) == T_EOF) err_at(fl, line, "#rule sem =>");
        if (r_nitems == MAXITEMS) err_at(fl, line, "itens demais no padrao do #rule");
        i64 k = 0;
        if (tok_id(cur) == T_IDENT) k = nt_kind();
        i64 it = 0;
        if (k) {
            next();
            if (tok_id(cur) != T_HOLE || tok_val(cur) != 0 - 1)
                err_at(tok_file(cur), tok_line(cur), "esperado $nome no padrao");
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
            // cur_name e nao tok_start: o lexema de um token fica guardado na
            // tabela e tok_text o imprime como string — tem de estar na arena
            i64 id = tok_id(cur);
            if (id == T_IDENT) id = tok_add(cur_name(), tok_len(cur));
            next();
            it = IT_LIT + id * 8;
        }
        if (r_nitems == 0 && (it & 7) != IT_LIT)
            err_at(fl, line, "o padrao do #rule tem de abrir por um token literal");
        set_ri_at(r_nitems, it);
        r_nitems = r_nitems + 1;
    }
    if (r_nitems == 0) err_at(fl, line, "padrao de #rule vazio");
    // o literal de despacho manda no parser de statements: deixar `if`, `loop`,
    // `return`, `i64` ... abrirem uma regra sequestraria a propria linguagem.
    // Pontuacao continua livre (`ident $x [ expr $i ] = expr $e ;` e legitimo).
    if ((ri_at(0) >> 3) >= K_U8 && (ri_at(0) >> 3) <= K_EXTERN)
        err_at(fl, line, "nao pode redefinir palavra-chave do nucleo");
    next();                                       // =>
    i64 tmpl = parse_stmt();                      // os $nome ja viraram buracos
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

// --dump-rules: uma linha por regra, na ordem de definicao
void dump_rules() {
    i64 i = 0;
    loop {
        if (i >= nrules) break;
        uptr r = ru_at(i);
        out_str(1, "regra ");
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
        out_str(1, " nos\n");
        i = i + 1;
    }
}

// uma constante do fonte, ja dobrada; usada pelos argumentos de #section
i64 const_arg(i64 line, uptr fl, uptr msg) {
    i64 e = fold(parse_expr(0));
    if (nd_kind(e) != N_INT) err_at(fl, line, msg);
    return nd_val(e);
}

// #section SEG SECT FLAGS [ALIGN] — secao corrente das funcoes e globais seguintes.
// Sem argumentos volta ao default. ALIGN e log2 e vale 4 (16 bytes) quando
// omitido: mesmo alinhamento que o codegen da a __data.
void do_section(i64 line, uptr fl) {
    if (tok_id(cur) != T_IDENT) { cur_sect = 0; return; }
    uptr seg = cur_name();
    next();
    if (tok_id(cur) != T_IDENT)
        err_at(tok_file(cur), tok_line(cur), "#section espera o nome da secao");
    uptr sect = cur_name();
    next();
    i64 flags = const_arg(line, fl, "#section espera flags constantes");
    i64 align = 4;
    // so um numero, um #define ou um parentese podem comecar o alinhamento:
    // nenhum deles comeca uma declaracao de topo, entao nao ha ambiguidade
    if (tok_id(cur) == T_INT || tok_id(cur) == T_IDENT || tok_id(cur) == K_LPAR) {
        align = const_arg(line, fl, "#section espera alinhamento constante");
        if (align < 0 || align > 15) err_at(fl, line, "alinhamento fora de 0..15");
    }
    if (flags < 0 || flags > 0xffffffff) err_at(fl, line, "flags de secao fora de 32 bits");
    cur_sect = sec_ent(seg, sect, (u32) flags, (u32) align) + 1;
}

// #opcode nome(p1, ...) EXPR — registra um encoder; nao e simbolo nem funcao.
// O nome de um parametro sombreia de proposito um #define de mesmo nome: dentro
// do template parse_primary consulta opc_param antes de def_find, entao o
// parametro ganha. E o que se quer — o template fala dos seus proprios
// argumentos — e vale so ate o fim da definicao, quando opc_nparams volta a zero.
void do_opcode(i64 line, uptr fl) {
    if (tok_id(cur) != T_IDENT) err_at(fl, line, "#opcode espera um nome");
    uptr name = cur_name();
    next();
    expect(K_LPAR, "esperado ( no #opcode");
    opc_nparams = 0;
    loop {
        if (tok_id(cur) == K_RPAR) break;
        if (tok_id(cur) != T_IDENT)
            err_at(tok_file(cur), tok_line(cur), "nome de parametro esperado no #opcode");
        if (opc_nparams == MAXPARAMS)
            err_at(tok_file(cur), tok_line(cur), "no maximo 8 parametros no #opcode");
        set_op_at(opc_nparams, cur_name());
        opc_nparams = opc_nparams + 1;
        next();
        if (tok_id(cur) != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "esperado ) no #opcode");
    i64 tmpl = parse_expr(0);                    // os parametros ja viraram N_HOLE
    i64 np = opc_nparams;
    opc_nparams = 0;                             // fora da definicao nao ha parametro
    if (opc_find(name) >= 0) err_at(fl, line, "#opcode repetido");
    if (nopcs == MAXOPCS)    die("opcodes demais");
    uptr e = oe_at(nopcs);
    set_oe_name(e, name);
    set_oe_np(e, np);
    set_oe_tmpl(e, tmpl);
    nopcs = nopcs + 1;
}

// ---- diretivas suportadas: #include, #define, #token, #infix, #prefix,
// #rule, #section, #opcode ----
void do_directive() {
    i64 d = tok_val(cur);
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    next();
    if (d == D_INCLUDE) {
        if (tok_id(cur) != T_STR) err_at(fl, line, "#include espera uma string");
        uptr path = cur_name();
        lex_include(path, line);                 // 0 = ja incluido: segue em frente
        next();                                  // ja no arquivo incluido, se houve push
        return;
    }
    if (d == D_DEFINE) {
        if (tok_id(cur) != T_IDENT) err_at(fl, line, "#define espera um nome");
        uptr name = cur_name();
        next();
        i64 e = fold(parse_expr(0));
        if (nd_kind(e) != N_INT) err_at(fl, line, "#define espera uma expressao constante");
        def_add(name, nd_val(e), line, fl);
        return;
    }
    if (d == D_TOKEN) {
        if (tok_id(cur) != T_STR) err_at(fl, line, "#token espera uma string");
        tok_add(tok_start(cur), tok_len(cur));   // bytes ficam na arena
        next();
        return;
    }
    if (d == D_INFIX || d == D_PREFIX) {
        if (tok_id(cur) != T_STR) err_at(fl, line, "diretiva espera uma string");
        i64 tok = tok_add(tok_start(cur), tok_len(cur));
        next();
        i64 prec = 0;
        i64 right = 0;
        if (d == D_INFIX) {
            if (tok_id(cur) != T_INT)
                err_at(tok_file(cur), tok_line(cur), "#infix espera a precedencia");
            if (tok_val(cur) < 1 || tok_val(cur) > 100)
                err_at(tok_file(cur), tok_line(cur), "precedencia fora de 1..100");
            prec = tok_val(cur);
            next();
            if (tok_id(cur) != T_IDENT)
                err_at(tok_file(cur), tok_line(cur), "#infix espera left ou right");
            if (cur_is("right")) right = 1;
            else if (!cur_is("left"))
                err_at(tok_file(cur), tok_line(cur), "#infix espera left ou right");
            next();
        }
        i64 tmpl = parse_expr(0);                    // $1/$2 viram N_HOLE
        if (d == D_INFIX) infix_set(tok, prec, right, tmpl);
        else              prefix_set(tok, tmpl);
        return;
    }
    if (d == D_RULE)    { do_rule(line, fl);    return; }
    if (d == D_SECTION) { do_section(line, fl); return; }
    if (d == D_OPCODE)  { do_opcode(line, fl);  return; }
    err_at(fl, line, "diretiva ainda nao suportada");
}

// ---- topo ----
// lista de parametros, ja com os parenteses; nenhum passa pela pilha
i64 parse_params() {
    expect(K_LPAR, "esperado ( na lista de parametros");
    i64 head = 0;
    i64 tail = 0;
    i64 n = 0;
    loop {
        if (tok_id(cur) == K_RPAR) break;
        i64 line = tok_line(cur);
        uptr fl = tok_file(cur);
        i64 pty = type_of_token(tok_id(cur));
        if (pty < 0)        err_at(fl, line, "tipo esperado no parametro");
        if (pty == TY_VOID) err_at(fl, line, "parametro de tipo void");
        next();
        if (tok_id(cur) != T_IDENT)
            err_at(tok_file(cur), tok_line(cur), "nome de parametro esperado");
        check_def();
        uptr pname = cur_name();
        next();
        i64 p = node_new(N_PARAM, line, fl);
        set_nd_type(p, pty);
        set_nd_name(p, pname);
        if (tail) set_nd_next(tail, p); else head = p;
        tail = p;
        n = n + 1;
        if (n > MAXPARAMS) err_at(fl, line, "no maximo 8 parametros");
        if (tok_id(cur) != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "esperado ) na lista de parametros");
    return head;
}

// extern tipo nome(params); — simbolo indefinido, resolvido pelo ld
i64 parse_extern() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    next();                                  // extern
    i64 ty = type_of_token(tok_id(cur));
    if (ty < 0) err_at(tok_file(cur), tok_line(cur), "tipo esperado no extern");
    next();
    if (tok_id(cur) != T_IDENT) err_at(tok_file(cur), tok_line(cur), "nome esperado no extern");
    check_def();
    uptr name = cur_name();
    next();
    i64 params = parse_params();
    expect(K_SEMI, "esperado ; apos extern");
    i64 f = node_new(N_EXTERN, line, fl);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    return f;
}

// inicializador de array global: { c1, c2, ... }, cada elemento uma constante ou,
// para uptr, um literal de string. Devolve a lista e conta em pn
i64 parse_initlist(i64 line, uptr fl, i64 ty, uptr pn) {
    expect(K_LBRACE, "esperado { no inicializador do array");
    i64 head = 0;
    i64 tail = 0;
    i64 k = 0;
    loop {
        if (tok_id(cur) == K_RBRACE) break;
        i64 e = fold(parse_expr(0));
        if (nd_kind(e) == N_STR) {
            if (ty != TY_UPTR) err_node(e, "string so inicializa uptr");
        } else if (nd_kind(e) != N_INT) err_node(e, "inicializador deve ser constante");
        if (tail) set_nd_next(tail, e); else head = e;
        tail = e;
        k = k + 1;
        if (tok_id(cur) != K_COMMA) break;
        next();
    }
    expect(K_RBRACE, "esperado } no inicializador do array");
    if (k == 0) err_at(fl, line, "inicializador de array vazio");
    st64(pn, k);
    return head;
}

// global: tipo nome[N] = { ... }; | tipo nome = CONST; | tipo nome; | tipo nome[CONST];
i64 parse_global(i64 line, uptr fl, i64 ty, uptr name) {
    if (ty == TY_VOID) err_at(fl, line, "global de tipo void");
    i64 nel = 0;
    i64 count = 0;
    i64 init = 0;
    i64 arr = tok_id(cur) == K_LBRACK;
    if (arr) nel = parse_dim(line, fl);
    if (tok_id(cur) == K_ASSIGN) {
        next();
        if (arr) {
            init = parse_initlist(line, fl, ty, &count);
            if (nel == 0) nel = count;                   // [] = { ... }: N vem da lista
            if (count > nel) err_at(fl, line, "inicializador com elementos demais");
        } else {
            init = fold(parse_expr(0));
            if (nd_kind(init) != N_INT)
                err_at(fl, line, "inicializador de global deve ser constante");
        }
    }
    if (arr && nel <= 0) err_at(fl, line, "tamanho de array deve ser constante positiva");
    if (nel > (1 << 30) / type_width(ty)) err_at(fl, line, "array global grande demais");
    expect(K_SEMI, "esperado ; apos a global");
    i64 n = node_new(N_GLOBAL, line, fl);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_a(n, init);
    set_nd_val(n, nel);
    return n;
}

// topo: so o ( depois do nome separa funcao de global; ; no lugar do corpo e prototipo
i64 parse_top() {
    i64 line = tok_line(cur);
    uptr fl = tok_file(cur);
    i64 ty = type_of_token(tok_id(cur));
    if (ty < 0) err_at(fl, line, "tipo esperado no topo");
    next();
    if (tok_id(cur) != T_IDENT) err_at(tok_file(cur), tok_line(cur), "nome esperado no topo");
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
    i64 body = parse_block();
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    set_nd_b(f, body);
    return f;
}

i64 parse_unit() {
    ops_init();
    defs_init();
    next();
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (tok_id(cur) == T_EOF) break;
        if (tok_id(cur) == T_DIR) { do_directive(); continue; }
        i64 f = 0;
        if (tok_id(cur) == K_EXTERN) f = parse_extern();
        else                         f = parse_top();
        set_nd_sect(f, cur_sect);                // placement do #section em vigor
        if (tail) set_nd_next(tail, f); else head = f;
        tail = f;
    }
    return head;
}
