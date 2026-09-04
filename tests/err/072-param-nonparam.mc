// 072-param-nonparam.mc — the second guard, and the one this position needs on
// its own: the node a syntax_param handler returns goes straight into a
// parameter list that gen_lower walks by nd_type/nd_name. Anything that is not
// an N_PARAM there is a wrong frame layout later, not a diagnostic here.
//
// lib/user_syntax_demo.mc registers `sd_pbad`, which consumes the word `pbad`
// (so the first guard is satisfied) and returns an N_INT.
//
// $ build/mc-syntax-demo tests/err/072-param-nonparam.mc -o /tmp/x.o
// tests/err/072-param-nonparam.mc:12: syntax_param handler did not return a parameter

i64 f(pbad) {
    return 0;
}

i64 main() {
    return f(1);
}
