// host_linux_aarch64.mc — the Linux host on AArch64 (M37). The OS half is in
// src/host_linux.mc; this file is only the three architecture answers.
#include "host_linux.mc"

uptr host_arch()    { return "aarch64"; }
uptr host_machine() { return "arm64"; }
uptr host_include() { return "mc/host_linux_aarch64"; }
