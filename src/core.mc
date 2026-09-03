// core.mc — the compiler without the extension point: just the list of #include, in
// dependency order, exactly like stage0 compiles stage0/*.c against mc.h.
//
//   arena.mc     xalloc/buf_*/out_*/die/err_at/read_file/write_file and the shared
//                limits (MAXSECS, MAXPARAMS), the role of mc.h
//   macho.mc     sections, symbols, relocations and writing the MH_OBJECT
//   lex.mc       mutable token table and incremental lexer
//   ast.mc       nodes in a flat array in the arena + dump
//   parse.mc     recursive descent + table-driven Pratt + folding
//   gen_arm64.mc instruction buffer, AArch64 encoders and --dump-asm
//   sha256.mc    pure SHA-256, for the ad-hoc signature and the executable UUID
//   backend_exe.mc backend `macho-exe`: signed MH_EXECUTE, without `ld` (M11)
//   backend_elf.mc backend `elf-obj`: ELF64 ET_REL for Linux arm64 (M16)
//   hooks.mc     Tier 2/3: passes (pass), backends (backend), syntax (syntax)
//   lz.mc        LZ77 both ways, for the bundle and for `#embed ... lz` (M15)
//   toml.mc      the TOML subset mc.toml is written in (M14)
//   driver.mc    `mc build`: reads mc.toml and drives the whole build (M14)
//   bundle_data.mc GENERATED (tools/bundle.mc): lib/ and the core, LZ-compressed
//   bundle.mc    `#include <name>` served from that blob (M15)
//   main.mc      CLI
//
// macho.mc comes before lex.mc because parse.mc uses sec_new (via sec_make) and the
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
#include "macho.mc"
#include "lex.mc"
#include "ast.mc"
#include "parse.mc"
#include "gen_arm64.mc"
#include "sha256.mc"
#include "backend_exe.mc"
#include "backend_elf.mc"
#include "hooks.mc"
#include "toml.mc"
#include "driver.mc"
#include "bundle_data.mc"
#include "bundle.mc"
#include "main.mc"
