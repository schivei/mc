// mc_probe.mc — the compiler that carries the probe machine (M24).
//
//   build/mc1 --exe lib/mc_probe.mc -o build/mc-probe
//   build/mc-probe --backend=macho-probe-core src/mc.mc -o x.o
//   cmp x.o build/mc1.o          # the probe changes no instruction
#include "../src/host_macos.mc"
#include "../src/core.mc"
#include "machine_probe.mc"

void user_init() {
    pr_init();
    backend("macho-probe", &pr_backend);
    backend("macho-probe-core", &pr_backend_core);
}
