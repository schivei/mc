// host_windows_aarch64.mc — the Windows host on ARM64 (M38). The OS half is in
// src/host_windows.mc; this file is only the three architecture answers.
#include "host_windows.mc"

uptr host_arch()    { return "aarch64"; }
uptr host_machine() { return "arm64"; }
uptr host_include() { return "mc/host_windows_aarch64"; }
