// core.mc — the compiler without the extension point: just the list of #include, in
// dependency order, exactly like stage0 compiles stage0/*.c against mc.h.
//
//   arena.mc     xalloc/buf_*/out_*/die/err_at/read_file/write_file and the shared
//                limits (MAXSECS, MAXPARAMS), the role of mc.h
//   objmodel.mc  sections, symbols and relocations: the model every writer reads
//   macho.mc     writing the arm64 MH_OBJECT, and the `macho` backend
//   lex.mc       mutable token table and incremental lexer
//   ast.mc       nodes in a flat array in the arena + dump
//   parse.mc     recursive descent + table-driven Pratt + folding
//   gen_resolve.mc name resolution and typing, in a side table (M17 step A)
//   gen_walk.mc  the target-independent walk: frames, depths, labels, calls
//   machine_arm64.mc the AArch64 machine behind the walker's task table
//   machine_x86_64.mc the x86-64 machine (SysV), for linux/x86_64 (M17 step B)
//   sha256.mc    pure SHA-256, for the ad-hoc signature and the executable UUID
//   backend_exe.mc backend `macho-exe`: signed MH_EXECUTE, without `ld` (M11)
//   backend_elf.mc backends `elf-obj` / `elf-obj-x86_64`: ELF64 ET_REL (M16/M17)
//   backend_coff.mc backend `coff-obj-arm64`: a COFF object for Windows on ARM (M19)
//   hooks.mc     Tier 2/3: passes (pass), backends (backend), syntax (syntax)
//   lz.mc        LZ77 both ways, for the bundle and for `#embed ... lz` (M15)
//   toml.mc      the TOML subset mc.toml is written in (M14)
//   driver.mc    `mc build`: reads mc.toml and drives the whole build (M14)
//   sysroots.mc  the pinned list of downloadable sysroots (M25)
//   sysroot.mc   where a cross link finds its files, and `mc sysroot` (M25)
//   stubs.mc     .tbd and .def stubs written from the program (M25)
//   bundle_data.mc GENERATED (tools/bundle.mc): lib/ and the core, LZ-compressed
//   bundle.mc    `#include <name>` served from that blob (M15)
//   limits.mc    the estimate, the reserve and `mc limits` (M23)
//   cli.mc       mc_main(): the CLI, the dump modes and the pipeline
//   main.mc      main(): which parts this compiler is made of
//
// objmodel.mc comes before lex.mc because parse.mc uses sec_new (via sec_make) and the
// R_* constants that defs_init registers; it is the same order src/astdump.mc
// already used in slice 3.
//
// Exactly one thing is missing here: `void user_init()`. Whoever includes core.mc has
// to define it — it is what registers passes, backends, syntax and aliases (M10,
// M12). The default compiler is src/mc.mc: core.mc + src/user.mc, which in turn
// picks up the empty user_init from lib/user_default.mc. A taught compiler is its
// own file, outside src/:
//
//     #include "../../src/core.mc"
//     #include "oop.mc"
//     void user_init() { syntax("class", &oop_class); }
//
// See docs/surface.md § Tier 3.

#include "arena.mc"
#include "lz.mc"
#include "objmodel.mc"
#include "macho.mc"
#include "lex.mc"
#include "ast.mc"
#include "parse.mc"
#include "gen_resolve.mc"
#include "gen_walk.mc"
#include "machine_arm64.mc"
#include "machine_x86_64.mc"
#include "sha256.mc"
#include "backend_exe.mc"
#include "backend_elf.mc"
#include "backend_coff.mc"
#include "hooks.mc"
#include "toml.mc"
#include "driver.mc"
#include "sysroots.mc"
#include "sysroot.mc"
#include "stubs.mc"
#include "bundle_data.mc"
#include "bundle.mc"
#include "limits.mc"
#include "cli.mc"
#include "main.mc"
