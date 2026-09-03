// expect-exit: 0
// expect-stdout: one
// Global array initializer: N explicit or inferred from { ... }. Elements are
// folded constants written at the type's width; for uptr, a string literal
// becomes 8 zeroed bytes plus an R_UNSIGNED relocation to l_strN.
#include "../lib/sys.mc"

uptr names[] = {"zero", "one", "two"};   // N inferred: 3 pointers in __data
u32  t[4] = {1, 2, 3};                   // N > count: the rest comes out zeroed
u8   bytes[] = {'a', 'b', 'c'};
i64  sum[2] = {20 + 22, 7 * 6};          // constant folding in the element

i64 main() {
    puts(ld64(names + 8));               // names[1] -> "one"
    write(1, "\n", 1);
    if (ld32(t + 8) != 3) return 1;      // third u32
    if (ld32(t + 12) != 0) return 2;     // padded with zero
    if (ld8(bytes + 2) != 'c') return 3;
    if (ld64(sum) != 42) return 4;
    if (ld64(sum + 8) != 42) return 5;
    return 0;
}
