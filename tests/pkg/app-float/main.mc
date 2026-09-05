// main.mc -- the override: `float` is a name the binary already ships, and this
// project pins a package that carries it. The `!` is the fixture's one visible
// difference; with no [deps] float line the same source prints without it.
//
// expect-exit: 42
// expect-stdout: 1.500000!
#include <sys>
#include <float/float_rt.mc>

i64 main() {
    putf64(1.5, 6);
    puts("\n");
    return 42;
}
