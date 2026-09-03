// expect-exit: 0
// Unsigned division: / and % with a u8/u16/u32/u64/uptr left operand use
// udiv/msub; only i64 uses sdiv. Constant folding mirrors the same criterion.
i64 main() {
    u64 big = 0xFFFFFFFFFFFFFFFF;
    if (big / 2 != 0x7FFFFFFFFFFFFFFF) return 1;      // at run time
    if ((u64) 0xFFFFFFFFFFFFFFFF / 2 != 0x7FFFFFFFFFFFFFFF) return 2;   // folded
    if (big % 10 != 5) return 3;                      // 18446744073709551615 % 10
    if ((u64) 0xFFFFFFFFFFFFFFFF % 10 != 5) return 4;

    i64 neg = 0 - 8;
    if (neg / 2 != 0 - 4) return 5;                   // i64 stays signed
    if ((0 - 8) / 2 != 0 - 4) return 6;
    if (neg % 3 != 0 - 2) return 7;

    uptr p = 24;
    if (p / 8 != 3) return 8;
    return 0;
}
