// expect-exit: 0
// expect-stdout: 3 -3 -1 3
// skip-windows: `extern i32 f(f64)` needs a C function to call, and the Windows
// target links against kernel32 alone -- there is no C runtime on it at all
//
// M45, risk 4: the shape `set_walk_depth_type(depth, rt)` exists for.
//
// After MTASK_CALL the walker's dtype[depth] still describes ARGUMENT 0, and a
// derived machine's MTASK_CAST reads that as the SOURCE type. For an
// `extern i32 f(f64 x)` -- an integer result from a function whose first
// argument is a double -- <float>'s fa_cast/fx_cast would see `f64` as the
// source of the narrowing cast the walker issues and emit `fcvtzs`/`cvttsd2si`
// on a general-purpose register that never held a float. With the line, the
// cast is int-to-int and delegates to the pristine `sxtw`/`movsxd`.
//
// `ilogb` is the C function with exactly that signature -- `int ilogb(double)`
// -- and every libc this project links against has it. `abs` covers the plainer
// half, an i32 argument and an i32 result.
//
// The float TYPES come from the COMPILER (build/mc-float), not from an include:
// `#include <float>` here would compile the module's own literal parser into
// the program.
#include <sys>
#include <float_rt>

extern i32 abs(i32 x);                    // int abs(int)
extern i32 ilogb(f64 x);                  // int ilogb(double) -- an f64 arg, an int out

i64 main() {
    putnum(abs(0 - 3));       puts(" ");   // 3: an i32 argument and an i32 result
    puti32(0 - 3);            puts(" ");   // -3: the callee half, an mc i32 function
    puti32(neg_i32());        puts(" ");   // -1: a call whose result is narrowed
    putnum(ilogb(8.0));       puts("\n");  // 3: THE case -- f64 in, i32 out
    return 0;
}

i32 neg_i32() { return 0 - 1; }

void puti32(i32 v) {
    if (v < 0) { puts("-"); putnum(0 - v); return; }
    putnum(v);
}
