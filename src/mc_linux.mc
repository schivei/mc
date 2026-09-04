// mc_linux.mc — the default compiler hosted on linux/aarch64 (M37).
//
// It is src/mc.mc with one line changed: the host layer. Everything else --
// the core, the extension point, the backends, the bundle -- is the same
// source, and the object it produces for a given input is the same object
// src/mc.mc produces, because none of that is host-dependent.
//
//   scripts/bootstrap-linux.sh   the fixed point of this file on a Linux host
//   src/mc.linux-aarch64.toml    how a macOS host cross-builds it
//
// See docs/guide/90-linux-host.md.

#include "host_linux_aarch64.mc"
#include "core.mc"
#include "user.mc"
