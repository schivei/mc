// astdump.mc — driver for M6 slice 3: parses the file given in argv[1]
// (following #include, like the real compiler) and prints exactly what
// `mc0 --dump-ast FILE` prints. Same sequence as stage0/main.c's M_AST
// mode: tok_init, lex_init, parse_unit, dump_ast — the tree comes out as it
// was parsed, BEFORE the fold() that the driver only applies on the codegen path.
// So directives do not appear (they do not become a node), but functions, globals, externs
// and prototypes do appear, in source order and with #include already expanded.
//
// macho.mc comes in because parse.mc uses sec_new (in sec_make) and the
// R_UNSIGNED/BRANCH26/PAGE21/PAGEOFF12 constants that defs_init registers; and also the
// #include order src/core.mc uses. hooks.mc came in at M12: parse.mc consults the
// syntax/syntax_stmt/type_alias tables that live there. None of them is populated
// here (this driver does not call user_init), so parsing is the same as mc0's.
// lz.mc came in at M15: `#embed ... lz` compresses at parse time. src/bundle.mc
// did NOT -- the lexer reaches the bundle by function pointer, and nobody
// registers it here, so `#include <name>` fails the same way it does in mc0.
#include "arena.mc"
#include "lz.mc"
#include "macho.mc"
#include "lex.mc"
#include "ast.mc"
#include "parse.mc"
#include "hooks.mc"

i64 main(i64 argc, uptr argv) {
    if (argc < 2) {
        out_str(2, "usage: astdump source.mc\n");
        return 1;
    }
    uptr in = ld64(argv + 8);          // argv[1]
    tok_init();
    lex_init(in);                      // the lexer opens and pushes the file
    i64 unit = parse_unit();
    dump_ast(unit);
    return 0;
}
