// mc_syntax_demo.mc — a whole taught compiler, in two lines of
// #include. Does not edit `src/`: it takes the core via `src/core.mc` (which
// is the compiler minus `user_init`) and `user_init` comes from user_syntax_demo.mc.
//
//   build/mc1 --exe lib/mc_syntax_demo.mc -o build/mc-syntax-demo
//   build/mc-syntax-demo --exe lib/syntax_demo_test.mc -o /tmp/t && /tmp/t; echo $?
//   42
//
// It is the same pattern as examples/api/mc-api.mc. `make check-surface` does both
// steps and checks the 42. See docs/surface.md § Tier 3.

// M37: the host layer, which src/core.mc no longer carries. This file is a
// hand-written entry point compiled straight by `mc0`/`mc1`, so it names the
// host file by path; a compiler assembled by `mc build` gets `<mc/host>`
// instead and is portable by construction (docs/guide/90-linux-host.md).
#include "../src/host_macos.mc"
#include "../src/core.mc"
#include "user_syntax_demo.mc"
