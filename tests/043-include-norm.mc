// expect-exit: 42
// path_join normaliza . e .. lexicamente: "inc/c.mc" e "inc/a/../c.mc" sao o
// mesmo caminho, entao o once-only pega e comum() nao e declarada duas vezes.
#include "inc/c.mc"
#include "./inc/a/b.mc"

i64 main() { return pelo_b(); }
