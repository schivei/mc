// 077-type-consumed-zero.mc — the guard the type position needs most, and the
// one the M41.5 review had already found one position over: a syntax_type
// handler that CONSUMES tokens and then returns 0.
//
// 0 means "not mine, the core keeps the type it read". A handler that scanned a
// suffix, moved the cursor and then declined would leave the core reading the
// rest of the declaration from the middle of a type: `u8[] x;` would be read as
// a `u8` named... whatever came after the brackets, with no diagnostic anywhere.
//
// lib/user_syntax_demo.mc registers `sd_teat`, which eats `[` `]` after a `u8`
// and then declines. Outside scripts/test.sh, like tests/err/073 and 074;
// scripts/check-surface.sh asserts the exact message.
//
// $ build/mc-syntax-demo tests/err/077-type-consumed-zero.mc -o /tmp/x.o
// tests/err/077-type-consumed-zero.mc:18: syntax_type handler consumed tokens and returned 0: u8

i64 main() {
    u8[] x;
    return x;
}
