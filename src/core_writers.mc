// core_writers.mc — the object writers, and the (os, arch) pairs they serve.
//
//   sha256.mc       pure SHA-256, for the ad-hoc signature and the UUID (M11)
//   macho.mc        the arm64 MH_OBJECT writer
//   backend_exe.mc  `macho-exe`: a signed MH_EXECUTE, without `ld` (M11)
//   backend_elf.mc  `elf-obj` / `elf-obj-x86_64`: ELF64 ET_REL (M16/M17)
//   backend_elf_exe.mc `elf-exe` / `elf-exe-x86_64`: a dynamic ELF64
//                   ET_EXEC, written with no linker and no sysroot (M42)
//   backend_coff.mc `coff-obj-arm64` / `coff-obj-x86_64`: COFF (M19/M20)
//
// mc_writers_init() is the six backend() and the five target() calls that used
// to sit at the top of main(). They are data: src/driver.mc reads the target
// registry and nothing else, and `--backend=NAME` reads the backend registry.
// A compiler that writes one format of its own registers one backend from
// user_init() and leaves this part out; it then names it with
// backend_default() or is told with --backend=.

#include "sha256.mc"
#include "macho.mc"
#include "backend_exe.mc"
#include "backend_elf.mc"
#include "backend_elf_exe.mc"
#include "backend_coff.mc"

// built-in backend `macho`: the two halves of gen plus writing the MH_OBJECT.
// It lived in src/main.mc until M41, and it is HERE and not in src/macho.mc
// because it is not part of the format: it calls gen_lower/gen_encode_all,
// which are <mc/core_min>'s, and src/macho.mc has to stay includable on its own
// (src/m0.mc builds the object model and the writer with no front end at all).
// The part that registers a backend is the part that defines it.
//
// M37: `machine_use` first, like every other backend since M17 -- a Mach-O
// object here is always arm64, and the machine that is current when the backend
// is called is the HOST's, which on a linux/x86_64 host is not the same thing.
void backend_macho(i64 unit, uptr out) {
    machine_use("arm64");
    gen_lower(unit);
    gen_encode_all();
    macho_write(out);
}

void mc_writers_init() {
    backend("macho", &backend_macho);           // the built-ins, always registered
    backend("macho-exe", &backend_exe);
    backend("elf-obj", &backend_elf);
    backend("elf-obj-x86_64", &backend_elf_x86);
    backend("elf-exe", &backend_elf_exe);
    backend("elf-exe-x86_64", &backend_elf_exe_x86);
    backend("coff-obj-arm64", &backend_coff);
    backend("coff-obj-x86_64", &backend_coff_x86);
    // M17/M33: the (os, arch) pairs `mc build` accepts, with the backend each
    // one writes objects and direct executables with. `0` as the executable
    // backend says the target has none and always goes through [linker] --
    // which is what Windows still does. M42 filled the two Linux slots: a
    // dynamic ELF executable needs no linker and no sysroot, only names.
    // src/driver.mc reads nothing but this table.
    target("macos", "aarch64", "macho", "macho-exe");
    target("linux", "aarch64", "elf-obj", "elf-exe");
    target("linux", "x86_64", "elf-obj-x86_64", "elf-exe-x86_64");
    target("windows", "aarch64", "coff-obj-arm64", 0);
    target("windows", "x86_64", "coff-obj-x86_64", 0);
}
