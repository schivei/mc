// user.mc — the user's extension point (Tier 2).
//
// This file is the only seam between the compiler and the modules of whoever
// teaches it: it says which modules go into the binary. By default only the
// empty `user_init` from lib/user_default.mc goes in — the default compiler,
// with no passes or backends beyond the built-in `macho`.
//
// To teach the compiler, swap the include below for your module and run
// `make mc1`. For example, to wire in the M10 demo (the
// `arm64-surface` backend and the `x * 1` -> `x` pass):
//
//     #include "../lib/user_default.mc"
//
// There is no dylib, no plugin ABI: the module is compiled together with the
// rest of the compiler. See docs/surface.md, Tier 2 section.

#include "../lib/user_default.mc"
