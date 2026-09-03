// astdump.mc — driver da fatia 3 do M6: parseia o arquivo dado em argv[1]
// (seguindo #include, como o compilador de verdade) e imprime exatamente o que
// `mc0 --dump-ast ARQUIVO` imprime. Mesma sequencia do modo M_AST de
// stage0/main.c: tok_init, lex_init, parse_unit, dump_ast — a arvore sai como
// foi parseada, ANTES do fold() que o driver so aplica no caminho do codegen.
// Logo diretivas nao aparecem (nao viram no), mas funcoes, globais, externs e
// prototipos aparecem, na ordem do fonte e ja com o #include expandido.
//
// macho.mc entra porque parse.mc usa sec_new (em sec_make) e as constantes
// R_UNSIGNED/BRANCH26/PAGE21/PAGEOFF12 que defs_init registra; e tambem a ordem
// de #include que src/mc.mc vai usar.
#include "arena.mc"
#include "macho.mc"
#include "lex.mc"
#include "ast.mc"
#include "parse.mc"

i64 main(i64 argc, uptr argv) {
    if (argc < 2) {
        out_str(2, "uso: astdump entrada.mc\n");
        return 1;
    }
    uptr in = ld64(argv + 8);          // argv[1]
    src_name = in;
    tok_init();
    lex_init(in);                      // o lexer abre e empilha o arquivo
    i64 unit = parse_unit();
    dump_ast(unit);
    return 0;
}
