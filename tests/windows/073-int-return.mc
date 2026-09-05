// expect-exit: 0
// expect-stdout: attr=-1 negative=1
// M45: a call returns what the callee DECLARED, against real kernel32.
//
// GetFileAttributesA returns a DWORD, 32 bits, and answers
// INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF for a path that does not exist.
// Declared `i32` -- which is what the API's own sentinel comparison means, and
// why the documented test is `== INVALID_FILE_ATTRIBUTES` and not `< 0` -- the
// walker sign-extends the result and `< 0` is true. Before M45 the compiler
// read all 64 bits of a register whose upper half both Windows ABIs leave
// unspecified for a 32-bit return, which is exactly why lib/sys_windows.mc
// masks every BOOL and DWORD result with `& BOOL_MASK` by hand (M45 D9 keeps
// those masks: the Windows chain's seed is a published release that does not
// narrow).
//
// It declares its own extern rather than including <sys_windows>, so the
// `self` link mode is not needed and the file has no dependency on the layer.
extern i32 GetFileAttributesA(uptr path);
extern uptr GetStdHandle(i64 which);
extern i32 WriteFile(uptr h, uptr buf, i64 n, uptr written, uptr ov);

u8   nbuf[24];
u8   nio[8];

void wr(uptr s, i64 n) { WriteFile(GetStdHandle(0 - 11), s, n, nio, 0); }

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
    wr(nbuf + i, 24 - i);
}

i64 main() {
    i64 a = GetFileAttributesA("Z:\\nonexistent-m45\\nope");
    wr("attr=", 5);
    puti(a);
    wr(" negative=", 10);
    puti(a < 0);
    wr("\n", 1);
    return 0;
}
