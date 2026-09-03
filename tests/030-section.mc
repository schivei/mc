// expect-exit: 42
// #section chooses the section of the following functions and globals.
// __DATA,__tbl is not zerofill: the array occupies real bytes in the file.
// __DATA,__zt is zerofill (flags & 0xff == 1): only zsize counts. #section
// with no arguments goes back to the default.

#section __DATA __tbl 0 3
u64 tbl[4];

#section __DATA __zt 1 4
u64 zt[2];

#section __TEXT __hot 0x80000400 2
i64 hot(i64 x) {
    return x + 2;
}

#section
i64 base = 30;                          // back to the default: __DATA,__data

i64 main() {
    if (ld64(zt) != 0) return 1;        // zerofill arrives zeroed
    if (ld64(tbl + 8) != 0) return 2;   // a regular custom section also arrives zeroed
    st64(zt, 4);
    st64(tbl, base + ld64(zt));         // 34
    return hot(ld64(tbl) + 6);          // 34 + 6 + 2
}
