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
//   stmtcount / ifcount          a counter fed by EVERY statement  (on_stmt)
//   blockdepth                   the deepest scope seen so far   (syntax_stmt "{")
//   tmpl slot<T, N> { ... }      a body recorded, not parsed     (p_skip_balanced)
//   make slot<i64, 3>;           the body re-parsed once per     (p_push_source
//                                argument tuple                   + p_subst_*)
//   make slot<i64, sum<1, 2>>;   `>>` split into two `>`         (p_resplit_punct)
//
// M31 adds the two gaps the concurrency panel found (docs/specs/M31.md § 2):
//
//   widen x = f(a);              the local's type and the argument  (decl_find
//                                casts come from f's DECLARATION     + decl_ret
//                                                                    + decl_nparams
//                                                                    + decl_param_type)
//   guard tick() { ... }         one statement on EVERY exit edge  (on_jump)
//   jumpdepth / retcount         the depth of the deepest jump, and the returns
//                                that still LOOKED like returns to on_stmt
//
// M41.5 adds the one parse position that had no hook at all -- the parameter
// list (docs/specs/M41.5.md):
//
//   i64 f(i64 x, i64 y = 10)     a DEFAULT parameter, recorded by      (syntax_param
//                                the module and filled in at the        + p_decl_name
//                                call site from a pass()                + decl_find
//                                                                       + decl_nparams)
//   i64 g(params i64 xs)         a parameter that opens with a TAUGHT
//                                word, lowered to `uptr xs`
//
//   capsule Name { ... }         a container whose members the MODULE     (syntax
//                                declares, with the public parse_params()  + p_set_decl_name
//                                and parse_function(), announcing each      + parse_function)
//                                member's name before its parameters
//
// Three more, `pnop`, `pbad` and `peat`, are broken on purpose the way
// `nop`/`nil` are, and so is the syntax_lit handler `sd_leat` (a literal ending
// in `q`): tests/err/071 to 074 are their whole reason to be here.
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

// ---- M21.5: on_stmt, a counter that rewrites nothing ----
// The hook receives EVERY statement the parser produces -- the core's
// `i64 a = 1;` and `return`, and the taught `unless` too, as the N_IF its own
// handler built. It returns the node it was given, so the AST is exactly what
// it would have been without the registration; only the two counters move.
// `stmtcount` and `ifcount` read them back at the point the expression is
// parsed, which is what makes them observable from a test program.
i64 sd_nstmt = 0;
i64 sd_nif   = 0;
// M31: how many statements still LOOKED like a return by the time on_stmt ran.
// A guarded jump does not: on_jump replaced it with an N_BLOCK first, and that
// ordering is the whole reason on_stmt is not a substitute for on_jump.
i64 sd_nret  = 0;

i64 sd_count(i64 n) {
    sd_nstmt = sd_nstmt + 1;
    if (nd_kind(n) == N_IF) sd_nif = sd_nif + 1;
    if (nd_kind(n) == N_RETURN) sd_nret = sd_nret + 1;
    return n;                                    // rewrites nothing
}

i64 sd_stmtcount() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `stmtcount` word
    return sd_int(sd_nstmt, line, fl);
}

i64 sd_ifcount() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `ifcount` word
    return sd_int(sd_nif, line, fl);
}

// ---- M21.5: scope tracking through syntax_stmt("{") ----
// The handler is the core's parse_block, line for line, plus two lines of
// bookkeeping: the AST it returns is identical, and `blockdepth` is the deepest
// nesting the module has seen. What it proves is WHICH blocks reach it -- since
// M21.5 parse_block itself dispatches here, so a function body and the
// `block $b` hole of a `#rule` (lib/prelude.mc's `while`) come through too.
// Before that, a module could only see the blocks somebody typed where a
// statement was expected, and a scope opened inside a rule body was invisible.
i64 sd_depth    = 0;
i64 sd_maxdepth = 0;

i64 sd_block() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // {
    sd_depth = sd_depth + 1;
    if (sd_depth > sd_maxdepth) sd_maxdepth = sd_depth;
    i64 head = 0;
    i64 tail = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        if (p_id() == T_EOF) err_at(fl, line, "unterminated block");
        i64 st = parse_stmt();
        if (tail) set_nd_next(tail, st); else head = st;
        tail = st;
    }
    p_next();                                    // }
    sd_depth = sd_depth - 1;
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

i64 sd_blockdepth() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `blockdepth` word
    return sd_int(sd_maxdepth, line, fl);
}

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

// ---- M31 (2.1): `widen`, a statement that reads the callee's declaration ----
// `widen x = f(a, b);` declares a local whose type is f's DECLARED RETURN TYPE
// and narrows every argument to the DECLARED PARAMETER TYPE. Neither is written
// at the use site: the module asks the core, through decl_find + decl_ret +
// decl_nparams + decl_param_type, about a declaration the parser already read.
// Before M31 the only way to that answer was to walk `unit_head`, a parser
// internal that is not part of the public API.
//
// Only what has been parsed SO FAR is visible, which is the honest limit of
// asking during the parse: `widen` sees a callee declared above it, and an
// `extern` too. The argument cast is what an FFI-marshalling module has to emit
// -- a C callee does not narrow its own arguments the way an mc prologue does --
// and `--dump-ast` shows it as a CAST node (scripts/check-surface.sh asserts it).
i64 sd_widen() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `widen` word
    uptr name = p_ident();                       // the local it declares
    p_expect(K_ASSIGN, "expected = after the widen name");
    uptr callee = p_ident();
    i64 d = decl_find(callee);
    if (d < 0) err_at2(fl, line, "widen: unknown function", callee);
    i64 ty = decl_ret(d);
    if (ty == TY_VOID)
        err_at2(fl, line, "widen: cannot bind the result of a void function", callee);
    p_expect(K_LPAR, "expected ( after the widen callee");
    i64 head = 0;
    i64 tail = 0;
    i64 na = 0;
    loop {
        if (p_id() == K_RPAR) break;
        i64 e = parse_expr(0);
        i64 pt = decl_param_type(d, na);         // -1 = more arguments than parameters
        if (pt < 0) err_at2(fl, line, "widen: wrong number of arguments", callee);
        i64 c = node_new(N_CAST, line, fl);
        set_nd_type(c, pt);
        set_nd_a(c, e);
        if (tail) set_nd_next(tail, c); else head = c;
        tail = c;
        na = na + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RPAR, "expected ) after the widen arguments");
    p_expect(K_SEMI, "expected ; after widen");
    if (na != decl_nparams(d)) err_at2(fl, line, "widen: wrong number of arguments", callee);
    i64 n = node_new(N_VAR, line, fl);
    set_nd_name(n, name);
    set_nd_type(n, ty);                          // the callee's return type, not a written one
    set_nd_a(n, sd_call(callee, head, line, fl));
    return n;
}

// ---- M31 (2.2): `guard EXPR { ... }`, one statement on every exit edge ----
// The action runs when control falls off the end of the block AND on every
// `return`/`break`/`continue` the core parses inside it. Appending it after the
// body -- the obvious version, and the one two design teams wrote -- misses the
// jumps, which for a `lock` is a deadlock. on_jump is the edge the appended copy
// cannot reach.
//
// The demo's limit, stated rather than hidden: it treats every jump inside the
// body as leaving it, which is exactly right while the body opens no loop of its
// own. A real scope guard tracks the loops it contains; `break N` with N > 1
// provably leaves more than the body and is refused here.
#define SD_MAXGUARD 8

i64 sd_gact[SD_MAXGUARD];                        // the action expression per open guard
i64 sd_gdep[SD_MAXGUARD];                        // the block depth where each one opened
i64 sd_ngd = 0;

i64 sd_gact_at(i64 g) { return ld64(sd_gact + g * 8); }
i64 sd_gdep_at(i64 g) { return ld64(sd_gdep + g * 8); }

// a fresh `EXPR;` statement per edge: node_copy, because two edges must never
// share one subtree
i64 sd_act_stmt(i64 act, i64 line, uptr fl) {
    i64 st = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(st, node_copy(act));
    return st;
}

i64 sd_guard() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `guard` word
    i64 act = parse_expr(0);                     // the action, one expression
    if (sd_ngd == SD_MAXGUARD) err_at(fl, line, "too many nested guards");
    st64(sd_gact + sd_ngd * 8, act);
    st64(sd_gdep + sd_ngd * 8, p_blockdepth());  // what a jump's depth is compared against
    sd_ngd = sd_ngd + 1;
    i64 b = parse_block();                       // on_jump fires from inside here
    sd_ngd = sd_ngd - 1;
    // the fall-through edge: the same action once more, at the end of the block
    set_nd_a(b, list_append(nd_a(b), sd_act_stmt(act, line, fl)));
    return b;
}

// ---- M31 (2.2): the on_jump handler ----
// Runs at the moment the core builds the N_RETURN/N_BREAK/N_CONTINUE, ahead of
// every on_stmt hook: what on_stmt sees for a guarded jump is the N_BLOCK below,
// which is why `retcount` stops counting it (the ordering, proved by a number).
// `depth` is what separates a jump in the guard body from one in a function the
// module generated while standing inside it -- parse_function rebases the count,
// so the generated body starts at 1 again.
i64 sd_jdepth = 0;                               // deepest jump depth seen

i64 sd_on_jump(i64 n, i64 kind, i64 depth) {
    if (depth > sd_jdepth) sd_jdepth = depth;
    i64 head = n;
    i64 g = 0;
    loop {                                       // outermost first: the innermost
        if (g >= sd_ngd) break;                  // action ends up nearest the jump
        if (depth > sd_gdep_at(g)) {
            if (kind == N_BREAK && nd_val(n) > 1)
                err_at(nd_file(n), nd_line(n),
                       "guard: break N leaves more than the guard body");
            i64 st = sd_act_stmt(sd_gact_at(g), nd_line(n), nd_file(n));
            set_nd_next(st, head);
            head = st;
        }
        g = g + 1;
    }
    if (head == n) return n;                     // no guard open: rewrites nothing
    i64 b = node_new(N_BLOCK, nd_line(n), nd_file(n));
    set_nd_a(b, head);
    return b;
}

i64 sd_jumpdepth() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `jumpdepth` word
    return sd_int(sd_jdepth, line, fl);
}

i64 sd_retcount() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `retcount` word
    return sd_int(sd_nret, line, fl);
}

// ---- M24 (Tier 4): a PRIMITIVE the core has never heard of ----
// Two registered types and one literal syntax, deliberately unrelated to
// floats: `fix` is 16.16 signed fixed point in eight bytes and `pair` is a
// sixteen-byte opaque value, which is all it takes to exercise every core
// decision M24 delegates -- the width of a frame slot, the width of a global,
// the name --dump-ast prints, the type a cast and a parameter may name, and the
// three folding guards.
//
// `1.5` is written in the source and read HERE, not in lex_number: the lexer
// stops the number at the `.` (its token is `1`), the handler rescans the raw
// bytes from p_start() and says where its literal ended with p_take_lit(). That
// is what keeps --dump-tokens byte for byte what the frozen stage0/lex.c
// produces and scripts/check-lex.sh meaningful over the whole tree.
//
// The node it returns is an ORDINARY N_INT whose val is the representation and
// whose type is the module's. Everything downstream follows from that: an
// initializer list accepts it, glob_place writes type_width bytes of it, and
// MTASK_CONST carries it to a machine -- no new node kind and no new task.
i64 sd_ty_fix  = 0;
i64 sd_ty_pair = 0;

i64 sd_dig(i64 c) { return c >= '0' && c <= '9'; }

i64 sd_lit() {
    uptr s = p_start();
    uptr e = p_src_end();
    if (s >= e || !sd_dig(ld8(s))) return 0;     // a char literal, or 0x...
    uptr q = s;
    i64 ip = 0;
    loop {
        if (q >= e || !sd_dig(ld8(q))) break;
        ip = ip * 10 + (ld8(q) - '0');
        q = q + 1;
    }
    // the `.` has to be there AND be followed by a digit: `50 .+ 60` is the
    // taught operator, not a literal, and `x.y` is nothing of ours either
    if (q + 1 >= e || ld8(q) != '.' || !sd_dig(ld8(q + 1))) return 0;
    q = q + 1;
    i64 num = 0;
    i64 den = 1;
    loop {
        if (q >= e || !sd_dig(ld8(q))) break;
        if (den < 1000000) {                     // six digits is all 16.16 can carry
            num = num * 10 + (ld8(q) - '0');
            den = den * 10;
        }
        q = q + 1;
    }
    i64 line = p_line();
    uptr fl = p_file();
    p_take_lit(q);                               // the cursor moves past the literal
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, ip * 65536 + (num * 65536 + den / 2) / den);
    set_nd_type(n, sd_ty_fix);
    p_next();
    return n;
}

// broken on purpose, and the reason tests/err/074 exists: it scans a literal
// that ends in `q`, moves the cursor past the whole thing with p_take_lit --
// and then declines. Nothing downstream could recover: the core would build its
// N_INT out of tok_val, a token whose span no longer covers what was read, and
// the bytes the handler swallowed would be gone with no diagnostic. Registered
// LAST, so that no later handler can claim the position it left in the middle.
i64 sd_leat() {
    uptr s = p_start();
    uptr e = p_src_end();
    if (s >= e || !sd_dig(ld8(s))) return 0;
    uptr q = s;
    loop {
        if (q >= e || !sd_dig(ld8(q))) break;
        q = q + 1;
    }
    if (q >= e || ld8(q) != 'q') return 0;       // only `123q` is ours
    p_take_lit(q + 1);                           // consumed...
    return 0;                                    // ...and then declined
}

// ---- M24 (M7): a NAMED HARDWARE INSTRUCTION, on values the allocator placed ----
// `rbit(x)` is AArch64's bit-reversal, which the core's operator set does not
// have and `#opcode` cannot reach for an arbitrary expression: #opcode folds
// constants and names fixed registers, so an operand would have to HAPPEN to
// sit in one, inside a whole leaf function.
//
// The handler receives its argument already lowered to depth `d`, asks the
// machine in effect where the allocator put it -- val_reg/dst_reg/dst_done, the
// three names contract version 3 publishes -- and emits one word.
void sd_rbit(i64 d, i64 nargs) {
    i64 rn = val_reg(d, REG_S1);                 // loads a spilled depth first
    i64 rd = dst_reg(d);
    ei(I_EMIT, 0, 0, 0xDAC00000 | (rn << 5) | rd);   // rbit xd, xn
    dst_done(d, rd);                             // ...and spills it back if it has to
}

// ---- M41.5: syntax_param, the parameter position ----
// Two things the mc language does not have, neither of them added to it:
//
//   i64 f(i64 x, i64 y = 10)     a DEFAULT parameter
//   i64 g(params i64 xs)         a typed variadic, C#-style
//
// Both are parameters, and until M41.5 a module could not see a parameter at
// all: `syntax` fires on the declaration's FIRST token, and `word_add` refuses
// the core type words, so no keyed table can ever be reached from `i64`.
// syntax_param is consulted at the head of parse_params's loop, before
// type_of_token, which is why `params` gets there first and why `i64 y = 10`
// can be read as one whole parameter by whoever wants the trailer.
//
// The division of labour is the point: the HOOK lets the module record the
// default; completing the call `f(1)` is the module's own job and is done from
// a pass(), with decl_find + decl_nparams. The core does nothing with what the
// handler recorded and does not know it exists.
#define SD_MAXDEF 16

uptr sd_dfn[SD_MAXDEF];                          // the declaration a default belongs to
i64  sd_didx[SD_MAXDEF];                         // its parameter index inside that declaration
i64  sd_dval[SD_MAXDEF];                         // the constant
i64  sd_ndef = 0;

i64 sd_tok_params = 0;                           // the taught word `params`
i64 sd_tok_pnop   = 0;                           // broken on purpose: tests/err/071
i64 sd_tok_pbad   = 0;                           // broken on purpose: tests/err/072
i64 sd_tok_peat   = 0;                           // broken on purpose: tests/err/073

// the parameter counter, and what makes p_decl_name() load-bearing: it is reset
// whenever the declaration under the cursor changes. The pointer p_decl_name()
// returns is the one cur_name() made for that declaration and does not move
// while the declaration is read, so identity is the right comparison.
uptr sd_pfn  = 0;
i64  sd_ppos = 0;

i64 sd_param() {
    uptr owner = p_decl_name();
    if (owner != sd_pfn) {                       // a new declaration: back to parameter 0
        sd_pfn = owner;
        sd_ppos = 0;
    }
    i64 line = p_line();
    uptr fl = p_file();
    // `params T name`: the taught word stands where the core demands a type.
    // It lowers to `uptr name` -- an ordinary parameter the core understands --
    // which is all this half is here to show.
    if (p_id() == sd_tok_params) {
        p_next();                                // the `params` word
        p_type();                                // the element type
        uptr vn = p_ident();
        sd_ppos = sd_ppos + 1;
        return param_new(TY_UPTR, vn);
    }
    i64 ty = type_of_token(p_id());
    // not a type, or `void`: decline, so the core keeps its own two diagnostics
    // (`type expected in parameter`, `parameter of type void`) word for word
    if (ty < 0 || ty == TY_VOID) return 0;
    p_next();
    uptr pn = p_ident();
    i64 idx = sd_ppos;
    sd_ppos = sd_ppos + 1;
    if (p_accept(K_ASSIGN)) {
        i64 e = fold(parse_expr(0));
        if (nd_kind(e) != N_INT)
            err_at(fl, line, "a default parameter must be a constant");
        if (owner == 0)
            err_at(fl, line, "a default parameter needs a named declaration");
        if (sd_ndef == SD_MAXDEF)
            err_at(fl, line, "too many default parameters");
        st64(sd_dfn + sd_ndef * 8, owner);
        st64(sd_didx + sd_ndef * 8, idx);
        st64(sd_dval + sd_ndef * 8, nd_val(e));
        sd_ndef = sd_ndef + 1;
    }
    return param_new(ty, pn);
}

// the two broken handlers, exactly like sd_nop/sd_nil for syntax_expr: they
// exist so tests/err/071 and tests/err/072 can assert the core's two guards
i64 sd_pnop() {
    if (p_id() != sd_tok_pnop) return 0;
    return param_new(TY_I64, "x");               // a node, and not one token consumed
}

i64 sd_pbad() {
    if (p_id() != sd_tok_pbad) return 0;
    p_next();
    return sd_int(0, p_line(), p_file());        // consumed, but it is not an N_PARAM
}

// the third broken one, and the reason tests/err/073 exists: it reads a WHOLE
// parameter, comma included, and then declines. Before the review's fix the
// core took `0` to mean "nothing happened here" and read the next parameter as
// if it were this one, so `i64 f(peat i64 x, i64 y, i64 z)` became a
// two-parameter f(y, z) that compiled clean and ran with the wrong arity.
// Registered LAST, so nothing after it can claim the position it abandoned.
i64 sd_peat() {
    if (p_id() != sd_tok_peat) return 0;
    p_next();                                    // the `peat` word
    p_type();                                    // ... the type ...
    p_ident();                                   // ... the name ...
    p_accept(K_COMMA);                           // ... and the separator
    return 0;                                    // consumed, and then declined
}

// ---- M41.5 (review): a container whose members the MODULE declares ----
// capsule Name { i64 m(i64 x, i64 y = 10) { ... } }  ->  one ordinary top-level
// function per member, read with the PUBLIC parse_params() and
// parse_function(). It is here for exactly one reason: parse_top and
// parse_extern set the declaration's name because they read it, and a handler
// in this shape reads the member's name itself -- the core never sees it, so
// p_decl_name() would answer the previous top-level name, or 0. The handler
// announces the member with p_set_decl_name() BEFORE calling parse_params(),
// and sd_param's per-declaration bookkeeping then works inside the container
// exactly as it works at the top level: two members with a default at the SAME
// parameter index keep their own.
void sd_capsule() {
    p_next();                                    // the `capsule` word
    p_ident();                                   // the container's name
    p_expect(K_LBRACE, "expected { after the capsule name");
    loop {
        if (p_id() == K_RBRACE) break;
        i64 line = p_line();
        uptr fl = p_file();
        i64 ty = p_type();
        uptr mname = p_ident();
        p_set_decl_name(mname);                  // whose parameters these are
        i64 params = parse_params();
        i64 f = parse_function(ty, mname, params);
        set_nd_line(f, line);                    // the member starts at its type
        set_nd_file(f, fl);
        top_add(f);                              // ... and top_add clears the name
    }
    p_expect(K_RBRACE, "expected } to close the capsule");
}

// which recorded default, if any, belongs to parameter `idx` of `fname`
i64 sd_default_of(uptr fname, i64 idx) {
    i64 i = 0;
    loop {
        if (i >= sd_ndef) break;
        if (ld64(sd_didx + i * 8) == idx && str_eq(ld64(sd_dfn + i * 8), fname)) return i;
        i = i + 1;
    }
    return -1;
}

// The half the hook does NOT do. A pass sees the whole unit, so decl_find here
// answers about a callee declared below the call as well -- the honest
// difference from asking during the parse, where only what is already appended
// is visible.
i64 sd_defaults(i64 root) {
    if (sd_ndef == 0) return root;               // nothing recorded: the pass is a no-op
    i64 top = nnodes;                            // nodes this pass appends are not calls
    i64 n = 1;
    loop {
        if (n >= top) break;
        if (nd_kind(n) == N_CALL) {
            uptr fname = nd_name(n);
            i64 d = decl_find(fname);
            i64 np = decl_nparams(d);            // -1 when there is no declaration
            i64 na = 0;
            i64 a = nd_a(n);
            loop {
                if (a == 0) break;
                na = na + 1;
                a = nd_next(a);
            }
            loop {
                if (na >= np) break;
                i64 k = sd_default_of(fname, na);
                if (k < 0) break;                // no default there: the arity error stands
                set_nd_a(n, list_append(nd_a(n),
                         sd_int(ld64(sd_dval + k * 8), nd_line(n), nd_file(n))));
                na = na + 1;
            }
        }
        n = n + 1;
    }
    return root;
}

void user_init() {
    sd_ty_fix  = type_new("fix",  8,  8,  TK_INT);    // M24: two taught primitives
    sd_ty_pair = type_new("pair", 16, 16, TK_WIDE);
    syntax_lit(&sd_lit);                         // M24: the literal position
    intrinsic("rbit", 1, TY_I64, &sd_rbit);      // M24: one instruction, by name
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
    on_stmt(&sd_count);                          // M21.5: every statement
    syntax_stmt("{", &sd_block);                 // M21.5: every block
    syntax_expr("stmtcount",  &sd_stmtcount);    // the two counters, readable
    syntax_expr("ifcount",    &sd_ifcount);
    syntax_expr("blockdepth", &sd_blockdepth);
    syntax_stmt("widen", &sd_widen);             // M31: decl_find + the three readers
    syntax_stmt("guard", &sd_guard);             // M31: a statement on every exit edge
    on_jump(&sd_on_jump);                        // M31: return / break / continue
    syntax_expr("jumpdepth", &sd_jumpdepth);     // the two M31 counters, readable
    syntax_expr("retcount",  &sd_retcount);
    sd_tok_params = word_add("params");          // M41.5: the parameter position
    sd_tok_pnop   = word_add("pnop");            // broken on purpose: tests/err/071
    sd_tok_pbad   = word_add("pbad");            // broken on purpose: tests/err/072
    sd_tok_peat   = word_add("peat");            // broken on purpose: tests/err/073
    syntax_param(&sd_pnop);
    syntax_param(&sd_pbad);
    syntax_param(&sd_param);                     // the one that claims real parameters
    syntax_param(&sd_peat);                      // LAST: it consumes and declines
    syntax_lit(&sd_leat);                        // LAST, for the same reason
    syntax("capsule", &sd_capsule);              // p_set_decl_name, per member
    pass(&sd_defaults);                          // ...and completes the calls it enabled
    // the operator's runtime, as a second source: the same mechanism an
    // instantiation uses, at the simplest point there is — before the first
    // token of the real file has been read, so no lookahead is at stake
    uptr rt = ld64(sd_rt);
    p_push_source("box runtime", rt, cstrlen(rt));
}
