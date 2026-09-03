// expect-exit: 42
// Globais escalares (com e sem inicializador) e um array global u64[8].
i64 count = 0;          // inicializada: vai para __data
i64 base = 10;          // idem
i64 spare;              // sem inicializador: vai para __bss
u8  flag = 200;         // larguras curtas: alinhadas pela largura no __data
u32 word = 0xDEADBEEF;
u16 half;               // __bss vem zerado
u64 tab[8];             // array global: sempre __bss

void bump(i64 k) { count = count + k; }

i64 main() {
    i64 i = 0;
    loop {                              // tab[i] = i * 2, em bytes
        st64(tab + i * 8, i * 2);
        i = i + 1;
        if (i == 8) break;
    }
    bump(3);
    bump(4);
    spare = ld64(tab + 56);             // ultimo elemento: 14
    if (flag != 200) return 1;          // leitura de u8 global: zero-extend
    if (word != 0xDEADBEEF) return 2;
    if (half != 0) return 3;            // __bss zerado pelo kernel
    half = 0x1FFFF;                     // escrita trunca para a largura do tipo
    if (half != 0xFFFF) return 4;
    return count + base + spare + ld64(&base) + 1;   // 7 + 10 + 14 + 10 + 1
}
