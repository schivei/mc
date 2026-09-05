// user_float.mc -- the compiler half of the fixture package `float`.
//
// The two machines come from the BUNDLE (`<machine_arm64_float>`,
// `<machine_x86_64_float>`): a package may always read the bundle, and this one
// only overrides the LIBRARY. `float.mc` is reached relatively, inside the
// package's own tree -- `<float>` here would resolve to this same package and
// be a no-op, since the once-only list has it already.
#include "float.mc"
#include <machine_arm64_float>
#include <machine_x86_64_float>

void float_pkg_init() {
    float_init();
    machine_arm64_float_init();
    machine_x86_64_float_init();
}
