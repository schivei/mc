// expect-exit: 0
// expect-stdout: open=-1 atoi=-1 strcmp=-1
// M45: a call returns what the callee DECLARED, against a real libc.
//
// Every function here is declared with the type C gives it -- `int` is `i32`,
// and after M45 the walker sign-extends the result from bit 31 with `sxtw` /
// `movsxd`. Before it, the compiler read all 64 bits of the result register,
// which both AAPCS64 and the SysV x86-64 ABI leave UNSPECIFIED above bit 31 for
// a 32-bit return.
//
// It declares its own externs and does not include lib/sys.mc: that file says
// `extern i64 open` (it must -- the frozen seed compiles it and cannot spell
// `i32`, M45 D8), and two disagreeing declarations of one name are
// `declaration does not match prototype`.
//
// The three calls are not interchangeable, and this is what the pre-milestone
// measurement found (docs/specs/M45.md § Implementation notes, Acceptance 1):
//
//   open   -- a syscall wrapper. On every libc and architecture measured it
//             already handed back a full 64-bit -1, so this line is the shape
//             the spec asks for and NOT the reproducing case.
//   atoi   -- ordinary compiled C. On musl (both architectures) the
//             pre-milestone compiler read 0x00000000ffffffff and `< 0` was
//             FALSE. That is the defect.
//   strcmp -- ordinary compiled C on glibc/x86_64 too, where it is the one that
//             reproduces.
//
// So between them the three cover every leg this test runs on.

extern i32 open(uptr path, i64 flags, i64 mode);
extern i32 atoi(uptr s);
extern i32 strcmp(uptr a, uptr b);
extern i64 write(i64 fd, uptr buf, i64 n);

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

// -1 if the value is negative, the value itself otherwise: it is the SIGN this
// file is about, and normalising it keeps the expectation one string on every
// libc (strcmp is only required to be negative, not to be -1).
i64 sign(i64 v) {
    if (v < 0) return 0 - 1;
    return v;
}

i64 main() {
    write(1, "open=", 5);
    puti(sign(open("/nonexistent-m45", 0, 0)));
    write(1, " atoi=", 6);
    puti(sign(atoi("-1")));
    write(1, " strcmp=", 8);
    puti(sign(strcmp("a", "b")));
    write(1, "\n", 1);
    return 0;
}
