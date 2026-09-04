// expect-exit: 0
// expect-stdout: 0x4008000000000000 0xc340000000000000 0x43f0000000000000 0x4000000000000000
// (f64) i is signed and (f64) u is unsigned, and the difference is visible: the
// same 64 bits are 1.8446744073709552e19 as a u64 and -1.0 as an i64.
// AArch64 has scvtf/ucvtf; SSE2 only converts signed, so the x86-64 machine
// takes the halving path for the unsigned one -- the answer is the same.
#include <sys>
#include <float_rt>

i64 main() {
    i64 a = 3;
    i64 b = -9007199254740992;
    u64 c = 0xffffffffffffffff;
    u8  d = 2;
    puthexf((f64) a); puts(" ");
    puthexf((f64) b); puts(" ");
    puthexf((f64) c); puts(" ");
    puthexf((f64) d); puts("\n");
    return 0;
}
