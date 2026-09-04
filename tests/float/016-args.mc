// expect-exit: 0
// expect-stdout: 0x4034000000000000 21
// Six integer and six float arguments in one call: twelve depths, so the depth
// stack spills on both sides (seven integer registers, eight float ones), and
// the AAPCS64 / SysV split has to route each argument by its TYPE and not by its
// position. That routing is `walk_depth_type(d + i)` in the module's MTASK_CALL
// -- the whole float ABI, and no task was added to the contract for it.
#include <sys>
#include <float_rt>

f64 fsum(f64 a, i64 p, f64 b, i64 q, f64 c, i64 r, f64 d, i64 s, f64 e, i64 t, f64 f, i64 u) {
    return a + b + c + d + e + f;
}

i64 isum(f64 a, i64 p, f64 b, i64 q, f64 c, i64 r, f64 d, i64 s, f64 e, i64 t, f64 f, i64 u) {
    return p + q + r + s + t + u;
}

i64 main() {
    puthexf(fsum(1.0, 1, 2.0, 2, 3.0, 3, 4.0, 4, 5.0, 5, 5.0, 6)); puts(" ");
    putnum(isum(1.0, 1, 2.0, 2, 3.0, 3, 4.0, 4, 5.0, 5, 5.0, 6));  puts("\n");
    return 0;
}
