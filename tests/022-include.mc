// expect-exit: 42
// The second #include of the same path is ignored (once-only): no redefinition.
#include "lib/util.mc"
#include "lib/util.mc"

i64 main() { return triple(12) + util_extra(); }
