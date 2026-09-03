// expect-exit: 42
// path_join normalizes . and .. lexically: "inc/c.mc" and "inc/a/../c.mc" are
// the same path, so once-only catches it and common() is not declared twice.
#include "inc/c.mc"
#include "./inc/a/b.mc"

i64 main() { return via_b(); }
