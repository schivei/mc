// main.mc -- the consumer of tests/pkg/src: a library package with a dependency
// of its own (`geo` -> `mathx`) and a compiler-module package (`teach`, which
// is where `unless` comes from).
//
// expect-exit: 42
// expect-stdout: geo 120
#include <sys>
#include <prelude>
#include <geo/geo.mc>
#include <geo>                 // the lib entry: the SAME file, once-only

i64 main() {
    unless (geo_dot(1, 2, 3, 4) == 11) { return 1; }
    unless (geo_len2(3, 4) == 25) { return 2; }
    unless (mathx_sq(7) == 49) { return 3; }
    puts("geo ");
    putnum(geo_version());
    puts("\n");
    return 42;
}
