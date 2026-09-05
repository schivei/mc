// 079-type-badid.mc — the third guard, and this position's own: the id a
// syntax_type handler returns goes straight into type_width / type_align /
// type_kind. An id outside the registry is a wrong frame layout later, not a
// diagnostic here, so the core checks it against type_count().
//
// lib/user_syntax_demo.mc registers `sd_tbad`, which eats `[` `]` after a `u32`
// (so the first guard is satisfied) and answers 9999.
//
// $ build/mc-syntax-demo tests/err/079-type-badid.mc -o /tmp/x.o
// tests/err/079-type-badid.mc:13: syntax_type handler returned an invalid type: u32

i64 main() {
    u32[] x;
    return x;
}
