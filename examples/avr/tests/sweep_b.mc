// sweep_b.mc — memory, globals, calls, recursion, function pointers and the
// frame past `ldd`'s six-bit displacement, checked on the device (M40,
// docs/specs/M40.md § Acceptance 5 and 6).
//
// The other half of examples/avr/tests/sweep_a.mc; see its header for why there
// are two.

#include "sys_avr.mc"
#include "rt_avr.mc"

i64 fails = 0;

// The check, and the reason it takes three arguments and not two: every
// argument is eight bytes copied into the caller's outgoing area -- sixteen
// instructions of flash each -- so a helper is what keeps forty of these inside
// an ATmega328P's 32 KiB at all. examples/avr/README.md § What it costs.
void check(i64 id, i64 got, i64 want) {
    if (got == want) return;
    fails = fails + 1;
    uart_puts("FAIL ");
    uart_putn(id);
    uart_puts(" got ");
    uart_putn(got);
    uart_puts(" want ");
    uart_putn(want);
    uart_putc('\n');
}

i64  g64 = 0x0123456789abcdef;
u8   g8  = 200;
// Two POINTERS in an initializer: four bytes of __DATA on this target, because
// the compiler declared uptr to be two bytes (M41 § 4a, C5). Each element is an
// R_UNSIGNED relocation the image writer resolves to an SRAM address.
uptr gstr[2] = { "alpha", "beta" };

i64 one(i64 a) { return a + 1; }

i64 twelve(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f,
           i64 g, i64 h, i64 i, i64 j, i64 k, i64 l) {
    return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6
         + g * 7 + h * 8 + i * 9 + j * 10 + k * 11 + l * 12;
}

i64 narrow3(u8 a, u16 b, u32 c) { return a + b + c; }

// the same three values added in 64 bits, which is what a source that wants the
// other machines' answer writes: the cast is not decoration, it is the width
i64 narrow_wide(u8 a, u16 b, u32 c) { return (i64) a + (i64) b + (i64) c; }

i64 fact(i64 n) {
    if (n <= 1) return 1;
    return n * fact(n - 1);
}

// A frame past 63 bytes: every access to this array goes through the machine's
// X fallback (movw X,Y + subi/sbci + `ld r,X+`), which nothing else reaches.
i64 big_frame() {
    u8 buf[200];
    i64 i = 0;
    loop {
        if (i >= 200) break;
        st8(buf + i, i & 0xff);
        i = i + 1;
    }
    i64 sum = 0;
    i = 0;
    loop {
        if (i >= 200) break;
        sum = sum + ld8(buf + i);
        i = i + 1;
    }
    return sum;
}

void sweep_memory() {
    u8 buf[16];
    st8(buf, 0xab);
    check(40, ld8(buf), 0xab);
    st16(buf + 2, 0xbeef);
    check(41, ld16(buf + 2), 0xbeef);
    st32(buf + 4, 0xdeadbeef);
    check(42, ld32(buf + 4), 0xdeadbeef);
    st64(buf + 8, g64);
    check(43, ld64(buf + 8), g64);
    check(44, ld8(buf + 8), 0xef);               // little-endian, byte by byte
    check(45, g8, 200);
    g8 = 201;
    check(46, g8, 201);
    check(47, ld8((uptr) ld16(gstr)), 'a');
    check(48, ld8((uptr) ld16(gstr + 2)), 'b');
    check(49, (uptr) ld16(gstr + 2) - (uptr) ld16(gstr), 6);   // "alpha" + NUL
}

void sweep_calls() {
    check(50, one(41), 42);
    check(51, twelve(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1), 78);
    // THE DIVERGENCE, on purpose and with its number written down: `a + b + c`
    // in narrow3 is typed from its LEFT operand, so it is computed in eight
    // bits here and in sixty-four on arm64 -- 8 against 3000040200. M40 D4
    // accepted it, docs/reference/machine.md § the avr column states it, and
    // this is the test that names it.
    check(52, narrow3(200, 40000, 3000000000), 8);
    check(56, narrow_wide(200, 40000, 3000000000), 3000040200);
    check(53, fact(10), 3628800);
    uptr p = &one;
    check(54, callp(p, 10), 11);                 // an indirect call: icall
    check(55, big_frame(), 19900);               // 0 + 1 + ... + 199
}

void amain() {
    uart_init();
    uart_puts("sweep_b\n");
    sweep_memory();
    sweep_calls();
    uart_puts("sweep_b ");
    uart_putn(fails);
    uart_puts(" failed\n");
    if (fails) halt(1);
    halt(0);
}
