// syntax_demo_test.mc — o programa que so o compilador ensinado do M12 compila.
// Usa as tres coisas de lib/user_syntax_demo.mc: `enum`, `unless` e `bool`.
// Com o compilador padrao (build/mc1) ele falha logo na primeira linha util,
// com `tipo esperado no topo` — `enum` la e so um identificador.
// expect-exit: 42

enum Cor { VERDE, AMARELO, VERMELHO }

// `bool` e alias de u8: vale como tipo de parametro e de local
i64 dois(bool b) {
    unless (b == 0) {
        return 2;
    }
    return 0;
}

i64 main() {
    i64 n = VERDE;                 // 0, constante gerada pelo enum
    bool ok = 1;
    n = n + dois(ok);              // 2
    Cor c = AMARELO;               // `Cor` virou alias de i64
    unless (c != AMARELO) {
        n = n + 40;
    }
    return n + VERMELHO * 0;       // 42
}
