// expect-exit: 42
// break 2 exits both loops at once; a plain break exits only the inner one.
i64 main() {
    i64 s = 0;
    loop {
        i64 j = 0;
        loop {
            j = j + 1;
            s = s + 1;
            if (s >= 42) break 2;
            if (j >= 3) break;
        }
        s = s + 0;
    }
    return s;
}
