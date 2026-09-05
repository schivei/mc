// 090-i32-basic.mc — M45: `i32`, the eighth word, registered by the core.
//
// It lives in tests/mc/ and not in tests/ for the reason every file here lives
// here: the frozen `stage0/parse.c` has no alias table and no registry, so it
// answers `type expected` at the first `i32`, and the four cross-checks that
// compare mc0 against mc1 over tests/*.mc would report that as a failure.
//
// Portable to all five targets: the only thing outside the language is `write`,
// declared here rather than through <sys>, so the file has no include at all.
// It runs on macOS (scripts/check-mc.sh, object + --exe), on linux/aarch64 and
// linux/x86_64 (scripts/test-linux.sh) and on windows/arm64 and windows/x86_64
// (scripts/test-windows.sh).
//
// What it proves: a negative value survives a local, a global, a parameter, a
// global array element and a return -- i.e. that a store truncates to four
// bytes and every read back sign-extends from bit 31.
// expect-exit: 0
// expect-stdout: -1 -5 -2147483648 2147483647 -7 -99 -1 -2 -3 -4

extern i64 write(i64 fd, uptr buf, i64 n);

i32 g    = 0 - 5;
i32 gmin = 0 - 2147483648;
i32 gmax = 2147483647;
i32 arr[4];

u8 nbuf[24];

// the six lines every test in this family carries instead of touching
// lib/io.mc, whose putnum is non-negative (M45 D11)
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

i32 idn(i32 x) { return x; }

i64 main() {
    i32 a = 0 - 1;                       // a local: str w, then ldrsw
    i64 b = a;
    puti(b);
    sp(); puti(g);                       // a global: ldrsw of a 4-byte cell
    sp(); puti(gmin);
    sp(); puti(gmax);
    sp(); puti(idn(0 - 7));               // a parameter: str w in the prologue
    i32 p = 0 - 99;
    sp(); puti(idn(p));

    // a global array of i32: four cells, four bytes apart, each read back
    // through the signed spelling of a 32-bit memory read (M45 D15)
    st32(arr + 0, 0 - 1);
    st32(arr + 4, 0 - 2);
    st32(arr + 8, 0 - 3);
    st32(arr + 12, 0 - 4);
    i64 i = 0;
    loop {
        if (i >= 4) break;
        sp(); puti((i32) ld32(arr + i * 4));
        i = i + 1;
    }
    write(1, "\n", 1);
    return 0;
}
