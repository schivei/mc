// expect-exit: 55
// Sums 1..10 with loop, break and continue.
i64 main() {
    i64 i = 0;
    i64 s = 0;
    loop {
        i = i + 1;
        if (i > 10) break;
        if (i < 100) {
            s = s + i;
            continue;
        }
        s = s + 1000;         // unreachable: the continue above always branches away
    }
    return s;
}
