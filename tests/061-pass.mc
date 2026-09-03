// 061-pass.mc — o fonte que o pass de demonstracao do M10 altera.
// Sem o pass (compilador padrao) `x * 1` chega inteiro ao codegen; com
// lib/pass_demo.mc ligado, `--dump-ast` mostra so o IDENT.
// expect-exit: 42

i64 main() {
    i64 x = 42;
    return x * 1;
}
