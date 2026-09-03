// pass_demo.mc — pass de AST da demonstracao do M10: troca `x * 1` por `x`.
//
// Prova que a AST e operavel de fora do compilador: e um array plano na arena
// com acessoras (`nd_kind`, `nd_op`, `nd_a`, ...), entao um modulo externo
// varre `1..nnodes-1` e reescreve os nos no lugar. O produto vira uma copia do
// operando da esquerda; o campo `next` e preservado porque ele pertence a lista
// de irmaos em que o no esta, nao ao no que o substitui.
//
// O nucleo nao faz isso: `fold` so dobra constante com constante, e `x` nao e
// constante. Com o pass ligado, `--dump-ast` de tests/061-pass.mc mostra
// `IDENT name=x` onde antes havia um `BINARY op=*`.

i64 pass_mul1(i64 root) {
    i64 i = 1;
    loop {
        if (i >= nnodes) break;
        if (nd_kind(i) == N_BINARY && nd_op(i) == K_MUL) {
            i64 b = nd_b(i);
            if (nd_kind(b) == N_INT && nd_val(b) == 1) {
                i64 nx = nd_next(i);
                node_assign(i, nd_a(i));       // o operando toma o lugar do produto
                set_nd_next(i, nx);
            }
        }
        i = i + 1;
    }
    return root;
}
