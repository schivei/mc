// 074-lit-consumed-zero.mc — the same shape at the literal position (M24), which
// had the same latent hole: a syntax_lit handler may move the cursor with
// p_take_lit and then answer 0, and the core would build its N_INT out of a
// token whose span no longer covers what was read.
//
// lib/user_syntax_demo.mc registers `sd_leat`, which claims a literal ending in
// `q`, consumes it, and declines. Before the fix this file compiled to
// `return 7;` -- the `q` swallowed, no diagnostic anywhere.
//
// $ build/mc-syntax-demo tests/err/074-lit-consumed-zero.mc -o /tmp/x.o
// tests/err/074-lit-consumed-zero.mc:14: syntax_lit handler consumed tokens and returned 0: 7

i64 main() {
    return 7q;
}
