// user_float.mc — `<float>` as a MODULE: the library, the two machines, and the
// user_init that registers them. This is the file a project names in
// `[compiler] modules = [...]`; lib/mc_float.mc is the same thing as a
// standalone compiler entry, the way lib/user_syntax_demo.mc and
// lib/mc_syntax_demo.mc pair up.
//
// The order matters in exactly one way: float_init() must run before the
// machines, because they read `ty_f64`/`ty_f32` to recognise a float depth.
#include "float.mc"
#include "machine_arm64_float.mc"
#include "machine_x86_64_float.mc"

void user_init() {
    float_init();
    machine_arm64_float_init();
    machine_x86_64_float_init();
}
