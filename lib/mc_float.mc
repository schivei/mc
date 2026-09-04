// mc_float.mc — the compiler that carries `<float>`, in three lines of #include.
//
//   build/mc1 --exe lib/mc_float.mc -o build/mc-float
//   build/mc-float --exe prog.mc -o prog
//
// Or, from a project, `[compiler] modules = ["user_float.mc"]` (docs/build.md).
// The stock `mc` has no floats: <float> is deliberately NOT in
// lib/user_default.mc, which is what makes "an untaught object is identical to
// the frozen seed's" a structural fact and not a coincidence.
#include "../src/host_macos.mc"
#include "../src/core.mc"
#include "user_float.mc"
