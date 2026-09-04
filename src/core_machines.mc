// core_machines.mc — the two HOST machines: AArch64 and x86-64.
//
// A machine is the half of the code generator that selects instructions
// (docs/reference/machine.md); the walker in <mc/core_min> drives it through a
// table of 31 tasks. These two are the ones `mc` itself runs on and
// cross-compiles between, and they are the only reason `src/machine_arm64.mc`
// and `src/machine_x86_64.mc` are in a binary at all: a compiler for a target
// that is neither leaves this part out and registers its own.
//
// mc_machines_init() registers both, in the order src/main.mc has always used.
// It does NOT make one current and it does not freeze the snapshot: mc_main()
// does both, so that a compiler with a different set of machines gets the same
// treatment (src/cli.mc).

#include "machine_arm64.mc"
#include "machine_x86_64.mc"

void mc_machines_init() {
    machine_arm64_init();
    machine_x86_64_init();
}
