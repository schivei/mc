// expect-exit: 0
// expect-stdout: 0x3ff6a09e667f3bcd 0x3ff6a09e667f3bcd 0x4008000000000000 0x3ff0000000000000 0x4000000000000000
// skip-windows: the Windows target links against kernel32 alone -- there is no C
// runtime on it at all, so libm's sqrt is not there to call (docs/guide/95-windows-host.md)
//
// `extern f64 sqrt(f64 x)` is THE case that is flatly unreachable without M24:
// the argument has to arrive in v0 / xmm0 and the result has to come back from
// there, and before `walk_depth_type` the walker had no way to tell MTASK_CALL
// that an argument was a double. The first column is that call; the second is
// `sqrt_f64`, the same operation as ONE INSTRUCTION through `intrinsic`, and the
// two agree bit for bit.
#include <sys>
#include <float_rt>

extern f64 sqrt(f64 x);

i64 main() {
    puthexf(sqrt(2.0));      puts(" ");
    puthexf(sqrt_f64(2.0));  puts(" ");
    puthexf(fabs(-3.0));     puts(" ");
    puthexf(fmin(1.0, 2.0)); puts(" ");
    puthexf(fmax(1.0, 2.0)); puts("\n");
    return 0;
}
