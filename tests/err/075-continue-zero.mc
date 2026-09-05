// `continue 0;` is refused at the parse position, exactly as `break 0;` is:
// a level counts loops from 1, and 0 is what "no level was written" means
// inside the node. Expected:
//
//   tests/err/075-continue-zero.mc:8: continue expects a positive level
i64 main() {
    loop {
        continue 0;
    }
    return 0;
}
