// expect-exit: 42
// O segundo #include do mesmo caminho e ignorado (once-only): sem redefinicao.
#include "lib/util.mc"
#include "lib/util.mc"

i64 main() { return triple(12) + util_extra(); }
