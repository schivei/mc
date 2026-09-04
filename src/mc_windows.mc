// mc_windows.mc — the default compiler hosted on windows/aarch64 (M38).
//
// It is src/mc.mc with one line changed: the host layer. Everything else --
// the core, the extension point, the backends, the bundle -- is the same
// source, and the object it produces for a given input is the same object
// src/mc.mc produces, because none of that is host-dependent. The CI proof of
// that sentence is the cross check: this compiler, running on Windows, writes
// a Mach-O object for src/mc.mc that is byte for byte the one macOS writes.
//
//   scripts/bootstrap-windows.sh   the fixed point of this file on a Windows host
//   src/mc.windows-aarch64.toml    how a macOS host cross-builds it
//
// The link needs two more objects than a Linux one does -- the entry point
// (lib/sys_windows_start.mc) and the POSIX shims (lib/sys_windows_host.mc) --
// because Windows has no C runtime to take them from. scripts/link-windows.sh
// writes that line.
//
// See docs/guide/95-windows-host.md.

#include "host_windows_aarch64.mc"
#include "core.mc"
#include "user.mc"
