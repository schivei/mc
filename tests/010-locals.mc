// expect-exit: 42
// Locals with and without an initializer, assignment and shadowing in a nested block.
i64 main() {
    i64 a = 40;
    i64 b;
    b = 2;
    {
        i64 a = 100;          // shadows the outer a until the end of the block
        b = b + a - 100;      // b stays 2
    }
    u8 c = 300;               // local's width: stores only one byte (44)
    return a + b + c - 44;
}
