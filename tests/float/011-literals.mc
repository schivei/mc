// expect-exit: 0
// expect-stdout: 0x3ff8000000000000 0x4000000000000000 0x3f50624dd2f1a9fc 0x000000003e800000 0x8000000000000000
// The five literal shapes of docs/specs/M24.md: 1.5, 2.0, 1e-3, 0.25f and -0.0.
// None of them is read by the lexer -- lex_number stops at the `.`, exactly as
// the frozen stage0/lex.c does -- they are read by <float>'s syntax_lit handler
// out of the raw source, converted with a correctly-rounded integer algorithm,
// and handed back as an ordinary N_INT carrying the IEEE bit pattern.
//
// `-0.0` is the one that needs M3: the core must NOT fold a unary minus over a
// literal of a type it did not define, or the bit pattern would be negated as an
// integer and come out 0xc000000000000000.
#include <sys>
#include <float_rt>

i64 main() {
    puthexf(1.5);     puts(" ");
    puthexf(2.0);     puts(" ");
    puthexf(1e-3);    puts(" ");
    puthexf32(0.25f); puts(" ");
    puthexf(-0.0);    puts("\n");
    return 0;
}
