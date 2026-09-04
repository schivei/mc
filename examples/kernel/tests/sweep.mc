// sweep.mc — a source whose only purpose is to make the RISC-V machine emit
// every instruction it knows, so that examples/kernel/test.sh can feed each one
// back through `llvm-mc -triple=riscv64 -mattr=+m` and compare bytes
// (docs/specs/M39.md § Acceptance 4, the shape M17 step B used for x86-64).
//
// It is never run. It only has to compile to an image, which is why `_start`
// exists at all and why nothing here talks to a device.
//
// What it covers, task by task (docs/reference/machine.md § 2):
//
//   CONST      small, 32-bit, 64-bit and negative constants -> the four `li` shapes
//   BIN        all thirteen MOP_*, signed and unsigned, through i64 and u64
//   CMP        all six MCOND_*
//   UN         MUN_NEG, MUN_NOT, MUN_LNOT
//   BOOL       && and ||
//   CAST       u8, u16, u32
//   LOAD/STORE all four widths, through ld8..st64
//   LOCAL_*    scalars, an array, and a 3000-byte frame past RV's 2047
//   SYM_ADDR   a global's address, a string literal, and `&function`
//   GLOBAL_*   all four widths
//   CALL       0..12 arguments, so the stack half of the ABI is exercised
//   CALLP      an indirect call through `&f`
//   RET/JUMP/JZ/JNZ/LABEL   if / else / loop / break / continue
//   WORD       one raw `#opcode` word
//   spill      an expression deeper than the four depth registers

#include <prelude>

i64  sw_i = 0;
u8   sw_b = 0;
u16  sw_h = 0;
u32  sw_w = 0;
u8   sw_arr[64];
i64  sw_init[] = { 1, 2, 3, 4 };
uptr sw_ptrs[] = { "one", "two" };               // R_UNSIGNED in __data

#opcode sw_nop() 0x00000013                      // addi x0, x0, 0

// every MOP_*, unsigned on the left (u64 divides and shifts without sign)
u64 sw_unsigned(u64 a, u64 b) {
    u64 r = a + b;
    r = r - a;
    r = r * b;
    r = r / (b + 1);
    r = r % (b + 3);
    r = r & a;
    r = r | b;
    r = r ^ a;
    r = r << 3;
    r = r >> 2;
    return r;
}

// and the signed half: i64 divides, takes remainders and shifts with sign
i64 sw_signed(i64 a, i64 b) {
    i64 r = a / (b + 1);
    r = r % (b + 5);
    r = r >> 4;
    r = 0 - r;
    r = ~r;
    if (!r) r = 1;
    return r;
}

// all six comparisons, plus && and || for MTASK_BOOL
i64 sw_compare(i64 a, i64 b) {
    i64 n = 0;
    if (a == b) n = n + 1;
    if (a != b) n = n + 2;
    if (a < b)  n = n + 4;
    if (a <= b) n = n + 8;
    if (a > b)  n = n + 16;
    if (a >= b) n = n + 32;
    if (a && b) n = n + 64;
    if (a || b) n = n + 128;
    return n;
}

// the four `li` shapes: a 12-bit immediate, a 32-bit one, a full 64-bit one and
// a negative
i64 sw_consts() {
    i64 a = 7;
    i64 b = 0x12345678;
    i64 c = 0x1122334455667788;
    i64 d = 0 - 100000;
    return a + b + c + d;
}

// MTASK_CAST at all three narrowing widths
i64 sw_casts(i64 v) {
    i64 a = (u8) v;
    i64 b = (u16) v;
    i64 c = (u32) v;
    return a + b + c;
}

// MTASK_LOAD / MTASK_STORE at all four widths, and MTASK_GLOBAL_* likewise
i64 sw_memory(uptr p) {
    st8(p, 1);
    st16(p + 2, 2);
    st32(p + 4, 3);
    st64(p + 8, 4);
    sw_b = 5;
    sw_h = 6;
    sw_w = 7;
    sw_i = 8;
    return ld8(p) + ld16(p + 2) + ld32(p + 4) + ld64(p + 8)
         + sw_b + sw_h + sw_w + sw_i;
}

// a frame between RV's signed 12-bit store displacement (2047) and the walker's
// 4095: every access to `big` goes through the machine's t2 fallback
i64 sw_big_frame() {
    u8 big[3000];
    i64 i = 0;
    while (i < 3000) {
        st8(big + i, i & 0xff);
        i = i + 1;
    }
    i64 s = 0;
    i = 0;
    while (i < 3000) {
        s = s + ld8(big + i);
        i = i + 1;
    }
    return s;
}

// twelve parameters: 1..8 in a0..a7 and 9..12 on the stack, read by the callee
// at [s0 + 16 + 8*(i-8)]
i64 sw_twelve(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f,
              i64 g, i64 h, i64 i, i64 j, i64 k, i64 l) {
    return a + b + c + d + e + f + g + h + i + j + k + l;
}

i64 sw_one(i64 a) { return a + 1; }

// an expression deeper than the four depth registers, so the machine has to
// spill through slot_new
i64 sw_deep(i64 a) {
    return sw_one(a) + (sw_one(a + 1) + (sw_one(a + 2) + (sw_one(a + 3)
         + (sw_one(a + 4) + (sw_one(a + 5) + sw_one(a + 6))))));
}

// loop, break and continue, so JUMP / JZ / JNZ / LABEL all appear
i64 sw_control(i64 n) {
    i64 s = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i = i + 1;
        if (i == 3) continue;
        s = s + i;
    }
    return s;
}

// MTASK_SYM_ADDR in its three callers: a global, a string literal, `&function`
i64 sw_addresses() {
    uptr p = sw_arr;
    uptr s = "sweep";
    uptr f = &sw_one;
    return callp(f, 41) + ld8(p) + ld8(s) + ld64(sw_init) + ld64(sw_ptrs);
}

i64 sw_all() {
    sw_nop();
    return sw_unsigned(9, 4) + sw_signed(9, 4) + sw_compare(1, 2)
         + sw_consts() + sw_casts(0x1234567) + sw_memory(sw_arr)
         + sw_big_frame() + sw_twelve(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
         + sw_deep(1) + sw_control(10) + sw_addresses();
}

void _start() {
    sw_i = sw_all();
    loop { sw_nop(); }
}
