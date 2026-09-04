// sweep_a.mc — arithmetic, comparison and the narrow types, checked on the
// device (M40, docs/specs/M40.md § Acceptance 5 and 6).
//
// Two files and not one, and the reason is the part: an ATmega328P has 32 KiB
// of flash, and a machine whose every value lives in a frame slot spends about
// 500 bytes on a line like `check(11, a * 3, 0x0369d036a306906d)`. Splitting is
// what keeps each image inside the device it is for; both halves run under both
// oracles and both feed the llvm-mc encoder sweep.
//
//     sweep_a 0 failed      every check agreed
//     FAIL <id> got X want Y
//
// Built and run by examples/avr/test.sh through the single-file CLI.

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

// __DATA: read through the flash-to-SRAM copy `_start` does, which is also what
// keeps the compiler from folding any of the arithmetic below
i64 g64 = 0x0123456789abcdef;
u8  g8  = 200;
u16 g16 = 40000;
u32 g32 = 3000000000;
i64 gzero = 0;

void sweep_arith() {
    i64 a = g64;
    check(1, a + 1, 0x0123456789abcdf0);
    check(2, a - 0x0023456789abcdef, 0x0100000000000000);
    check(3, a & 0xffff, 0xcdef);
    check(4, a ^ a, 0);
    check(5, 0 - a, 0 - 0x0123456789abcdef);
    check(6, ~a + 1, 0 - 0x0123456789abcdef);
    check(7, a << 4, 0x123456789abcdef0);
    check(8, a >> 8, 0x000123456789abcd);
    check(9, (0 - 16) >> 2, 0 - 4);              // i64 shifts arithmetically
    check(10, a * 3, 0x0369d0369d0369cd);
    check(11, a / 1000, 81985529216486);
    check(12, a % 1000, 895);
    check(13, (0 - 1000000) / 7, 0 - 142857);
    check(14, (0 - 1000000) % 7, 0 - 1);
}

void sweep_compare() {
    i64 a = gzero + 5;
    i64 b = gzero - 5;
    check(20, a > b, 1);
    check(21, b < a, 1);
    check(22, a == 5, 1);
    check(23, !gzero, 1);
    check(24, a && b, 1);
    check(25, gzero || a, 1);
    // The narrow types are UNSIGNED and comparison in this language is SIGNED,
    // so the machine compares one byte wider than the widest operand: a u16 of
    // 40000 is 40000 and not -25536 (examples/avr/machine_avr.mc, avr_cmp_width).
    u16 big = g16;
    check(26, big > 1, 1);
    u8 b8 = g8;
    check(27, b8 > 100, 1);
    u32 b32 = g32;
    check(28, b32 > 1, 1);
}

void sweep_narrow() {
    // Arithmetic happens at the DECLARED width, which is the point of the
    // narrow types on this part and the divergence M40 D4 accepted: on arm64
    // every one of these is computed in 64 bits and then truncated by the
    // store, and both answers below would be the wider number.
    u8 x = g8;
    check(30, x + 100, 44);                      // 300 mod 256
    check(31, x * 2, 144);                       // 400 mod 256
    u16 y = g16;
    check(32, y + 30000, 4464);                  // 70000 mod 65536
    check(33, (i64) x, 200);                     // a cast up is zero extension
    check(34, (u8) 300, 44);
    u32 z = g32;
    check(35, z + 1000000000, 4000000000);   // 4e9 still fits in 32 bits
    check(36, z >> 16, 45776);
}

void amain() {
    uart_init();
    uart_puts("sweep_a\n");
    sweep_arith();
    sweep_compare();
    sweep_narrow();
    uart_puts("sweep_a ");
    uart_putn(fails);
    uart_puts(" failed\n");
    if (fails) halt(1);
    halt(0);
}
