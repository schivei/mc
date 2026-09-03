// lexdump.mc — driver for M4: tokenizes the file given in argv[1] and prints
// exactly what `mc0 --dump-tokens FILE` prints (LINE ID TEXT).
// Like stage0, the pure lexer does not follow #include: the directive just becomes a T_DIR.
#include "arena.mc"
#include "lex.mc"

i64 main(i64 argc, uptr argv) {
    if (argc < 2) {
        out_str(2, "usage: lexdump source.mc\n");
        return 1;
    }
    uptr in = ld64(argv + 8);          // argv[1]
    tok_init();
    lex_init(in);                      // the lexer opens and pushes the file
    dump_tokens();
    return 0;
}
