/* main.c — driver do mc0.
 * uso: mc0 [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] entrada.mc [-o saida.o]
 * Os modos --dump-* escrevem em stdout e nao geram o objeto. */
#include "mc.h"

enum { M_COMPILE = 0, M_TOKENS, M_AST, M_ASM, M_SYMS, M_RULES };

static void usage(void) {
    out_str(2, "uso: mc0 [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] "
               "entrada.mc [-o saida.o]\n");
}

int main(int argc, char **argv) {
    const char *in = 0;
    const char *out = "out.o";
    int mode = M_COMPILE;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (str_eq(a, "--dump-tokens"))     mode = M_TOKENS;
        else if (str_eq(a, "--dump-ast"))   mode = M_AST;
        else if (str_eq(a, "--dump-asm"))   mode = M_ASM;
        else if (str_eq(a, "--dump-syms"))  mode = M_SYMS;
        else if (str_eq(a, "--dump-rules")) mode = M_RULES;
        else if (str_eq(a, "-o")) {
            if (i + 1 >= argc) die("-o exige um argumento");
            out = argv[++i];
        /* Tier 2 (pass()/backend()) so existe no compilador em .mc: o stage0 e a
         * semente e nao e ensinavel. Aqui --backend=macho e aceito e nada mais. */
        } else if (str_eq(a, "--backend=macho")) { }
        else if (a[0] == '-')  die2("opcao desconhecida", a);
        else if (in == 0)        in = a;
        else                     die2("entrada duplicada", a);
    }
    if (in == 0) { usage(); return 1; }

    tok_init();
    lex_init(in);                                      /* o lexer abre e empilha o arquivo */
    if (mode == M_TOKENS) { dump_tokens(); return 0; }

    int unit = parse_unit();
    if (mode == M_RULES) { dump_rules(); return 0; }   /* regras que o fonte registrou */
    if (mode == M_AST) { dump_ast(unit); return 0; }   /* arvore ja com #rule expandido */

    unit = fold(unit);                                 /* dobra antes do codegen */
    gen_lower(unit);                                   /* AST -> buffers Ins */
    if (mode == M_ASM) { gen_dump_asm(); return 0; }
    gen_encode_all();                                  /* Ins -> palavras no __text */
    if (mode == M_SYMS) { dump_syms(); return 0; }

    macho_write(out);
    return 0;
}
