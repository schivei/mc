// user_syntax_demo.mc — the Tier 3 (M12) demonstration: syntax taught by
// code. Three things the core does not have and `#rule` cannot reach,
// written from outside, without touching `src/`:
//
//   unless (cond) { ... }        new statement    (syntax_stmt)
//   enum Name { A, B, C }        new declaration  (syntax)
//   bool                         new type         (type_alias)
//
// `unless` would fit in a `#rule stmt:`; it is here on purpose, to show the
// same result via both paths. `enum` does not fit: it is a top-level
// position, the list has variable size and the effect is registering
// constants, not producing a node. `bool` does not fit either: `#rule` has no
// `type $t` hole.
//
// This module does not go into src/: whoever wires it in is
// lib/mc_syntax_demo.mc, a compiler of its own that includes `src/core.mc`
// and defines the `user_init` below. See docs/surface.md § Tier 3 and
// scripts/check-surface.sh.

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

void user_init() {
    syntax("enum", &sd_enum);                    // top-level position
    syntax_stmt("unless", &sd_unless);           // statement position
    type_alias("bool", TY_U8);                   // new type, no new syntax
}
