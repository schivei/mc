// expect-exit: 0
// expect-stdout: 0x3fd3333333333334 0x400921fb54442d11 0x7fe1ccf385ebc8a0 0x0000000000000001 0x4415af1d78b58c40 0x419d6f3454800000
// The decimal-to-binary conversion is CORRECTLY ROUNDED, and these are the cases
// that say so: a value with no exact binary form (0.1 + 0.2, whose sum ends in
// ...334 and not ...333), pi to fifteen digits, the largest normal (1e308), the
// smallest SUBNORMAL (5e-324, whose entire significand is one bit), a value past
// 2^53 where the exponent does the work (1e20), and one that is exact.
//
// The algorithm is in lib/float.mc and uses integers only -- the value is the
// exact rational U/V, the quotient is taken with one guard bit over a 2048-bit
// big integer, and the remainder decides the tie. There is no double rounding
// and no floating-point arithmetic at compile time, because the compiler that
// runs it has none.
#include <sys>
#include <float_rt>

i64 main() {
    puthexf(0.1 + 0.2);          puts(" ");
    puthexf(3.14159265358979);   puts(" ");
    puthexf(1e308);              puts(" ");
    puthexf(5e-324);             puts(" ");
    puthexf(1e20);               puts(" ");
    puthexf(123456789.125);      puts("\n");
    return 0;
}
