// expect-exit: 0
// expect-stdout: 0x4010000000000000 0x4008000000000000 0x4023000000000000 0x3ff0000000000000
// Arithmetic and precedence on f64, bit-exact. Every expected value was produced
// once by python3 (struct.pack('<d', v)) and RECORDED here: the suite has no
// python3 dependency, and a change in the machine or in the literal reader shows
// up as a differing bit pattern rather than as a rounding argument.
//
//   1.5 + 2.5        = 4.0
//   1.5 * 2.0        = 3.0
//   1.5 + 2.0 * 4.0  = 9.5   (precedence: the taught type uses the core's table)
//   3.0 / 3.0        = 1.0
#include <sys>
#include <float_rt>

i64 main() {
    puthexf(1.5 + 2.5);      puts(" ");
    puthexf(1.5 * 2.0);      puts(" ");
    puthexf(1.5 + 2.0 * 4.0); puts(" ");
    puthexf(3.0 / 3.0);      puts("\n");
    return 0;
}
