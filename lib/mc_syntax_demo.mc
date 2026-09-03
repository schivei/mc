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

#include "../src/core.mc"
#include "user_syntax_demo.mc"
