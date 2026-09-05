// stubs.mc -- the stub writers (M25, docs/specs/M25.md § 4,
// docs/reference/sysroot.md § 9).
//
// A link needs two things from a library: its NAME and the list of symbols it
// exports. Neither is code, and neither is anything `mc` has to download --
// which is what makes both an Apple `.tbd` and a Windows `.def` writable from
// the program itself. `mc` already knows, at the moment the link line is being
// assembled, every symbol the program declared `extern` and which library each
// one belongs to (`extern_lib_find`, src/parse.mc, fed by `#dylib` and by
// [libs]/[externs]). This file turns that into files a linker accepts:
//
//   macos    build/stubs/<lib>.tbd -- a TBD v4 text file per library, listing
//            exactly the symbols this program asks for. `dyld_stub_binder` is
//            added unconditionally to the libSystem one: it is what `-lSystem`
//            really contributes to a lazily-bound image, and no program
//            declares it.
//   windows  build/stubs/<lib>.def, and then `llvm-dlltool` over it to make
//            <lib>.lib -- the exact mirror, and the same thing
//            scripts/sysroot-windows.sh does by hand for kernel32.
//   linux    nothing: a static `libc.a` is code, not a name list. That is what
//            `mc sysroot fetch linux-<arch>` is for.
//
// Nothing here redistributes anything: a symbol NAME is not SDK content, and
// the files this writes carry no code at all.
//
// The macOS road matters only for `.o` + `ld`. The built-in `macho-exe`
// backend (`--exe`) binds dylibs by ordinal and signs the file itself: it needs
// no SDK, no linker and no stub (docs/reference/sysroot.md § 6).
//
// Depends on ast.mc (nd_kind/nd_name/nd_next), on parse.mc (extern_lib_find,
// dylib_count, dylib_path), on toml.mc (tm_cat) and on driver.mc (drv_spawn,
// drv_put). It reads the unit the parser returned and writes files; it does not
// touch the code generator, and it runs whether or not anything was lowered.

#include "../lib/prelude.mc"

// ---- naming ----
// last path component, minus a trailing .dylib/.tbd/.dll/.lib -- so
// "/usr/lib/libsqlite3.dylib" is "libsqlite3" and a bare "user32" stays
// "user32"
uptr stub_base(uptr p) {
    uptr b = fetch_basename(p);
    i64 n = cstrlen(b);
    if (n > 6 && mem_eq(b + n - 6, ".dylib", 6)) n = n - 6;
    else if (n > 4 && mem_eq(b + n - 4, ".tbd", 4)) n = n - 4;
    else if (n > 4 && mem_eq(b + n - 4, ".dll", 4)) n = n - 4;
    else if (n > 4 && mem_eq(b + n - 4, ".lib", 4)) n = n - 4;
    u8 t[BUF_SIZE];
    buf_init(t);
    buf_put(t, b, n);
    buf_u8(t, 0);
    return buf_p(t);
}

// the file name stem for a dylib ordinal. Ordinal 1 is the system default:
// libSystem on macOS, kernel32 on Windows -- the library every extern that no
// `#dylib` and no [externs] pattern claims belongs to on that system.
uptr stub_lib_name(i64 ord, uptr os) {
    if (ord == 1) {
        if (str_eq(os, "windows")) return "kernel32";
        return "libSystem";
    }
    return stub_base(dylib_path(ord - 2));
}

// what the `.tbd` records as the library's install name -- the path a program
// linked against it will ask dyld for at run time
uptr stub_install_name(i64 ord) {
    if (ord == 1) return "/usr/lib/libSystem.B.dylib";
    return dylib_path(ord - 2);
}

// the DLL the `.def` names. A [libs] value may be written with or without the
// extension; the import library records the name with it.
uptr stub_dll_name(i64 ord, uptr os) {
    return tm_cat(stub_lib_name(ord, os), ".dll");
}

// "arm64" / "x86_64" -- the architecture as a TBD target spells it
uptr stub_tbd_arch(uptr arch) {
    if (str_eq(arch, "aarch64")) return "arm64";
    return arch;
}

// llvm-dlltool's -m, the same values scripts/sysroot-windows.sh passes
uptr stub_dlltool_machine(uptr arch) {
    if (str_eq(arch, "aarch64")) return "arm64";
    return "i386:x86-64";
}

// ---- the externs of one library ----
// 1 when the extern `name` was already emitted for this library: two `extern`
// declarations of one name (a header included twice) must not become two
// symbols in the list.
i64 stub_seen(i64 unit, i64 upto, uptr name) {
    i64 n = unit;
    loop {
        if (n == 0 || n == upto) return 0;
        if (nd_kind(n) == N_EXTERN && str_eq(nd_name(n), name)) return 1;
        n = nd_next(n);
    }
}

// how many externs belong to `ord`; with `b` non-zero, each one is also
// appended to the buffer, prefixed with `pfx` and separated by `sep`
i64 stub_symbols(uptr b, i64 unit, i64 ord, uptr pfx, uptr sep) {
    i64 count = 0;
    i64 n = unit;
    loop {
        if (n == 0) break;
        if (nd_kind(n) == N_EXTERN) {
            uptr name = nd_name(n);
            if (extern_lib_find(name) == ord && !stub_seen(unit, n, name)) {
                if (b != 0) {
                    if (count > 0) drv_put(b, sep);
                    drv_put(b, pfx);
                    drv_put(b, name);
                }
                count = count + 1;
            }
        }
        n = nd_next(n);
    }
    return count;
}

// ---- macOS: TBD v4 ----
// The shape `ld` and `ld64.lld` read, and nothing more: no re-exports, no
// umbrella, no objc classes, no frameworks (docs/specs/M25.md § Out of scope).
void stub_tbd(uptr dir, i64 unit, i64 ord, uptr arch) {
    uptr tgt = tm_cat(stub_tbd_arch(arch), "-macos");
    u8 b[BUF_SIZE];
    buf_init(b);
    drv_put(b, "--- !tapi-tbd\ntbd-version: 4\ntargets: [ ");
    drv_put(b, tgt);
    drv_put(b, " ]\ninstall-name: '");
    drv_put(b, stub_install_name(ord));
    drv_put(b, "'\ncurrent-version: 1.0\nexports:\n  - targets: [ ");
    drv_put(b, tgt);
    drv_put(b, " ]\n    symbols: [ ");
    i64 n = stub_symbols(b, unit, ord, "_", ", ");
    // dyld_stub_binder is not one of the program's externs and has to be there:
    // it is what -lSystem really contributes to a lazily-bound image
    if (ord == 1) {
        if (n > 0) drv_put(b, ", ");
        drv_put(b, "dyld_stub_binder");
    }
    drv_put(b, " ]\n...\n");
    write_file(tm_cat(tm_cat(dir, "/"), tm_cat(stub_lib_name(ord, "macos"), ".tbd")), b);
}

// ---- Windows: .def, then llvm-dlltool ----
// COFF symbols are undecorated on arm64 and on x64 alike, so the names go in as
// the program wrote them. A DATA export would need a `DATA` keyword this
// synthesizer cannot infer from a declaration -- that is the documented gap,
// and the reason `mc sysroot fetch windows-<arch>` exists.
void stub_def(uptr dir, i64 unit, i64 ord, uptr arch) {
    uptr stem = stub_lib_name(ord, "windows");
    uptr def = tm_cat(tm_cat(dir, "/"), tm_cat(stem, ".def"));
    uptr lib = tm_cat(tm_cat(dir, "/"), tm_cat(stem, ".lib"));
    u8 b[BUF_SIZE];
    buf_init(b);
    drv_put(b, "LIBRARY ");
    drv_put(b, stub_dll_name(ord, "windows"));
    drv_put(b, "\nEXPORTS\n");
    stub_symbols(b, unit, ord, "", "\n");
    drv_put(b, "\n");
    write_file(def, b);
    u8 av[10 * 8];
    st64(av + 0, "llvm-dlltool");
    st64(av + 8, "-m");
    st64(av + 16, stub_dlltool_machine(arch));
    st64(av + 24, "-d");
    st64(av + 32, def);
    st64(av + 40, "-D");
    st64(av + 48, stub_dll_name(ord, "windows"));
    st64(av + 56, "-l");
    st64(av + 64, lib);
    st64(av + 72, 0);
    i64 rc = drv_spawn_ok("llvm-dlltool", av, 0);
    if (rc < 0) die2("cannot run llvm-dlltool for", def);
    if (rc != 0) die2("llvm-dlltool failed for", def);
}

// ---- the entry point ----
// One file per library the program actually uses. `dir` is created by the
// caller. Returns how many libraries were written.
i64 stubs_write(i64 unit, uptr dir, uptr os, uptr arch) {
    if (!str_eq(os, "macos") && !str_eq(os, "windows"))
        die2("no stub writer for", tm_cat(os, ": a static libc is code, not a name list"));
    i64 written = 0;
    i64 ord = 1;
    i64 last = dylib_count() + 1;
    loop {
        if (ord > last) break;
        i64 n = stub_symbols(0, unit, ord, "", "");
        // ordinal 1 is written even with no externs of its own: on macOS it
        // still carries dyld_stub_binder, which every image needs
        if (n > 0 || (ord == 1 && str_eq(os, "macos"))) {
            if (str_eq(os, "macos")) stub_tbd(dir, unit, ord, arch);
            else                     stub_def(dir, unit, ord, arch);
            written = written + 1;
        }
        ord = ord + 1;
    }
    return written;
}
