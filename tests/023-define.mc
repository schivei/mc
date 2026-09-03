// expect-exit: 42
// #define dobrado na definicao, usado no tamanho de um array e em expressao.
#define N 8
#define SIZE (N * 4)
#define ANSWER (N * 5 + 2)

i64 main() {
    u8 buf[SIZE];
    st8(buf + SIZE - 1, ANSWER);
    return ld8(buf + 31);
}
