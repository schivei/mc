// user_demo.mc — the M10 demonstration's `user_init`.
//
// Wiring this in means swapping src/user.mc's include for
//
//     #include "../lib/user_demo.mc"
//
// and running `make mc1`. The recompiled compiler then has the
// `arm64-surface` backend (`--backend=arm64-surface`) and the `x * 1` -> `x`
// pass. `make check-surface` does this swap on its own and returns the
// repository to how it was. See docs/surface.md, Tier 2 section.

#include "backend_arm64.mc"
#include "pass_demo.mc"

void user_init() {
    backend("arm64-surface", &sur_backend);
    pass(&pass_mul1);
}
