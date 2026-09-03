// expect-exit: 42
// expect-stdout: 12,30,
// Regra que usa regra: o template de `repeat` e parseado com o parser normal,
// que ja conhece `while` e `+=` do prelude. A expansao acontece NA DEFINICAO —
// o que fica guardado e uma arvore de `loop`/`if`/`break`, entao nao ha
// reexpansao textual e recursao infinita e impossivel por construcao.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

#rule stmt: repeat ( expr $n ) block $b
    => { i64 $$i = 0; while ($$i < $n) { $b $$i += 1; } }

i64 main() {
    i64 s = 0;
    repeat (4) { s += 3; }
    putnum(s);  write(1, ",", 1);     // 12

    // duas expansoes no mesmo bloco: cada uma tem o seu contador
    repeat (3) { s += 6; }
    putnum(s);  write(1, ",", 1);     // 30

    return s + 12;                    // 42
}
