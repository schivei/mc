// cli.mc — the command line: `mc_main()`, the flags, the dump modes and the
// compile pipeline. M41 split it out of src/main.mc, which kept nothing but the
// `main()` that says which PARTS this compiler is made of.
//
// usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules|--dump-machine]
//         [--backend=NAME|--exe] [--machine=NAME] [--include=DIR] input.mc [-o output]
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

void usage() {
    out_str(2, "usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules|--dump-machine] [--backend=NAME|--exe] [--machine=NAME] [--include=DIR] source.mc [-o out]\n");
    out_str(2, "       mc --host\n");
    drv_usage();
}
