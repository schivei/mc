// user_tokadd.mc — M10 regression: a `user_init` that pokes at the lexer table.
//
// This module teaches nothing: it only registers a new lexeme. It exists to
// pin down the driver's initialization order. The ids of the core's words
// (`K_U8`..`K_EXTERN` = 256..269) are the 14 first entries `tok_init`
// creates, in the order it creates them; if `user_init` ran before
// `tok_init`, this `tok_add` would take id 256 and shift all of them — the
// whole core would start reading `u8` as `u16` and so on down the line.
// `scripts/check-surface.sh` wires this module in, recompiles the compiler
// and checks that `tests/001-return42.mc` still compiles and returns 42.
//
// See src/main.mc: `user_init()` is called after `tok_init()` and
// `lex_init()`, and before any token is read — the lexer is incremental, so
// a `tok_add` from here still applies to the whole source.

void user_init() {
    tok_add("<+>", 3);
}
