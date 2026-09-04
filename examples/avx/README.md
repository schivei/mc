# examples/avx — one AVX instruction, named by its encoding

This directory is a proof, not a library. It answers the second half of M24's
question — *"a hardware-specific instruction, a new AVX op on a specific CPU,
usable from the surface"* — with about three hundred lines outside `src/` and
**zero inside it**.

```
build/mc1 --exe examples/avx/mc-avx.mc -o build/mc-avx
build/mc-avx --backend=elf-obj-x86_64 examples/avx/main.mc -o main.o
```

## What it teaches

| | |
|---|---|
| `v8f32` | `type_new("v8f32", 32, 32, TK_OPAQUE)` — thirty-two byte globals, array elements and **frame slots**, from the width alone |
| `vaddps(a, b)` · `vmulps(a, b)` | `intrinsic`: a NAME whose two operands arrive already lowered to depths |
| `vloadu(p)` · `vstoreu(p, v)` | the same, over an address |
| the machine | a copy of `x86_64` with nine slots replaced: the 32-byte spill, the four memory tasks, and its own encoder, sizer and dump |

Depths 0..5 live in `ymm0..ymm5` and spill from 6 into 32-byte frame slots.
The frame is 16-byte aligned (`src/gen_walk.mc`), so a 32-byte **aligned** spill
is unreachable and the machine uses `vmovups` — which it would use anyway.

## Why `#opcode` cannot do this

`#opcode` folds its arguments to constants and names fixed registers, so an
operand would have to *happen* to sit in one, inside a whole leaf function; and
`emit()` is exactly 32 bits, while `vaddps ymm, ymm, ymm` is four bytes only in
its VEX2 form and five in VEX3. A module's own machine has no such limit —
`x86_put` already writes one to ten bytes — which is what
`docs/specs/M24.md` means by *"M7 reaches them; only `emit()`/`#opcode` from a
source file stay 4-byte-bound"*.

## Which VEX forms are reachable

| form | reachable | how |
|---|---|---|
| **VEX2** (`C5`), register operands in `ymm0..ymm7` | yes | this module, and `#opcode` too: `vmovups ymm0, [rdi]` is exactly `C5 FC 10 07`, one 32-bit word. On x86 the `#opcode` word is a little-endian byte string, so it is written `emit(0x0710FCC5)` |
| **VEX3** (`C4`), any register `r8`/`ymm8` and above, or a memory base in `r8..r15` | yes, **here** | three prefix bytes plus opcode plus modrm; `emit()` cannot express five bytes |
| a displacement, or an immediate (`vcmpps`, `vpermilps`) | yes here, never through `emit()` | `x86_modrm_m` writes the displacement, and a module may append its own immediate byte |
| `vfmadd231ps` and the rest of the `0F38`/`0F3A` maps | not implemented, and no obstacle | one more `mmmmm` value in `av_vex` |

The module emits the **shortest** form, `C5` when nothing outside the low eight
registers is named and `C4` otherwise — which is the rule `llvm-mc` follows, and
what makes the re-assembly check in `scripts/check-wide.sh` an equality rather
than an approximation: every distinct instruction the module invents is fed back
through the assembler and required to come out byte for byte.

## What is NOT here

Execution. There is no AVX machine in this repository's development loop and no
emulator in it that is guaranteed to have AVX, so `scripts/check-wide.sh` builds
the object and re-assembles every instruction and does not run the program. A
linux/x86_64 machine with AVX runs it as it stands.

There is no CPU-feature model in `mc` and there should not be one: this module
says plainly what it was built for, and a program built with it runs on a machine
with AVX and nowhere else.
