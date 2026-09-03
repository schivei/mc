// driver.mc — `mc build`: the project driver (M14, docs/specs/M14.md,
// docs/build.md).
//
//   mc build [DIR] [--config FILE] [--entry-only]
//
// DIR defaults to `.` and the config to `DIR/mc.toml`. Every path in the file is
// relative to the DIRECTORY OF THE CONFIG, never to the working directory, so
// `mc build examples/api` from the repository root does the same as `mc build`
// from inside it.
//
// The two shapes of a build:
//
//   no [compiler]      parse the TOML, compile [project].entry in THIS process
//                      with the backend [project].kind asks for.
//   with [compiler]    write a source file that is `#include` of the core plus
//                      each [compiler].modules, compile it here with `macho-exe`
//                      -- that is the taught compiler -- and then SPAWN it as
//                      `<compiler> build DIR --config FILE --entry-only` so the
//                      entry is compiled by the compiler that just came out.
//
// M16: `[target].os` also takes "linux". That swaps the object backend for
// `elf-obj` (src/backend_elf.mc) and REQUIRES `[linker]` — there is no direct
// executable for Linux — and adds the `{sysroot}` placeholder, which is where
// the musl crt objects and libc.a come from. Everything else is unchanged,
// including the taught compiler, which is always built for the host.
//
// The spawn is not a detail: the compiler's tables (lexer, arena, AST, symbols)
// are global and are built once per process, so two compilations never fit in
// one run. `--entry-only` is the flag that says "you are the second half": it
// skips the [compiler] step and compiles the entry, reading the same TOML -- so
// [include]/[libs]/[externs] apply to the entry in either shape.
//
// Depends on arena.mc, on toml.mc, on lex.mc (tok_init/lex_init/path_join/
// path_norm/lex_add_include_path), on parse.mc (parse_unit/fold/dylib_add/
// extern_lib_pattern_add), on hooks.mc (user_init/run_passes/backend_find) and
// on main.mc (opt_val). Nothing here is reachable from the single-file CLI.

#include "../lib/prelude.mc"

// libSystem, for spawning tools. There is no equivalent in lib/sys_svc.mc: the
// syscall path exists to prove the core does not need libc for I/O, and
// posix_spawn is not a syscall -- it is a libSystem routine over
// __posix_spawn(2) with a struct layout this language cannot lay out. See
// docs/build.md, section "Spawning tools".
extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 posix_spawn_file_actions_init(uptr fa);
extern i64 posix_spawn_file_actions_addopen(uptr fa, i64 fd, uptr path, i64 flags, i64 mode);
extern i64 posix_spawn_file_actions_destroy(uptr fa);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern i64 mkdir(uptr path, i64 mode);
extern i64 unlink(uptr path);
extern uptr _NSGetEnviron();

#define DRV_MAXARG 64                 // argv of the spawned tool, NULL included
// MODE_755 (0755 in decimal) comes from backend_exe.mc, which already needs it
// to mark the executable it writes.

uptr cfg_file = 0;                    // path of mc.toml, as it will appear in errors
uptr drv_sdk_cache = 0;               // {sdk}, resolved at most once
i64  drv_linux = 0;                   // [target].os == "linux" (M16)

// the backend that writes the object for the target in effect. There is no
// direct-executable backend for Linux: `os = "linux"` always goes through
// [linker] (docs/build.md § Linux targets).
uptr drv_obj_backend() {
    if (drv_linux) return "elf-obj";
    return "macho";
}

// ---- small helpers ----
void drv_put(uptr b, uptr s) { buf_put(b, s, cstrlen(s)); }

// path written in the TOML -> path usable from the working directory
uptr drv_path(uptr rel) { return path_join(cfg_file, rel); }

// `what a -> b`, one line per step
void drv_step(uptr what, uptr a, uptr b) {
    out_str(1, what);
    out_str(1, " ");
    out_str(1, a);
    out_str(1, " -> ");
    out_str(1, b);
    out_str(1, "\n");
}

// creates every parent directory of `path` (the string is mutated and put back)
void drv_mkdirs(uptr path) {
    i64 i = 0;
    loop {
        i64 c = ld8(path + i);
        if (c == 0) break;
        if (c == '/' && i > 0) {
            st8(path + i, 0);
            mkdir(path, MODE_755);
            st8(path + i, '/');
        }
        i = i + 1;
    }
}

// 1 if `pat` appears anywhere in `s`
i64 drv_has(uptr s, uptr pat) {
    i64 pl = cstrlen(pat);
    i64 i = 0;
    loop {
        if (ld8(s + i) == 0) break;
        if (mem_eq(s + i, pat, pl)) return 1;
        i = i + 1;
    }
    return 0;
}

// every occurrence of `pat` in `s` replaced by `rep`
uptr drv_subst(uptr s, uptr pat, uptr rep) {
    i64 pl = cstrlen(pat);
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 i = 0;
    loop {
        if (ld8(s + i) == 0) break;
        if (mem_eq(s + i, pat, pl)) {
            drv_put(b, rep);
            i = i + pl;
            continue;
        }
        buf_put(b, s + i, 1);
        i = i + 1;
    }
    buf_u8(b, 0);
    return buf_p(b);
}

// ---- spawning ----
// runs `file` with the argv in `av` (NULL-terminated) and returns its exit code;
// 128+N when a signal killed it. stdin/stdout/stderr are inherited, which is how
// the tool's own diagnostics reach the user unchanged.
i64 drv_spawn(uptr file, uptr av, uptr fa) {
    u8 pid[8];
    st64(pid, 0);
    if (posix_spawnp(pid, file, fa, 0, av, ld64(_NSGetEnviron())) != 0)
        die2("cannot run", file);
    u8 st[8];
    st64(st, 0);
    if (waitpid(ld64(pid), st, 0) < 0) die2("waitpid failed", file);
    i64 s = ld32(st);
    if ((s & 127) != 0) return 128 + (s & 127);
    return (s >> 8) & 255;
}

// {sdk}: `xcrun --show-sdk-path`, run at most once and only if some argument
// actually uses it. stdout goes to `tmpf` via a spawn file action -- no shell,
// no pipe.
uptr drv_sdk(uptr tmpf) {
    if (drv_sdk_cache != 0) return drv_sdk_cache;
    u8 fa[8];
    st64(fa, 0);
    if (posix_spawn_file_actions_init(fa) != 0) die("posix_spawn_file_actions_init failed");
    drv_mkdirs(tmpf);
    if (posix_spawn_file_actions_addopen(fa, 1, tmpf, O_WRONLY | O_CREAT | O_TRUNC, MODE_644) != 0)
        die2("cannot create", tmpf);
    u8 av[3 * 8];
    st64(av + 0,  "xcrun");
    st64(av + 8,  "--show-sdk-path");
    st64(av + 16, 0);
    i64 rc = drv_spawn("xcrun", av, fa);
    posix_spawn_file_actions_destroy(fa);
    if (rc != 0) die("xcrun --show-sdk-path failed");
    i64 len = 0;
    uptr s = read_file(tmpf, &len);
    while (len > 0 && (ld8(s + len - 1) == '\n' || ld8(s + len - 1) == '\r')) { len = len - 1; }
    st8(s + len, 0);
    unlink(tmpf);
    drv_sdk_cache = s;
    return s;
}

// ---- [libs] / [externs] / [include] ----
// ordinal of the library named `name` in [libs]; dylib_add is idempotent, so
// asking twice gives the same ordinal
i64 drv_lib_ord(uptr name) {
    uptr key = tm_cat("libs.", name);
    uptr path = toml_get(key);
    if (path == 0) toml_err_key(key, "library not declared in [libs]");
    return dylib_add(path);
}

// [include].paths, [libs] and [externs] applied to the compilation that is about
// to happen. Walks the flat table in source order -- that is what fixes the
// ordinals: the first [libs] key gets 2, the next 3, and so on (1 is libSystem).
void drv_apply_config() {
    i64 n = toml_count("include.paths");
    i64 i = 0;
    while (i < n) {
        lex_add_include_path(tm_cat(drv_path(toml_get_array("include.paths", i)), "/"));
        i = i + 1;
    }
    i = 0;
    while (i < toml_entries()) {
        if (opt_val(toml_path_at(i), "libs.") != 0) dylib_add(toml_val_at(i));
        i = i + 1;
    }
    i = 0;
    while (i < toml_entries()) {
        uptr k = opt_val(toml_path_at(i), "externs.");
        if (k != 0) extern_lib_pattern_add(k, drv_lib_ord(toml_val_at(i)));
        i = i + 1;
    }
}

// ---- compiling in this process ----
// The same sequence as the single-file CLI in main.mc, with the config applied
// between lex_init and the parse. `cfg` says whether this is the entry (1) or
// the taught compiler (0) -- the compiler is built with the core's own rules,
// never with the project's [libs]/[externs].
void drv_compile(uptr src, uptr out, uptr bname, i64 cfg) {
    tok_init();
    lex_init(src);
    user_init();
    if (cfg) drv_apply_config();
    i64 unit = parse_unit();
    unit = run_passes(unit);
    unit = fold(unit);
    i64 bi = backend_find(bname);
    if (bi < 0) backend_die(bname);
    drv_mkdirs(out);
    unlink(out);                       // never rewrite a signed binary in place
    callp(backend_fn_at(bi), unit, out);
}

// ---- the taught compiler ----
// "../" for each level between the config's directory and [compiler].out's, so
// the generated file -- which lives next to the compiler, inside build/ -- can
// `#include` the modules by the paths written in the TOML.
uptr drv_updots(uptr p) {
    if (ld8(p) == '/') toml_err_key("compiler.out", "must be a relative path");
    i64 i = 0;
    loop {                             // `..` is checked on the RAW string: the
        i64 c = ld8(p + i);            // normalization below would absorb it
        if (c == 0) break;
        if (c == '.' && ld8(p + i + 1) == '.') toml_err_key("compiler.out", "must not contain ..");
        i = i + 1;
    }
    uptr q = path_norm(p);             // count levels on the SAME form drv_path
    u8 b[BUF_SIZE];                    // writes the file at, so "./build/x" and
    buf_init(b);                       // "build//x" are one level, not two
    i = 0;
    loop {
        i64 c = ld8(q + i);
        if (c == 0) break;
        if (c == '/') drv_put(b, "../");
        i = i + 1;
    }
    buf_u8(b, 0);
    return buf_p(b);
}

void drv_include(uptr b, uptr up, uptr rel) {
    drv_put(b, "#include \"");
    if (ld8(rel) != '/') drv_put(b, up);
    drv_put(b, rel);
    drv_put(b, "\"\n");
}

// writes the source of the taught compiler and returns its path. The file is
// generated, not checked in: it lives next to [compiler].out. `#include` is
// once-only, so a module that already pulls the core in (like
// examples/api/mc-api.mc) works either way.
//
// M15: with no [compiler].core the core comes from the BUNDLE, `#include
// <mc/core>` -- so a project needs no path into this repository to teach the
// compiler. [compiler].core is still accepted and still wins: that is how a
// project pins its own checkout of src/core.mc instead of the one the binary
// carries.
uptr drv_gen_compiler(uptr cout) {
    uptr up = drv_updots(cout);
    u8 b[BUF_SIZE];
    buf_init(b);
    drv_put(b, "// generated by `mc build` from ");
    drv_put(b, cfg_file);
    drv_put(b, "\n");
    uptr core = toml_get("compiler.core");
    if (core != 0) drv_include(b, up, core);
    else           drv_put(b, "#include <mc/core>\n");
    i64 n = toml_count("compiler.modules");
    if (n == 0) toml_err_key("compiler.modules", "missing key");
    i64 i = 0;
    while (i < n) {
        drv_include(b, up, toml_get_array("compiler.modules", i));
        i = i + 1;
    }
    uptr gen = tm_cat(drv_path(cout), ".mc");
    drv_mkdirs(gen);
    write_file(gen, b);
    return gen;
}

// posix_spawnp only searches PATH when the name has no '/': a compiler written
// as `mc-api` in the TOML has to be run as `./mc-api`
uptr drv_runnable(uptr p) {
    i64 i = 0;
    loop {
        i64 c = ld8(p + i);
        if (c == 0) break;
        if (c == '/') return p;
        i = i + 1;
    }
    return tm_cat("./", p);
}

// ---- linking ----
// {sysroot}: [sysroot].path, resolved against the config's directory like every
// other path in the file. M16 uses it for the musl crt objects and libc.a that
// scripts/sysroot-linux.sh copies out of Alpine.
uptr drv_sysroot() {
    uptr p = toml_get("sysroot.path");
    if (p == 0) toml_err_key("sysroot.path", "missing key");
    return drv_path(p);
}

// {out} {obj} {sysroot} {sdk} substituted anywhere inside an argument. {sdk} is
// lazy: it is what makes `xcrun --show-sdk-path` run, and only if some argument
// asks for it.
uptr drv_ph(uptr a, uptr obj, uptr out) {
    a = drv_subst(a, "{out}", out);
    a = drv_subst(a, "{obj}", obj);
    if (drv_has(a, "{sysroot}")) a = drv_subst(a, "{sysroot}", drv_sysroot());
    if (drv_has(a, "{sdk}")) a = drv_subst(a, "{sdk}", drv_sdk(tm_cat(out, ".sdk")));
    return a;
}

// [linker].args, argument by argument. {libs} is the one placeholder that has to
// be a WHOLE argument: it expands to one argument per [libs] entry, in the order
// the keys are written, each one going through the same substitution -- so a
// library can be written as "{sdk}/usr/lib/libsqlite3.tbd".
void drv_link(uptr obj, uptr out) {
    uptr cmd = toml_get("linker.cmd");
    u8 av[DRV_MAXARG * 8];
    i64 n = 0;
    st64(av + n * 8, cmd);
    n = n + 1;
    i64 na = toml_count("linker.args");
    i64 i = 0;
    while (i < na) {
        uptr a = toml_get_array("linker.args", i);
        i = i + 1;
        if (n + 2 >= DRV_MAXARG) die("too many arguments in [linker].args");
        if (str_eq(a, "{libs}")) {
            i64 k = 0;
            while (k < toml_entries()) {
                if (opt_val(toml_path_at(k), "libs.") != 0) {
                    if (n + 2 >= DRV_MAXARG) die("too many arguments in [linker].args");
                    st64(av + n * 8, drv_ph(toml_val_at(k), obj, out));
                    n = n + 1;
                }
                k = k + 1;
            }
            continue;
        }
        st64(av + n * 8, drv_ph(a, obj, out));
        n = n + 1;
    }
    st64(av + n * 8, 0);
    i64 rc = drv_spawn(cmd, av, 0);
    if (rc != 0) _exit(1);
}

// ---- the two halves of a build ----
void drv_entry(uptr entry, uptr out, uptr kind) {
    uptr src = drv_path(entry);
    uptr has_linker = toml_get("linker.cmd");
    if (str_eq(kind, "obj")) {
        drv_step("compile", entry, out);
        drv_compile(src, drv_path(out), drv_obj_backend(), 1);
        return;
    }
    if (has_linker == 0) {
        if (drv_linux) toml_err_key("target.os", "linux requires [linker]: there is no direct executable");
        drv_step("compile", entry, out);
        drv_compile(src, drv_path(out), "macho-exe", 1);
        return;
    }
    uptr obj = tm_cat(out, ".o");
    drv_step("compile", entry, obj);
    drv_compile(src, drv_path(obj), drv_obj_backend(), 1);
    drv_step("link", obj, out);
    drv_link(drv_path(obj), drv_path(out));
}

// builds the taught compiler and hands the entry over to it
i64 drv_teach(uptr cout, uptr dir) {
    uptr gen = drv_gen_compiler(cout);
    drv_step("compiler", tm_cat(cout, ".mc"), cout);
    drv_compile(gen, drv_path(cout), "macho-exe", 0);
    uptr comp = drv_runnable(drv_path(cout));
    u8 av[7 * 8];
    st64(av + 0,  comp);
    st64(av + 8,  "build");
    st64(av + 16, dir);
    st64(av + 24, "--config");
    st64(av + 32, cfg_file);
    st64(av + 40, "--entry-only");
    st64(av + 48, 0);
    if (drv_spawn(comp, av, 0) != 0) return 1;
    return 0;
}

// ---- CLI ----
void drv_usage() {
    out_str(2, "usage: mc build [DIR] [--config FILE]\n");
}

i64 drv_build(i64 argc, uptr argv) {
    uptr dir = 0;
    uptr cfg = 0;
    i64 entry_only = 0;
    i64 i = 2;                                 // argv[1] is "build"
    while (i < argc) {
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--config")) {
            if (i + 1 >= argc) die("--config requires an argument");
            i = i + 1;
            cfg = ld64(argv + i * 8);
        }
        else if (str_eq(a, "--entry-only")) entry_only = 1;
        else if (ld8(a) == '-')             { drv_usage(); return 1; }
        else if (dir == 0)                  dir = a;
        else                                die2("duplicate directory", a);
        i = i + 1;
    }
    if (dir == 0) dir = ".";
    if (cfg == 0) cfg = path_norm(tm_cat(dir, "/mc.toml"));
    cfg_file = cfg;
    toml_parse(cfg);

    uptr os = toml_get("target.os");
    drv_linux = 0;
    if (os != 0 && str_eq(os, "linux")) drv_linux = 1;
    else if (os != 0 && !str_eq(os, "macos"))
        toml_err_key("target.os", "only macos and linux (see docs/build.md)");
    uptr arch = toml_get("target.arch");
    if (arch != 0 && !str_eq(arch, "aarch64"))
        toml_err_key("target.arch", "only aarch64 (see docs/build.md)");

    uptr entry = toml_get("project.entry");
    if (entry == 0) toml_err_key("project.entry", "missing key");
    uptr out = toml_get("project.out");
    if (out == 0) toml_err_key("project.out", "missing key");
    uptr kind = toml_get("project.kind");
    if (kind == 0) kind = "exe";
    if (!str_eq(kind, "exe") && !str_eq(kind, "obj"))
        toml_err_key("project.kind", "must be exe or obj");

    if (!entry_only && toml_count("compiler.modules") != 0) {
        uptr cout = toml_get("compiler.out");
        if (cout == 0) {
            uptr name = toml_get("project.name");
            if (name == 0) toml_err_key("compiler.out", "missing key");
            cout = tm_cat("build/mc-", name);
        }
        return drv_teach(cout, dir);
    }
    drv_entry(entry, out, kind);
    return 0;
}
