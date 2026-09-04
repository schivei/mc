// mc-kernel.mc — this example's compiler: the `mc` core plus a RISC-V 64
// machine, a flat-image writer and four words of bare-metal syntax. It does not
// edit `src/`: it takes the whole compiler minus `user_init` from the BUNDLE
// inside the binary (`<mc/core>`, M15) and supplies `user_init`.
//
//   ../../build/mc1 build examples/kernel                   -> build/kernel.bin
//   ../../build/mc1 build examples/kernel --compiler-only   -> build/mc-kernel
//   build/mc-kernel --backend=rv-image --include=lib main.mc -o build/kernel.bin
//
// The default compiler (`build/mc1`) refuses both halves: `--backend=rv-image`
// is `unknown backend`, and the source is `type expected at top level` at the
// first `mmio` line. See docs/surface.md § Tier 3 and docs/guide/97-a-new-
// architecture.md.

// M37: `<mc/host>` is the host file of whichever `mc` compiles this line -- the
// one thing in a compiler that cannot come from a portable core.
#include <mc/host>
#include <mc/core>
#include "machine_riscv64.mc"
#include "image.mc"
#include "kernel_syntax.mc"

// The registrations of docs/specs/M39.md § 1, and nothing else.
// `machine()` also makes its table the one in effect (src/hooks.mc), so this
// compiler dumps RISC-V by default and `--machine=arm64` flips back -- decided
// in M39 D5.
//
// M39.5 adds the fourth line. `target(os, arch, obj, exe)` is what makes
// `[target] os = "none" / arch = "riscv64"` in mc.toml mean something, and a
// pair only this binary knows now works because `mc build` resolves [target]
// after `user_init()` (docs/specs/M39.md § Gaps, G1). Both roles are the same
// backend on purpose: a bare-metal board has no separable object step -- the
// flat image IS the artefact -- so `rv-image` fills the EXE slot, which is what
// lets `mc build examples/kernel` write build/kernel.bin with no [linker].
void user_init() {
    machine_riscv64_init();                      // fills m_rv64, registers "riscv64"
    backend("rv-image", &backend_rv_image);      // --backend=rv-image
    target("none", "riscv64", "rv-image", "rv-image");   // [target] in mc.toml
    kernel_syntax_init();                        // mmio / csrw / csrr / yield
}
