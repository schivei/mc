// main.mc — transliteration of stage0/main.c: compiler driver.
// usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules]
//         [--backend=NAME|--exe] input.mc [-o output]
// The --dump-* modes write to stdout and do not generate the object.
//
// argv arrives as uptr: argv[i] is ld64(argv + i * 8) (there is no typed pointer).
// Depends on arena.mc (str_eq, out_str, die, die2), on lex.mc (tok_init,
// lex_init, dump_tokens), on parse.mc (parse_unit, fold), on ast.mc (dump_ast),
// on gen_arm64.mc (gen_lower, gen_encode_all, gen_dump_asm), on macho.mc
// (dump_syms, macho_write), on backend_exe.mc (backend_exe), on hooks.mc
// (pass/backend/run_passes/backend_find) and on user.mc (user_init).
//
// M10: the driver calls user_init() before any parse (that is where the user's
// modules register passes and backends), applies the passes to the AST and
// picks the backend via --backend=NAME. The built-in `macho` backend is
// gen_lower + gen_encode_all + macho_write and is the default.
//
// M15: main() also registers `bundle_open` in the lexer, which is what makes
// `#include <name>` work -- see src/bundle.mc and docs/build.md.
//
// M11: `macho-exe` (gen_lower + gen_encode_all + exe_write) is also built in and
// writes a signed MH_EXECUTE, without `ld`. `--exe` is an alias for
// `--backend=macho-exe`. This backend only exists in the .mc compiler: the stage0
// in C is the seed and stays only with `macho` (docs/surface.md § Tier 2).

#define M_COMPILE 0
#define M_TOKENS  1
#define M_AST     2
#define M_ASM     3
#define M_SYMS    4
#define M_RULES   5

// built-in backend: the two halves of gen plus writing the MH_OBJECT
void backend_macho(i64 unit, uptr out) {
    gen_lower(unit);
    gen_encode_all();
    macho_write(out);
}

// text after the prefix `pre` in `a`, or 0 if `a` does not start with `pre`
uptr opt_val(uptr a, uptr pre) {
    i64 i = 0;
    loop {
        if (ld8(pre + i) == 0) break;
        if (ld8(a + i) != ld8(pre + i)) return 0;
        i = i + 1;
    }
    return a + i;
}

void usage() {
    out_str(2, "usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] [--backend=NAME|--exe] source.mc [-o out]\n");
    drv_usage();
}

i64 main(i64 argc, uptr argv) {
    uptr in = 0;
    uptr out = "out.o";
    uptr bname = "macho";
    i64 mode = M_COMPILE;

    backend("macho", &backend_macho);           // the built-ins, always registered
    backend("macho-exe", &backend_exe);
    // M15: the lexer only reaches the bundle through this pointer, so
    // src/lexdump.mc and src/astdump.mc keep compiling without src/bundle.mc.
    // Registered here, before any lex_init -- including the one inside
    // `mc build`, which goes through this same main().
    lex_set_bundle(&bundle_open);

    // M14: `mc build [DIR] [--config FILE]` is a subcommand, not a flag -- it
    // reads mc.toml and drives the whole build (src/driver.mc, docs/build.md).
    // It comes after the backends because that is what the driver picks from.
    if (argc >= 2 && str_eq(ld64(argv + 8), "build")) return drv_build(argc, argv);

    i64 i = 1;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--dump-tokens"))     mode = M_TOKENS;
        else if (str_eq(a, "--dump-ast"))   mode = M_AST;
        else if (str_eq(a, "--dump-asm"))   mode = M_ASM;
        else if (str_eq(a, "--dump-syms"))  mode = M_SYMS;
        else if (str_eq(a, "--dump-rules")) mode = M_RULES;
        else if (str_eq(a, "--exe"))        bname = "macho-exe";
        else if (str_eq(a, "-o")) {
            if (i + 1 >= argc) die("-o requires an argument");
            i = i + 1;
            out = ld64(argv + i * 8);
        } else if (ld8(a) == '-') {
            uptr bn = opt_val(a, "--backend=");
            if (bn == 0) die2("unknown option", a);
            bname = bn;
        }
        else if (in == 0)          in = a;
        else                       die2("duplicate entry", a);
        i = i + 1;
    }
    if (in == 0) { usage(); return 1; }

    tok_init();
    lex_init(in);                                      // the lexer opens and pushes the file
    // Tier 2 after tok_init(): the ids K_U8..K_EXTERN are fixed at 256..269, so
    // a user_init that calls tok_add before that would shift the table and break
    // the entire core. Before any token is read, because the lexer is
    // incremental: the user's `#token`/`#rule` still apply to the whole source.
    user_init();
    if (mode == M_TOKENS) { dump_tokens(); return 0; }

    i64 unit = parse_unit();
    if (mode == M_RULES) { dump_rules(); return 0; }   // rules the source registered
    unit = run_passes(unit);                           // Tier 2: user passes
    if (mode == M_AST) { dump_ast(unit); return 0; }   // tree already with #rule and passes

    unit = fold(unit);                                 // fold before codegen
    if (mode == M_ASM) { gen_lower(unit); gen_dump_asm(); return 0; }
    if (mode == M_SYMS) { gen_lower(unit); gen_encode_all(); dump_syms(); return 0; }

    i64 bi = backend_find(bname);
    if (bi < 0) backend_die(bname);
    callp(backend_fn_at(bi), unit, out);
    return 0;
}
