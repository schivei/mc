// mc_windows_x86_64.mc — the default compiler hosted on windows/x86_64 (M38).
// src/mc_windows.mc's sibling: same core, same extension point, the Win64 half
// of the x86-64 machine.
//
//   scripts/bootstrap-windows.sh    the fixed point of this file on a Windows host
//   src/mc.windows-x86_64.toml      how a macOS host cross-builds it

#include "host_windows_x86_64.mc"
#include "core.mc"
#include "user.mc"
