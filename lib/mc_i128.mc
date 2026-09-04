// mc_i128.mc — the compiler that carries lib/i128.mc (M24 step 2).
//
//   build/mc1 --exe lib/mc_i128.mc -o build/mc-i128
//   build/mc-i128 --exe tests/wide/030-i128.mc -o t && ./t
#include "../src/host_macos.mc"
#include "../src/core.mc"
#include "i128.mc"

void user_init() {
    i128_init();
}
