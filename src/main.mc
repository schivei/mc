// main.mc — the entry point, and the only file that names every part.
//
// Since M41 the core is composable: src/core.mc is the sum of five parts
// (<mc/core_min>, <mc/core_machines>, <mc/core_writers>, <mc/core_build>,
// <mc/core_bundle>, docs/reference/bundle.md § The parts) and this file is the
// `main()` that turns that pile of registries into `mc`:
//
//   host_init(envp)      the host layer, before anything else (M37)
//   mc_machines_init()   arm64 and x86-64                     <mc/core_machines>
//   mc_writers_init()    the six backends and the five targets <mc/core_writers>
//   mc_bundle_init()     `#include <name>`                     <mc/core_bundle>
//   mc_build_init()      `mc build|limits|sysroot`, and the pre-scan
//                                                              <mc/core_build>
//   mc_main(argc, argv, envp)  everything else                 <mc/core_min>
//
// A recreated compiler is this file with a different list -- its own machine,
// its own writer, and none of the parts it does not want. That is exactly what
// examples/kernel and scripts/check-parts.sh do, and what
// docs/guide/98-recreating-the-compiler.md walks through.
//
// The order matters in one place only: every *_init here runs BEFORE mc_main,
// and none of them may call tok_add -- the token ids K_U8..K_EXTERN are frozen
// by tok_init() inside mc_main, and user_init() is the one hook that runs after
// it (docs/reference/hooks.md § 1).

// envp is the third argument the C runtime passes (libSystem on macOS, musl's
// crt1.o on Linux). The Linux host has no other way to reach the environment,
// so it is handed over before anything else runs (src/host_linux.mc).
i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    mc_machines_init();
    mc_writers_init();
    mc_bundle_init();
    mc_build_init();
    return mc_main(argc, argv, envp);
}
