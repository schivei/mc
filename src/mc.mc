// mc.mc — the default compiler: the core (core.mc) plus the user's extension
// point (user.mc, which by default only has an empty `user_init`).
//
// The split exists since M12: a taught compiler does not edit src/, it is its
// own file that includes `src/core.mc` and defines its own `user_init`
// (see docs/surface.md § Tier 3 and examples/api/mc-api.mc). src/user.mc remains
// the seam for those who prefer to teach the default compiler instead.

#include "core.mc"
#include "user.mc"
