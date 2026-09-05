// core.mc — the compiler without the extension point, as the SUM OF ITS PARTS.
//
// Since M41 the core is composable. Six parts, each a file of its own and each
// a bundled name a recreated compiler can include or omit:
//
//   <mc/core_min>       arena lz objmodel lex ast parse gen_resolve gen_walk
//                       hooks cli — the compiler that has no target
//   <mc/core_machines>  machine_arm64 machine_x86_64
//   <mc/core_writers>   sha256 macho backend_exe backend_elf backend_coff
//   <mc/core_build>     toml driver sysroots sysroot stubs limits
//   <mc/core_bundle>    bundle_data bundle — `#include <name>`
//   <mc/core_pkg>       pkg — `mc pkg`, `mc update` (M44)
//   <mc/core_sandbox>   sandbox — `mc sandbox run|exec|check` (M43)
//
// and then main.mc, which is the `main()` that calls each part's *_init and
// hands over to mc_main(). That is the design's load-bearing property: the full
// assembly is LITERALLY the parts, so there is no second list to drift.
// scripts/check-parts.sh compiles both spellings and `cmp`s the two objects.
//
// Exactly one thing is missing here: `void user_init()`. Whoever includes
// core.mc has to define it — it is what registers passes, backends, syntax,
// aliases, types, intrinsics and machines (M10, M12, M24). The default compiler
// is src/mc.mc: core.mc + src/user.mc, which in turn picks up the empty
// user_init from lib/user_default.mc. A taught compiler is its own file,
// outside src/:
//
//     #include "../../src/core.mc"
//     #include "oop.mc"
//     void user_init() { syntax("class", &oop_class); }
//
// A RECREATED compiler names the parts it wants instead of this file, and
// writes its own main(); see docs/guide/98-recreating-the-compiler.md and
// docs/surface.md § Tier 3.

#include "core_min.mc"
#include "core_machines.mc"
#include "core_writers.mc"
#include "core_build.mc"
#include "core_bundle.mc"
#include "core_pkg.mc"
#include "core_sandbox.mc"
#include "main.mc"
