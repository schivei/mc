// expect-exit: 42
// Expression depth above 7: the excess values go to the frame.
i64 add8(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h) {
    return a + b + c + d + e + f + g + h;
}

i64 main() {
    i64 a = 1;
    // 11 right-nested operands: depth 10
    i64 deep = a + (a + (a + (a + (a + (a + (a + (a + (a + (a + a)))))))));
    // call with 8 args whose last is another call with 8 args: depth 14
    i64 nested = add8(1, 2, 3, 4, 5, 6, 7, add8(1, 2, 3, 4, 5, 6, 7, 0 - 14));
    return nested + deep - 11;
}
