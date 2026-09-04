// expect-exit: 0
// expect-stdout: 2 2 0 1 7 1
// (i64) f truncates TOWARD ZERO on both signs -- the C rule, and what fcvtzs and
// cvttsd2si both do, which is why the same source is the oracle on every leg.
// The negative results are negated back before printing: <io>'s putnum is
// unsigned, and the last column is the sign test itself.
#include <sys>
#include <float_rt>

i64 main() {
    i64 a = (i64) 2.75;
    i64 b = (i64) (-2.75);
    i64 c = (i64) 0.9;
    i64 d = (i64) (-1.9);
    i64 e = (i64) 7.0;
    putnum(a);     puts(" ");
    putnum(0 - b); puts(" ");
    putnum(c);     puts(" ");
    putnum(0 - d); puts(" ");
    putnum(e);     puts(" ");
    putnum(b < 0 && d < 0); puts("\n");
    return 0;
}
