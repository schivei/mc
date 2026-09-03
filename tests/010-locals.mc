// expect-exit: 42
// Locais com e sem inicializador, atribuicao e sombreamento em bloco aninhado.
i64 main() {
    i64 a = 40;
    i64 b;
    b = 2;
    {
        i64 a = 100;          // sombreia o a de fora ate o fim do bloco
        b = b + a - 100;      // b continua 2
    }
    u8 c = 300;               // largura do local: guarda so um byte (44)
    return a + b + c - 44;
}
