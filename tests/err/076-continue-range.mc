// `continue N;` with N past the enclosing loop depth: two loops, level three.
// The depth is only known while lowering, so this one comes from the walker,
// like `break out of range`. Expected:
//
//   tests/err/076-continue-range.mc:9: continue out of range
i64 main() {
    loop {
        loop {
            continue 3;
        }
    }
    return 0;
}
