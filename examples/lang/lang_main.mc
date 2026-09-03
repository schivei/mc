// lang_main.mc — the CLI of the taught compiler, in place of `src/main.mc`.
//
// It is `src/main.mc` with two things left out, and for one reason: arena.
// `mc` holds the whole compilation in a 32 MiB arena (`HEAP_SIZE` in
// `src/arena.mc`) and `examples/lang`'s module does not fit next to the whole
// core. Measured on this checkout with a twenty-statement function as the unit
// (`mc1` compiling the taught compiler):
//
//     src/core.mc as published (bundle included)     44 units spare
//     the same, bundle blob stubbed out             189 units spare
//     lang_core.mc (no bundle, no ELF backend)      240 units spare
//     lang_core.mc + lang.mc                         21 units spare
//
// So what is missing here is:
//
//   * `elf-obj` (`src/backend_elf.mc`) — `lx` targets macOS/arm64 only, and a
//     `[target] os = "linux"` build through this compiler answers
//     `unknown backend: elf-obj` instead of producing an ELF;
//   * the bundle (`src/bundle.mc` + `src/bundle_data.mc`) — `#include <name>`
//     is therefore not available, and every source under `examples/lang` uses
//     `#include "relative/path"`, which is unaffected.
//
// Everything else is identical: the same `--dump-*` modes, the same
// `--backend=`/`--exe`, the same `mc build` subcommand through `src/driver.mc`.
// See README.md § Limits; the fix belongs in the core, not here.

#define M_COMPILE 0
#define M_TOKENS  1
#define M_AST     2
#define M_ASM     3
#define M_SYMS    4
#define M_RULES   5

// the built-in backend: the two halves of gen plus writing the MH_OBJECT
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
    out_str(2, "usage: mc-lang [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] [--backend=NAME|--exe] source.lx [-o out]\n");
    drv_usage();
}

i64 main(i64 argc, uptr argv) {
    uptr in = 0;
    uptr out = "out.o";
    uptr bname = "macho";
    i64 mode = M_COMPILE;

    backend("macho", &backend_macho);
    backend("macho-exe", &backend_exe);

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
    lex_init(in);
    user_init();                                 // the lx module registers here
    if (mode == M_TOKENS) { dump_tokens(); return 0; }

    i64 unit = parse_unit();
    if (mode == M_RULES) { dump_rules(); return 0; }
    unit = run_passes(unit);
    if (mode == M_AST) { dump_ast(unit); return 0; }

    unit = fold(unit);                           // fold before codegen
    if (mode == M_ASM)  { gen_lower(unit); gen_dump_asm(); return 0; }
    if (mode == M_SYMS) { gen_lower(unit); gen_encode_all(); dump_syms(); return 0; }

    i64 bi = backend_find(bname);
    if (bi < 0) backend_die(bname);
    callp(backend_fn_at(bi), unit, out);
    return 0;
}
