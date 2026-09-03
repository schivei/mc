// expect-exit: 0
// expect-stdout: um
// Inicializador de array global: N explicito ou inferido de { ... }. Elementos
// sao constantes dobradas escritas na largura do tipo; para uptr, um literal de
// string vira 8 bytes zerados mais uma relocacao R_UNSIGNED para l_strN.
#include "../lib/sys.mc"

uptr names[] = {"zero", "um", "dois"};   // N inferido: 3 ponteiros em __data
u32  t[4] = {1, 2, 3};                   // N > count: o resto sai zerado
u8   bytes[] = {'a', 'b', 'c'};
i64  soma[2] = {20 + 22, 7 * 6};         // dobra de constante no elemento

i64 main() {
    puts(ld64(names + 8));               // names[1] -> "um"
    write(1, "\n", 1);
    if (ld32(t + 8) != 3) return 1;      // terceiro u32
    if (ld32(t + 12) != 0) return 2;     // preenchido com zero
    if (ld8(bytes + 2) != 'c') return 3;
    if (ld64(soma) != 42) return 4;
    if (ld64(soma + 8) != 42) return 5;
    return 0;
}
