// main.mc — transliteration of stage0/main.c: compiler driver.
// usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules]
//         [--backend=NAME|--exe] [--machine=NAME] [--include=DIR] input.mc [-o output]
//        mc build [DIR] [--limits|--fix-limits]   ·   mc limits [DIR|FILE.mc]
// The --dump-* modes write to stdout and do not generate the object.
//
// argv arrives as uptr: argv[i] is ld64(argv + i * 8) (there is no typed pointer).
// Depends on arena.mc (str_eq, out_str, die, die2), on lex.mc (tok_init,
// lex_init, dump_tokens), on parse.mc (parse_unit, fold), on ast.mc (dump_ast),
// on gen_walk.mc (gen_lower, gen_encode_all, gen_dump_asm), on machine_arm64.mc
// (machine_arm64_init), on macho.mc (dump_syms, macho_write), on backend_exe.mc
// (backend_exe), on backend_elf.mc (backend_elf), on backend_coff.mc
// (backend_coff), on hooks.mc (pass, backend,
// run_passes, backend_find, machine, target) and on user.mc (user_init).
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
//
// M16: `elf-obj` (gen_lower + gen_encode_all + elf_write) writes an ELF64 ET_REL
// for aarch64 Linux. It has no `--exe`-style alias: a Linux build always goes
// through an external linker, chosen by `[target].os = "linux"` in mc.toml
// (src/driver.mc, docs/build.md § Linux targets).
//
// M17 step B: `elf-obj-x86_64` is its x86-64 sibling, and `[target] os = "linux"
// arch = "x86_64"` selects it. An object backend names the machine it needs
// (`machine_use`), because the file format records the architecture too; the
// dump modes never reach a backend, so `--machine=NAME` is what points them at
// a machine other than the host's.
//
// M19: `coff-obj-arm64` (gen_lower + gen_encode_all + coff_write) writes a COFF
// object for Windows on ARM, and `[target] os = "windows" arch = "aarch64"`
// selects it. Like Linux it has no direct-executable backend: the link always
// goes through `[linker]` (`lld-link`), so the registration passes 0 for it.

// M37: the compiler is hosted on macOS AND on Linux. Everything that differs
// between the two is in the host layer the entry point includes before the core
// (src/host_macos.mc, src/host_linux.mc); here that shows up in four places --
// host_init(envp) at the top of main, `--host`, the machine the dump modes
// start with, and `<mc/host>` in host_bundle_open below.

#define M_COMPILE 0
#define M_TOKENS  1
#define M_AST     2
#define M_ASM     3
#define M_SYMS    4
#define M_RULES   5

// built-in backend: the two halves of gen plus writing the MH_OBJECT.
// M37: `machine_use` first, like every other backend since M17 -- a Mach-O
// object here is always arm64, and the machine that is current when the backend
// is called is the HOST's, which on a linux/x86_64 host is not the same thing.
void backend_macho(i64 unit, uptr out) {
    machine_use("arm64");
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

// M15/M37: the lexer's one door into the bundle. `<mc/host>` is not an entry of
// its own -- it is the name of THIS compiler's host file, which is what makes a
// generated taught compiler (src/driver.mc, drv_gen_compiler) portable: the
// same two lines produce a macOS compiler on a macOS host and a Linux one on a
// Linux host. Every other name goes straight through.
uptr host_bundle_open(uptr name, i64 base, uptr pcanon, uptr plen) {
    if (str_eq(name, "mc/host")) name = host_include();
    return bundle_open(name, base, pcanon, plen);
}

// `mc --host`: what this binary is, in the vocabulary mc.toml uses. The first
// two lines are the [target] pair a config with no [target] gets; `sys` is the
// bundled system layer a program on this host includes for its I/O.
void dump_host() {
    out_str(1, "os ");
    out_str(1, host_os());
    out_str(1, "\narch ");
    out_str(1, host_arch());
    out_str(1, "\nsys ");
    out_str(1, host_sys());
    out_str(1, "\n");
}

void usage() {
    out_str(2, "usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] [--backend=NAME|--exe] [--machine=NAME] [--include=DIR] source.mc [-o out]\n");
    out_str(2, "       mc --host\n");
    drv_usage();
}

// envp is the third argument the C runtime passes (libSystem on macOS, musl's
// crt1.o on Linux). The Linux host has no other way to reach the environment,
// so it is handed over before anything else runs (src/host_linux.mc).
i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    uptr in = 0;
    uptr out = "out.o";
    uptr bname = 0;                             // 0 = the host's object backend
    uptr mname = 0;                             // --machine=, for the dump modes
    i64 mode = M_COMPILE;

    // M17: the machines the walker can drive, before any backend can lower.
    // `machine()` also makes each one current, so the host machine is named
    // again at the end; from there on the object backend in use picks its own
    // (src/backend_elf.mc) and `--machine=` overrides for the dump modes.
    machine_arm64_init();
    machine_x86_64_init();
    machine_use(host_machine());                // the host's own, for the dumps
    backend("macho", &backend_macho);           // the built-ins, always registered
    backend("macho-exe", &backend_exe);
    backend("elf-obj", &backend_elf);
    backend("elf-obj-x86_64", &backend_elf_x86);
    backend("coff-obj-arm64", &backend_coff);
    // M17/M33: the (os, arch) pairs `mc build` accepts, with the backend each
    // one writes objects and direct executables with. `0` as the executable
    // backend says the target has none and always goes through [linker] --
    // which is what Linux does. src/driver.mc reads nothing but this table.
    target("macos", "aarch64", "macho", "macho-exe");
    target("linux", "aarch64", "elf-obj", 0);
    target("linux", "x86_64", "elf-obj-x86_64", 0);
    target("windows", "aarch64", "coff-obj-arm64", 0);
    // M15: the lexer only reaches the bundle through this pointer, so
    // src/lexdump.mc and src/astdump.mc keep compiling without src/bundle.mc.
    // Registered here, before any lex_init -- including the one inside
    // `mc build`, which goes through this same main().
    lex_set_bundle(&host_bundle_open);

    // M14: `mc build [DIR] [--config FILE]` is a subcommand, not a flag -- it
    // reads mc.toml and drives the whole build (src/driver.mc, docs/build.md).
    // It comes after the backends because that is what the driver picks from.
    if (argc >= 2 && str_eq(ld64(argv + 8), "build")) return drv_build(argc, argv);
    // M23: the same driver, stopping at the report instead of the object.
    if (argc >= 2 && str_eq(ld64(argv + 8), "limits")) return drv_limits(argc, argv);

    i64 i = 1;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--host"))          { dump_host(); return 0; }
        else if (str_eq(a, "--dump-tokens")) mode = M_TOKENS;
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
            uptr mn = opt_val(a, "--machine=");
            uptr bn = opt_val(a, "--backend=");
            // M37: the same extra `#include` root [include].paths gives a
            // project, for the single-file CLI. It is what lets one source tree
            // carry two platform layers in different directories and pick one
            // without `mc build` (examples/conc/lib/macos, lib/linux).
            uptr ip = opt_val(a, "--include=");
            if (mn)      mname = mn;
            else if (bn) bname = bn;
            else if (ip) { }                    // applied after lex_init, below
            else         die2("unknown option", a);
        }
        else if (in == 0)          in = a;
        else                       die2("duplicate entry", a);
        i = i + 1;
    }
    if (in == 0) { usage(); return 1; }

    // M37: with no --backend and no --exe, `mc x.mc -o x.o` writes an object
    // for the machine it is RUNNING on -- Mach-O on macOS, ELF on Linux, each
    // with that host's architecture. It comes out of the same target registry
    // `mc build` reads, so a host is supported exactly when it is registered.
    if (bname == 0) {
        i64 ht = target_find(host_os(), host_arch());
        if (ht < 0) die2("the host is not a registered target", host_os());
        bname = tgt_obj_at(ht);
    }

    // M23: the pre-scan sizes every table before the first one exists. With no
    // mc.toml there is no tolerance to read, so the default 0.25 applies and the
    // arena stays the static heap[].
    lim_plan(in, lim_tol, 0, in);
    tok_init();
    lex_init(in);                                      // the lexer opens and pushes the file
    // M37: the extra `#include` roots, applied here and not while the flags are
    // being read -- the table lives in the arena, which lim_plan has only just
    // sized, and no include is resolved before the first token anyway.
    i = 1;
    while (i < argc) {
        uptr ip = opt_val(ld64(argv + i * 8), "--include=");
        if (ip) lex_add_include_path(tm_cat(ip, "/"));
        i = i + 1;
    }
    // Tier 2 after tok_init(): the ids K_U8..K_EXTERN are fixed at 256..269, so
    // a user_init that calls tok_add before that would shift the table and break
    // the entire core. Before any token is read, because the lexer is
    // incremental: the user's `#token`/`#rule` still apply to the whole source.
    user_init();
    // after user_init, so a module can register the machine the flag names
    if (mname) machine_use(mname);
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
