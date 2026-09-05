// 091-i32-cast.mc — M45: the cast, in both directions, at compile time and at
// run time.
//
// `(i32) x` fills the bytes above bit 31 with the SIGN; `(u32) x` fills them
// with zero. On a constant that is fold_cast (src/parse.mc), on a value it is
// MTASK_CAST (sxtw / movsxd / sext.w). The two have to agree, and half of this
// file is a constant and half of it is not.
//
// It also pins the one thing `u32` and `i32` share: the STORED BYTES. A value
// written through a `u32` cell and read through an `i32` cell is the same four
// bytes, seen with a different sign.
// expect-exit: 0
// expect-stdout: -1 -1 4294967295 4294967295 -2147483648 2147483648 0 -1 -1 305419896 -1 -2

extern i64 write(i64 fd, uptr buf, i64 n);

#define M32 (i32) 0x80000000                  // folds to -2147483648
#define U32 (u32) 0x80000000                  // folds to  2147483648

u32 cell;
u8  nbuf[24];

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

i64 val(i64 v) { return v; }                  // an opaque value: nothing folds

i64 main() {
    // a constant, folded: (i32) of a pattern with bit 31 set is negative
    puti((i32) 0xffffffff);
    sp(); puti(M32 / 2147483648);              // -2147483648 / 2147483648 = -1
    // the same pattern through (u32): still positive
    sp(); puti((u32) 0xffffffff);
    // and at run time, through a value the folder cannot see
    sp(); puti((u32) val(0 - 1));
    sp(); puti((i32) val(0x80000000));
    sp(); puti(U32);
    // a cast of an already-narrow value is idempotent
    sp(); puti((i32) val(0));
    sp(); puti((i32) (i32) val(0 - 1));
    // u32 <-> i32 is a no-op ON THE STORED BYTES: one cell, two readings
    st32(&cell, 0 - 1);
    sp(); puti((i32) ld32(&cell));
    st32(&cell, 0x12345678);
    sp(); puti((i32) ld32(&cell));
    // a narrowing cast of a wide value keeps the low 32 bits, then extends
    sp(); puti((i32) val(0x1ffffffff));
    sp(); puti((i32) val(0xfffffffe));
    write(1, "\n", 1);
    return 0;
}
