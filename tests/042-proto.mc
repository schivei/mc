// expect-exit: 0
// expect-stdout: 42
// Prototipo: `tipo nome(params);` no topo registra a assinatura; a definicao
// vem depois e tem de bater no tipo de retorno e na aridade. Um prototipo sem
// definicao nem extern e erro no fim da unidade.
#include "../lib/sys.mc"

i64  soma(i64 a, i64 b);        // usado antes de definido
void mostra(i64 v);
i64  dobro(i64 x);              // definido depois de quem o chama

i64 main() {
    mostra(soma(dobro(20), 2));
    return 0;
}

i64 soma(i64 a, i64 b) { return a + b; }

i64 dobro(i64 x) { return x + x; }

void mostra(i64 v) {
    putnum(v);
    write(1, "\n", 1);
}
