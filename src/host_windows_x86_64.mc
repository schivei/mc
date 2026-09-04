// host_windows_x86_64.mc — the Windows host on x64 (M38). The OS half is in
// src/host_windows.mc; this file is only the three architecture answers.
//
// The machine is `x86_64-win`, the Win64 half of the x86-64 machine (M20): the
// same encoders and the same dump as `x86_64`, another calling convention
// (docs/reference/machine.md).
#include "host_windows.mc"

uptr host_arch()    { return "x86_64"; }
uptr host_machine() { return "x86_64-win"; }
uptr host_include() { return "mc/host_windows_x86_64"; }
