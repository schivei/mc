// expect-exit: 30
// expect-stdout: 45,20,
// for do prelude: `{ init loop { if (!cond) break; corpo passo; } }`.
// O passo fica no FIM do corpo, entao `continue` pula o passo — igual ao que
// aconteceria escrevendo o loop a mao. E o preco de nao ter label de passo; o
// segundo loop abaixo mostra a consequencia e o jeito de contornar.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

i64 main() {
    i64 s = 0;
    for (i64 i = 0; i < 10; i = i + 1) {
        s = s + i;
    }
    putnum(s);                        // 45
    write(1, ",", 1);

    // continue pula o passo: quem sai por continue tem de mexer no contador
    // antes, senao o loop nao anda. Aqui o continue vem depois do incremento
    // manual, entao o loop termina e a soma pula os impares.
    i64 t = 0;
    i64 k = 0;
    for (k = 0; k < 10; k = k + 1) {
        if (k % 2) { k = k + 1; continue; }   // pula o passo: k anda na mao
        t = t + k;
    }
    putnum(t);                        // 0+2+4+6+8 = 20
    write(1, ",", 1);

    // for aninhado: cada expansao gera o seu proprio loop, sem interferencia
    i64 n = 0;
    for (i64 a = 0; a < 3; a = a + 1) {
        for (i64 b = 0; b < 4; b = b + 1) {
            n = n + 1;
        }
    }
    return n + 18;                    // 12 + 18 = 30
}
