// expect-exit: 0
// expect-stdout: 0 0 0 0 0 0 1 1
// A NaN makes all six ORDERED predicates false and `!=` true. That is not a core
// rule -- the core only knows that a comparison yields i64 -- it is the condition
// code the module's machine picks after fcmp (mi/ls/gt/ge/eq, never lt/le) and
// after ucomisd (the unsigned codes, plus the parity flag for == and !=).
//
// The NaN is built from its bit pattern through `f64raw`, the third type <float>
// registers: the same eight bytes seen as an integer, so the cast between them is
// one `fmov`/`movq` and not a numeric conversion.
#include <sys>
#include <float_rt>

i64 main() {
    f64 n = (f64) (f64raw) 0x7ff8000000000000;
    f64 x = 1.0;
    putnum(n < x);  puts(" ");
    putnum(n <= x); puts(" ");
    putnum(n > x);  puts(" ");
    putnum(n >= x); puts(" ");
    putnum(n == x); puts(" ");
    putnum(n == n); puts(" ");
    putnum(n != x); puts(" ");
    putnum(n != n); puts("\n");
    return 0;
}
