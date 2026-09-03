/* parse.c — descida recursiva para declaracoes/statements e Pratt dirigido por
 * tabela para expressoes. As tabelas infix/prefix sao arrays em ordem de
 * insercao, buscados linearmente: e o que #infix/#prefix mutam.
 * Linha e arquivo andam sempre juntos: quem guarda `line` guarda `fl`, senao o
 * erro de um construto que comeca dentro de um #include cita o arquivo errado. */
#include "mc.h"

#define MAXOPS 128
/* 512 e nao 256: a transliteracao para .mc gasta ~104 #define so com os
 * offsets dos layouts planos (em C sao campos de struct, custo zero), e
 * src/mc.mc chega a 319 constantes. src/parse.mc tem o mesmo valor. */
#define MAXDEFS 512
#define MAXOPCS 64

static InfixEnt  infixes[MAXOPS];  static int ninfix;
static PrefixEnt prefixes[MAXOPS]; static int nprefix;
static DefEnt    defs[MAXDEFS];    static int ndefs;
static OpcEnt    opcs[MAXOPCS];    static int nopcs;
static SecEnt    secs[MAXSECS];    static int nsecs;

/* parametros do #opcode sendo definido agora; fora disso nparams e 0 */
static const char *opc_params[MAXPARAMS]; static int opc_nparams;
static int cur_sect;               /* #section corrente + 1; 0 = secao default */

static Token cur;                  /* lookahead de 1 token */
static void next(void) { lex_next(&cur); }
static void expect(int id, const char *msg) {
    if (cur.id != id) err_at(cur.file, cur.line, msg);
    next();
}
static bool cur_is(const char *s) {
    return cur.len == (int)cstrlen(s) && mem_eq(cur.start, s, (size_t)cur.len);
}
/* o nome do token corrente, copiado para a arena */
static const char *cur_name(void) { return xstrdup((const char *)cur.start, (size_t)cur.len); }

/* ---- tabelas Pratt ---- */
static int infix_find(int tok) {
    for (int i = 0; i < ninfix; i++) if (infixes[i].tok == tok) return i;
    return -1;
}
static int prefix_find(int tok) {
    for (int i = 0; i < nprefix; i++) if (prefixes[i].tok == tok) return i;
    return -1;
}
static void infix_set(int tok, int prec, bool right, int tmpl) {
    int i = infix_find(tok);
    if (i < 0) {
        if (ninfix == MAXOPS) die("tabela infix cheia");
        i = ninfix++;
    }
    infixes[i].tok = tok; infixes[i].prec = prec;
    infixes[i].right = right; infixes[i].tmpl = tmpl;
}
static void prefix_set(int tok, int tmpl) {
    int i = prefix_find(tok);
    if (i < 0) {
        if (nprefix == MAXOPS) die("tabela prefix cheia");
        i = nprefix++;
    }
    prefixes[i].tok = tok; prefixes[i].tmpl = tmpl;
}

/* precedencias do nucleo: maior liga mais forte */
static void ops_init(void) {
    infix_set(K_OROR,   1, false, 0);
    infix_set(K_ANDAND, 2, false, 0);
    infix_set(K_OR,     3, false, 0);
    infix_set(K_XOR,    4, false, 0);
    infix_set(K_AND,    5, false, 0);
    infix_set(K_EQ,     6, false, 0); infix_set(K_NE, 6, false, 0);
    infix_set(K_LT,     7, false, 0); infix_set(K_LE, 7, false, 0);
    infix_set(K_GT,     7, false, 0); infix_set(K_GE, 7, false, 0);
    infix_set(K_SHL,    8, false, 0); infix_set(K_SHR, 8, false, 0);
    infix_set(K_ADD,    9, false, 0); infix_set(K_SUB, 9, false, 0);
    infix_set(K_MUL,   10, false, 0); infix_set(K_DIV, 10, false, 0);
    infix_set(K_MOD,   10, false, 0);
    prefix_set(K_SUB, 0); prefix_set(K_TILDE, 0); prefix_set(K_BANG, 0);
    prefix_set(K_AND, 0);              /* &x vira N_ADDR em parse_unary */
}

/* ---- #define: tabela linear de constantes ja dobradas ---- */
static int def_find(const char *s, int len) {
    for (int i = 0; i < ndefs; i++)
        if ((int)cstrlen(defs[i].name) == len && mem_eq(defs[i].name, s, (size_t)len)) return i;
    return -1;
}
static void def_add(const char *name, i64 val, int line, const char *fl) {
    if (def_find(name, (int)cstrlen(name)) >= 0) err_at(fl, line, "#define repetido");
    if (ndefs == MAXDEFS) die("defines demais");
    defs[ndefs].name = name; defs[ndefs].val = val;
    ndefs++;
}
/* um #define ja e constante em toda parte: declarar o mesmo nome esconderia a
 * constante em alguns pontos do fonte e nao em outros. Erro, entao */
static void check_def(void) {
    if (def_find((const char *)cur.start, cur.len) >= 0)
        err_at(cur.file, cur.line, "nome ja definido por #define");
}
/* tipos de relocacao de reloc(): constantes internas, nao precisam de #include */
static void defs_init(void) {
    def_add("UNSIGNED",  R_UNSIGNED,  0, "?");
    def_add("BRANCH26",  R_BRANCH26,  0, "?");
    def_add("PAGE21",    R_PAGE21,    0, "?");
    def_add("PAGEOFF12", R_PAGEOFF12, 0, "?");
}

/* ---- #section: so registra; gen_sections cria as secoes na ordem certa ---- */
int sec_pending(void) { return nsecs; }
int sec_make(int i) { return sec_new(secs[i].seg, secs[i].sect, secs[i].flags, secs[i].align); }
static int sec_ent(const char *seg, const char *sect, u32 flags, u32 align) {
    for (int i = 0; i < nsecs; i++)
        if (str_eq(secs[i].seg, seg) && str_eq(secs[i].sect, sect)) return i;
    if (nsecs == MAXSECS) die("secoes demais");
    secs[nsecs].seg = seg; secs[nsecs].sect = sect;
    secs[nsecs].flags = flags; secs[nsecs].align = align;
    return nsecs++;
}

/* ---- #opcode: tabela linear de encoders, na ordem de definicao ---- */
int opc_find(const char *name) {
    for (int i = 0; i < nopcs; i++) if (str_eq(opcs[i].name, name)) return i;
    return -1;
}
/* dentro do template de um #opcode, o nome de um parametro vira N_HOLE numerado */
static int opc_param(const u8 *s, int len) {
    for (int i = 0; i < opc_nparams; i++)
        if ((int)cstrlen(opc_params[i]) == len && mem_eq(opc_params[i], s, (size_t)len)) return i + 1;
    return 0;
}
/* chamada de #opcode: os argumentos viram os buracos do template, que e dobrado */
int opc_expand(int i, int call) {
    int holes[MAXPARAMS + 1];
    int k = 0;
    for (int a = nodes[call].a; a; a = nodes[a].next) {
        if (k == opcs[i].nparams) err_node(call, "numero de argumentos errado no #opcode");
        holes[++k] = a;
    }
    if (k != opcs[i].nparams) err_node(call, "numero de argumentos errado no #opcode");
    return fold(node_copy_subst(opcs[i].tmpl, holes, k));
}

/* ---- #rule: tabela linear de regras, indexada pelo token que abre o statement.
 * Nada de backtracking: o token corrente escolhe a regra e dali cada item tem de
 * casar. Buracos de NO (expr/stmt/block) viajam por node_copy_subst; buracos de
 * NOME (`ident $x` e o gensym `$$t`) sao trocados por identidade de ponteiro
 * depois da copia — e o que permite `$x` aparecer onde a AST guarda um nome
 * (esquerda de atribuicao, declaracao de local) e nao um no. ---- */
#define MAXRULES 32
#define MAXBIND  12               /* buracos citados por uma regra (padrao + gensym) */
#define MAXRDEPTH 64              /* aninhamento de regra num template (MAXDEPTH em
                                   * gen_arm64.c ja e a profundidade de expressao) */

static RuleEnt rules[MAXRULES]; static int nrules;
static int gensym_n;              /* contador de __g<N>: determinista, nunca reinicia */
static int rule_depth;            /* regras aninhadas na definicao de um template */

/* buracos da regra sendo definida agora; bnd_txt guarda o texto com o $ */
static const char *bnd_txt[MAXBIND];
static int bnd_kind[MAXBIND], bnd_slot[MAXBIND], nbnd;
static int rule_def;              /* 1 enquanto do_rule le o padrao e o template */
/* padrao em construcao: so vai para a tabela quando a definicao termina */
static int r_items[MAXITEMS], r_nitems, r_nholes, r_nnames, r_lead;

static const char *nt_names[] = { "lit", "expr", "stmt", "block", "ident" };

static int bnd_find(const u8 *s, int len) {
    for (int i = 0; i < nbnd; i++)
        if ((int)cstrlen(bnd_txt[i]) == len && mem_eq(bnd_txt[i], s, (size_t)len)) return i;
    return -1;
}
/* registra o buraco do token corrente ($nome ou $$nome) e devolve o indice */
static int bnd_add(int kind, int slot) {
    if (nbnd == MAXBIND) die("buracos demais em #rule");
    if (bnd_find(cur.start, cur.len) >= 0) err_at(cur.file, cur.line, "buraco repetido em #rule");
    bnd_txt[nbnd] = cur_name(); bnd_kind[nbnd] = kind; bnd_slot[nbnd] = slot;
    return nbnd++;
}
/* reserva mais um buraco de nome (ident do padrao ou gensym do template) */
static int name_slot(void) {
    if (r_nnames == MAXNAMES) err_at(cur.file, cur.line, "buracos de nome demais em #rule");
    return r_nnames++;
}
/* um nome novo por expansao: __g1, __g2, ... na ordem em que sao criados */
static const char *gensym_new(void) {
    char tmp[24]; int i = 24; i64 v = ++gensym_n;
    do { tmp[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    char *s = xalloc((size_t)(28 - i));
    s[0] = '_'; s[1] = '_'; s[2] = 'g';
    for (int k = i; k < 24; k++) s[3 + k - i] = tmp[k];
    return s;
}
/* nome de nao-terminal no padrao; 0 = o token corrente nao e um */
static int nt_kind(void) {
    for (int i = IT_EXPR; i <= IT_IDENT; i++) if (cur_is(nt_names[i])) return i;
    if (cur_is("type")) err_at(cur.file, cur.line, "nt `type` fora do escopo do M9");
    return 0;
}
/* a ultima regra definida para o mesmo token de abertura vence */
static int rule_find(int tok, int lead) {
    for (int i = nrules - 1; i >= 0; i--)
        if (rules[i].tok == tok && rules[i].lead == lead) return i;
    return -1;
}
/* troca por to[j] todo nome que ainda aponta para o placeholder ph[j]: e assim
 * que `ident $x` e `$$t` viram nomes de verdade na copia recem-expandida */
static void name_fix(int n, const char **ph, const char **to, int nn) {
    if (n == 0) return;
    for (int j = 0; j < nn; j++)
        if (nodes[n].name == ph[j]) { nodes[n].name = to[j]; break; }
    name_fix(nodes[n].a, ph, to, nn);
    name_fix(nodes[n].b, ph, to, nn);
    name_fix(nodes[n].c, ph, to, nn);
    name_fix(nodes[n].d, ph, to, nn);
    name_fix(nodes[n].next, ph, to, nn);
}

/* ---- expressoes ---- */
static int parse_expr(int minprec);

static int type_of_token(int id) {
    if (id == K_U8)   return TY_U8;
    if (id == K_U16)  return TY_U16;
    if (id == K_U32)  return TY_U32;
    if (id == K_U64)  return TY_U64;
    if (id == K_I64)  return TY_I64;
    if (id == K_UPTR) return TY_UPTR;
    if (id == K_VOID) return TY_VOID;
    return -1;
}

static int parse_unary(void);

static int parse_primary(void) {
    int line = cur.line; const char *fl = cur.file;
    if (cur.id == T_INT || cur.id == T_CHAR) {
        int n = node_new(N_INT, line, fl);
        nodes[n].val = cur.val; nodes[n].type = TY_I64;
        next();
        return n;
    }
    if (cur.id == T_STR) {
        const char *s = cur_name();
        int n = node_new(N_STR, line, fl);
        nodes[n].name = s; nodes[n].val = cur.len; nodes[n].type = TY_UPTR;
        next();
        return n;
    }
    if (cur.id == T_IDENT) {
        int hi = opc_param(cur.start, cur.len);      /* parametro de #opcode: liga primeiro */
        if (hi) {
            int n = node_new(N_HOLE, line, fl);
            nodes[n].val = hi;
            next();
            return n;
        }
        int di = def_find((const char *)cur.start, cur.len);
        if (di >= 0) {                           /* #define vem antes de tudo: vira N_INT */
            int n = node_new(N_INT, line, fl);
            nodes[n].val = defs[di].val; nodes[n].type = TY_I64;
            next();
            return n;
        }
        const char *s = cur_name();
        int n = node_new(N_IDENT, line, fl);
        nodes[n].name = s; nodes[n].type = TY_I64;
        next();
        return n;
    }
    if (cur.id == T_HOLE) {
        int b = bnd_find(cur.start, cur.len);    /* buraco ligado por #rule */
        if (b < 0 && cur.val == -2) {            /* $$nome novo: gensym do template */
            if (!rule_def) err_at(fl, line, "$$nome so vale no template de #rule");
            b = bnd_add(IT_GEN, name_slot());
        }
        if (b >= 0) {
            if (bnd_kind[b] == IT_IDENT || bnd_kind[b] == IT_GEN) {
                int n = node_new(N_IDENT, line, fl);     /* buraco de nome */
                nodes[n].name = bnd_txt[b]; nodes[n].type = TY_I64;
                next();
                return n;
            }
            int n = node_new(N_HOLE, line, fl);
            nodes[n].val = bnd_slot[b];
            next();
            return n;
        }
        if (cur.val < 0) err_at(fl, line, "buraco $nome sem regra que o ligue");
        int n = node_new(N_HOLE, line, fl);      /* $1/$2 do #infix/#prefix */
        nodes[n].val = cur.val;
        next();
        return n;
    }
    if (cur.id == K_LPAR) {
        next();
        int ty = type_of_token(cur.id);
        if (ty >= 0) {                       /* cast: apos ( veio palavra de tipo */
            if (ty == TY_VOID) err_at(fl, line, "cast para void");
            next();
            expect(K_RPAR, "esperado ) no cast");
            int e = parse_unary();
            int n = node_new(N_CAST, line, fl);
            nodes[n].type = ty; nodes[n].a = e;
            return n;
        }
        int e = parse_expr(0);
        expect(K_RPAR, "esperado ) apos expressao");
        return e;
    }
    err_at(fl, line, "expressao esperada");
}

/* chamada e sempre por nome: N_CALL guarda o nome e a lista de argumentos em a */
static int parse_call(int callee) {
    int line = cur.line; const char *fl = cur.file;
    if (nodes[callee].kind != N_IDENT) err_at(fl, line, "chamada so por nome");
    const char *name = nodes[callee].name;
    next();                                  /* ( */
    int head = 0, tail = 0;
    if (cur.id != K_RPAR)
        for (;;) {
            int a = parse_expr(0);
            if (tail) nodes[tail].next = a; else head = a;
            tail = a;
            if (cur.id != K_COMMA) break;
            next();
        }
    expect(K_RPAR, "esperado ) na chamada");
    int c = node_new(N_CALL, line, fl);
    nodes[c].name = name; nodes[c].a = head; nodes[c].type = TY_I64;
    return c;
}

static int parse_postfix(void) {
    int n = parse_primary();
    while (cur.id == K_LPAR) n = parse_call(n);   /* pos-fixo: liga mais forte que tudo */
    return n;
}

static int parse_unary(void) {
    int i = prefix_find(cur.id);
    if (i < 0) return parse_postfix();
    int tok = cur.id, tmpl = prefixes[i].tmpl, line = cur.line;
    const char *fl = cur.file;
    next();
    int operand = parse_unary();
    if (tmpl) {
        int holes[2];
        holes[0] = 0; holes[1] = operand;
        return node_copy_subst(tmpl, holes, 1);
    }
    if (tok == K_AND) {                      /* &nome: endereco de um local */
        if (nodes[operand].kind != N_IDENT) err_at(fl, line, "& espera um nome");
        const char *name = nodes[operand].name;
        int u = node_new(N_ADDR, line, fl);
        nodes[u].name = name; nodes[u].type = TY_UPTR;
        return u;
    }
    int u = node_new(N_UNARY, line, fl);
    nodes[u].op = tok; nodes[u].a = operand;
    return u;
}

static int parse_expr(int minprec) {
    int lhs = parse_unary();
    for (;;) {
        int i = infix_find(cur.id);
        if (i < 0 || infixes[i].prec < minprec) return lhs;
        int tok = cur.id, prec = infixes[i].prec, tmpl = infixes[i].tmpl;
        bool right = infixes[i].right;
        int line = cur.line; const char *fl = cur.file;
        next();
        int rhs = parse_expr(right ? prec : prec + 1);
        if (tmpl) {
            int holes[3];
            holes[0] = 0; holes[1] = lhs; holes[2] = rhs;
            lhs = node_copy_subst(tmpl, holes, 2);
        } else {
            int b = node_new(N_BINARY, line, fl);
            nodes[b].op = tok; nodes[b].a = lhs; nodes[b].b = rhs;
            lhs = b;
        }
    }
}

/* ---- dobra de constantes ---- */
static i64 const_bin(int op, i64 x, i64 y, int type, int n) {
    u64 a = (u64)x, b = (u64)y;
    if (op == K_ADD) return (i64)(a + b);
    if (op == K_SUB) return (i64)(a - b);
    if (op == K_MUL) return (i64)(a * b);
    if (op == K_DIV || op == K_MOD) {
        if (y == 0) err_node(n, "divisao por zero");
        if (type != TY_I64) return (i64)(op == K_DIV ? a / b : a % b);   /* espelha udiv */
        if (y == -1) return op == K_DIV ? (i64)(0 - a) : 0;     /* evita overflow de INT64_MIN */
        return op == K_DIV ? x / y : x % y;
    }
    if (op == K_AND) return (i64)(a & b);
    if (op == K_OR)  return (i64)(a | b);
    if (op == K_XOR) return (i64)(a ^ b);
    if (op == K_SHL) return (i64)(a << (b & 63));
    if (op == K_SHR) {
        if (type == TY_I64) return x >> (y & 63);              /* aritmetico */
        return (i64)(a >> (b & 63));                           /* logico */
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
}

/* tipo: literal e i64; binario herda o do operando esquerdo; cast define o seu */
static void fold_unary(int n) {
    int a = fold(nodes[n].a);
    nodes[n].a = a; nodes[n].type = nodes[a].type;
    if (nodes[a].kind != N_INT) return;
    u64 v = (u64)nodes[a].val, r;
    int op = nodes[n].op;
    if (op == K_SUB)        r = 0 - v;
    else if (op == K_TILDE) r = ~v;
    else if (op == K_BANG)  r = v ? 0 : 1;
    else return;                                   /* & nao dobra */
    nodes[n].kind = N_INT; nodes[n].val = (i64)r; nodes[n].op = 0; nodes[n].a = 0;
}

static void fold_binary(int n) {
    int a = fold(nodes[n].a); nodes[n].a = a;
    int b = fold(nodes[n].b); nodes[n].b = b;
    nodes[n].type = nodes[a].type;
    if (nodes[a].kind != N_INT || nodes[b].kind != N_INT) return;
    i64 r = const_bin(nodes[n].op, nodes[a].val, nodes[b].val, nodes[a].type, n);
    nodes[n].kind = N_INT; nodes[n].val = r; nodes[n].op = 0; nodes[n].a = 0; nodes[n].b = 0;
}

static void fold_cast(int n) {
    int a = fold(nodes[n].a); nodes[n].a = a;
    if (nodes[a].kind != N_INT) return;
    u64 v = (u64)nodes[a].val;
    int t = nodes[n].type;
    if (t == TY_U8)       v &= 0xff;
    else if (t == TY_U16) v &= 0xffff;
    else if (t == TY_U32) v &= 0xffffffffu;
    nodes[n].kind = N_INT; nodes[n].val = (i64)v; nodes[n].a = 0;   /* type = o do cast */
}

int fold(int n) {
    if (n == 0) return 0;
    int k = nodes[n].kind;
    if (k == N_UNARY)       fold_unary(n);
    else if (k == N_BINARY) fold_binary(n);
    else if (k == N_CAST)   fold_cast(n);
    else {
        int a = fold(nodes[n].a); nodes[n].a = a;
        int b = fold(nodes[n].b); nodes[n].b = b;
        int c = fold(nodes[n].c); nodes[n].c = c;
        int d = fold(nodes[n].d); nodes[n].d = d;
    }
    int nx = fold(nodes[n].next);
    nodes[n].next = nx;
    return n;
}

/* ---- statements ---- */
static int parse_block(void);
static int parse_stmt(void);
static int rule_expand(int ri, int lead);

/* tamanho entre [ ]; devolve 0 quando os colchetes vem vazios (`[]`) */
static i64 parse_dim(int line, const char *fl) {
    next();                                  /* [ */
    i64 nel = 0;
    if (cur.id != K_RBRACK) {
        int e = fold(parse_expr(0));
        if (nodes[e].kind != N_INT || nodes[e].val <= 0)
            err_at(fl, line, "tamanho de array deve ser constante positiva");
        nel = nodes[e].val;                  /* a conta e em i64: (int) truncaria */
    }
    expect(K_RBRACK, "esperado ] no tamanho do array");
    return nel;
}

/* nome numa declaracao: um T_IDENT normal ou, dentro de um template de #rule,
 * um buraco de nome (`$x` ligado a um `ident` do padrao, ou o gensym `$$t`) */
static const char *decl_name(const char *msg) {
    if (cur.id == T_HOLE) {
        int b = bnd_find(cur.start, cur.len);
        if (b < 0 && cur.val == -2 && rule_def) b = bnd_add(IT_GEN, name_slot());
        if (b >= 0 && (bnd_kind[b] == IT_IDENT || bnd_kind[b] == IT_GEN)) {
            const char *s = bnd_txt[b];
            next();
            return s;
        }
    }
    if (cur.id != T_IDENT) err_at(cur.file, cur.line, msg);
    check_def();
    const char *s = cur_name();
    next();
    return s;
}

/* declaracao de local: tipo nome = expr; | tipo nome; | tipo nome[CONST]; */
static int parse_var(int line, const char *fl, int ty) {
    if (ty == TY_VOID) err_at(fl, line, "local de tipo void");
    next();                                  /* tipo */
    const char *name = decl_name("nome de variavel esperado");
    i64 nel = 0;
    int init = 0;
    if (cur.id == K_LBRACK) {
        nel = parse_dim(line, fl);
        if (nel < 1) err_at(fl, line, "tamanho de array deve ser constante positiva");
        if (nel > 4095 || nel * type_width(ty) > 4095) err_at(fl, line, "array local grande demais");
    } else if (cur.id == K_ASSIGN) {
        next();
        init = parse_expr(0);
    }
    expect(K_SEMI, "esperado ; apos declaracao");
    int n = node_new(N_VAR, line, fl);
    nodes[n].name = name; nodes[n].type = ty; nodes[n].a = init; nodes[n].val = nel;
    return n;
}

static int parse_stmt(void) {
    int line = cur.line; const char *fl = cur.file;
    int ri = rule_find(cur.id, 0);               /* o token corrente abre uma regra? */
    if (ri >= 0) return rule_expand(ri, 0);
    if (cur.id == T_HOLE) {                      /* `$init`/`$b` soltos no template */
        int b = bnd_find(cur.start, cur.len);
        if (b >= 0 && (bnd_kind[b] == IT_STMT || bnd_kind[b] == IT_BLOCK)) {
            int n = node_new(N_HOLE, line, fl);
            nodes[n].val = bnd_slot[b];
            next();
            return n;
        }
    }
    if (cur.id == K_LBRACE) return parse_block();
    int ty = type_of_token(cur.id);
    if (ty >= 0) return parse_var(line, fl, ty);
    if (cur.id == K_IF) {
        next();
        expect(K_LPAR, "esperado ( apos if");
        int c = parse_expr(0);
        expect(K_RPAR, "esperado ) apos a condicao");
        int t = parse_stmt();
        int e = 0;
        if (cur.id == K_ELSE) { next(); e = parse_stmt(); }
        int n = node_new(N_IF, line, fl);
        nodes[n].a = c; nodes[n].b = t; nodes[n].c = e;
        return n;
    }
    if (cur.id == K_LOOP) {
        next();
        int b = parse_stmt();
        int n = node_new(N_LOOP, line, fl);
        nodes[n].a = b;
        return n;
    }
    if (cur.id == K_BREAK) {
        next();
        i64 lv = 1;
        if (cur.id == T_INT) { lv = cur.val; next(); }
        if (lv < 1) err_at(fl, line, "break espera um nivel positivo");
        expect(K_SEMI, "esperado ; apos break");
        int n = node_new(N_BREAK, line, fl);
        nodes[n].val = lv;
        return n;
    }
    if (cur.id == K_CONTINUE) {
        next();
        expect(K_SEMI, "esperado ; apos continue");
        return node_new(N_CONTINUE, line, fl);
    }
    if (cur.id == K_RETURN) {
        next();
        int e = 0;
        if (cur.id != K_SEMI) e = parse_expr(0);
        expect(K_SEMI, "esperado ; apos return");
        int n = node_new(N_RETURN, line, fl);
        nodes[n].a = e;
        return n;
    }
    int e = parse_expr(0);
    if (cur.id == K_ASSIGN) {                /* nome = expr; (o = nao esta na tabela infix) */
        if (nodes[e].kind != N_IDENT) err_at(fl, line, "lado esquerdo da atribuicao deve ser um nome");
        const char *name = nodes[e].name;
        next();
        int v = parse_expr(0);
        expect(K_SEMI, "esperado ; apos atribuicao");
        int n = node_new(N_ASSIGN, line, fl);
        nodes[n].name = name; nodes[n].a = v;
        return n;
    }
    /* regra que comeca por `ident $x`: o nome ja foi lido como expressao e o
     * despacho continua sendo por token literal (`+=`, `++`), sem backtracking */
    ri = rule_find(cur.id, 1);
    if (ri >= 0) {
        if (nodes[e].kind != N_IDENT) err_at(fl, line, "a regra esperava um nome a esquerda");
        return rule_expand(ri, e);
    }
    expect(K_SEMI, "esperado ; apos expressao");
    int n = node_new(N_EXPRSTMT, line, fl);
    nodes[n].a = e;
    return n;
}

static int parse_block(void) {
    int line = cur.line; const char *fl = cur.file;
    expect(K_LBRACE, "esperado {");
    int head = 0, tail = 0;
    while (cur.id != K_RBRACE) {
        if (cur.id == T_EOF) err_at(fl, line, "bloco nao terminado");
        int s = parse_stmt();
        if (tail) nodes[tail].next = s; else head = s;
        tail = s;
    }
    next();
    int b = node_new(N_BLOCK, line, fl);
    nodes[b].a = head;
    return b;
}

/* casa os itens da regra ri contra o fonte e devolve o template expandido.
 * lead != 0 e o N_IDENT que ja foi lido antes do token de despacho. */
static int rule_expand(int ri, int lead) {
    int holes[MAXITEMS + 1];
    const char *to[MAXNAMES];
    int nn = rules[ri].nnames;
    if (++rule_depth > MAXRDEPTH) die("regras aninhadas demais");
    for (int j = 0; j < nn; j++) to[j] = 0;
    if (rules[ri].lead) to[0] = nodes[lead].name;
    for (int k = 0; k < rules[ri].nitems; k++) {
        int it = rules[ri].items[k], kd = it & 7, v = it >> 3;
        if (kd == IT_LIT) {
            if (cur.id != v) err_at2(cur.file, cur.line, "a regra esperava", tok_text(v));
            next();
        } else if (kd == IT_IDENT) {
            if (cur.id != T_IDENT) err_at(cur.file, cur.line, "a regra esperava um nome");
            to[v] = cur_name();
            next();
        } else if (kd == IT_EXPR)  holes[v] = parse_expr(0);
        else if (kd == IT_STMT)    holes[v] = parse_stmt();
        else                       holes[v] = parse_block();
    }
    for (int j = 0; j < nn; j++) if (!to[j]) to[j] = gensym_new();   /* $$t da vez */
    int e = node_copy_subst(rules[ri].tmpl, holes, rules[ri].nholes);
    name_fix(e, rules[ri].ph, to, nn);
    rule_depth--;
    return e;
}

/* #rule stmt: PADRAO => TEMPLATE — o padrao e uma sequencia plana de tokens
 * literais e `nt $nome`; o template e um statement parseado aqui, agora, com os
 * $nome ja virando buracos. Um identificador usado como token literal vira
 * palavra-chave reservada na hora (tok_add). */
static void do_rule(int line, const char *fl) {
    if (cur.id != T_IDENT) err_at(fl, line, "#rule espera a categoria stmt");
    if (cur_is("expr")) err_at(fl, line, "#rule expr: reservado, ainda nao suportado");
    if (!cur_is("stmt")) err_at(fl, line, "#rule so conhece a categoria stmt");
    next();
    expect(K_COLON, "esperado : apos a categoria do #rule");
    if (nrules == MAXRULES) die("regras demais");
    nbnd = 0; r_nitems = 0; r_nholes = 0; r_nnames = 0; r_lead = 0;
    rule_def = 1;
    if (cur.id == T_IDENT && nt_kind() == IT_IDENT) {   /* `ident $x` antes do token */
        next();
        if (cur.id != T_HOLE || cur.val != -1) err_at(cur.file, cur.line, "esperado $nome no padrao");
        bnd_add(IT_IDENT, name_slot());
        next();
        r_lead = 1;
    }
    while (cur.id != K_ARROW) {
        if (cur.id == T_EOF) err_at(fl, line, "#rule sem =>");
        if (r_nitems == MAXITEMS) err_at(fl, line, "itens demais no padrao do #rule");
        int k = cur.id == T_IDENT ? nt_kind() : 0;
        int it;
        if (k) {
            next();
            if (cur.id != T_HOLE || cur.val != -1) err_at(cur.file, cur.line, "esperado $nome no padrao");
            int slot = k == IT_IDENT ? name_slot() : ++r_nholes;
            bnd_add(k, slot);
            next();
            it = k + slot * 8;
        } else {
            /* cur_name e nao cur.start: o lexema de um token fica guardado na
             * tabela e tok_text o imprime como string — tem de estar na arena */
            int id = cur.id == T_IDENT ? tok_add(cur_name(), cur.len) : cur.id;
            next();
            it = IT_LIT + id * 8;
        }
        if (r_nitems == 0 && (it & 7) != IT_LIT)
            err_at(fl, line, "o padrao do #rule tem de abrir por um token literal");
        r_items[r_nitems++] = it;
    }
    if (r_nitems == 0) err_at(fl, line, "padrao de #rule vazio");
    next();                                       /* => */
    int tmpl = parse_stmt();                      /* os $nome ja viraram buracos */
    rule_def = 0;
    RuleEnt *r = &rules[nrules];
    r->tok = r_items[0] >> 3; r->lead = r_lead; r->nitems = r_nitems;
    r->nholes = r_nholes;     r->nnames = r_nnames; r->tmpl = tmpl;
    for (int k = 0; k < r_nitems; k++) r->items[k] = r_items[k];
    for (int i = 0; i < nbnd; i++)
        if (bnd_kind[i] == IT_IDENT || bnd_kind[i] == IT_GEN) r->ph[bnd_slot[i]] = bnd_txt[i];
    nbnd = 0;
    nrules++;
}

/* --dump-rules: uma linha por regra, na ordem de definicao */
void dump_rules(void) {
    for (int i = 0; i < nrules; i++) {
        out_str(1, "regra "); out_num(1, i); out_str(1, ": stmt:");
        if (rules[i].lead) out_str(1, " ident $0");
        for (int k = 0; k < rules[i].nitems; k++) {
            int it = rules[i].items[k];
            out_str(1, " ");
            if ((it & 7) == IT_LIT) out_str(1, tok_text(it >> 3));
            else { out_str(1, nt_names[it & 7]); out_str(1, " $"); out_num(1, it >> 3); }
        }
        out_str(1, " => "); out_num(1, node_size(rules[i].tmpl)); out_str(1, " nos\n");
    }
}

/* uma constante do fonte, ja dobrada; usada pelos argumentos de #section */
static i64 const_arg(int line, const char *fl, const char *msg) {
    int e = fold(parse_expr(0));
    if (nodes[e].kind != N_INT) err_at(fl, line, msg);
    return nodes[e].val;
}

/* #section SEG SECT FLAGS [ALIGN] — secao corrente das funcoes e globais seguintes.
 * Sem argumentos volta ao default. ALIGN e log2 e vale 4 (16 bytes) quando
 * omitido: mesmo alinhamento que o codegen da a __data. */
static void do_section(int line, const char *fl) {
    if (cur.id != T_IDENT) { cur_sect = 0; return; }
    const char *seg = cur_name();
    next();
    if (cur.id != T_IDENT) err_at(cur.file, cur.line, "#section espera o nome da secao");
    const char *sect = cur_name();
    next();
    i64 flags = const_arg(line, fl, "#section espera flags constantes");
    i64 align = 4;
    /* so um numero, um #define ou um parentese podem comecar o alinhamento:
     * nenhum deles comeca uma declaracao de topo, entao nao ha ambiguidade */
    if (cur.id == T_INT || cur.id == T_IDENT || cur.id == K_LPAR) {
        align = const_arg(line, fl, "#section espera alinhamento constante");
        if (align < 0 || align > 15) err_at(fl, line, "alinhamento fora de 0..15");
    }
    if (flags < 0 || flags > 0xffffffff) err_at(fl, line, "flags de secao fora de 32 bits");
    cur_sect = sec_ent(seg, sect, (u32)flags, (u32)align) + 1;
}

/* #opcode nome(p1, ...) EXPR — registra um encoder; nao e simbolo nem funcao.
 * O nome de um parametro sombreia de proposito um #define de mesmo nome: dentro
 * do template primary() consulta opc_param antes de def_find, entao o parametro
 * ganha. E o que se quer — o template fala dos seus proprios argumentos — e vale
 * so ate o fim da definicao, quando opc_nparams volta a zero. */
static void do_opcode(int line, const char *fl) {
    if (cur.id != T_IDENT) err_at(fl, line, "#opcode espera um nome");
    const char *name = cur_name();
    next();
    expect(K_LPAR, "esperado ( no #opcode");
    opc_nparams = 0;
    while (cur.id != K_RPAR) {
        if (cur.id != T_IDENT)         err_at(cur.file, cur.line, "nome de parametro esperado no #opcode");
        if (opc_nparams == MAXPARAMS)  err_at(cur.file, cur.line, "no maximo 8 parametros no #opcode");
        opc_params[opc_nparams++] = cur_name();
        next();
        if (cur.id != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "esperado ) no #opcode");
    int tmpl = parse_expr(0);                    /* os parametros ja viraram N_HOLE */
    int np = opc_nparams;
    opc_nparams = 0;                             /* fora da definicao nao ha parametro */
    if (opc_find(name) >= 0) err_at(fl, line, "#opcode repetido");
    if (nopcs == MAXOPCS)    die("opcodes demais");
    opcs[nopcs].name = name; opcs[nopcs].nparams = np; opcs[nopcs].tmpl = tmpl;
    nopcs++;
}

/* ---- diretivas suportadas: #include, #define, #token, #infix, #prefix,
 * #rule, #section, #opcode ---- */
static void do_directive(void) {
    int d = (int)cur.val, line = cur.line;
    const char *fl = cur.file;
    next();
    if (d == D_INCLUDE) {
        if (cur.id != T_STR) err_at(fl, line, "#include espera uma string");
        const char *path = cur_name();
        lex_include(path, line);                 /* false = ja incluido: segue em frente */
        next();                                  /* ja no arquivo incluido, se houve push */
        return;
    }
    if (d == D_DEFINE) {
        if (cur.id != T_IDENT) err_at(fl, line, "#define espera um nome");
        const char *name = cur_name();
        next();
        int e = fold(parse_expr(0));
        if (nodes[e].kind != N_INT) err_at(fl, line, "#define espera uma expressao constante");
        def_add(name, nodes[e].val, line, fl);
        return;
    }
    if (d == D_TOKEN) {
        if (cur.id != T_STR) err_at(fl, line, "#token espera uma string");
        tok_add((const char *)cur.start, cur.len);   /* bytes ficam na arena */
        next();
        return;
    }
    if (d == D_INFIX || d == D_PREFIX) {
        if (cur.id != T_STR) err_at(fl, line, "diretiva espera uma string");
        int tok = tok_add((const char *)cur.start, cur.len);
        next();
        int prec = 0;
        bool right = false;
        if (d == D_INFIX) {
            if (cur.id != T_INT) err_at(cur.file, cur.line, "#infix espera a precedencia");
            if (cur.val < 1 || cur.val > 100)    /* faixa checada em i64, antes do cast */
                err_at(cur.file, cur.line, "precedencia fora de 1..100");
            prec = (int)cur.val;
            next();
            if (cur.id != T_IDENT) err_at(cur.file, cur.line, "#infix espera left ou right");
            if (cur_is("right")) right = true;
            else if (!cur_is("left")) err_at(cur.file, cur.line, "#infix espera left ou right");
            next();
        }
        int tmpl = parse_expr(0);                    /* $1/$2 viram N_HOLE */
        if (d == D_INFIX) infix_set(tok, prec, right, tmpl);
        else              prefix_set(tok, tmpl);
        return;
    }
    if (d == D_RULE)    { do_rule(line, fl);    return; }
    if (d == D_SECTION) { do_section(line, fl); return; }
    if (d == D_OPCODE)  { do_opcode(line, fl);  return; }
    err_at(fl, line, "diretiva ainda nao suportada");
}

/* ---- topo ---- */
/* lista de parametros, ja com os parenteses; nenhum passa pela pilha */
static int parse_params(void) {
    expect(K_LPAR, "esperado ( na lista de parametros");
    int head = 0, tail = 0, n = 0;
    while (cur.id != K_RPAR) {
        int line = cur.line; const char *fl = cur.file;
        int pty = type_of_token(cur.id);
        if (pty < 0)         err_at(fl, line, "tipo esperado no parametro");
        if (pty == TY_VOID)  err_at(fl, line, "parametro de tipo void");
        next();
        if (cur.id != T_IDENT) err_at(cur.file, cur.line, "nome de parametro esperado");
        check_def();
        const char *pname = cur_name();
        next();
        int p = node_new(N_PARAM, line, fl);
        nodes[p].type = pty; nodes[p].name = pname;
        if (tail) nodes[tail].next = p; else head = p;
        tail = p;
        n++;
        if (n > MAXPARAMS) err_at(fl, line, "no maximo 8 parametros");
        if (cur.id != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "esperado ) na lista de parametros");
    return head;
}

/* extern tipo nome(params); — simbolo indefinido, resolvido pelo ld */
static int parse_extern(void) {
    int line = cur.line; const char *fl = cur.file;
    next();                                  /* extern */
    int ty = type_of_token(cur.id);
    if (ty < 0) err_at(cur.file, cur.line, "tipo esperado no extern");
    next();
    if (cur.id != T_IDENT) err_at(cur.file, cur.line, "nome esperado no extern");
    check_def();
    const char *name = cur_name();
    next();
    int params = parse_params();
    expect(K_SEMI, "esperado ; apos extern");
    int f = node_new(N_EXTERN, line, fl);
    nodes[f].name = name; nodes[f].type = ty; nodes[f].a = params;
    return f;
}

/* inicializador de array global: { c1, c2, ... }, cada elemento uma constante ou,
 * para uptr, um literal de string. Devolve a lista e conta em pn */
static int parse_initlist(int line, const char *fl, int ty, i64 *pn) {
    expect(K_LBRACE, "esperado { no inicializador do array");
    int head = 0, tail = 0;
    i64 k = 0;
    while (cur.id != K_RBRACE) {
        int e = fold(parse_expr(0));
        if (nodes[e].kind == N_STR) {
            if (ty != TY_UPTR) err_node(e, "string so inicializa uptr");
        } else if (nodes[e].kind != N_INT) err_node(e, "inicializador deve ser constante");
        if (tail) nodes[tail].next = e; else head = e;
        tail = e;
        k++;
        if (cur.id != K_COMMA) break;
        next();
    }
    expect(K_RBRACE, "esperado } no inicializador do array");
    if (k == 0) err_at(fl, line, "inicializador de array vazio");
    *pn = k;
    return head;
}

/* global: tipo nome[N] = { ... }; | tipo nome = CONST; | tipo nome; | tipo nome[CONST]; */
static int parse_global(int line, const char *fl, int ty, const char *name) {
    if (ty == TY_VOID) err_at(fl, line, "global de tipo void");
    i64 nel = 0, count = 0;
    int init = 0;
    bool arr = cur.id == K_LBRACK;
    if (arr) nel = parse_dim(line, fl);
    if (cur.id == K_ASSIGN) {
        next();
        if (arr) {
            init = parse_initlist(line, fl, ty, &count);
            if (nel == 0) nel = count;                   /* [] = { ... }: N vem da lista */
            if (count > nel) err_at(fl, line, "inicializador com elementos demais");
        } else {
            init = fold(parse_expr(0));
            if (nodes[init].kind != N_INT) err_at(fl, line, "inicializador de global deve ser constante");
        }
    }
    if (arr && nel <= 0) err_at(fl, line, "tamanho de array deve ser constante positiva");
    if (nel > ((i64)1 << 30) / type_width(ty)) err_at(fl, line, "array global grande demais");
    expect(K_SEMI, "esperado ; apos a global");
    int n = node_new(N_GLOBAL, line, fl);
    nodes[n].name = name; nodes[n].type = ty; nodes[n].a = init; nodes[n].val = nel;
    return n;
}

/* topo: so o ( depois do nome separa funcao de global; ; no lugar do corpo e prototipo */
static int parse_top(void) {
    int line = cur.line; const char *fl = cur.file;
    int ty = type_of_token(cur.id);
    if (ty < 0) err_at(fl, line, "tipo esperado no topo");
    next();
    if (cur.id != T_IDENT) err_at(cur.file, cur.line, "nome esperado no topo");
    check_def();
    const char *name = cur_name();
    next();
    if (cur.id != K_LPAR) return parse_global(line, fl, ty, name);
    int params = parse_params();
    if (cur.id == K_SEMI) {
        next();
        int p = node_new(N_PROTO, line, fl);
        nodes[p].name = name; nodes[p].type = ty; nodes[p].a = params;
        return p;
    }
    int body = parse_block();
    int f = node_new(N_FUNC, line, fl);
    nodes[f].name = name; nodes[f].type = ty; nodes[f].a = params; nodes[f].b = body;
    return f;
}

int parse_unit(void) {
    ops_init();
    defs_init();
    next();
    int head = 0, tail = 0;
    while (cur.id != T_EOF) {
        if (cur.id == T_DIR) { do_directive(); continue; }
        int f = cur.id == K_EXTERN ? parse_extern() : parse_top();
        nodes[f].sect = cur_sect;                /* placement do #section em vigor */
        if (tail) nodes[tail].next = f; else head = f;
        tail = f;
    }
    return head;
}
