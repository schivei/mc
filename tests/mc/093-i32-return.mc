// 093-i32-return.mc — M45: a call returns what the callee DECLARED.
//
// Three halves:
//
//   * the CALLER half. `neg()` is declared `i32`, so the walker issues
//     MTASK_CAST(i32) after MTASK_CALL and the result is sign-extended from
//     bit 31 -- `sxtw` on arm64, `movsxd` on x86-64, `sext.w` on riscv64.
//     `low()` is declared `u8` and gets the zero-extending twin (`and #0xff`,
//     `movzx`), so 300 comes back as 44.
//   * the CALLEE half (M45 D5). Both functions also EXTEND before their own
//     `return`, which is what a C caller of an `mc` function is entitled to.
//     Here both sides are `mc`, so the two extensions agree by construction --
//     which is exactly what makes this file portable to a target with no libc.
//   * a REAL C callee, `close`, declared `extern i32`. Every libc returns -1
//     from close(-1); what differs between platforms is whether bits 63..32
//     carry the sign, and after M45 that no longer matters.
//
// `close` is the one libc name in the file and it resolves on all five targets:
// libSystem on macOS, libc on both Linux legs, and lib/sys_windows.mc's own
// kernel32 wrapper (linked next to the test as winrt.obj) on both Windows ones.
// There close(-1) is NOT CloseHandle(INVALID_HANDLE_VALUE): -1 is also the
// pseudo-handle GetCurrentProcess() returns, and CloseHandle succeeds on a
// pseudo-handle, so the wrapper refuses a negative descriptor itself and
// answers -1 like every other close here. The CI legs are what found that.
// expect-exit: 0
// expect-stdout: -1 44 -32768 1 1

extern i64 write(i64 fd, uptr buf, i64 n);
extern i32 close(i64 fd);

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

i32 neg()          { return 0 - 1; }          // -1, fully extended
u8  low(i64 x)     { return x; }              // 300 -> 44
i32 wide(i64 x)    { return x; }              // 0xffff8000 -> -32768
i64 opaque(i64 v)  { return v; }

i64 main() {
    i64 a = neg();
    puti(a);                                  // -1, not 4294967295
    sp(); puti(low(300));                      // 44
    sp(); puti(wide(0xffff8000));              // -32768
    // the same again, but as the operand of a comparison rather than a store:
    // a call whose result is not extended would make this false
    sp(); puti(neg() < 0);                     // 1
    // a real C callee declared i32
    sp(); puti(close(0 - 1) < 0);              // 1
    write(1, "\n", 1);
    return 0;
}
