// 078-type-noadvance.mc — the first guard, the one every handler position has:
// a syntax_type handler that answers a type without reading a token. There is
// no suffix then, so the answer cannot be about this position, and the core
// would silently swap the declared type for one the source never spelled.
//
// lib/user_syntax_demo.mc registers `sd_tnop`, which returns the taught `i64[]`
// on a `u16` followed by `[` and consumes nothing.
//
// $ build/mc-syntax-demo tests/err/078-type-noadvance.mc -o /tmp/x.o
// tests/err/078-type-noadvance.mc:13: syntax_type handler consumed no tokens: u16

i64 main() {
    u16[] x;
    return x;
}
