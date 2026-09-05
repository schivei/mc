// user_coreop.mc -- M41.5: the parser-level counterpart of lib/user_badmach.mc.
//
// lib/user_badmach.mc proves that a module can take the MACHINE slot that lowers
// `+` and make an addition come out as a subtraction. This module proves the same
// thing one seam earlier, at the PARSER: `syntax_infix("+", 9, &co_plus)` takes
// the operator itself, so `a + b` never becomes an N_BINARY at all -- it becomes
// a call to a function named `plus` that the PROGRAM provides, which is what
// operator overloading looks like when the language has no operator overloading.
//
// Until M41.5 this registration was accepted and then silently undone: ops_init()
// filled the core precedence table as parse_unit's first statement, after
// user_init(), and infix_set clears the handler column. A handler with a die() in
// it never fired and `1 + 2` still compiled to 3.
//
//   build/mc1 --exe lib/mc_coreop.mc -o build/mc-coreop
//   build/mc-coreop --exe prog.mc -o /tmp/p && /tmp/p; echo $?
//
// with prog.mc = `i64 plus(i64 a, i64 b) { return a - b; }` + `v(50) + v(8)`:
// 42 here, 58 with the stock compiler. scripts/check-surface.sh does exactly that.
//
// The precedence is the module's, not the core's: syntax_infix re-declares the
// entry, the way `#infix` does. 9 is what the core uses for `+` and `-`, so the
// `+` half of this module keeps `a + b * c` meaning `a + (b * c)`. The `*` half
// deliberately does NOT keep the core's 10: it re-declares `*` at 3, looser than
// `-`, which makes the precedence that won observable in the tree -- `a - b * c`
// comes out as `star(a - b, c)` here and as `a - (b * c)` everywhere else.
i64 co_plus(i64 left) {
    i64 line = p_line();
    uptr fl = p_file();
    // `+` is left-associative at precedence 9, so the right side stops at 10 --
    // the same `prec + 1` the core's parse_expr uses for a left-associative
    // operator. The core has already consumed the `+` before calling.
    i64 right = parse_expr(10);
    set_nd_next(left, right);                // the argument list: left, then right
    i64 n = node_new(N_CALL, line, fl);
    set_nd_name(n, "plus");
    set_nd_a(n, left);
    set_nd_type(n, TY_I64);
    return n;
}

// `*` taught the same way, at a precedence that is not the core's. Note what the
// two rewrites cost the program: `plus` and `star` cannot use `+` or `*` in their
// own bodies, because the rewrite is unconditional and program-wide -- they would
// call themselves. That is a property of THIS module, not of the mechanism; a
// real one would look at the operand types first.
i64 co_star(i64 left) {
    i64 line = p_line();
    uptr fl = p_file();
    i64 right = parse_expr(4);               // prec 3, left-associative -> 3 + 1
    set_nd_next(left, right);
    i64 n = node_new(N_CALL, line, fl);
    set_nd_name(n, "star");
    set_nd_a(n, left);
    set_nd_type(n, TY_I64);
    return n;
}

void user_init() {
    syntax_infix("+", 9, &co_plus);          // the core's own precedence, kept
    syntax_infix("*", 3, &co_star);          // 3, not the core's 10
}
