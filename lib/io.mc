// io.mc — I/O utilities written in the language itself, on top of write().
// Does not choose an implementation: whoever includes it (sys.mc, sys_svc.mc or
// sys_linux.mc) is the one that declares open/read/write/close/exit AND the
// O_RDONLY/O_WRONLY/O_CREAT/O_TRUNC constants — those are per-system values
// (M16: on Linux O_CREAT is 0x40, on macOS 0x200), so they cannot live here.
// Never include this file alone.

// length of a NUL-terminated string
i64 strlen(uptr s) {
    i64 n = 0;
    loop {
        if (ld8(s + n) == 0) break;
        n = n + 1;
    }
    return n;
}

// writes the string to stdout, without the NUL
void puts(uptr s) {
    write(1, s, strlen(s));
}

// writes a non-negative integer to stdout, with no line break
void putnum(i64 v) {
    u8 buf[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(buf + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);
}
