// 073-param-consumed-zero.mc — the third guard the parameter position needs, and
// the one the M41.5 review found missing: a handler that CONSUMES tokens and
// then returns 0.
//
// Until the fix the core read 0 as "nothing happened here, the core reads this
// parameter" and went on from wherever the handler had left the cursor.
// lib/user_syntax_demo.mc registers `sd_peat`, which reads a whole parameter --
// `peat i64 x` and the comma after it -- and then declines, so this file used to
// compile CLEAN as a two-parameter f(y, z): the three-parameter declaration
// below ran as f(4, 2) and exited 42, with no diagnostic anywhere. Outside
// scripts/test.sh, like tests/err/071 and 072; scripts/check-surface.sh asserts
// the exact message.
//
// $ build/mc-syntax-demo tests/err/073-param-consumed-zero.mc -o /tmp/x.o
// tests/err/073-param-consumed-zero.mc:17: syntax_param handler consumed tokens and returned 0: peat

i64 f(peat i64 x, i64 y, i64 z) {
    return y * 10 + z;
}

i64 main() {
    return f(4, 2);
}
