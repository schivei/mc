// expect-exit: 0
// expect-stdout: 45 0x4022000000000000
// Nine integer arguments and three float ones: the ninth integer overflows the
// register file and travels on the STACK, at the caller's outgoing area, while
// the three floats still fit in v0..v2 / xmm0..xmm2. Two counters, not one --
// which is exactly what an ABI that separates the files means, and what a
// positional rule would get wrong.
#include <sys>
#include <float_rt>

i64 nine(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h, i64 i, f64 x, f64 y, f64 z) {
    return a + b + c + d + e + f + g + h + i;
}

f64 three(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h, i64 i, f64 x, f64 y, f64 z) {
    return x + y + z;
}

i64 main() {
    putnum(nine(1, 2, 3, 4, 5, 6, 7, 8, 9, 1.0, 2.0, 6.0));  puts(" ");
    puthexf(three(1, 2, 3, 4, 5, 6, 7, 8, 9, 1.0, 2.0, 6.0)); puts("\n");
    return 0;
}
