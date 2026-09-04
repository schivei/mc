// core_min.mc — the MINIMAL core: everything a compiler for any target needs,
// and nothing that names a target. Ten files, in dependency order:
//
//   arena.mc      xalloc/buf_*/out_*/die/err_at/read_file/write_file, the growable
//                 tables and the shared limits (MAXPARAMS), the role of mc.h
//   lz.mc         LZ77 both ways, for `#embed ... lz` (and, when the bundle part
//                 is there, for the bundle)
//   objmodel.mc   sections, symbols, relocations: the model every writer reads
//   lex.mc        mutable token table and incremental lexer
//   ast.mc        nodes in a flat array in the arena + dump
//   parse.mc      recursive descent + table-driven Pratt + folding
//   gen_resolve.mc name resolution and typing, in a side table (M17 step A)
//   gen_walk.mc   the target-independent walk: frames, depths, labels, calls,
//                 and the machine task table it drives
//   hooks.mc      every registry: passes, backends, machines, targets, syntax,
//                 types, intrinsics, subcommands
//   cli.mc        mc_main(): the flags, the dump modes and the pipeline
//
// objmodel.mc comes before lex.mc because parse.mc uses sec_new (via sec_make)
// and the R_* constants that defs_init registers; it is the same order
// src/astdump.mc has used since M6.
//
// What is NOT here: no object writer, no machine, no `mc build`, no bundle.
// A compiler built from this part alone parses, resolves and walks — and then
// has nowhere to send the result, which is why it must register at least one
// machine and one backend from user_init():
//
//     #include <mc/host>
//     #include <mc/core_min>
//     #include "machine_avr.mc"
//     #include "image_avr.mc"
//     i64 main(i64 argc, uptr argv, uptr envp) {
//         host_init(envp);
//         return mc_main(argc, argv, envp);
//     }
//     void user_init() {
//         machine_avr_init();
//         backend("avr-image", &backend_avr);
//         backend_default("avr-image");
//     }
//
// With no machine registered, mc_main says `no machine registered` before it
// lowers anything; with no backend and no target registry, it says
// `no backend: use --backend=NAME`.
//
// See docs/reference/bundle.md § The parts and
// docs/guide/98-recreating-the-compiler.md.

#include "arena.mc"
#include "lz.mc"
#include "objmodel.mc"
#include "lex.mc"
#include "ast.mc"
#include "parse.mc"
#include "gen_resolve.mc"
#include "gen_walk.mc"
#include "hooks.mc"
#include "cli.mc"
