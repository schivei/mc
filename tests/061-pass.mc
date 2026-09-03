// 061-pass.mc — the source that the M10 demonstration pass changes.
// Without the pass (default compiler) `x * 1` reaches codegen intact; with
// lib/pass_demo.mc wired in, `--dump-ast` shows only the IDENT.
// expect-exit: 42

i64 main() {
    i64 x = 42;
    return x * 1;
}
