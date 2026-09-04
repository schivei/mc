// 071-param-noadvance.mc — the first guard the core puts around a syntax_param
// handler, and the same one syntax/syntax_stmt/syntax_expr already had.
//
// lib/user_syntax_demo.mc registers `sd_pnop`, which returns a real N_PARAM on
// the word `pnop` and consumes NOTHING. parse_params would hand it the same
// token again, forever; the core stops it with a name and a position instead.
// Outside scripts/test.sh, like tests/err/055 and 064: it is a compile error by
// design. scripts/check-surface.sh asserts the exact message.
//
// $ build/mc-syntax-demo tests/err/071-param-noadvance.mc -o /tmp/x.o
// tests/err/071-param-noadvance.mc:13: syntax_param handler consumed no tokens: pnop

i64 f(pnop) {
    return 0;
}

i64 main() {
    return f(1);
}
