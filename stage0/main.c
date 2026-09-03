/* main.c — mc0 driver.
 * usage: mc0 [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] input.mc [-o output.o]
 * The --dump-* modes write to stdout and do not generate the object. */
#include "mc.h"

enum { M_COMPILE = 0, M_TOKENS, M_AST, M_ASM, M_SYMS, M_RULES };

static void usage(void) {
    out_str(2, "usage: mc0 [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] "
               "source.mc [-o out.o]\n");
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
            if (i + 1 >= argc) die("-o requires an argument");
            out = argv[++i];
        /* Tier 2 (pass()/backend()) only exists in the .mc compiler: stage0 is the
         * seed and is not teachable. Here --backend=macho is accepted and nothing else. */
        } else if (str_eq(a, "--backend=macho")) { }
        else if (a[0] == '-')  die2("unknown option", a);
        else if (in == 0)        in = a;
        else                     die2("duplicate entry", a);
    }
    if (in == 0) { usage(); return 1; }

    tok_init();
    lex_init(in);                                      /* the lexer opens and pushes the file */
    if (mode == M_TOKENS) { dump_tokens(); return 0; }

    int unit = parse_unit();
    if (mode == M_RULES) { dump_rules(); return 0; }   /* rules the source registered */
    if (mode == M_AST) { dump_ast(unit); return 0; }   /* tree with #rule already expanded */

    unit = fold(unit);                                 /* fold before codegen */
    gen_lower(unit);                                   /* AST -> Ins buffers */
    if (mode == M_ASM) { gen_dump_asm(); return 0; }
    gen_encode_all();                                  /* Ins -> words in __text */
    if (mode == M_SYMS) { dump_syms(); return 0; }

    macho_write(out);
    return 0;
}
