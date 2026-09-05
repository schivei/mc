// cli.mc — the command line: `mc_main()`, the flags, the dump modes and the
// compile pipeline. M41 split it out of src/main.mc, which kept nothing but the
// `main()` that says which PARTS this compiler is made of.
//
// usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules|--dump-machine]
//         [--backend=NAME|--exe] [--machine=NAME] [--include=DIR]
//         [--libc=gnu|musl] [--interp=PATH] [--link=dynamic|static] input.mc [-o output]
//        mc --host   ·   mc --version
//        mc build [DIR]   ·   mc limits [DIR|FILE.mc]   ·   mc sysroot ...
// The --dump-* modes write to stdout and do not generate the object.
//
// argv arrives as uptr: argv[i] is ld64(argv + i * 8) (there is no typed pointer).
// Depends on arena.mc (str_eq, out_str, die, die2), on lex.mc (tok_init,
// lex_init, dump_tokens), on parse.mc (parse_unit, fold), on ast.mc (dump_ast),
// on gen_walk.mc (gen_lower, gen_encode_all, gen_dump_asm, MTASK_*),
// on objmodel.mc (dump_syms) and on hooks.mc (run_passes, backend_find,
// machine_use_if, subcommand_find, run_on_plan, target_find) — every one of
// them a member of <mc/core_min>. Nothing here names a writer, a machine, the
// driver or the bundle: those are the optional parts, and they reach this file
// through the registries alone (docs/reference/hooks.md).
//
// M10: the driver calls user_init() before any parse (that is where the user's
// modules register passes and backends), applies the passes to the AST and
// picks the backend via --backend=NAME.
//
// M17 step B: an object backend names the machine it needs (`machine_use`),
// because the file format records the architecture too; the dump modes never
// reach a backend, so `--machine=NAME` is what points them at a machine other
// than the host's.
//
// M37: the compiler is hosted on macOS AND on Linux. Everything that differs
// between the two is in the host layer the entry point includes before the core
// (src/host_macos.mc, src/host_linux.mc); here that shows up in three places --
// `--host`, the machine the dump modes start with, and the target the default
// object backend comes from.
//
// M41: three things that used to be written here as `if`s are registrations
// now, so that a compiler assembled from a subset of the parts still has a
// working command line: the machine is only made current when it exists
// (machine_use_if), the default backend comes from the target registry or from
// backend_default(), and `build`/`limits`/`sysroot` come out of the subcommand
// table that <mc/core_build> fills.

#define M_COMPILE 0
#define M_TOKENS  1
#define M_AST     2
#define M_ASM     3
#define M_SYMS    4
#define M_RULES   5
#define M_MACHINE 6

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

// `mc --version`: the version this binary was BUILT as, one line, `mc X.Y.Z`.
// The program name is on the line because that is what every other `--version`
// on the machine prints and what a bug report gets pasted into; the version
// itself carries no `v`, because `docs/ci.md` § Versioning says the `v` belongs
// to the tag name and nothing else -- it is the same string release-assets.sh
// takes as its first argument. `0.0.0-dev` in any binary built from the working
// tree (src/version.mc). `--host` is the shape: a one-shot informational flag,
// stdout, exit 0, answered before anything else is read.
void dump_version() {
    out_str(1, "mc ");
    out_str(1, mc_version());
    out_str(1, "\n");
}

// M24 (M9): `--dump-machine` — every registered machine, one line per task, with
// the ORIGIN of the slot. There is no runtime symbol table, so the origin is
// read from the registry itself: a slot whose pointer is the same pointer a
// BUNDLED machine has for that task is `bundled <that machine>`, and anything
// else is `taught`. That is exactly what makes a derived machine reviewable —
// which slots a module actually replaced, and on top of what — and it is the
// cheapest observable test that an override took effect.
//
// The machine `mach_tab` points at is marked `(current)`: with `machine()`
// reusing the slot of a name it shadows (M24 D5), a module that re-registers
// `arm64` is reported under that name, not as a fourth row.
uptr mach_origin(i64 mi, i64 t) {
    uptr fn = ld64(mach_tabs_at(mi) + t * 8);
    i64 b = 0;
    loop {
        if (b >= mach_builtin) break;
        if (ld64(mach_btabs_at(b) + t * 8) == fn) return mach_bnames_at(b);
        b = b + 1;
    }
    return 0;
}

void dump_machine() {
    i64 i = 0;
    loop {
        if (i >= nmachines) break;
        out_str(1, "machine ");
        out_str(1, mach_names_at(i));
        if (mach_tabs_at(i) == mach_tab) out_str(1, " (current)");
        out_str(1, "\n");
        i64 t = 0;
        loop {
            if (t >= MTASK_COUNT) break;
            out_str(1, "  ");
            out_str(1, mtask_name(t));
            i64 n = 18 - cstrlen(mtask_name(t));
            loop {                               // one fixed column, no tabs
                if (n <= 0) break;
                out_str(1, " ");
                n = n - 1;
            }
            uptr from = mach_origin(i, t);
            if (from) { out_str(1, "bundled "); out_str(1, from); }
            else        out_str(1, "taught");
            out_str(1, "\n");
            t = t + 1;
        }
        i = i + 1;
    }
}

// M41: the two fixed lines, then one entry per REGISTERED subcommand. A
// compiler without <mc/core_build> has none and prints just the two -- which is
// the honest answer, since `mc build` is not in it.
void usage() {
    out_str(2, "usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules|--dump-machine] [--backend=NAME|--exe] [--machine=NAME] [--include=DIR] [--libc=gnu|musl] [--interp=PATH] [--link=dynamic|static] source.mc [-o out]\n");
    out_str(2, "       mc --host\n");
    out_str(2, "       mc --version\n");
    subcommand_usage();
}

// The whole command line, and the compile pipeline behind it. Called by the
// main() of every compiler built on <mc/core_min>, after that main() has run
// the *_init of each part it is made of (src/main.mc).
//
// envp is the third argument the C runtime passes (libSystem on macOS, musl's
// crt1.o on Linux). The Linux host has no other way to reach the environment,
// so main() hands it over before anything else runs (src/host_linux.mc), and it
// is passed on here for the same reason.
i64 mc_main(i64 argc, uptr argv, uptr envp) {
    uptr in = 0;
    uptr out = "out.o";
    uptr bname = 0;                             // 0 = the host's object backend
    uptr mname = 0;                             // --machine=, for the dump modes
    i64 mode = M_COMPILE;
    i64 want_exe = 0;                           // --exe: the HOST's exe backend
    uptr linkflag = 0;                          // the last of --libc/--interp/--link

    // M17: the machines were registered before this call. `machine()` also
    // makes each one current, so the host's is named again here -- when it
    // exists: M41 made it machine_use_if, because a compiler for a foreign
    // target has no machine by the host's name and must not die for it. From
    // here on the object backend in use picks its own (src/backend_elf.mc) and
    // `--machine=` overrides for the dump modes.
    machine_use_if(host_machine());             // the host's own, for the dumps
    // M24: everything registered up to here is bundled; --dump-machine reads
    // that snapshot to tell a taught slot from a built-in one
    machine_freeze();

    // M14/M41: `mc build [DIR]`, `mc limits` and `mc sysroot` are subcommands,
    // not flags, and they belong to <mc/core_build>: what is registered is what
    // this binary understands (src/hooks.mc, subcommand()).
    if (argc >= 2) {
        i64 si = subcommand_find(ld64(argv + 8));
        if (si >= 0) return callp(sub_fn_at(si), argc, argv);
    }

    i64 i = 1;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--host"))          { dump_host(); return 0; }
        else if (str_eq(a, "--version"))  { dump_version(); return 0; }
        else if (str_eq(a, "--dump-tokens")) mode = M_TOKENS;
        else if (str_eq(a, "--dump-ast"))   mode = M_AST;
        else if (str_eq(a, "--dump-asm"))   mode = M_ASM;
        else if (str_eq(a, "--dump-syms"))  mode = M_SYMS;
        else if (str_eq(a, "--dump-rules")) mode = M_RULES;
        else if (str_eq(a, "--dump-machine")) mode = M_MACHINE;
        // post-M41 review: `--exe` asks for A DIRECT EXECUTABLE FOR THE HOST,
        // which is not a synonym for "macho-exe": it used to be written here
        // as that name, and a Linux- or Windows-hosted mc then wrote a Mach-O
        // binary its own kernel refuses. The name is resolved from the target
        // registry below, after user_init(), so a module's registration counts
        // (M39.5). Both flags write the same decision, so the LAST one wins.
        else if (str_eq(a, "--exe"))        { want_exe = 1; bname = 0; }
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
            // post-M42 patch: the two axes of a Linux dynamic executable, said
            // on the command line exactly as [target] says them in mc.toml --
            // one vocabulary, and no probe of the machine: `mc --exe prog.mc`
            // with no flag writes the same bytes on every host, which is what
            // docs/determinism.md asks for. They are written straight into the
            // globals src/objmodel.mc holds for the writer; the last one wins,
            // like every other flag here.
            uptr lc = opt_val(a, "--libc=");
            uptr it = opt_val(a, "--interp=");
            uptr lk = opt_val(a, "--link=");
            if (mn)      mname = mn;
            else if (bn) { bname = bn; want_exe = 0; }
            else if (ip) { }                    // applied after lex_init, below
            else if (lc) {
                if (!str_eq(lc, "gnu") && !str_eq(lc, "musl"))
                    die2("--libc must be gnu or musl", lc);
                dyn_libc = lc;
                linkflag = "--libc";
            }
            else if (it) { dyn_interp = it; linkflag = "--interp"; }
            else if (lk) {
                if (str_eq(lk, "static"))        dyn_static = 1;
                else if (str_eq(lk, "dynamic"))  dyn_static = 0;
                else die2("--link must be dynamic or static", lk);
                linkflag = "--link";
            }
            else         die2("unknown option", a);
        }
        else if (in == 0)          in = a;
        else                       die2("duplicate entry", a);
        i = i + 1;
    }
    if (in == 0) { usage(); return 1; }

    // M23/M41: the pre-scan sizes every table before the first one exists. It
    // lives in <mc/core_build> and reaches here through on_plan(); with that
    // part absent nothing is pre-sized and the tables grow from the seeds in
    // src/arena.mc, which is what src/astdump.mc has always done.
    run_on_plan(in, in);
    tok_init();
    lex_init(in);                                      // the lexer opens and pushes the file
    // M37: the extra `#include` roots, applied here and not while the flags are
    // being read -- the table lives in the arena, which the pre-scan has only
    // just sized, and no include is resolved before the first token anyway.
    i = 1;
    while (i < argc) {
        uptr ip = opt_val(ld64(argv + i * 8), "--include=");
        if (ip) lex_add_include_path(tm_cat(ip, "/"));
        i = i + 1;
    }
    // M45: the core's own registered primitives -- `i32` today. After
    // tok_init() for the same reason user_init is, and BEFORE it so that a
    // module registering the same word wins (alias_find walks from the end).
    core_types_init();
    // Tier 2 after tok_init(): the ids K_U8..K_EXTERN are fixed at 256..269, so
    // a user_init that calls tok_add before that would shift the table and break
    // the entire core. Before any token is read, because the lexer is
    // incremental: the user's `#token`/`#rule` still apply to the whole source.
    user_init();

    // post-M42 review: --libc, --interp and --link describe A LINUX DYNAMIC
    // EXECUTABLE, and nothing else reads them -- src/backend_elf_exe.mc is the
    // only file in the tree that names dyn_libc/dyn_interp/dyn_static. So every
    // other road silently ignored them: on a Linux host `mc x.mc -o x.o
    // --libc=gnu` wrote exactly the object it writes without the flag (elf-obj
    // has no PT_INTERP and no DT_NEEDED to put it in), and so did
    // `--backend=elf-obj --libc=gnu` on any host. Three questions, in the order
    // a user can act on them:
    //
    //   1. is anything written at all? a --dump-* mode returns before a backend
    //      is ever reached, so the flag can affect nothing there either;
    //   2. is what is written an EXECUTABLE? that is `--exe`, or a --backend=
    //      the TARGET REGISTRY names in an exe slot (backend_is_exe,
    //      src/hooks.mc) -- asked of the registry, never of the name, so a
    //      target a module registered answers for its own writer;
    //   3. is that executable a Linux one? the host decides when no backend was
    //      named; with one named the caller chose the format and this is the
    //      cross road (`--backend=elf-exe --libc=gnu` from macOS).
    //
    // Here and not where the flags were read, for the reason M39.5 wrote for
    // `mc build`'s [target]: after user_init() a backend a module registered
    // counts. The price is that the entry is opened and lexed first, so
    // `cannot open` now comes before the refusal (docs/reference/diagnostics.md).
    if (linkflag) {
        if (mode != M_COMPILE)
            die(tm_cat(linkflag, " applies to an executable: a --dump-* mode writes none"));
        if (!want_exe && (bname == 0 || !backend_is_exe(bname)))
            die(tm_cat(linkflag, " applies to an executable: use --exe"));
        if (bname == 0 && !str_eq(host_os(), "linux"))
            die(tm_cat(linkflag, " applies to a linux target"));
    }

    // after user_init, so a module can register the machine the flag names
    if (mname) machine_use(mname);
    // M24: after user_init and after --machine=, because both are what a
    // taught compiler changes; before the parse, because a machine table is
    // not a function of the source
    if (mode == M_MACHINE) { dump_machine(); return 0; }
    if (mode == M_TOKENS) { dump_tokens(); return 0; }

    i64 unit = parse_unit();
    if (mode == M_RULES) { dump_rules(); return 0; }   // rules the source registered
    unit = run_passes(unit);                           // Tier 2: user passes
    if (mode == M_AST) { dump_ast(unit); return 0; }   // tree already with #rule and passes

    unit = fold(unit);                                 // fold before codegen
    // M41: everything below drives a machine through gen_lower. Said here, once,
    // instead of dereferencing a null table inside the first mach() call.
    if (mach_tab == 0) die("no machine registered");
    if (mode == M_ASM) { gen_lower(unit); gen_dump_asm(); return 0; }
    if (mode == M_SYMS) { gen_lower(unit); gen_encode_all(); dump_syms(); return 0; }

    // post-M41 review: the backend the HOST answers for -- the exe slot for
    // `--exe`, the object slot for a plain `mc x.mc -o x.o` -- is resolved here
    // and not where the flags were read. Here means after user_init(), so a
    // target a module registered counts (the rule M39.5 wrote for `mc build`,
    // which resolves inside drv_parse for the same reason), and after the dumps
    // have returned, so `--dump-asm` still dumps on a host that answers for no
    // backend at all. `--backend=NAME` skips the whole block: it named one.
    //
    // A 0 in either slot is a REGISTRATION saying this target does not have
    // that role -- 0 in the exe slot is windows (src/core_writers.mc; linux had
    // one too until M42 filled it), 0 in the object slot is what a board whose
    // flat image is the whole artefact writes (examples/kernel) -- and neither
    // of the two may reach backend_find(), which takes a name and would
    // dereference it. Both messages are the
    // driver's (drv_backend_for, src/driver.mc), with what a TOML file would do
    // replaced by what a command line can: `[linker]` becomes "a linker" and
    // `kind = "exe"` becomes `--exe`.
    if (want_exe) {
        i64 he = target_find(host_os(), host_arch());
        if (he < 0) die2("the host is not a registered target", host_os());
        if (tgt_exe_at(he) == 0)
            die(tm_cat(host_os(),
                       " requires a linker: there is no direct executable"));
        bname = tgt_exe_at(he);
    } else if (bname == 0) {
        // M37: with no --backend and no --exe, `mc x.mc -o x.o` writes an
        // object for the machine it is RUNNING on -- Mach-O on macOS, ELF on
        // Linux, each with that host's architecture -- out of the same registry
        // `mc build` reads, so a host is supported exactly when it is
        // registered. M41: a compiler with no target registry at all -- one
        // machine, one writer, nothing to look up -- says which backend is its
        // default instead (backend_default, src/hooks.mc). With neither there
        // is nothing to guess.
        i64 ht = target_find(host_os(), host_arch());
        if (ht >= 0) {
            if (tgt_obj_at(ht) == 0)
                die(tm_cat(tm_cat(host_os(), "/"),
                           tm_cat(host_arch(),
                                  " has no object backend: use --exe")));
            bname = tgt_obj_at(ht);
        }
        else if (backend_default_name()) bname = backend_default_name();
        else if (ntargets)               die2("the host is not a registered target", host_os());
        else                             die("no backend: use --backend=NAME");
    }

    i64 bi = backend_find(bname);
    if (bi < 0) backend_die(bname);
    callp(backend_fn_at(bi), unit, out);
    return 0;
}
