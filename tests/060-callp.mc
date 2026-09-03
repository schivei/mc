// 060-callp.mc — M10: `&name` of a function becomes a uptr and callp does the
// indirect call. The `tbl` table holds two function addresses (UNSIGNED
// relocation in __data); callp puts the arguments in x0..x6, the pointer in
// x16, and does `blr x16`.
// expect-exit: 42

i64 add2(i64 a) { return a + 2; }
i64 mul2(i64 a) { return a * 2; }

// seven arguments: exercises x0..x6 at once
i64 sum7(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g) {
    return a + b + c + d + e + f + g;
}

uptr tbl[2];

i64 main() {
    st64(tbl, &add2);
    st64(tbl + 8, &mul2);
    i64 r = callp(ld64(tbl), 8);                    // add2(8)  = 10
    r = r + callp(ld64(tbl + 8), 5);                // mul2(5)  = 10
    r = r + callp(&sum7, 1, 2, 3, 4, 5, 6, 1);      // sum7(..) = 22
    return r;                                        // 42
}
