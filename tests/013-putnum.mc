// expect-exit: 0
// expect-stdout: 46368
// fib(24) impresso por putnum: array local, st8, / e %, saida por extern write.
extern i64 write(i64 fd, uptr buf, i64 n);

i64 fib(i64 n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

void putnum(i64 v) {
    u8 buf[24];
    i64 i = 23;
    st8(buf + i, 10);                     // \n no fim do buffer
    loop {
        i = i - 1;
        st8(buf + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);
}

i64 main() {
    putnum(fib(24));
    return 0;
}
