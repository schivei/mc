// user_syntax_demo.mc — the Tier 3 demonstration, written from outside `src/`.
//
// M12 taught three things the core does not have and `#rule` cannot reach:
//
//   unless (cond) { ... }        new statement    (syntax_stmt)
//   enum Name { A, B, C }        new declaration  (syntax)
//   bool                         new type         (type_alias)
//
// M21 adds the rest of the surface, and the toy it teaches is deliberately NOT
// a class or a generic system — the point is that the same mechanisms carry a
// language that looks nothing like the one they were designed against:
//
//   bits u32                     a TYPE in expression position   (syntax_expr)
//   pipe(x, f, g)                g(f(x)), variable-length        (syntax_expr)
//   a .+ b                       saturating add at 100           (syntax_infix)
//   p ~> len   p ~> len = 3      a NAME on the right, and `=`    (syntax_infix)
//   p ~> at(i)                   a call on the right             (syntax_infix)
//   tmpl slot<T, N> { ... }      a body recorded, not parsed     (p_skip_balanced)
//   make slot<i64, 3>;           the body re-parsed once per     (p_push_source
//                                argument tuple                   + p_subst_*)
//   make slot<i64, sum<1, 2>>;   `>>` split into two `>`         (p_resplit_punct)
//
// Two more registrations, `nop` and `nil`, exist only to prove the two guards
// the core puts around a syntax_expr handler; they are broken on purpose and
// tests/err/064 and tests/err/065 are their whole reason to be here.
//
// This module does not go into src/: whoever wires it in is
// lib/mc_syntax_demo.mc, a compiler of its own that includes `src/core.mc`
// and defines the `user_init` below. See docs/surface.md § Tier 3 and
// scripts/check-surface.sh.

// ---- M12: unless / enum / bool ----

// unless (cond) block  ->  if (!cond) block
// The handler receives the parse stopped at the `unless` word and returns the
// statement node's index; consuming the word is up to it.
i64 sd_unless() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `unless` word
    p_expect(K_LPAR, "expected ( after unless");
    i64 c = parse_expr(0);
    p_expect(K_RPAR, "expected ) after unless condition");
    i64 b = parse_block();
    i64 neg = node_new(N_UNARY, line, fl);       // !cond
    set_nd_op(neg, K_BANG);
    set_nd_a(neg, c);
    i64 n = node_new(N_IF, line, fl);
    set_nd_a(n, neg);
    set_nd_b(n, b);
    return n;
}

// enum Name { A, B, C }  ->  #define A 0, #define B 1, #define C 2
// and `Name` becomes an alias of i64, so that `Name c = B;` is a valid
// declaration. Produces no declaration at all: the handler does not call
// top_add and parse_top returns 0. The whole effect is in the #define table
// and the alias table.
void sd_enum() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `enum` word
    uptr name = p_ident();
    p_expect(K_LBRACE, "expected { in enum");
    i64 v = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        def_add(p_ident(), v, line, fl);         // rejects an already-defined name
        v = v + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RBRACE, "expected } in enum");
    if (v == 0) err_at(fl, line, "enum with no members");
    type_alias(name, TY_I64);
}

// ---- M21: small node builders ----
// Nothing here is machinery the core provides: the module assembles ordinary
// nodes with node_new/set_nd_*, exactly like the core's own parser does.

i64 sd_int(i64 v, i64 line, uptr fl) {
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 sd_bin(i64 op, i64 a, i64 b, i64 line, uptr fl) {
    i64 n = node_new(N_BINARY, line, fl);
    set_nd_op(n, op);
    set_nd_a(n, a);
    set_nd_b(n, b);
    return n;
}

// a call by name, with the argument list already chained through nd_next
i64 sd_call(uptr name, i64 args, i64 line, uptr fl) {
    i64 n = node_new(N_CALL, line, fl);
    set_nd_name(n, name);
    set_nd_a(n, args);
    set_nd_type(n, TY_I64);
    return n;
}

// ---- M21: `bits TYPE` in expression position (syntax_expr) ----
// This is the case no `#prefix` template reaches: its template parses exactly
// one operand with parse_unary, and a type word is not an operand.
i64 sd_bits() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `bits` word
    i64 ty = p_type();                           // core type or type_alias
    return sd_int(type_width(ty) * 8, line, fl);
}

// ---- M21: `pipe(x, f, g)` -> g(f(x)) (syntax_expr) ----
// A variable-length list in expression position: also out of a template's reach.
i64 sd_pipe() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `pipe` word
    p_expect(K_LPAR, "expected ( after pipe");
    i64 v = parse_expr(0);
    loop {
        if (!p_accept(K_COMMA)) break;
        v = sd_call(p_ident(), v, line, fl);     // one more stage around the value
    }
    p_expect(K_RPAR, "expected ) after pipe");
    return v;
}

// ---- M21: the two guards, on purpose ----
// sd_nop returns without consuming the word; sd_nil consumes it and returns 0.
// The core refuses both, by name and with a position (tests/err/064, /065).
i64 sd_nop() { return 0; }
i64 sd_nil() { p_next(); return 0; }

// ---- M21: `a .+ b`, saturating add (syntax_infix) ----
// It lowers to a call to sd_sat100, which is not part of the compiled program:
// the module pushes it as a second source in user_init (see sd_rt below). The
// operator shares the `#infix` table, so `#infix "<+>" 9 left ...` written in
// the same file sits in one comparable precedence order with it.
#define SD_SAT_PREC 9

i64 sd_sat(i64 left) {
    i64 line = p_line();
    uptr fl = p_file();
    i64 right = parse_expr(SD_SAT_PREC + 1);     // left-associative, like the core
    set_nd_next(left, right);
    return sd_call("sd_sat100", left, line, fl);
}

// ---- M21: `p ~> field` (syntax_infix), the case a template cannot express ----
// The right operand is a NAME, resolved in the module's own table; `p ~> len = 3`
// works because `=` is deliberately not in the infix table, so the Pratt loop has
// already stopped and the handler reads the `=` itself. A box is two words of
// header (len, cap) followed by its elements.
#define SD_BOX_HEAD 16

i64 sd_field_off(uptr f) {
    if (str_eq(f, "len")) return 0;
    if (str_eq(f, "cap")) return 8;
    return -1;
}

i64 sd_arrow(i64 left) {
    i64 line = p_line();
    uptr fl = p_file();
    uptr f = p_ident();                          // the field name, on the right
    if (str_eq(f, "at")) {                       // p ~> at(i): element i
        p_expect(K_LPAR, "expected ( after ~> at");
        i64 idx = parse_expr(0);
        p_expect(K_RPAR, "expected ) after ~> at");
        i64 off = sd_bin(K_ADD, sd_int(SD_BOX_HEAD, line, fl),
                         sd_bin(K_MUL, idx, sd_int(8, line, fl), line, fl), line, fl);
        return sd_call("ld64", sd_bin(K_ADD, left, off, line, fl), line, fl);
    }
    i64 off = sd_field_off(f);
    if (off < 0) err_at2(fl, line, "unknown box field", f);
    i64 addr = sd_bin(K_ADD, left, sd_int(off, line, fl), line, fl);
    if (p_accept(K_ASSIGN)) {                    // p ~> len = e  ->  st64(p + 0, e)
        i64 v = parse_expr(0);
        set_nd_next(addr, v);
        return sd_call("st64", addr, line, fl);
    }
    return sd_call("ld64", addr, line, fl);
}

// ---- M21: tmpl / make ----
// `tmpl name<T, N> { body }` records the body without parsing it; `make
// name<i64, 3>;` re-parses it once per argument tuple, with T and N substituted.
// Mangling, memoization and the whole notion of "argument" are the module's:
// the core only hands out a span, a second source and a substitution.
#define SD_MAXTMPL 8
#define SD_MAXINST 32

uptr sd_tname[SD_MAXTMPL];
uptr sd_tp0[SD_MAXTMPL];                         // the type parameter
uptr sd_tp1[SD_MAXTMPL];                         // the constant parameter
uptr sd_tbody[SD_MAXTMPL];
i64  sd_tlen[SD_MAXTMPL];
i64  sd_ntmpl = 0;
uptr sd_inst[SD_MAXINST];                        // instantiations already generated
i64  sd_ninst = 0;

// the runtime the `.+` operator lowers to. A global array of one uptr, because
// a scalar global initializer has to be a constant and a string is not one.
uptr sd_rt[] = {
    "i64 sd_sat100(i64 a, i64 b) { i64 s = a + b; if (s > 100) { return 100; } return s; }\n"
};

i64 sd_tmpl_find(uptr name) {
    i64 i = 0;
    loop {
        if (i >= sd_ntmpl) break;
        if (str_eq(ld64(sd_tname + i * 8), name)) return i;
        i = i + 1;
    }
    return -1;
}

i64 sd_inst_find(uptr mang) {
    i64 i = 0;
    loop {
        if (i >= sd_ninst) break;
        if (str_eq(ld64(sd_inst + i * 8), mang)) return i;
        i = i + 1;
    }
    return -1;
}

// v >= 0 in decimal, in the arena
uptr sd_num(i64 v) {
    u8 tmp[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    return xstrdup(tmp + i, 24 - i);
}

// closes an argument list. A `>>` here is one token the lexer built by longest
// match and the parser cannot undo — p_resplit_punct is exactly that undo, and
// the second `>` goes back to being lexed as itself.
void sd_expect_gt() {
    if (p_id() == K_SHR) p_resplit_punct(1);
    p_expect(K_GT, "expected > in the argument list");
}

// a constant argument: a literal, or `sum<a, b>` — which exists only to make a
// nested list, and therefore a `>>`, reachable in a toy this small
i64 sd_arg_int() {
    if (p_id() == T_INT) {
        i64 v = p_val();
        p_next();
        return v;
    }
    if (p_id() == T_IDENT && str_eq(p_name(), "sum")) {
        p_next();
        p_expect(K_LT, "expected < after sum");
        i64 a = sd_arg_int();
        p_expect(K_COMMA, "expected , in sum");
        i64 b = sd_arg_int();
        sd_expect_gt();
        return a + b;
    }
    err_at(p_file(), p_line(), "expected a constant argument");
    return 0;
}

// name__type__n: the module's own mangling, from the argument LEXEMES in source
// order, which is what makes the generation order a function of first use
uptr sd_mangle(uptr name, uptr ty, i64 n) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, name, cstrlen(name));
    buf_put(b, "__", 2);
    buf_put(b, ty, cstrlen(ty));
    buf_put(b, "__", 2);
    uptr d = sd_num(n);
    buf_put(b, d, cstrlen(d));
    buf_u8(b, 0);
    return buf_p(b);
}

// "slot__i64__3 instantiated from prog.mc:7" — the provenance is a STRING the
// module composes, and err_at prints it for everything inside the frame. Nested
// instantiations compose by construction, because the module builds the name
// from the name it is already inside.
uptr sd_frame(uptr mang, uptr fl, i64 line) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, mang, cstrlen(mang));
    buf_put(b, " instantiated from ", 19);
    buf_put(b, fl, cstrlen(fl));
    buf_u8(b, ':');
    uptr d = sd_num(line);
    buf_put(b, d, cstrlen(d));
    buf_u8(b, 0);
    return buf_p(b);
}

// tmpl name<T, N> { ... } — records and produces nothing
void sd_tmpl() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `tmpl` word
    uptr name = p_ident();
    p_expect(K_LT, "expected < after the tmpl name");
    uptr p0 = p_ident();
    p_expect(K_COMMA, "expected , between the tmpl parameters");
    uptr p1 = p_ident();
    sd_expect_gt();
    if (sd_ntmpl == SD_MAXTMPL) err_at(fl, line, "too many tmpl");
    i64 len = 0;
    uptr body = p_skip_balanced(K_LBRACE, K_RBRACE, &len);
    st64(sd_tname + sd_ntmpl * 8, name);
    st64(sd_tp0 + sd_ntmpl * 8, p0);
    st64(sd_tp1 + sd_ntmpl * 8, p1);
    st64(sd_tbody + sd_ntmpl * 8, body);
    st64(sd_tlen + sd_ntmpl * 8, len);
    sd_ntmpl = sd_ntmpl + 1;
}

// generates one instantiation: header + the recorded body, re-parsed as a
// second source with the two parameters substituted
void sd_emit(i64 ti, uptr mang, uptr ty, i64 nval, i64 line, uptr fl) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, "i64 ", 4);
    buf_put(b, mang, cstrlen(mang));
    buf_put(b, "() ", 3);
    buf_put(b, ld64(sd_tbody + ti * 8), ld64(sd_tlen + ti * 8));
    if (sd_ninst == SD_MAXINST) err_at(fl, line, "too many instantiations");
    st64(sd_inst + sd_ninst * 8, mang);
    sd_ninst = sd_ninst + 1;
    p_subst_reset();
    p_subst_name(ld64(sd_tp0 + ti * 8), ty);     // T -> i64: resolved by word_id
    p_subst_int(ld64(sd_tp1 + ti * 8), nval);    // N -> a T_INT token
    i64 d0 = p_depth();
    p_push_source(sd_frame(mang, fl, line), buf_p(b), buf_len(b));
    p_next();                                    // the contract: discards the `;`
    loop {                                       // drives the generated declarations
        if (p_depth() == d0) break;              // into the unit
        top_add(parse_top());
    }
}

// make name<TYPE, CONST>; — instantiates, memoized by the mangled name
void sd_make() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `make` word
    uptr name = p_ident();
    i64 ti = sd_tmpl_find(name);
    if (ti < 0) err_at2(fl, line, "unknown tmpl", name);
    p_expect(K_LT, "expected < after the tmpl name");
    uptr ty = p_name();                          // the lexeme, for the substitution
    p_type();                                    // ... which has to BE a type
    p_expect(K_COMMA, "expected , in the make arguments");
    i64 nval = sd_arg_int();
    sd_expect_gt();
    // the lookahead contract: the handler has to sit on the LAST token of its
    // own construct when it pushes, so the `;` is not consumed here
    if (p_id() != K_SEMI) err_at(p_file(), p_line(), "expected ; after make");
    uptr mang = sd_mangle(name, ty, nval);
    if (sd_inst_find(mang) >= 0) { p_next(); return; }   // already generated
    sd_emit(ti, mang, ty, nval, line, fl);
}

void user_init() {
    syntax("enum", &sd_enum);                    // M12: top-level position
    syntax_stmt("unless", &sd_unless);           // M12: statement position
    type_alias("bool", TY_U8);                   // M12: new type, no new syntax
    syntax_expr("bits", &sd_bits);               // M21: expression position
    syntax_expr("pipe", &sd_pipe);
    syntax_expr("nop", &sd_nop);                 // broken on purpose: tests/err/064
    syntax_expr("nil", &sd_nil);                 // broken on purpose: tests/err/065
    syntax_infix(".+", SD_SAT_PREC, &sd_sat);    // M21: taught operator
    syntax_infix("~>", 12, &sd_arrow);
    syntax("tmpl", &sd_tmpl);                    // M21: record
    syntax("make", &sd_make);                    // M21: replay
    // the operator's runtime, as a second source: the same mechanism an
    // instantiation uses, at the simplest point there is — before the first
    // token of the real file has been read, so no lookahead is at stake
    uptr rt = ld64(sd_rt);
    p_push_source("box runtime", rt, cstrlen(rt));
}
