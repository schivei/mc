// main.mc — transliteracao de stage0/main.c: driver do compilador.
// uso: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms] entrada.mc [-o saida.o]
// Os modos --dump-* escrevem em stdout e nao geram o objeto.
//
// argv chega como uptr: argv[i] e ld64(argv + i * 8) (nao ha ponteiro tipado).
// Depende de arena.mc (str_eq, out_str, die, die2), de lex.mc (tok_init,
// lex_init, dump_tokens), de parse.mc (parse_unit, fold), de ast.mc (dump_ast),
// de gen_arm64.mc (gen_unit) e de macho.mc (dump_syms, macho_write).

#define M_COMPILE 0
#define M_TOKENS  1
#define M_AST     2
#define M_ASM     3
#define M_SYMS    4

void usage() {
    out_str(2, "uso: mc0 [--dump-tokens|--dump-ast|--dump-asm|--dump-syms] entrada.mc [-o saida.o]\n");
}

i64 main(i64 argc, uptr argv) {
    uptr in = 0;
    uptr out = "out.o";
    i64 mode = M_COMPILE;

    i64 i = 1;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--dump-tokens"))     mode = M_TOKENS;
        else if (str_eq(a, "--dump-ast"))   mode = M_AST;
        else if (str_eq(a, "--dump-asm"))   mode = M_ASM;
        else if (str_eq(a, "--dump-syms"))  mode = M_SYMS;
        else if (str_eq(a, "-o")) {
            if (i + 1 >= argc) die("-o exige um argumento");
            i = i + 1;
            out = ld64(argv + i * 8);
        } else if (ld8(a) == '-')  die2("opcao desconhecida", a);
        else if (in == 0)          in = a;
        else                       die2("entrada duplicada", a);
        i = i + 1;
    }
    if (in == 0) { usage(); return 1; }

    tok_init();
    lex_init(in);                                      // o lexer abre e empilha o arquivo
    if (mode == M_TOKENS) { dump_tokens(); return 0; }

    i64 unit = parse_unit();
    if (mode == M_AST) { dump_ast(unit); return 0; }   // arvore como foi parseada

    unit = fold(unit);                                 // dobra antes do codegen
    gen_unit(unit, mode == M_ASM);
    if (mode == M_ASM) return 0;
    if (mode == M_SYMS) { dump_syms(); return 0; }

    macho_write(out);
    return 0;
}
