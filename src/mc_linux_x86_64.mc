// mc_linux_x86_64.mc — the default compiler hosted on linux/x86_64 (M37).
// src/mc_linux.mc's sibling: same core, same extension point, x86-64 host.
//
//   scripts/bootstrap-linux.sh   the fixed point of this file on a Linux host
//   src/mc.linux-x86_64.toml     how a macOS host cross-builds it

#include "host_linux_x86_64.mc"
#include "core.mc"
#include "user.mc"
