// host_linux_x86_64.mc — the Linux host on x86-64 (M37). The OS half is in
// src/host_linux.mc; this file is only the three architecture answers, plus
// the raw system-call shim and the number table for this architecture (M43).
#include "host_linux.mc"
#include "sysno_linux_x86_64.mc"

uptr host_arch()    { return "x86_64"; }
uptr host_machine() { return "x86_64"; }
uptr host_include() { return "mc/host_linux_x86_64"; }
