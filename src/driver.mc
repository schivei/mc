// driver.mc — `mc build`: the project driver (M14, docs/specs/M14.md,
// docs/build.md).
//
//   mc build [DIR] [--config FILE] [--entry-only] [--compiler-only]
//            [--limits] [--fix-limits]
//   mc limits [DIR|FILE.mc]
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
// M21.5: `--compiler-only` is the first half alone. It builds the taught
// compiler, prints its path on stdout and stops -- no spawn, no entry. It is
// the flag a `test.sh` wants (it drives the taught compiler over its own test
// suite and never needs [project].entry) and the one the editor server needs.
// Without [compiler].modules it is an error, not a silent full build.
//
// M16: `[target].os` also takes "linux". That swaps the object backend for
// `elf-obj` (src/backend_elf.mc) and REQUIRES `[linker]` — there is no direct
// executable for Linux — and adds the `{sysroot}` placeholder, which is where
// the musl crt objects and libc.a come from. Everything else is unchanged,
// including the taught compiler, which is always built for the host.
//
// M17: which backend that is stopped being written here. `[target]` is looked
// up in the registry `target(os, arch, obj, exe)` fills (src/hooks.mc,
// registered in src/main.mc), so a new operating system or architecture is a
// registration and not an edit to this file.
//
// The spawn is not a detail: the compiler's tables (lexer, arena, AST, symbols)
// are global and are built once per process, so two compilations never fit in
// one run. `--entry-only` is the flag that says "you are the second half": it
// skips the [compiler] step and compiles the entry, reading the same TOML -- so
// [include]/[libs]/[externs] apply to the entry in either shape.
//
// Depends on arena.mc, on toml.mc, on lex.mc (tok_init/lex_init/path_join/
// path_norm/lex_add_include_path), on parse.mc (parse_unit/fold/dylib_add/
// extern_lib_pattern_add), on hooks.mc (user_init/run_passes/backend_find and
// the target registry) and on main.mc (opt_val). Nothing here is reachable from
// the single-file CLI.

#include "../lib/prelude.mc"

// M37: posix_spawnp/waitpid/mkdir/unlink, the environment and the O_* values
// this file uses are declared by the HOST layer (src/host_macos.mc,
// src/host_linux.mc), which every compiler entry point includes before the
// core. Nothing here names an operating system any more: `host_os()`,
// `host_arch()`, `host_environ()` and `host_has_sdk()` are the whole interface.
// See docs/build.md § Spawning tools and docs/guide/90-linux-host.md.

#define DRV_MAXARG 64                 // argv of the spawned tool, NULL included
// MODE_755 (0755 in decimal) comes from backend_exe.mc, which already needs it
// to mark the executable it writes.

uptr cfg_file = 0;                    // path of mc.toml, as it will appear in errors
uptr drv_sdk_cache = 0;               // {sdk}, resolved at most once
i64  drv_target = -1;                 // index in the target registry (hooks.mc)
uptr drv_os = 0;                      // [target].os, as the file wrote it
uptr drv_arch = 0;                    // [target].arch, likewise (M25: {sysroot})
uptr drv_stubs_cache = 0;             // {stubs}, written at most once (M25)
i64  drv_unit = 0;                    // the unit the last parse produced -- what
                                      // the stub writer reads its externs from
i64  drv_stub_mode = 0;               // `mc sysroot stub`: parse, write the
                                      // stubs, and neither compile nor link

// the backends that write for the target in effect. M17 replaced the whitelist
// this file used to carry -- an `i64 drv_linux` flag and two literal messages --
// with the registry in src/hooks.mc: `target(os, arch, obj, exe)`, registered by
// src/main.mc. A zero `exe` slot says the target has no direct executable and
// always goes through [linker], which is what Windows does -- Linux did too
// until M42 wrote `elf-exe` (docs/build.md § Linux targets).
//
// M39.5: the pair is NOT resolved when the TOML is read. drv_run keeps
// [target].os/.arch as the strings the file wrote, drv_entry asks for a ROLE,
// and drv_backend_for turns that role into a backend name inside drv_parse,
// right after user_init() -- so a target a module registered counts, and
// `mc build` reaches a bare-metal pair the running binary alone does not know
// (docs/specs/M39.md § Gaps, G1). The two diagnostics and the [linker] check
// are the ones this file has always printed, moved and not rewritten.
#define DRV_ROLE_OBJ 1                // the object backend of [target]
#define DRV_ROLE_EXE 2                // its direct-executable backend
#define DRV_ROLE_NONE 3               // no backend at all: check [target] and
                                      // stop (`mc sysroot stub`, below)
uptr drv_bname = 0;                   // what drv_compile writes with: a role
                                      // until the resolution below names it

// the (os, arch) pair against the registry, and nothing about backends. Split
// out of drv_backend_for so that `mc sysroot stub` -- which needs the target's
// os and arch and no backend whatsoever -- runs the SAME two checks, in the
// same place and with the same two messages, instead of walking on with an
// unvalidated [target] (docs/reference/sysroot.md § 7).
void drv_target_resolve() {
    if (!target_os_known(drv_os)) toml_err_key("target.os", target_os_list());
    drv_target = target_find(drv_os, drv_arch);
    if (drv_target < 0) toml_err_key("target.arch", target_arch_list(drv_os));
}

uptr drv_backend_for(i64 role) {
    drv_target_resolve();
    if (role == DRV_ROLE_NONE) return 0;
    // a zero slot is a REGISTRATION saying that role does not exist for this
    // target, and both are reachable from a module: `target(os, arch, 0, "x")`
    // is what a board with no separable object step registers (the image is
    // the artefact), and `target(os, arch, "x", 0)` is Linux. Neither may reach
    // backend_find(), which takes a name and would dereference the 0.
    if (role == DRV_ROLE_OBJ) {
        if (tgt_obj_at(drv_target) == 0)
            toml_err_key("target.os", tm_cat(tm_cat(drv_os, "/"),
                         tm_cat(drv_arch,
                                " has no object backend: use kind = \"exe\"")));
        return tgt_obj_at(drv_target);
    }
    if (tgt_exe_at(drv_target) == 0)
        toml_err_key("target.os", tm_cat(drv_os,
                     " requires [linker]: there is no direct executable"));
    return tgt_exe_at(drv_target);
}

// M23: 0 = plain build, 1 = --limits (report + verdict), 2 = --fix-limits
// (report + rewrite the [limits] section). `mc limits` is mode 1.
i64 drv_lim_mode = 0;
i64 drv_tol = 2500;                   // [limits].tolerance, in basis points

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
// M25: the same thing, but -1 instead of a diagnostic when the program is not
// on PATH at all. `mc sysroot fetch` tries curl and then wget, and "not
// installed" is a case it handles rather than a failure -- see
// sysroot_download (src/sysroot.mc).
//
// -1 means EXACTLY that, and nothing else. posix_spawnp returns the error
// number rather than setting errno, so ENOENT is the one value that says "no
// such program"; EACCES (a file that is there and not executable), ENOEXEC (a
// file that is there and not a program) and everything else are real failures,
// and turning them into -1 sent the caller looking for a second downloader, or
// printing `no downloader on this PATH` about a curl that is on the PATH. They
// stop the build here instead, with the tool and the number
// (docs/reference/diagnostics.md § 10).
//
// The Windows shim (lib/sys_windows_host.mc) answers in the same vocabulary:
// ENOENT when CreateProcessA could not find the program, another non-zero
// otherwise. See docs/reference/sysroot.md § 7.
#define ENOENT 2

i64 drv_spawn_ok(uptr file, uptr av, uptr fa) {
    u8 pid[8];
    st64(pid, 0);
    i64 e = posix_spawnp(pid, file, fa, 0, av, host_environ());
    if (e == ENOENT) return -1;
    if (e != 0)
        die2("cannot spawn", tm_cat(file, tm_cat(" (error ", tm_cat(tm_num_str(e), ")"))));
    u8 st[8];
    st64(st, 0);
    if (waitpid(ld64(pid), st, 0) < 0) die2("waitpid failed", file);
    i64 s = ld32(st);
    if ((s & 127) != 0) return 128 + (s & 127);
    return (s >> 8) & 255;
}

i64 drv_spawn(uptr file, uptr av, uptr fa) {
    u8 pid[8];
    st64(pid, 0);
    if (posix_spawnp(pid, file, fa, 0, av, host_environ()) != 0)
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
    // M37: `xcrun` is a macOS program. On any other host {sdk} is a config
    // error, not a spawn that fails halfway through a build.
    if (!host_has_sdk())
        toml_err_key("linker.args", "{sdk} needs xcrun: it exists only on macos");
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
// where the remembered usage lives, relative to the config's directory
uptr drv_usage_file() { return drv_path("build/.mc-usage.toml"); }

// `label` is the source as the TOML names it (`main.mc`, `build/mc-api.mc`):
// the key of this compilation's section in build/.mc-usage.toml, stable no
// matter which directory `mc build` was run from.
// M25: the front half on its own, because `mc sysroot stub` needs exactly this
// much -- the program parsed, its `extern`s and their libraries known -- and
// nothing that follows. It also leaves the unit in `drv_unit`, which is what
// {stubs} reads at link time: the compile and the link happen in one process,
// so the externs are still in memory when the link line is assembled.
i64 drv_parse(uptr src, i64 cfg, uptr label) {
    lim_plan(src, drv_tol, drv_usage_file(), label);   // M23: before any table exists
    tok_init();
    lex_init(src);
    user_init();
    // M39.5: HERE. After user_init(), so a [target] a module registered is in
    // the registry; before parse_unit(), so an unknown pair is still reported
    // ahead of anything the source itself might be wrong about.
    if (drv_bname == DRV_ROLE_OBJ || drv_bname == DRV_ROLE_EXE
        || drv_bname == DRV_ROLE_NONE)
        drv_bname = drv_backend_for(drv_bname);
    if (cfg) drv_apply_config();
    i64 unit = parse_unit();
    unit = run_passes(unit);
    unit = fold(unit);
    drv_unit = unit;
    return unit;
}

// `bname` is a backend name, or one of the two DRV_ROLE_* markers drv_entry
// passes when the name has to come out of [target] (M39.5).
void drv_compile(uptr src, uptr out, uptr bname, i64 cfg, uptr label) {
    drv_bname = bname;
    i64 unit = drv_parse(src, cfg, label);
    i64 bi = backend_find(drv_bname);
    if (bi < 0) backend_die(drv_bname);
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
    // M37: the host layer, before the core and whatever the core came from.
    // `<mc/host>` is not a file: it is the host file of the compiler running
    // right now (src/main.mc, host_bundle_open), so this same generated source
    // teaches a macOS compiler on macOS and a Linux one on Linux.
    drv_put(b, "#include <mc/host>\n");
    // M41: a value that starts with `<` is a BUNDLED name, not a path -- it is
    // emitted verbatim, so a project can ask for a part instead of the whole
    // core: `core = "<mc/core_min>"` (docs/build.md § [compiler]).
    uptr core = toml_get("compiler.core");
    if (core != 0 && ld8(core) == '<') {
        drv_put(b, "#include ");
        drv_put(b, core);
        drv_put(b, "\n");
    }
    else if (core != 0) drv_include(b, up, core);
    else                drv_put(b, "#include <mc/core>\n");
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
// {sysroot}: where the musl crt objects and libc.a (or the Windows import
// library, or the macOS SDK) come from.
// M25: this used to be `toml_get` plus a path join, with no existence check --
// a wrong directory was reported by the linker, in the linker's words, halfway
// through a build. It is now one call into the resolution chain
// (src/sysroot.mc): [sysroot].path checked against the target's marker files,
// then the running system when host == target, then the cache
// (--sysroot-dir / [sysroot].cache / ~/.mc/sysroots), then the message and exit
// 2. `mc build` still never downloads: only `mc sysroot fetch --yes` does.
uptr drv_sysroot() {
    return sysroot_for(drv_os, drv_arch);
}

// everything of `p` before its last '/', or "." when it has none
uptr drv_dirname(uptr p) {
    i64 last = -1;
    i64 i = 0;
    loop {
        i64 c = ld8(p + i);
        if (c == 0) break;
        if (c == '/') last = i;
        i = i + 1;
    }
    if (last < 0) return ".";
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, p, last);
    buf_u8(b, 0);
    return buf_p(b);
}

// {stubs}: the directory holding one synthesized import file per library the
// program uses -- a TBD v4 `.tbd` on macOS, a `.def` plus the `.lib`
// llvm-dlltool builds from it on Windows (src/stubs.mc). Written from the
// program's own `extern`s, at most once per build, and only because some
// [linker].args value asked for it -- the same laziness {sdk} has.
//
// It sits beside the output, `<dirname of [project].out>/stubs`, which for the
// usual `out = "build/app"` is `build/stubs`.
uptr drv_stubs() {
    if (drv_stubs_cache != 0) return drv_stubs_cache;
    uptr out = toml_get("project.out");
    if (out == 0) toml_err_key("project.out", "missing key");
    uptr d = drv_path(tm_cat(drv_dirname(out), "/stubs"));
    drv_mkdirs(tm_cat(d, "/x"));
    i64 n = stubs_write(drv_unit, d, drv_os, drv_arch);
    out_str(1, "stubs ");
    out_num(1, n);
    out_str(1, " -> ");
    out_str(1, d);
    out_str(1, "\n");
    drv_stubs_cache = d;
    return d;
}

// {out} {obj} {sysroot} {sdk} {stubs} substituted anywhere inside an argument.
// {sdk} is lazy: it is what makes `xcrun --show-sdk-path` run, and only if some
// argument asks for it. {stubs} is lazy in the same way, and for the same
// reason: it writes files.
uptr drv_ph(uptr a, uptr obj, uptr out) {
    a = drv_subst(a, "{out}", out);
    a = drv_subst(a, "{obj}", obj);
    if (drv_has(a, "{sysroot}")) a = drv_subst(a, "{sysroot}", drv_sysroot());
    if (drv_has(a, "{sdk}")) a = drv_subst(a, "{sdk}", drv_sdk(tm_cat(out, ".sdk")));
    if (drv_has(a, "{stubs}")) a = drv_subst(a, "{stubs}", drv_stubs());
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
    // M25: `mc sysroot stub` is the front half of a build and no more -- parse
    // the entry, write one stub per library it uses, stop. No object, no link,
    // and no [linker] required.
    if (drv_stub_mode) {
        // M39.5: the role marker is what makes drv_parse resolve [target] after
        // user_init(), the same way a compiling build does. Without it this
        // path reached the stub writer with a pair nobody had checked, and a
        // foreign [target].os came out as `no stub writer for: haiku: ...`
        // instead of the positioned message the registry builds. DRV_ROLE_NONE
        // and not DRV_ROLE_OBJ: writing a .tbd/.def needs the os and the arch,
        // never a backend, so a target registered with no object backend must
        // not be refused here.
        drv_bname = DRV_ROLE_NONE;
        drv_parse(src, 1, entry);
        drv_stubs();
        return;
    }
    if (str_eq(kind, "obj")) {
        drv_step("compile", entry, out);
        drv_compile(src, drv_path(out), DRV_ROLE_OBJ, 1, entry);
        return;
    }
    if (has_linker == 0) {
        drv_step("compile", entry, out);
        drv_compile(src, drv_path(out), DRV_ROLE_EXE, 1, entry);
        return;
    }
    uptr obj = tm_cat(out, ".o");
    drv_step("compile", entry, obj);
    drv_compile(src, drv_path(obj), DRV_ROLE_OBJ, 1, entry);
    drv_step("link", obj, out);
    drv_link(drv_path(obj), drv_path(out));
}

// builds the taught compiler and hands the entry over to it. Under --limits the
// TWO compilations each report their own tables, the compiler's first: the
// parent's is in this process, the entry's in the child, which gets the same
// flag. The worst of the two verdicts is what comes back.
i64 drv_teach(uptr cout, uptr dir, i64 compiler_only) {
    uptr gen = drv_gen_compiler(cout);
    // M38: [compiler].out names a program the driver LINKS and then SPAWNS, so
    // it is the one place `mc` has to know what an executable is called on the
    // host it is running on -- nothing on macOS and Linux, ".exe" on Windows
    // (src/host_windows.mc, Decision 4). The generated source keeps the bare
    // name: `<out>.mc` is a source file on every host.
    uptr cbin = tm_cat(cout, host_exe_suffix());
    drv_step("compiler", tm_cat(cout, ".mc"), cbin);
    // M37: the taught compiler is a program for the HOST, never for [target] --
    // it has to run here, right after it is written. Which backend that is
    // comes from the registry, looked up with the host's own pair: `macho-exe`
    // on macos and, since M42, `elf-exe` / `elf-exe-x86_64` on linux -- one
    // step in both cases. A host with no direct executable (windows) is the
    // object backend plus [linker], the same linker the entry uses.
    i64 ht = target_find(host_os(), host_arch());
    if (ht < 0) die2("the host is not a registered target", host_os());
    if (tgt_exe_at(ht) != 0) {
        drv_compile(gen, drv_path(cbin), tgt_exe_at(ht), 0, tm_cat(cout, ".mc"));
    } else {
        if (toml_get("linker.cmd") == 0)
            toml_err_key("linker.cmd",
                         "a taught compiler on this host needs [linker]: there is no direct executable");
        uptr cobj = tm_cat(cout, ".o");
        drv_compile(gen, drv_path(cobj), tgt_obj_at(ht), 0, tm_cat(cout, ".mc"));
        drv_step("link", cobj, cbin);
        drv_link(drv_path(cobj), drv_path(cbin));
    }
    i64 rc = drv_finish(tm_cat(cout, ".mc"));
    // M21.5: --compiler-only stops here and prints the path of the binary it
    // just wrote. A test.sh that runs the taught compiler itself, and the LSP,
    // need the compiler and not the entry; without the flag they had to build
    // the entry too, just to throw it away.
    if (compiler_only) {
        out_str(1, drv_path(cbin));
        out_str(1, "\n");
        return rc;
    }
    uptr comp = drv_runnable(drv_path(cbin));
    u8 av[8 * 8];
    st64(av + 0,  comp);
    st64(av + 8,  "build");
    st64(av + 16, dir);
    st64(av + 24, "--config");
    st64(av + 32, cfg_file);
    st64(av + 40, "--entry-only");
    i64 n = 6;
    if (drv_lim_mode == 1) { st64(av + 48, "--limits"); n = 7; }
    if (drv_lim_mode == 2) { st64(av + 48, "--fix-limits"); n = 7; }
    st64(av + n * 8, 0);
    i64 crc = drv_spawn(comp, av, 0);
    if (crc != 0 && crc != 3) return 1;
    if (crc > rc) rc = crc;
    return rc;
}

// ---- M23: what every build ends with ----
// The usage file is written on every `mc build`, so the next one pre-sizes from
// it; the report and the verdict only come out under --limits/--fix-limits.
i64 drv_finish(uptr what) {
    lim_write_usage(drv_usage_file(), what);
    if (drv_lim_mode == 0) return 0;
    lim_report(what);
    if (drv_lim_mode == 2 && lim_fix(cfg_file)) return 0;
    return lim_exit_code();
}

// ---- CLI ----
// M41: the text is not written here any more -- each subcommand carries its own
// usage string in the registration src/core_build.mc makes, and this prints
// them all, in registration order. Same four lines, byte for byte; the
// difference is that a compiler without one of them does not advertise it.
void drv_usage() { subcommand_usage(); }

// everything after the flags: one shape for `mc build` and for `mc limits`
i64 drv_run(uptr dir, uptr cfg, i64 entry_only, i64 compiler_only) {
    if (dir == 0) dir = ".";
    if (cfg == 0) cfg = path_norm(tm_cat(dir, "/mc.toml"));
    cfg_file = cfg;
    toml_parse(cfg);
    drv_tol = toml_bp("limits.tolerance", 2500, 0, 10000,
                      "tolerance must be between 0 and 1");

    // M17/M33: the target comes out of the registry, never out of a list
    // written here. The two messages are built from the same table, so they
    // name what is actually registered -- including a target a module added.
    // M37: with no [target] the target IS the host. On macOS that is exactly
    // the macos/aarch64 this used to hardcode; on a Linux host it is that
    // host's own pair, which is what makes a config with no [target] portable.
    // M39.5: only the STRINGS are read here. The registry lookup waits for
    // drv_backend_for, after user_init() -- this process may be the untaught
    // parent of a compiler that registers the pair itself.
    uptr os = toml_get("target.os");
    if (os == 0) os = host_os();
    uptr arch = toml_get("target.arch");
    if (arch == 0) arch = host_arch();
    drv_os = os;
    drv_arch = arch;
    // M42: the two names a dynamic ELF executable needs and no object does.
    // They are per-libc, not per-target, so they are keys and not constants:
    // the writer's default is musl (`libc.so`, `/lib/ld-musl-<arch>.so.1`) and
    // glibc is `interp = "/lib/ld-linux-aarch64.so.1"` (or
    // "/lib64/ld-linux-x86-64.so.2") plus `libc = "libc.so.6"`. The globals
    // live in src/objmodel.mc so that this file names no writer
    // (docs/reference/toml.md § [target]).
    dyn_interp = toml_get("target.interp");
    dyn_libc = toml_get("target.libc");

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
        return drv_teach(cout, dir, compiler_only);
    }
    if (compiler_only) toml_err_key("compiler.modules", "missing key");
    drv_entry(entry, out, kind);
    return drv_finish(entry);
}

i64 drv_build(i64 argc, uptr argv) {
    uptr dir = 0;
    uptr cfg = 0;
    i64 entry_only = 0;
    i64 compiler_only = 0;
    i64 i = 2;                                 // argv[1] is "build"
    while (i < argc) {
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--config")) {
            if (i + 1 >= argc) die("--config requires an argument");
            i = i + 1;
            cfg = ld64(argv + i * 8);
        }
        else if (str_eq(a, "--sysroot-dir")) {
            // M25: the sysroot for THIS target, as a directory, overriding both
            // [sysroot].cache and ~/.mc/sysroots. CI passes it so that no job
            // depends on HOME (docs/reference/sysroot.md).
            if (i + 1 >= argc) die("--sysroot-dir requires an argument");
            i = i + 1;
            sr_dir_opt = ld64(argv + i * 8);
        }
        else if (str_eq(a, "--entry-only"))    entry_only = 1;
        else if (str_eq(a, "--compiler-only")) compiler_only = 1;
        else if (str_eq(a, "--limits"))        drv_lim_mode = 1;
        else if (str_eq(a, "--fix-limits"))    drv_lim_mode = 2;
        else if (ld8(a) == '-')               { drv_usage(); return 1; }
        else if (dir == 0)                    dir = a;
        else                                  die2("duplicate directory", a);
        i = i + 1;
    }
    if (entry_only && compiler_only) die("--entry-only and --compiler-only are exclusive");
    return drv_run(dir, cfg, entry_only, compiler_only);
}

// 1 if the path ends in `.mc`: `mc limits` takes either a project directory or
// one source file, and that is how it tells them apart
i64 drv_is_source(uptr p) {
    i64 n = cstrlen(p);
    if (n < 3) return 0;
    return ld8(p + n - 3) == '.' && ld8(p + n - 2) == 'm' && ld8(p + n - 1) == 'c';
}

// mc limits [DIR|FILE.mc] — the build plus the report, nothing written when the
// argument is a single file (the object is not the point, the tables are).
i64 drv_limits(i64 argc, uptr argv) {
    uptr path = 0;
    uptr cfg = 0;
    i64 i = 2;                                 // argv[1] is "limits"
    while (i < argc) {
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--config")) {
            if (i + 1 >= argc) die("--config requires an argument");
            i = i + 1;
            cfg = ld64(argv + i * 8);
        }
        else if (ld8(a) == '-')  { drv_usage(); return 1; }
        else if (path == 0)      path = a;
        else                     die2("duplicate directory", a);
        i = i + 1;
    }
    drv_lim_mode = 1;
    if (path != 0 && drv_is_source(path)) {
        lim_compile_file(path);
        lim_report(path);
        return lim_exit_code();
    }
    return drv_run(path, cfg, 0, 0);
}
