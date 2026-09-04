// main.mc — eight single-precision lanes added and multiplied with ONE AVX
// instruction each, on values the register allocator placed.
//
// The point is not the arithmetic. It is that `vaddps(a, b)` is a NAME the
// module registered with `intrinsic`, that `a` and `b` arrived at depths the
// core chose, and that the module found them with `val_reg`/`dst_reg` and wrote
// its own VEX bytes -- none of which `#opcode` can do, and none of which cost a
// line in `src/`.
//
// Build: build/mc-avx --backend=elf-obj-x86_64 examples/avx/main.mc -o main.o
// It needs a machine with AVX; see README.md.
#include <sys>

v8f32 a;
v8f32 b;
v8f32 c;

u32 lanes[8];

i64 main() {
    // the two inputs, as raw lanes: 1.0f .. 8.0f and 10.0f
    i64 i = 0;
    loop {
        if (i >= 8) break;
        st32(a + i * 4, 0x3f800000 + i * 0x00800000);   // 1.0f, 2.0f, 4.0f...
        st32(b + i * 4, 0x40000000);                    // 2.0f
        i = i + 1;
    }
    v8f32 x = vaddps(a, b);
    v8f32 y = vmulps(x, b);
    c = y;
    vstoreu(lanes, y);
    i = 0;
    loop {
        if (i >= 8) break;
        putnum(ld32(lanes + i * 4));
        puts(" ");
        i = i + 1;
    }
    puts("\n");
    return 0;
}
