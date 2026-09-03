/* parse.c — descida recursiva para declaracoes/statements e Pratt dirigido por
 * tabela para expressoes. As tabelas infix/prefix sao arrays em ordem de
 * insercao, buscados linearmente: e o que #infix/#prefix mutam. */
#include "mc.h"

#define MAXOPS 128
#define MAXDEFS 256

static InfixEnt  infixes[MAXOPS];  static int ninfix;
static PrefixEnt prefixes[MAXOPS]; static int nprefix;
static DefEnt    defs[MAXDEFS];    static int ndefs;

static Token cur;                  /* lookahead de 1 token */
static void next(void) { lex_next(&cur); }
static void expect(int id, const char *msg) {
    if (cur.id != id) err_at(cur.line, msg);
    next();
}
static bool cur_is(const char *s) {
    return cur.len == (int)cstrlen(s) && mem_eq(cur.start, s, (size_t)cur.len);
}

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
static void def_add(const char *name, i64 val, int line) {
    if (def_find(name, (int)cstrlen(name)) >= 0) err_at(line, "#define repetido");
    if (ndefs == MAXDEFS) die("defines demais");
    defs[ndefs].name = name; defs[ndefs].val = val;
    ndefs++;
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
    int line = cur.line;
    if (cur.id == T_INT || cur.id == T_CHAR) {
        int n = node_new(N_INT, line);
        nodes[n].val = cur.val; nodes[n].type = TY_I64;
        next();
        return n;
    }
    if (cur.id == T_STR) {
        const char *s = xstrdup((const char *)cur.start, (size_t)cur.len);
        int n = node_new(N_STR, line);
        nodes[n].name = s; nodes[n].val = cur.len; nodes[n].type = TY_UPTR;
        next();
        return n;
    }
    if (cur.id == T_IDENT) {
        int di = def_find((const char *)cur.start, cur.len);
        if (di >= 0) {                           /* #define vem antes de tudo: vira N_INT */
            int n = node_new(N_INT, line);
            nodes[n].val = defs[di].val; nodes[n].type = TY_I64;
            next();
            return n;
        }
        const char *s = xstrdup((const char *)cur.start, (size_t)cur.len);
        int n = node_new(N_IDENT, line);
        nodes[n].name = s; nodes[n].type = TY_I64;
        next();
        return n;
    }
    if (cur.id == T_HOLE) {
        int n = node_new(N_HOLE, line);
        nodes[n].val = cur.val;
        next();
        return n;
    }
    if (cur.id == K_LPAR) {
        next();
        int ty = type_of_token(cur.id);
        if (ty >= 0) {                       /* cast: apos ( veio palavra de tipo */
            if (ty == TY_VOID) err_at(line, "cast para void");
            next();
            expect(K_RPAR, "esperado ) no cast");
            int e = parse_unary();
            int n = node_new(N_CAST, line);
            nodes[n].type = ty; nodes[n].a = e;
            return n;
        }
        int e = parse_expr(0);
        expect(K_RPAR, "esperado ) apos expressao");
        return e;
    }
    err_at(line, "expressao esperada");
}

/* chamada e sempre por nome: N_CALL guarda o nome e a lista de argumentos em a */
static int parse_call(int callee) {
    int line = cur.line;
    if (nodes[callee].kind != N_IDENT) err_at(line, "chamada so por nome");
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
    int c = node_new(N_CALL, line);
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
    next();
    int operand = parse_unary();
    if (tmpl) {
        int holes[2];
        holes[0] = 0; holes[1] = operand;
        return node_copy_subst(tmpl, holes, 1);
    }
    if (tok == K_AND) {                      /* &nome: endereco de um local */
        if (nodes[operand].kind != N_IDENT) err_at(line, "& espera um nome");
        const char *name = nodes[operand].name;
        int u = node_new(N_ADDR, line);
        nodes[u].name = name; nodes[u].type = TY_UPTR;
        return u;
    }
    int u = node_new(N_UNARY, line);
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
        int line = cur.line;
        next();
        int rhs = parse_expr(right ? prec : prec + 1);
        if (tmpl) {
            int holes[3];
            holes[0] = 0; holes[1] = lhs; holes[2] = rhs;
            lhs = node_copy_subst(tmpl, holes, 2);
        } else {
            int b = node_new(N_BINARY, line);
            nodes[b].op = tok; nodes[b].a = lhs; nodes[b].b = rhs;
            lhs = b;
        }
    }
}

/* ---- dobra de constantes ---- */
static i64 const_bin(int op, i64 x, i64 y, int type, int line) {
    u64 a = (u64)x, b = (u64)y;
    if (op == K_ADD) return (i64)(a + b);
    if (op == K_SUB) return (i64)(a - b);
    if (op == K_MUL) return (i64)(a * b);
    if (op == K_DIV || op == K_MOD) {
        if (y == 0) err_at(line, "divisao por zero");
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
    err_at(line, "operador sem dobra de constante");
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
    i64 r = const_bin(nodes[n].op, nodes[a].val, nodes[b].val, nodes[a].type, nodes[n].line);
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

/* declaracao de local: tipo nome = expr; | tipo nome; | tipo nome[CONST]; */
static int parse_var(int line, int ty) {
    if (ty == TY_VOID) err_at(line, "local de tipo void");
    next();                                  /* tipo */
    if (cur.id != T_IDENT) err_at(cur.line, "nome de variavel esperado");
    const char *name = xstrdup((const char *)cur.start, (size_t)cur.len);
    next();
    int nelem = 0, init = 0;
    if (cur.id == K_LBRACK) {
        next();
        int e = fold(parse_expr(0));
        if (nodes[e].kind != N_INT || nodes[e].val <= 0)
            err_at(line, "tamanho de array deve ser constante positiva");
        i64 nel = nodes[e].val;                  /* a conta e em i64: (int) truncaria */
        if (nel > 4095 || nel * type_width(ty) > 4095)
            err_at(line, "array local grande demais");
        nelem = (int)nel;
        expect(K_RBRACK, "esperado ] no tamanho do array");
    } else if (cur.id == K_ASSIGN) {
        next();
        init = parse_expr(0);
    }
    expect(K_SEMI, "esperado ; apos declaracao");
    int n = node_new(N_VAR, line);
    nodes[n].name = name; nodes[n].type = ty; nodes[n].a = init; nodes[n].val = nelem;
    return n;
}

static int parse_stmt(void) {
    int line = cur.line;
    if (cur.id == K_LBRACE) return parse_block();
    int ty = type_of_token(cur.id);
    if (ty >= 0) return parse_var(line, ty);
    if (cur.id == K_IF) {
        next();
        expect(K_LPAR, "esperado ( apos if");
        int c = parse_expr(0);
        expect(K_RPAR, "esperado ) apos a condicao");
        int t = parse_stmt();
        int e = 0;
        if (cur.id == K_ELSE) { next(); e = parse_stmt(); }
        int n = node_new(N_IF, line);
        nodes[n].a = c; nodes[n].b = t; nodes[n].c = e;
        return n;
    }
    if (cur.id == K_LOOP) {
        next();
        int b = parse_stmt();
        int n = node_new(N_LOOP, line);
        nodes[n].a = b;
        return n;
    }
    if (cur.id == K_BREAK) {
        next();
        i64 lv = 1;
        if (cur.id == T_INT) { lv = cur.val; next(); }
        if (lv < 1) err_at(line, "break espera um nivel positivo");
        expect(K_SEMI, "esperado ; apos break");
        int n = node_new(N_BREAK, line);
        nodes[n].val = lv;
        return n;
    }
    if (cur.id == K_CONTINUE) {
        next();
        expect(K_SEMI, "esperado ; apos continue");
        return node_new(N_CONTINUE, line);
    }
    if (cur.id == K_RETURN) {
        next();
        int e = 0;
        if (cur.id != K_SEMI) e = parse_expr(0);
        expect(K_SEMI, "esperado ; apos return");
        int n = node_new(N_RETURN, line);
        nodes[n].a = e;
        return n;
    }
    int e = parse_expr(0);
    if (cur.id == K_ASSIGN) {                /* nome = expr; (o = nao esta na tabela infix) */
        if (nodes[e].kind != N_IDENT) err_at(line, "lado esquerdo da atribuicao deve ser um nome");
        const char *name = nodes[e].name;
        next();
        int v = parse_expr(0);
        expect(K_SEMI, "esperado ; apos atribuicao");
        int n = node_new(N_ASSIGN, line);
        nodes[n].name = name; nodes[n].a = v;
        return n;
    }
    expect(K_SEMI, "esperado ; apos expressao");
    int n = node_new(N_EXPRSTMT, line);
    nodes[n].a = e;
    return n;
}

static int parse_block(void) {
    int line = cur.line;
    expect(K_LBRACE, "esperado {");
    int head = 0, tail = 0;
    while (cur.id != K_RBRACE) {
        if (cur.id == T_EOF) err_at(line, "bloco nao terminado");
        int s = parse_stmt();
        if (tail) nodes[tail].next = s; else head = s;
        tail = s;
    }
    next();
    int b = node_new(N_BLOCK, line);
    nodes[b].a = head;
    return b;
}

/* ---- diretivas suportadas: #include, #define, #token, #infix, #prefix ---- */
static void do_directive(void) {
    int d = (int)cur.val, line = cur.line;
    next();
    if (d == D_INCLUDE) {
        if (cur.id != T_STR) err_at(line, "#include espera uma string");
        const char *path = xstrdup((const char *)cur.start, (size_t)cur.len);
        lex_include(path, line);                 /* false = ja incluido: segue em frente */
        next();                                  /* ja no arquivo incluido, se houve push */
        return;
    }
    if (d == D_DEFINE) {
        if (cur.id != T_IDENT) err_at(line, "#define espera um nome");
        const char *name = xstrdup((const char *)cur.start, (size_t)cur.len);
        next();
        int e = fold(parse_expr(0));
        if (nodes[e].kind != N_INT) err_at(line, "#define espera uma expressao constante");
        def_add(name, nodes[e].val, line);
        return;
    }
    if (d == D_TOKEN) {
        if (cur.id != T_STR) err_at(line, "#token espera uma string");
        tok_add((const char *)cur.start, cur.len);   /* bytes ficam na arena */
        next();
        return;
    }
    if (d == D_INFIX || d == D_PREFIX) {
        if (cur.id != T_STR) err_at(line, "diretiva espera uma string");
        int tok = tok_add((const char *)cur.start, cur.len);
        next();
        int prec = 0;
        bool right = false;
        if (d == D_INFIX) {
            if (cur.id != T_INT) err_at(cur.line, "#infix espera a precedencia");
            if (cur.val < 1 || cur.val > 100)    /* faixa checada em i64, antes do cast */
                err_at(cur.line, "precedencia fora de 1..100");
            prec = (int)cur.val;
            next();
            if (cur.id != T_IDENT) err_at(cur.line, "#infix espera left ou right");
            if (cur_is("right")) right = true;
            else if (!cur_is("left")) err_at(cur.line, "#infix espera left ou right");
            next();
        }
        int tmpl = parse_expr(0);                    /* $1/$2 viram N_HOLE */
        if (d == D_INFIX) infix_set(tok, prec, right, tmpl);
        else              prefix_set(tok, tmpl);
        return;
    }
    err_at(line, "diretiva ainda nao suportada");
}

/* ---- topo ---- */
#define MAXPARAMS 8               /* nunca passa argumento pela pilha */

/* lista de parametros, ja com os parenteses; nenhum passa pela pilha */
static int parse_params(void) {
    expect(K_LPAR, "esperado ( na lista de parametros");
    int head = 0, tail = 0, n = 0;
    while (cur.id != K_RPAR) {
        int line = cur.line;
        int pty = type_of_token(cur.id);
        if (pty < 0)         err_at(line, "tipo esperado no parametro");
        if (pty == TY_VOID)  err_at(line, "parametro de tipo void");
        next();
        if (cur.id != T_IDENT) err_at(cur.line, "nome de parametro esperado");
        const char *pname = xstrdup((const char *)cur.start, (size_t)cur.len);
        next();
        int p = node_new(N_PARAM, line);
        nodes[p].type = pty; nodes[p].name = pname;
        if (tail) nodes[tail].next = p; else head = p;
        tail = p;
        n++;
        if (n > MAXPARAMS) err_at(line, "no maximo 8 parametros");
        if (cur.id != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "esperado ) na lista de parametros");
    return head;
}

/* extern tipo nome(params); — simbolo indefinido, resolvido pelo ld */
static int parse_extern(void) {
    int line = cur.line;
    next();                                  /* extern */
    int ty = type_of_token(cur.id);
    if (ty < 0) err_at(cur.line, "tipo esperado no extern");
    next();
    if (cur.id != T_IDENT) err_at(cur.line, "nome esperado no extern");
    const char *name = xstrdup((const char *)cur.start, (size_t)cur.len);
    next();
    int params = parse_params();
    expect(K_SEMI, "esperado ; apos extern");
    int f = node_new(N_EXTERN, line);
    nodes[f].name = name; nodes[f].type = ty; nodes[f].a = params;
    return f;
}

/* global: tipo nome = CONST; | tipo nome; | tipo nome[CONST]; */
static int parse_global(int line, int ty, const char *name) {
    if (ty == TY_VOID) err_at(line, "global de tipo void");
    i64 nelem = 0;
    int init = 0;
    if (cur.id == K_LBRACK) {
        next();
        int e = fold(parse_expr(0));
        if (nodes[e].kind != N_INT || nodes[e].val <= 0)
            err_at(line, "tamanho de array deve ser constante positiva");
        nelem = nodes[e].val;                    /* a conta e em i64, antes de qualquer cast */
        if (nelem > ((i64)1 << 30) / type_width(ty))
            err_at(line, "array global grande demais");
        expect(K_RBRACK, "esperado ] no tamanho do array");
    } else if (cur.id == K_ASSIGN) {
        next();
        init = fold(parse_expr(0));
        if (nodes[init].kind != N_INT) err_at(line, "inicializador de global deve ser constante");
    }
    expect(K_SEMI, "esperado ; apos a global");
    int n = node_new(N_GLOBAL, line);
    nodes[n].name = name; nodes[n].type = ty; nodes[n].a = init; nodes[n].val = nelem;
    return n;
}

/* topo: so o ( depois do nome separa funcao de global */
static int parse_top(void) {
    int line = cur.line;
    int ty = type_of_token(cur.id);
    if (ty < 0) err_at(line, "tipo esperado no topo");
    next();
    if (cur.id != T_IDENT) err_at(cur.line, "nome esperado no topo");
    const char *name = xstrdup((const char *)cur.start, (size_t)cur.len);
    next();
    if (cur.id != K_LPAR) return parse_global(line, ty, name);
    int params = parse_params();
    int body = parse_block();
    int f = node_new(N_FUNC, line);
    nodes[f].name = name; nodes[f].type = ty; nodes[f].a = params; nodes[f].b = body;
    return f;
}

int parse_unit(void) {
    ops_init();
    next();
    int head = 0, tail = 0;
    while (cur.id != T_EOF) {
        if (cur.id == T_DIR) { do_directive(); continue; }
        int f = cur.id == K_EXTERN ? parse_extern() : parse_top();
        if (tail) nodes[tail].next = f; else head = f;
        tail = f;
    }
    return head;
}
