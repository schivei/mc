// mc.mc — the default compiler: the core (core.mc) plus the user's extension
// point (user.mc, which by default only has an empty `user_init`).
//
// The split exists since M12: a taught compiler does not edit src/, it is its
// own file that includes `src/core.mc` and defines its own `user_init`
// (see docs/surface.md § Tier 3 and examples/api/mc-api.mc). src/user.mc remains
// the seam for those who prefer to teach the default compiler instead.

// M37: the host layer comes first and is the ONE file that differs between
// src/mc.mc, src/mc_linux.mc and src/mc_linux_x86_64.mc (docs/guide/90-linux-host.md).
#include "host_macos.mc"
#include "core.mc"
#include "user.mc"
