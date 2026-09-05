// mc_teach.mc -- the compiler half of the fixture package `teach`.
//
// It teaches one statement, `unless (cond) { ... }` -> `if (!cond) { ... }`,
// through the M12 hook syntax_stmt. The whole point of the fixture is WHERE it
// comes from: `[compiler] modules = ["<teach/mc_teach.mc>", "user.mc"]`, so a
// package reaches the FIRST of `mc build`'s two compilations.
//
// A package never defines user_init (M44 D8). It exports <name>_init() and the
// project's own module calls it.
i64 teach_unless() {
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

void teach_init() { syntax_stmt("unless", &teach_unless); }
