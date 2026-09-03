// expect-exit: 42
// st8/st16/st32/st64 and ld8/ld16/ld32/ld64 on a local array, with zero-extend.
i64 main() {
    u8 b[16];
    i64 s = 0;
    st64(b, 0x1122334455667788);
    if (ld64(b) == 0x1122334455667788) s = s + 10;
    st32(b + 8, 0x11223344);
    if (ld32(b + 8) == 0x11223344) s = s + 10;
    st16(b + 12, 0xBEEF);
    if (ld16(b + 12) == 0xBEEF) s = s + 10;
    st8(b + 14, 0xFF);
    if (ld8(b + 14) == 255) s = s + 10;   // zero-extend, not -1
    if (ld8(b + 1) == 0x77) s = s + 2;    // little-endian: byte 1 of the st64
    return s;
}
