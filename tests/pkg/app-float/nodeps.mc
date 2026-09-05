// nodeps.mc -- the same program with the [deps] float line gone: `<float_rt>`
// is a bundled name again and the `!` disappears. Its object is what "the
// override leaves nothing behind" means.
//
// expect-exit: 42
// expect-stdout: 1.500000
#include <sys>
#include <float_rt>

i64 main() {
    putf64(1.5, 6);
    puts("\n");
    return 42;
}
