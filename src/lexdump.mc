// lexdump.mc — driver do M4: tokeniza o arquivo dado em argv[1] e imprime
// exatamente o que `mc0 --dump-tokens ARQUIVO` imprime (LINHA ID TEXTO).
// Como o stage0, o lexer puro nao segue #include: a diretiva vira so um T_DIR.
#include "arena.mc"
#include "lex.mc"

i64 main(i64 argc, uptr argv) {
    if (argc < 2) {
        out_str(2, "uso: lexdump entrada.mc\n");
        return 1;
    }
    uptr in = ld64(argv + 8);          // argv[1]
    src_name = in;
    tok_init();
    lex_init(in);                      // o lexer abre e empilha o arquivo
    dump_tokens();
    return 0;
}
