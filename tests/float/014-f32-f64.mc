// expect-exit: 0
// expect-stdout: 0x3fd0000000000000 0x000000003fc00000 0x000000003e800000 0x3fd0000000000000
// f32 and f64 are two registered types, four bytes and eight, and the conversion
// between them is one instruction (fcvt / cvtsd2ss). f32 is NOT produced by
// narrowing an f64: `0.25f` runs the same correctly-rounded conversion with a
// 24-bit significand, so there is no double rounding anywhere.
#include <sys>
#include <float_rt>

f32 g32 = 0.25f;

i64 main() {
    f32 a = 0.25f;
    f64 b = (f64) a;
    f32 c = (f32) 1.5;
    puthexf(b);        puts(" ");
    puthexf32(c);      puts(" ");
    puthexf32(g32);    puts(" ");
    puthexf((f64) g32); puts("\n");
    return 0;
}
