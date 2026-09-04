// mc_f16.mc — the compiler that carries lib/f16.mc on top of <float> (M24 step 2).
//
// The order is the point: f16 DERIVES from the machine <float> registered under
// `arm64`, so float_init and machine_arm64_float_init have to come first. A
// module that stacks on another one says which one it needs (risk 4 of
// docs/specs/M24.md: machine registration is last-wins).
#include "../src/host_macos.mc"
#include "../src/core.mc"
#include "float.mc"
#include "machine_arm64_float.mc"
#include "machine_x86_64_float.mc"
#include "f16.mc"

void user_init() {
    float_init();
    machine_arm64_float_init();
    machine_x86_64_float_init();
    f16_init();
}
