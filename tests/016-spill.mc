// expect-exit: 42
// Profundidade de expressao acima de 7: os valores excedentes vao para o frame.
i64 add8(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h) {
    return a + b + c + d + e + f + g + h;
}

i64 main() {
    i64 a = 1;
    // 11 operandos aninhados a direita: profundidade 10
    i64 deep = a + (a + (a + (a + (a + (a + (a + (a + (a + (a + a)))))))));
    // chamada com 8 args cujo ultimo e outra chamada com 8 args: profundidade 14
    i64 nested = add8(1, 2, 3, 4, 5, 6, 7, add8(1, 2, 3, 4, 5, 6, 7, 0 - 14));
    return nested + deep - 11;
}
