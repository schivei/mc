// expect-exit: 52
// expect-stdout: 45
// while do prelude: a regra vira `loop { if (!c) break; b }`.
// break e continue dentro do corpo continuam sendo os do nucleo — o continue
// volta para o topo do loop, que e onde a condicao e reavaliada.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

i64 main() {
    i64 i = 0;
    i64 s = 0;
    while (i < 10) {
        s = s + i;
        i = i + 1;
    }
    putnum(s);                        // 0+1+...+9 = 45

    i64 j = 0;
    i64 t = 0;
    while (j < 100) {
        j = j + 1;
        if (j > 10) break;            // break sai do loop gerado pela regra
        if (j == 3) continue;         // continue reavalia a condicao: pula o 3
        t = t + j;
    }
    return t;                         // 55 - 3 = 52
}
