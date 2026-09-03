// expect-exit: 42
// Classic arena: global array in __bss + bump pointer in __data.
#define HEAP_SIZE 4096
u8 heap[HEAP_SIZE];
i64 hp = 0;

uptr alloc(i64 n) {
    uptr p = heap + hp;
    hp = hp + ((n + 7) & ~7);           // rounds up to 8
    return p;
}

i64 main() {
    uptr a = alloc(5);
    uptr b = alloc(16);
    st64(a, 40);
    st64(b, 2);
    if (b - a != 8) return 1;           // 5 rounded up to 8
    if ((a & 7) != 0) return 2;         // aligned to 8
    if (hp != 24) return 3;
    return ld64(a) + ld64(b);
}
