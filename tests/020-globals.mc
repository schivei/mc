// expect-exit: 42
// Scalar globals (with and without an initializer) and a global u64[8] array.
i64 count = 0;          // initialized: goes to __data
i64 base = 10;          // ditto
i64 spare;              // no initializer: goes to __bss
u8  flag = 200;         // short widths: aligned by width in __data
u32 word = 0xDEADBEEF;
u16 half;               // __bss comes zeroed
u64 tab[8];             // global array: always __bss

void bump(i64 k) { count = count + k; }

i64 main() {
    i64 i = 0;
    loop {                              // tab[i] = i * 2, in bytes
        st64(tab + i * 8, i * 2);
        i = i + 1;
        if (i == 8) break;
    }
    bump(3);
    bump(4);
    spare = ld64(tab + 56);             // last element: 14
    if (flag != 200) return 1;          // reading a global u8: zero-extend
    if (word != 0xDEADBEEF) return 2;
    if (half != 0) return 3;            // __bss zeroed by the kernel
    half = 0x1FFFF;                     // write truncates to the type's width
    if (half != 0xFFFF) return 4;
    return count + base + spare + ld64(&base) + 1;   // 7 + 10 + 14 + 10 + 1
}
