// 092-i32-div.mc — M45: `/`, `%` and `>>` are SIGNED for a TK_SINT, and the one
// observable difference from C is written down and asserted.
//
// The model is `u32`'s, unchanged since M0: arithmetic is 64-bit on the value
// as it sits in the depth, extended from its width, and it wraps at the next
// store or cast (docs/reference/language.md § 2). So `INT_MIN / -1` is a `sdiv`
// on two SIGN-EXTENDED 64-bit operands and the answer is 2147483648 on every
// machine -- and, because the divide is 64-bit, there is no `#DE` on x86-64,
// where a 32-bit `idiv` of INT_MIN by -1 would trap. INT_MIN comes back only
// after a store to an `i32`, and the last line asserts that too.
//
// The same file also pins the contrast: the identical bit patterns read through
// `u32` divide and shift UNSIGNED.
// expect-exit: 0
// expect-stdout: -3 -1 -2 2147483648 -2147483648 -1 1431655765 2147483647

extern i64 write(i64 fd, uptr buf, i64 n);

i32 imin = 0 - 2147483648;
i32 mone = 0 - 1;
i32 sink;
u32 umax = 0xffffffff;

u8 nbuf[24];

void puti(i64 v) {
    i64 i = 24;
    u64 u = v;
    i64 neg = 0;
    if (v < 0) { neg = 1; u = 0 - v; }
    loop {
        i = i - 1;
        st8(nbuf + i, '0' + u % 10);
        u = u / 10;
        if (u == 0) break;
    }
    if (neg) { i = i - 1; st8(nbuf + i, '-'); }
    write(1, nbuf + i, 24 - i);
}

void sp() { write(1, " ", 1); }

i64 main() {
    i32 a = 0 - 7;
    i32 b = 2;
    puti(a / b);                          // sdiv: -3, not 9223372036854775804
    sp(); puti(a % b);                    // -1
    sp(); puti(a >> 2);                   // asr: -2

    // THE documented answer, on every machine and with no trap
    sp(); puti(imin / mone);              // 2147483648
    // ... and INT_MIN again after a store back into four bytes
    sink = imin / mone;
    sp(); puti(sink);                     // -2147483648

    // a comparison is signed on the extended value, so a negative i32 is
    // smaller than zero -- which is the whole point of the milestone
    sp(); puti(0 - (imin < 0));           // -1

    // the same bits through u32: unsigned divide and logical shift
    sp(); puti(umax / 3);             // 4294967295 / 3, unsigned
    sp(); puti(umax >> 1);                // 2147483647
    write(1, "\n", 1);
    return 0;
}
