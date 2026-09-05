// mc-avr.mc — this example's compiler, and the first RECREATED one: not `mc`
// plus a module, but a compiler ASSEMBLED out of the parts M41 split
// `<mc/core>` into, with the parts this target has no use for left out
// (docs/specs/M40.md § Amendment, docs/specs/M41.md § 3a,
// docs/guide/98-recreating-the-compiler.md).
//
// What it is made of:
//
//   <mc/host>        the host file of whichever `mc` compiles this line (M37)
//   <mc/core_min>    arena lz objmodel lex ast parse gen_resolve gen_walk hooks
//                    cli -- the compiler that has no target
//   <mc/core_build>  `mc build`, `mc limits`: this compiler is the CHILD `mc
//                    build` spawns, so it has to be able to read mc.toml itself
//   machine_avr.mc   the ATmega328P machine, thirty-one task slots
//   image_avr.mc     the ELF32 EM_AVR writer
//   avr_syntax.mc    three words a bare-metal source wants
//
// What it is NOT made of, and this is the milestone's headline:
//
//   <mc/core_machines>  no arm64, no x86-64
//   <mc/core_writers>   no Mach-O, no ELF64, no COFF, no SHA-256
//   <mc/core_bundle>    no bundle at all -- so no `#include <name>`, and every
//                       include in this directory is a relative path
//
// and one thing it DECLARES that `mc` does not: `uptr` is two bytes. That is
// M41's type_set_width, whose reason for existing is this line (M24 D8 refused
// it for having no caller; M40 is the caller). Everything follows from it --
// the granule a frame slot is rounded to, the alignment of a local array, the
// size of a pointer in a `uptr[]` initializer, and the bound `uptr t[1000]` is
// measured against.
//
//   ../../build/mc1 build examples/avr                  -> build/avr.elf
//   ../../build/mc1 build examples/avr --compiler-only  -> build/mc-avr
//   build/mc-avr --backend=avr-image --include=lib main.mc -o build/avr.elf
//
// The default compiler refuses every half: `--backend=avr-image` is an unknown
// backend, the source is `type expected at top level` at the first `sfr` line,
// and `[target] none/avr` is not a pair it knows.

#include <mc/host>
#include <mc/core_min>
#include <mc/core_build>
#include "machine_avr.mc"
#include "image_avr.mc"
#include "avr_syntax.mc"

// The five lines a recreated compiler writes instead of copying `mc_main`.
// `mc_machines_init` and `mc_writers_init` are simply not called, because the
// parts that define them are not here (M41 § 3a: removal is not including).
i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    mc_build_init();
    return mc_main(argc, argv, envp);
}

// The registrations, and nothing else. `machine()` also makes its table the one
// in effect, so this compiler dumps AVR by default; `backend_default` is what
// gives `mc-avr x.mc -o x.elf` an answer in a compiler with no host target in
// its registry (M41 § 2), and `target()` is what makes `[target] os = "none" /
// arch = "avr"` in mc.toml mean something -- resolved after user_init since
// M39.5. Both roles are the same backend: a bare part has no separable object
// step, so the image IS the artefact and `kind = "exe"` needs no [linker].
void user_init() {
    type_set_width(TY_UPTR, 2);                  // M41 § 4a: the declared word
    // M45: this machine's invariant is that every slot holds eight valid bytes
    // with the ones above the width ZEROED -- "extend" always means zero here,
    // which is false for a TK_SINT. Rather than be silently wrong, the word is
    // taken out of the surface: `i32 x;` is `i32: removed by this compiler`.
    // Sign-fill on AVR is a later ask (docs/specs/M45.md § A3).
    type_disable(ty_i32);
    machine_avr_init();                          // fills m_avr, registers "avr"
    backend("avr-image", &backend_avr_image);
    backend_default("avr-image");
    target("none", "avr", "avr-image", "avr-image");
    avr_syntax_init();                           // sfr / isr / halt
}
