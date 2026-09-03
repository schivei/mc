// expect-exit: 42
// #define folded at definition, used in an array's size and in an expression.
#define N 8
#define SIZE (N * 4)
#define ANSWER (N * 5 + 2)

i64 main() {
    u8 buf[SIZE];
    st8(buf + SIZE - 1, ANSWER);
    return ld8(buf + 31);
}
