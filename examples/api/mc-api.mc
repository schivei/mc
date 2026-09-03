// mc-api.mc — this example's compiler: the `mc` core plus `class`,
// `interface` and two type aliases. Does not edit `src/`: it takes the whole
// compiler minus `user_init` from the BUNDLE inside the binary (`<mc/core>`,
// M15) and supplies `user_init`. There is no path into the repository here:
// the same file compiles with an `mc` copied anywhere.
//
//   make -C examples/api mc-api      # build/mc-api, via `build/mc1 --exe`
//   examples/api/build/mc-api --exe tests/oop_test.mc -o build/oop_test
//
// The default compiler (`build/mc1`) rejects the same source with
// `type expected at top level` at the first `interface` line: the syntax
// belongs to this file, not to the language. See docs/surface.md § Tier 3.

#include <mc/core>
#include "oop.mc"

void user_init() {
    syntax("class", &oop_class);                 // top-level declaration
    syntax("interface", &oop_interface);         // top-level declaration
    type_alias("bool", TY_U8);                   // new type, no new syntax
    type_alias("str", TY_UPTR);
}
