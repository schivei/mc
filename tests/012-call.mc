// expect-exit: 42
// Recursao (fib) e uma funcao com os 8 parametros permitidos.
i64 fib(i64 n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

i64 sum8(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h) {
    return a + b + c + d + e + f + g + h;
}

i64 main() {
    return fib(10) - sum8(1, 2, 3, 4, 5, 6, 7, 8) + 23;   // 55 - 36 + 23
}
