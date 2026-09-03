// pass_demo.mc — AST pass from the M10 demonstration: replaces `x * 1` with `x`.
//
// Proves that the AST is operable from outside the compiler: it is a flat
// array in the arena with accessors (`nd_kind`, `nd_op`, `nd_a`, ...), so an
// external module walks `1..nnodes-1` and rewrites the nodes in place. The
// product becomes a copy of the left-hand operand; the `next` field is
// preserved because it belongs to the sibling list the node is in, not to the
// node that replaces it.
//
// The core does not do this: `fold` only folds constant with constant, and
// `x` is not a constant. With the pass wired in, `--dump-ast` of
// tests/061-pass.mc shows `IDENT name=x` where there used to be a `BINARY op=*`.

i64 pass_mul1(i64 root) {
    i64 i = 1;
    loop {
        if (i >= nnodes) break;
        if (nd_kind(i) == N_BINARY && nd_op(i) == K_MUL) {
            i64 b = nd_b(i);
            if (nd_kind(b) == N_INT && nd_val(b) == 1) {
                i64 nx = nd_next(i);
                node_assign(i, nd_a(i));       // the operand takes the product's place
                set_nd_next(i, nx);
            }
        }
        i = i + 1;
    }
    return root;
}
