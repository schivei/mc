/* parse.c — recursive descent for declarations/statements and table-driven
 * Pratt parsing for expressions. The infix/prefix tables are arrays in
 * insertion order, searched linearly: that is what #infix/#prefix mutate.
 * Line and file always travel together: whoever stores `line` stores `fl`, otherwise
 * the error for a construct that starts inside an #include cites the wrong file. */
#include "mc.h"

#define MAXOPS 128
/* 512, not 256: the transliteration to .mc spends ~104 #define entries just on the
 * offsets of the flat layouts (in C these are struct fields, zero cost), and
 * src/mc.mc reaches 319 constants. src/parse.mc has the same value. */
#define MAXDEFS 512
#define MAXOPCS 64

static InfixEnt  infixes[MAXOPS];  static int ninfix;
static PrefixEnt prefixes[MAXOPS]; static int nprefix;
static DefEnt    defs[MAXDEFS];    static int ndefs;
static OpcEnt    opcs[MAXOPCS];    static int nopcs;
static SecEnt    secs[MAXSECS];    static int nsecs;

/* parameters of the #opcode being defined right now; outside that, nparams is 0 */
static const char *opc_params[MAXPARAMS]; static int opc_nparams;
static int cur_sect;               /* current #section + 1; 0 = default section */

static Token cur;                  /* lookahead de 1 token */
static void next(void) { lex_next(&cur); }
static void expect(int id, const char *msg) {
    if (cur.id != id) err_at(cur.file, cur.line, msg);
    next();
}
static bool cur_is(const char *s) {
    return cur.len == (int)cstrlen(s) && mem_eq(cur.start, s, (size_t)cur.len);
}
/* the current token's lexeme, copied into the arena */
static const char *cur_name(void) { return xstrdup((const char *)cur.start, (size_t)cur.len); }

/* ---- Pratt tables ---- */
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
        if (ninfix == MAXOPS) die("infix table full");
        i = ninfix++;
    }
    infixes[i].tok = tok; infixes[i].prec = prec;
    infixes[i].right = right; infixes[i].tmpl = tmpl;
}
static void prefix_set(int tok, int tmpl) {
    int i = prefix_find(tok);
    if (i < 0) {
        if (nprefix == MAXOPS) die("prefix table full");
        i = nprefix++;
    }
    prefixes[i].tok = tok; prefixes[i].tmpl = tmpl;
}

/* core precedences: higher binds stronger */
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
    prefix_set(K_AND, 0);              /* &x becomes N_ADDR in parse_unary */
}

/* ---- #define: linear table of already-folded constants ---- */
static int def_find(const char *s, int len) {
    for (int i = 0; i < ndefs; i++)
        if ((int)cstrlen(defs[i].name) == len && mem_eq(defs[i].name, s, (size_t)len)) return i;
    return -1;
}
static void def_add(const char *name, i64 val, int line, const char *fl) {
    if (def_find(name, (int)cstrlen(name)) >= 0) err_at(fl, line, "duplicate #define");
    if (ndefs == MAXDEFS) die("too many defines");
    defs[ndefs].name = name; defs[ndefs].val = val;
    ndefs++;
}
/* a #define is already a constant everywhere: declaring the same name would hide the
 * constant at some points in the source and not at others. So it is an error */
static void check_def(void) {
    if (def_find((const char *)cur.start, cur.len) >= 0)
        err_at(cur.file, cur.line, "name already defined by #define");
}
/* reloc()'s relocation types: internal constants, do not need an #include */
static void defs_init(void) {
    def_add("UNSIGNED",  R_UNSIGNED,  0, "?");
    def_add("BRANCH26",  R_BRANCH26,  0, "?");
    def_add("PAGE21",    R_PAGE21,    0, "?");
    def_add("PAGEOFF12", R_PAGEOFF12, 0, "?");
}

/* ---- #section: only registers; gen_sections creates the sections in the right order ---- */
int sec_pending(void) { return nsecs; }
int sec_make(int i) { return sec_new(secs[i].seg, secs[i].sect, secs[i].flags, secs[i].align); }
static int sec_ent(const char *seg, const char *sect, u32 flags, u32 align) {
    for (int i = 0; i < nsecs; i++)
        if (str_eq(secs[i].seg, seg) && str_eq(secs[i].sect, sect)) return i;
    if (nsecs == MAXSECS) die("too many sections");
    secs[nsecs].seg = seg; secs[nsecs].sect = sect;
    secs[nsecs].flags = flags; secs[nsecs].align = align;
    return nsecs++;
}

/* ---- #opcode: linear table of encoders, in definition order ---- */
int opc_find(const char *name) {
    for (int i = 0; i < nopcs; i++) if (str_eq(opcs[i].name, name)) return i;
    return -1;
}
/* inside an #opcode's template, a parameter's name becomes a numbered N_HOLE */
static int opc_param(const u8 *s, int len) {
    for (int i = 0; i < opc_nparams; i++)
        if ((int)cstrlen(opc_params[i]) == len && mem_eq(opc_params[i], s, (size_t)len)) return i + 1;
    return 0;
}
/* #opcode call: the arguments become the template's holes, which is then folded */
int opc_expand(int i, int call) {
    int holes[MAXPARAMS + 1];
    int k = 0;
    for (int a = nodes[call].a; a; a = nodes[a].next) {
        if (k == opcs[i].nparams) err_node(call, "wrong number of arguments in #opcode");
        holes[++k] = a;
    }
    if (k != opcs[i].nparams) err_node(call, "wrong number of arguments in #opcode");
    return fold(node_copy_subst(opcs[i].tmpl, holes, k));
}

/* ---- #rule: linear table of rules, indexed by the token that opens the statement.
 * No backtracking: the current token picks the rule and from there each item has to
 * match. NODE holes (expr/stmt/block) travel via node_copy_subst; NAME holes
 * (`ident $x` and the gensym `$$t`) are swapped by pointer identity after the
 * copy — that is what lets `$x` appear where the AST holds a name
 * (left side of an assignment, local declaration) and not a node. ---- */
#define MAXRULES 32
#define MAXBIND  12               /* holes referenced by a rule (pattern + gensym) */
#define MAXRDEPTH 64              /* rule nesting in a template (MAXDEPTH in
                                   * gen_arm64.c is already the expression depth) */

static RuleEnt rules[MAXRULES]; static int nrules;
static int gensym_n;              /* $g<N> counter: deterministic, never resets */
static int rule_depth;            /* rules nested inside a template's definition */

/* holes for the rule being defined right now; bnd_txt stores the text with the $ */
static const char *bnd_txt[MAXBIND];
static int bnd_kind[MAXBIND], bnd_slot[MAXBIND], nbnd;
static int rule_def;              /* 1 while do_rule reads the pattern and template */
/* pattern under construction: only goes into the table when the definition ends */
static int r_items[MAXITEMS], r_nitems, r_nholes, r_nnames, r_lead;

static const char *nt_names[] = { "lit", "expr", "stmt", "block", "ident" };

static int bnd_find(const u8 *s, int len) {
    for (int i = 0; i < nbnd; i++)
        if ((int)cstrlen(bnd_txt[i]) == len && mem_eq(bnd_txt[i], s, (size_t)len)) return i;
    return -1;
}
/* registers the current token's hole ($name or $$name) and returns the index */
static int bnd_add(int kind, int slot) {
    if (nbnd == MAXBIND) die("too many holes in #rule");
    if (bnd_find(cur.start, cur.len) >= 0) err_at(cur.file, cur.line, "duplicate hole in #rule");
    bnd_txt[nbnd] = cur_name(); bnd_kind[nbnd] = kind; bnd_slot[nbnd] = slot;
    return nbnd++;
}
/* reserves one more name hole (pattern ident or template gensym) */
static int name_slot(void) {
    if (r_nnames == MAXNAMES) err_at(cur.file, cur.line, "too many name holes in #rule");
    return r_nnames++;
}
/* a new name per expansion: $g1, $g2, ... in the order they are created. The `$`
 * makes capture impossible by construction: the lexer never forms a T_IDENT with
 * `$`, so no name written by the user can collide with a gensym. */
static const char *gensym_new(void) {
    char tmp[24]; int i = 24; i64 v = ++gensym_n;
    do { tmp[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    char *s = xalloc((size_t)(27 - i));
    s[0] = '$'; s[1] = 'g';
    for (int k = i; k < 24; k++) s[2 + k - i] = tmp[k];
    return s;
}
/* name of a non-terminal in the pattern; 0 = the current token is not one */
static int nt_kind(void) {
    for (int i = IT_EXPR; i <= IT_IDENT; i++) if (cur_is(nt_names[i])) return i;
    if (cur_is("type")) err_at(cur.file, cur.line, "nt `type` is out of scope for M9");
    return 0;
}
/* the last rule defined for the same opening token wins */
static int rule_find(int tok, int lead) {
    for (int i = nrules - 1; i >= 0; i--)
        if (rules[i].tok == tok && rules[i].lead == lead) return i;
    return -1;
}
/* swaps in to[j] every name that still points to placeholder ph[j]: this is how
 * `ident $x` and `$$t` become real names in the freshly expanded copy */
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

/* ---- expressions ---- */
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
        int hi = opc_param(cur.start, cur.len);      /* #opcode parameter: binds first */
        if (hi) {
            int n = node_new(N_HOLE, line, fl);
            nodes[n].val = hi;
            next();
            return n;
        }
        int di = def_find((const char *)cur.start, cur.len);
        if (di >= 0) {                           /* #define comes before everything: becomes N_INT */
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
        int b = bnd_find(cur.start, cur.len);    /* hole bound by #rule */
        if (b < 0 && cur.val == -2) {            /* new $$name: template gensym */
            if (!rule_def) err_at(fl, line, "$$name only works in a #rule template");
            b = bnd_add(IT_GEN, name_slot());
        }
        if (b >= 0) {
            if (bnd_kind[b] == IT_IDENT || bnd_kind[b] == IT_GEN) {
                int n = node_new(N_IDENT, line, fl);     /* name hole */
                nodes[n].name = bnd_txt[b]; nodes[n].type = TY_I64;
                next();
                return n;
            }
            int n = node_new(N_HOLE, line, fl);
            nodes[n].val = bnd_slot[b];
            next();
            return n;
        }
        if (cur.val < 0) err_at(fl, line, "hole $name has no rule binding it");
        int n = node_new(N_HOLE, line, fl);      /* $1/$2 from #infix/#prefix */
        nodes[n].val = cur.val;
        next();
        return n;
    }
    if (cur.id == K_LPAR) {
        next();
        int ty = type_of_token(cur.id);
        if (ty >= 0) {                       /* cast: a type word came right after ( */
            if (ty == TY_VOID) err_at(fl, line, "cast to void");
            next();
            expect(K_RPAR, "expected ) in cast");
            int e = parse_unary();
            int n = node_new(N_CAST, line, fl);
            nodes[n].type = ty; nodes[n].a = e;
            return n;
        }
        int e = parse_expr(0);
        expect(K_RPAR, "expected ) after expression");
        return e;
    }
    err_at(fl, line, "expression expected");
}

/* a call is always by name: N_CALL holds the name and the argument list in a */
static int parse_call(int callee) {
    int line = cur.line; const char *fl = cur.file;
    if (nodes[callee].kind != N_IDENT) err_at(fl, line, "call by name only");
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
    expect(K_RPAR, "expected ) in call");
    int c = node_new(N_CALL, line, fl);
    nodes[c].name = name; nodes[c].a = head; nodes[c].type = TY_I64;
    return c;
}

static int parse_postfix(void) {
    int n = parse_primary();
    while (cur.id == K_LPAR) n = parse_call(n);   /* postfix: binds stronger than everything */
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
    if (tok == K_AND) {                      /* &name: address of a local */
        if (nodes[operand].kind != N_IDENT) err_at(fl, line, "& expects a name");
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

/* ---- constant folding ---- */
static i64 const_bin(int op, i64 x, i64 y, int type, int n) {
    u64 a = (u64)x, b = (u64)y;
    if (op == K_ADD) return (i64)(a + b);
    if (op == K_SUB) return (i64)(a - b);
    if (op == K_MUL) return (i64)(a * b);
    if (op == K_DIV || op == K_MOD) {
        if (y == 0) err_node(n, "division by zero");
        if (type != TY_I64) return (i64)(op == K_DIV ? a / b : a % b);   /* mirrors udiv */
        if (y == -1) return op == K_DIV ? (i64)(0 - a) : 0;     /* avoids INT64_MIN overflow */
        return op == K_DIV ? x / y : x % y;
    }
    if (op == K_AND) return (i64)(a & b);
    if (op == K_OR)  return (i64)(a | b);
    if (op == K_XOR) return (i64)(a ^ b);
    if (op == K_SHL) return (i64)(a << (b & 63));
    if (op == K_SHR) {
        if (type == TY_I64) return x >> (y & 63);              /* arithmetic */
        return (i64)(a >> (b & 63));                           /* logical */
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
}

/* type: a literal is i64; a binary op inherits the left operand's; a cast sets its own */
static void fold_unary(int n) {
    int a = fold(nodes[n].a);
    nodes[n].a = a; nodes[n].type = nodes[a].type;
    if (nodes[a].kind != N_INT) return;
    u64 v = (u64)nodes[a].val, r;
    int op = nodes[n].op;
    if (op == K_SUB)        r = 0 - v;
    else if (op == K_TILDE) r = ~v;
    else if (op == K_BANG)  r = v ? 0 : 1;
    else return;                                   /* & does not fold */
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
    nodes[n].kind = N_INT; nodes[n].val = (i64)v; nodes[n].a = 0;   /* type = the cast's own */
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

/* size between [ ]; returns 0 when the brackets come empty (`[]`) */
static i64 parse_dim(int line, const char *fl) {
    next();                                  /* [ */
    i64 nel = 0;
    if (cur.id != K_RBRACK) {
        int e = fold(parse_expr(0));
        if (nodes[e].kind != N_INT || nodes[e].val <= 0)
            err_at(fl, line, "array size must be a positive constant");
        nel = nodes[e].val;                  /* count in i64: (int) would truncate */
    }
    expect(K_RBRACK, "expected ] in the array size");
    return nel;
}

/* name in a declaration: a plain T_IDENT or, inside a #rule template,
 * a name hole (`$x` bound to a pattern's `ident`, or the gensym `$$t`) */
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

/* local declaration: type name = expr; | type name; | type name[CONST]; */
static int parse_var(int line, const char *fl, int ty) {
    if (ty == TY_VOID) err_at(fl, line, "local of type void");
    next();                                  /* type */
    const char *name = decl_name("variable name expected");
    i64 nel = 0;
    int init = 0;
    if (cur.id == K_LBRACK) {
        nel = parse_dim(line, fl);
        if (nel < 1) err_at(fl, line, "array size must be a positive constant");
        if (nel > 4095 || nel * type_width(ty) > 4095) err_at(fl, line, "local array too large");
    } else if (cur.id == K_ASSIGN) {
        next();
        init = parse_expr(0);
    }
    expect(K_SEMI, "expected ; after declaration");
    int n = node_new(N_VAR, line, fl);
    nodes[n].name = name; nodes[n].type = ty; nodes[n].a = init; nodes[n].val = nel;
    return n;
}

static int parse_stmt(void) {
    int line = cur.line; const char *fl = cur.file;
    int ri = rule_find(cur.id, 0);               /* does the current token open a rule? */
    if (ri >= 0) return rule_expand(ri, 0);
    if (cur.id == T_HOLE) {                      /* loose `$init`/`$b` in the template */
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
        expect(K_LPAR, "expected ( after if");
        int c = parse_expr(0);
        expect(K_RPAR, "expected ) after condition");
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
        if (lv < 1) err_at(fl, line, "break expects a positive level");
        expect(K_SEMI, "expected ; after break");
        int n = node_new(N_BREAK, line, fl);
        nodes[n].val = lv;
        return n;
    }
    if (cur.id == K_CONTINUE) {
        next();
        expect(K_SEMI, "expected ; after continue");
        return node_new(N_CONTINUE, line, fl);
    }
    if (cur.id == K_RETURN) {
        next();
        int e = 0;
        if (cur.id != K_SEMI) e = parse_expr(0);
        expect(K_SEMI, "expected ; after return");
        int n = node_new(N_RETURN, line, fl);
        nodes[n].a = e;
        return n;
    }
    int e = parse_expr(0);
    if (cur.id == K_ASSIGN) {                /* name = expr; (the = is not in the infix table) */
        if (nodes[e].kind != N_IDENT) err_at(fl, line, "left side of assignment must be a name");
        const char *name = nodes[e].name;
        next();
        int v = parse_expr(0);
        expect(K_SEMI, "expected ; after assignment");
        int n = node_new(N_ASSIGN, line, fl);
        nodes[n].name = name; nodes[n].a = v;
        return n;
    }
    /* a rule that starts with `ident $x`: the name was already read as an expression and
     * dispatch is still done by a literal token (`+=`, `++`), with no backtracking */
    ri = rule_find(cur.id, 1);
    if (ri >= 0) {
        if (nodes[e].kind != N_IDENT) err_at(fl, line, "the rule expected a name on the left");
        return rule_expand(ri, e);
    }
    expect(K_SEMI, "expected ; after expression");
    int n = node_new(N_EXPRSTMT, line, fl);
    nodes[n].a = e;
    return n;
}

static int parse_block(void) {
    int line = cur.line; const char *fl = cur.file;
    expect(K_LBRACE, "expected {");
    int head = 0, tail = 0;
    while (cur.id != K_RBRACE) {
        if (cur.id == T_EOF) err_at(fl, line, "unterminated block");
        int s = parse_stmt();
        if (tail) nodes[tail].next = s; else head = s;
        tail = s;
    }
    next();
    int b = node_new(N_BLOCK, line, fl);
    nodes[b].a = head;
    return b;
}

/* matches rule ri's items against the source and returns the expanded template.
 * lead != 0 is the N_IDENT that was already read before the dispatch token. */
static int rule_expand(int ri, int lead) {
    int holes[MAXITEMS + 1];
    const char *to[MAXNAMES];
    int nn = rules[ri].nnames;
    if (++rule_depth > MAXRDEPTH) die("too many nested rules");
    for (int j = 0; j < nn; j++) to[j] = 0;
    if (rules[ri].lead) to[0] = nodes[lead].name;
    for (int k = 0; k < rules[ri].nitems; k++) {
        int it = rules[ri].items[k], kd = it & 7, v = it >> 3;
        if (kd == IT_LIT) {
            if (cur.id != v) err_at2(cur.file, cur.line, "the rule expected", tok_text(v));
            next();
        } else if (kd == IT_IDENT) {
            if (cur.id != T_IDENT) err_at(cur.file, cur.line, "the rule expected a name");
            to[v] = cur_name();
            next();
        } else if (kd == IT_EXPR)  holes[v] = parse_expr(0);
        else if (kd == IT_STMT)    holes[v] = parse_stmt();
        else                       holes[v] = parse_block();
    }
    for (int j = 0; j < nn; j++) if (!to[j]) to[j] = gensym_new();   /* this $$t's turn */
    int e = node_copy_subst(rules[ri].tmpl, holes, rules[ri].nholes);
    name_fix(e, rules[ri].ph, to, nn);
    rule_depth--;
    return e;
}

/* #rule stmt: PATTERN => TEMPLATE — the pattern is a flat sequence of literal
 * tokens and `nt $name`; the template is a statement parsed here, right now, with the
 * $name entries already becoming holes. An identifier used as a literal token becomes
 * a reserved keyword on the spot (tok_add). */
static void do_rule(int line, const char *fl) {
    if (cur.id != T_IDENT) err_at(fl, line, "#rule expects category stmt");
    if (cur_is("expr")) err_at(fl, line, "#rule expr: reserved, not yet supported");
    if (!cur_is("stmt")) err_at(fl, line, "#rule only knows category stmt");
    next();
    expect(K_COLON, "expected : after the #rule category");
    if (nrules == MAXRULES) err_at(fl, line, "too many rules");
    nbnd = 0; r_nitems = 0; r_nholes = 0; r_nnames = 0; r_lead = 0;
    rule_def = 1;
    if (cur.id == T_IDENT && nt_kind() == IT_IDENT) {   /* `ident $x` before the token */
        next();
        if (cur.id != T_HOLE || cur.val != -1) err_at(cur.file, cur.line, "expected $name in the pattern");
        bnd_add(IT_IDENT, name_slot());
        next();
        r_lead = 1;
    }
    while (cur.id != K_ARROW) {
        if (cur.id == T_EOF) err_at(fl, line, "#rule without =>");
        if (r_nitems == MAXITEMS) err_at(fl, line, "too many items in the #rule pattern");
        int k = cur.id == T_IDENT ? nt_kind() : 0;
        int it;
        if (k) {
            next();
            if (cur.id != T_HOLE || cur.val != -1) err_at(cur.file, cur.line, "expected $name in the pattern");
            int slot = k == IT_IDENT ? name_slot() : ++r_nholes;
            bnd_add(k, slot);
            next();
            it = k + slot * 8;
        } else {
            /* cur_name, not cur.start: a token's lexeme stays stored in the
             * table and tok_text prints it as a string — it has to live in the arena */
            int id = cur.id == T_IDENT ? tok_add(cur_name(), cur.len) : cur.id;
            next();
            it = IT_LIT + id * 8;
        }
        if (r_nitems == 0 && (it & 7) != IT_LIT)
            err_at(fl, line, "the #rule pattern must open with a literal token");
        r_items[r_nitems++] = it;
    }
    if (r_nitems == 0) err_at(fl, line, "empty #rule pattern");
    /* the dispatch literal rules the statement parser: letting `if`, `loop`,
     * `return`, `i64` ... open a rule would hijack the language itself.
     * Punctuation stays free (`ident $x [ expr $i ] = expr $e ;` is legitimate). */
    if ((r_items[0] >> 3) >= K_U8 && (r_items[0] >> 3) <= K_EXTERN)
        err_at(fl, line, "cannot redefine core keyword");
    next();                                       /* => */
    int tmpl = parse_stmt();                      /* the $name entries already became holes */
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

/* --dump-rules: one line per rule, in definition order */
void dump_rules(void) {
    for (int i = 0; i < nrules; i++) {
        out_str(1, "rule "); out_num(1, i); out_str(1, ": stmt:");
        if (rules[i].lead) out_str(1, " ident $0");
        for (int k = 0; k < rules[i].nitems; k++) {
            int it = rules[i].items[k];
            out_str(1, " ");
            if ((it & 7) == IT_LIT) out_str(1, tok_text(it >> 3));
            else { out_str(1, nt_names[it & 7]); out_str(1, " $"); out_num(1, it >> 3); }
        }
        out_str(1, " => "); out_num(1, node_size(rules[i].tmpl)); out_str(1, " nodes\n");
    }
}

/* a constant from the source, already folded; used by #section's arguments */
static i64 const_arg(int line, const char *fl, const char *msg) {
    int e = fold(parse_expr(0));
    if (nodes[e].kind != N_INT) err_at(fl, line, msg);
    return nodes[e].val;
}

/* #section SEG SECT FLAGS [ALIGN] — current section for the following functions and globals.
 * With no arguments it returns to the default. ALIGN is log2 and defaults to 4 (16 bytes)
 * when omitted: the same alignment codegen gives __data. */
static void do_section(int line, const char *fl) {
    if (cur.id != T_IDENT) { cur_sect = 0; return; }
    const char *seg = cur_name();
    next();
    if (cur.id != T_IDENT) err_at(cur.file, cur.line, "#section expects the section name");
    const char *sect = cur_name();
    next();
    i64 flags = const_arg(line, fl, "#section expects constant flags");
    i64 align = 4;
    /* only a number, a #define, or a parenthesis can start the alignment:
     * none of them starts a top-level declaration, so there is no ambiguity */
    if (cur.id == T_INT || cur.id == T_IDENT || cur.id == K_LPAR) {
        align = const_arg(line, fl, "#section expects constant alignment");
        if (align < 0 || align > 15) err_at(fl, line, "alignment out of 0..15");
    }
    if (flags < 0 || flags > 0xffffffff) err_at(fl, line, "section flags out of 32 bits");
    cur_sect = sec_ent(seg, sect, (u32)flags, (u32)align) + 1;
}

/* #opcode name(p1, ...) EXPR — registers an encoder; it is neither a symbol nor a function.
 * A parameter's name deliberately shadows a #define of the same name: inside
 * the template primary() consults opc_param before def_find, so the parameter
 * wins. That is what is wanted — the template speaks about its own arguments — and it holds
 * only until the end of the definition, when opc_nparams goes back to zero. */
static void do_opcode(int line, const char *fl) {
    if (cur.id != T_IDENT) err_at(fl, line, "#opcode expects a name");
    const char *name = cur_name();
    next();
    expect(K_LPAR, "expected ( in #opcode");
    opc_nparams = 0;
    while (cur.id != K_RPAR) {
        if (cur.id != T_IDENT)         err_at(cur.file, cur.line, "parameter name expected in #opcode");
        if (opc_nparams == MAXPARAMS)  err_at(cur.file, cur.line, "at most 8 parameters in #opcode");
        opc_params[opc_nparams++] = cur_name();
        next();
        if (cur.id != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "expected ) in #opcode");
    int tmpl = parse_expr(0);                    /* the parameters already became N_HOLE */
    int np = opc_nparams;
    opc_nparams = 0;                             /* outside the definition there is no parameter */
    if (opc_find(name) >= 0) err_at(fl, line, "duplicate #opcode");
    if (nopcs == MAXOPCS)    die("too many opcodes");
    opcs[nopcs].name = name; opcs[nopcs].nparams = np; opcs[nopcs].tmpl = tmpl;
    nopcs++;
}

/* ---- supported directives: #include, #define, #token, #infix, #prefix,
 * #rule, #section, #opcode ---- */
static void do_directive(void) {
    int d = (int)cur.val, line = cur.line;
    const char *fl = cur.file;
    next();
    if (d == D_INCLUDE) {
        if (cur.id != T_STR) err_at(fl, line, "#include expects a string");
        const char *path = cur_name();
        lex_include(path, line);                 /* false = already included: keep going */
        next();                                  /* already in the included file, if a push happened */
        return;
    }
    if (d == D_DEFINE) {
        if (cur.id != T_IDENT) err_at(fl, line, "#define expects a name");
        const char *name = cur_name();
        next();
        int e = fold(parse_expr(0));
        if (nodes[e].kind != N_INT) err_at(fl, line, "#define expects a constant expression");
        def_add(name, nodes[e].val, line, fl);
        return;
    }
    if (d == D_TOKEN) {
        if (cur.id != T_STR) err_at(fl, line, "#token expects a string");
        tok_add((const char *)cur.start, cur.len);   /* bytes stay in the arena */
        next();
        return;
    }
    if (d == D_INFIX || d == D_PREFIX) {
        if (cur.id != T_STR) err_at(fl, line, "directive expects a string");
        int tok = tok_add((const char *)cur.start, cur.len);
        next();
        int prec = 0;
        bool right = false;
        if (d == D_INFIX) {
            if (cur.id != T_INT) err_at(cur.file, cur.line, "#infix expects the precedence");
            if (cur.val < 1 || cur.val > 100)    /* range checked in i64, before the cast */
                err_at(cur.file, cur.line, "precedence out of 1..100");
            prec = (int)cur.val;
            next();
            if (cur.id != T_IDENT) err_at(cur.file, cur.line, "#infix expects left or right");
            if (cur_is("right")) right = true;
            else if (!cur_is("left")) err_at(cur.file, cur.line, "#infix expects left or right");
            next();
        }
        int tmpl = parse_expr(0);                    /* $1/$2 become N_HOLE */
        if (d == D_INFIX) infix_set(tok, prec, right, tmpl);
        else              prefix_set(tok, tmpl);
        return;
    }
    if (d == D_RULE)    { do_rule(line, fl);    return; }
    if (d == D_SECTION) { do_section(line, fl); return; }
    if (d == D_OPCODE)  { do_opcode(line, fl);  return; }
    err_at(fl, line, "directive not yet supported");
}

/* ---- top level ---- */
/* parameter list, parentheses included; none pass through the stack */
static int parse_params(void) {
    expect(K_LPAR, "expected ( in the parameter list");
    int head = 0, tail = 0, n = 0;
    while (cur.id != K_RPAR) {
        int line = cur.line; const char *fl = cur.file;
        int pty = type_of_token(cur.id);
        if (pty < 0)         err_at(fl, line, "type expected in parameter");
        if (pty == TY_VOID)  err_at(fl, line, "parameter of type void");
        next();
        if (cur.id != T_IDENT) err_at(cur.file, cur.line, "parameter name expected");
        check_def();
        const char *pname = cur_name();
        next();
        int p = node_new(N_PARAM, line, fl);
        nodes[p].type = pty; nodes[p].name = pname;
        if (tail) nodes[tail].next = p; else head = p;
        tail = p;
        n++;
        if (n > MAXPARAMS) err_at(fl, line, "at most 8 parameters");
        if (cur.id != K_COMMA) break;
        next();
    }
    expect(K_RPAR, "expected ) in the parameter list");
    return head;
}

/* extern type name(params); — undefined symbol, resolved by ld */
static int parse_extern(void) {
    int line = cur.line; const char *fl = cur.file;
    next();                                  /* extern */
    int ty = type_of_token(cur.id);
    if (ty < 0) err_at(cur.file, cur.line, "type expected in extern");
    next();
    if (cur.id != T_IDENT) err_at(cur.file, cur.line, "name expected in extern");
    check_def();
    const char *name = cur_name();
    next();
    int params = parse_params();
    expect(K_SEMI, "expected ; after extern");
    int f = node_new(N_EXTERN, line, fl);
    nodes[f].name = name; nodes[f].type = ty; nodes[f].a = params;
    return f;
}

/* global array initializer: { c1, c2, ... }, each element a constant or,
 * for uptr, a string literal. Returns the list and the count in pn */
static int parse_initlist(int line, const char *fl, int ty, i64 *pn) {
    expect(K_LBRACE, "expected { in the array initializer");
    int head = 0, tail = 0;
    i64 k = 0;
    while (cur.id != K_RBRACE) {
        int e = fold(parse_expr(0));
        if (nodes[e].kind == N_STR) {
            if (ty != TY_UPTR) err_node(e, "a string only initializes uptr");
        } else if (nodes[e].kind != N_INT) err_node(e, "initializer must be constant");
        if (tail) nodes[tail].next = e; else head = e;
        tail = e;
        k++;
        if (cur.id != K_COMMA) break;
        next();
    }
    expect(K_RBRACE, "expected } in the array initializer");
    if (k == 0) err_at(fl, line, "empty array initializer");
    *pn = k;
    return head;
}

/* global: type name[N] = { ... }; | type name = CONST; | type name; | type name[CONST]; */
static int parse_global(int line, const char *fl, int ty, const char *name) {
    if (ty == TY_VOID) err_at(fl, line, "global of type void");
    i64 nel = 0, count = 0;
    int init = 0;
    bool arr = cur.id == K_LBRACK;
    if (arr) nel = parse_dim(line, fl);
    if (cur.id == K_ASSIGN) {
        next();
        if (arr) {
            init = parse_initlist(line, fl, ty, &count);
            if (nel == 0) nel = count;                   /* [] = { ... }: N comes from the list */
            if (count > nel) err_at(fl, line, "initializer with too many elements");
        } else {
            init = fold(parse_expr(0));
            if (nodes[init].kind != N_INT) err_at(fl, line, "global initializer must be constant");
        }
    }
    if (arr && nel <= 0) err_at(fl, line, "array size must be a positive constant");
    if (nel > ((i64)1 << 30) / type_width(ty)) err_at(fl, line, "global array too large");
    expect(K_SEMI, "expected ; after the global");
    int n = node_new(N_GLOBAL, line, fl);
    nodes[n].name = name; nodes[n].type = ty; nodes[n].a = init; nodes[n].val = nel;
    return n;
}

/* top level: only the ( after the name separates a function from a global; a ; where the body would be is a prototype */
static int parse_top(void) {
    int line = cur.line; const char *fl = cur.file;
    int ty = type_of_token(cur.id);
    if (ty < 0) err_at(fl, line, "type expected at top level");
    next();
    if (cur.id != T_IDENT) err_at(cur.file, cur.line, "name expected at top level");
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
        nodes[f].sect = cur_sect;                /* placement of the current #section */
        if (tail) nodes[tail].next = f; else head = f;
        tail = f;
    }
    return head;
}
