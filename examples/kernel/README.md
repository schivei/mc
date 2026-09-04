# `examples/kernel` — a bare-metal RISC-V 64 micro-kernel, and the architecture it runs on

A developer asked whether `mc` could target MIPS, AVR or PIC. `mc` has no native support for any
of them, and the honest answer is not "wait for a fourth machine in the compiler" — it is **here is
how you add one from outside**. This directory is that answer, taken all the way to a booting
image: a RISC-V 64 instruction set, a flat-image writer and four words of bare-metal syntax, all in
`.mc` under `examples/`, with **zero lines added to `src/`, `stage0/`, `lib/` or `tests/`**.

```
../../build/mc1 build examples/kernel                     # -> build/mc-kernel, build/kernel.bin
qemu-system-riscv64 -machine virt -bios none -nographic -kernel examples/kernel/build/kernel.bin
```

One command, two processes: `mc build` assembles the taught compiler out of `<mc/core>` plus this
directory's modules, then spawns it for `[target] os = "none" / arch = "riscv64"` — a pair the
running `mc` has never heard of and `mc-kernel.mc` registers. The single-file CLI is still there
and still equivalent, and is what `test.sh` uses for the sources that are not `[project].entry`:

```
../../build/mc1 build examples/kernel --compiler-only     # -> build/mc-kernel
cd examples/kernel
./build/mc-kernel --backend=rv-image --include=lib main.mc -o build/kernel.bin
```

```
boot
trap
t0 t1 t0 t1 t0 t1 t0 t1 t0 t1
ok
```

…and exit 0. `sh test.sh` (or `make check-kernel` from the repository root) asserts every line of
that, the exit code, and a good deal more.

## What is here

| file | lines | what |
|---|---|---|
| `machine_riscv64.mc` | 780 | the RV64IM machine: all 31 tasks of [the contract](../../docs/reference/machine.md), registered as `riscv64` |
| `image.mc` | 246 | the `rv-image` backend: place, rebase, resolve, synthesize a reset stub, write raw bytes |
| `kernel_syntax.mc` | 117 | Tier 3: `mmio`, `csrw`, `csrr(…)`, `yield` |
| `mc-kernel.mc` | 30 | `#include <mc/core>` + the three modules + `user_init` |
| `lib/sys_bare.mc` | 148 | UART, `halt`, the CSR wrappers, `_start` |
| `lib/trap.mc` | 95 | `mtvec`, `trap_entry`, `mret` |
| `lib/sched.mc` | 90 | two tasks and the context switch |
| `main.mc` | 90 | the kernel |
| `tests/sweep.mc` | 177 | a source that makes the machine emit everything it knows |
| `mc.toml` · `test.sh` | 62 · 502 | the build, and the oracle |

`user_init()` is the entire seam, and it is three lines:

```c
void user_init() {
    machine_riscv64_init();                  // fills m_rv64, registers "riscv64"
    backend("rv-image", &backend_rv_image);  // --backend=rv-image
    kernel_syntax_init();                    // mmio / csrw / csrr / yield
}
```

The default compiler refuses both halves: `build/mc1 --backend=rv-image x.mc` prints
`unknown backend: rv-image` with the list of the ones it does have, and `build/mc1 main.mc` stops
at `type expected at top level` on the first `mmio`. The architecture belongs to this directory,
not to the language.

## The three registrations, in order of how much they buy

**1. The machine.** `machine("riscv64", m_rv64)` hands `src/gen_walk.mc` a table of 31 `&fn`, one
per task. The walker never learns a third instruction set: it says "the value is at depth 2, add
depth 3 to it" and `machine_riscv64.mc` decides that depth 2 is `t5`. RV64IM is the friendliest
set the walker has met — all thirteen `MOP_*` are one R-type instruction each, `sll/srl/sra`
already mask the shift count modulo 64, and `lbu/lhu/lwu/ld` already zero-extend, which is exactly
what `MTASK_LOAD` asks for.

**2. The writer.** `backend("rv-image", &backend_rv_image)` is a function of six lines over the
public object model — `machine_use`, `gen_lower`, `gen_encode_all`, then `rv_image_write`, which
does what `ld` and a linker script would have done. There is no ELF here, no Mach-O, no header at
all: 0x80000000 is where QEMU's `virt` board puts a raw image, so the file *is* the address space.

**3. The syntax.** Four words that a bare-metal source wants and the core language does not have.
This is the smallest of the three and it is the one a reader will copy first.

## The ABI this machine guarantees

[`docs/reference/objects.md` § 4](../../docs/reference/objects.md) says the register and frame
contract is **per machine**, and that a machine added from outside has to state its own or say
plainly that it does not. This is RISC-V's, and `test.sh` asserts every line of it against
`--dump-asm --machine=riscv64` over the whole kernel:

| registers | role |
|---|---|
| `a0..a7` (x10-x17) | parameters 1..8 in, `a0` the result out |
| `t0` (x5) | scratch: left/destination, and `callp`'s pointer |
| `t1` (x6) | scratch: right |
| `t2` (x7) | address materialisation, and nothing else |
| `t3..t6` (x28-x31) | expression depths 0..3 |
| `s0` (x8) | the frame base; every local is at `[s0 - off]` |
| `ra` (x1), `sp` (x2) | saved and restored by every function |
| `s1..s11`, `gp`, `tp` | **never written, never read** |

* **Parameters 1..8 arrive in `a0..a7` and the prologue does not clobber them.** The prologue is
  four instructions and an optional reserve, then one store per parameter; it *reads* the argument
  registers and writes none. That is what lets `lib/sys_bare.mc` write a CSR access as a function
  with a parameter and one `#opcode` word.
* **Parameters 9..12 arrive at `[s0 + 16 + 8*(i-8)]`** — above the frame record, because
  `addi sp, sp, -16` is what moved `sp` by 16. The caller leaves them at its own `[sp + 8*(i-8)]`,
  at the bottom of its frame, and writes them *before* it fills `a0..a7`.
* **The frame record is unconditional.** Every function opens with
  `addi sp,sp,-16 / sd ra,8(sp) / sd s0,0(sp) / mv s0,sp`, even a leaf with no locals — which is
  what makes a stack walk, and the context switch below, possible.
* **The epilogue is `mv sp,s0 / ld ra,8(sp) / ld s0,0(sp) / addi sp,sp,16 / ret`, always, and it
  is never patched.** `mv sp, s0` releases a frame of any size, so `MTASK_FRAME_FIX` touches one
  instruction in the prologue and nothing else. None of the five names `a0`, so a function whose
  body ends without a `return` hands back whatever `a0` holds.
* **`callp(p, …)` puts the pointer in `t0` and moves it LAST**, after `a0..a7` are written: its
  source is a depth register or a frame slot, and neither can be clobbered by a write to an
  argument register.
* **`x / 0` is `-1`, `x % 0` is `x`, `INT64_MIN / -1` is `INT64_MIN`, and none of them traps.**
  That is RV64M's answer, and it is a third one:
  [machine.md](../../docs/reference/machine.md) tabulates AArch64's (the same values) and
  x86-64's (`SIGFPE`, the process dies).

## The context switch is two instructions

`docs/specs/M39.md` priced `yield()` at "~25 `#opcode` words swapping `ra`/`sp`/`s0..s11`". It is
two, and the reason is the contract above rather than a trick:

* `s1..s11` are never written by generated code, so a switch does not have to save them;
* `ra` and `s0` of a suspended task are already on that task's own stack, put there by the
  unconditional frame record;
* `sp` is derived from `s0` by the epilogue.

So swapping `s0` swaps everything that matters. `ctx_switch(save, load)` is
`sd s0, 0(a0)` + `ld s0, 0(a1)`, and its own epilogue — the compiler's, unmodified — releases the
other task's frame, reloads the other task's `ra` and `s0` from the other task's stack, and
returns onto it. A task that has never run is started by writing that record by hand:
`lib/sched.mc`'s `task_start` puts the entry point where the return address goes.

This is the clearest case in the repository of an ABI guarantee being load-bearing rather than
documentary.

## What the image looks like

```
0x80000000  reset stub      li sp, _stack_top ; j _start ; (nop padding to 32 bytes)
0x80000020  __TEXT,__text   the functions, in definition order
            __TEXT,__cstring
            __DATA,__data
----------  end of the file
            __DATA,__bss    addressed, never written
            _stack_top      16 KiB above that
```

The writer defines six symbols the layer would otherwise need a linker script for —
`_bss_start`, `_bss_end`, `_data_start`, `_data_end`, `_data_lma`, `_stack_top` — and `_start`
uses five of them to zero `.bss` and copy `.data`. On this board the load address and the run
address are the same, so the copy is a no-op; it is written anyway, because it is what a flash
target needs and because `_data_lma` is a symbol the writer already has to compute.

The **reset stub sets `sp`**, which is a deviation from the spec's one-line sketch and not an
optional one: a RISC-V hart comes out of reset with every register zero, and the compiler's frame
record is unconditional, so `_start`'s own `sd ra, 8(sp)` would fault on the very first
instruction of the kernel. Nothing below the reset vector can set `sp`, and the writer is the code
that decided where the stack is.

Two relocation kinds are private to the machine, 32 and 33, following the precedent
`src/machine_x86_64.mc` set with 16 and 17. Both are carried by ONE fused 8-byte `Ins` — an
`auipc` plus an `addi` (or a `jalr`) — so the walker's "one implicit relocation per instruction"
rule is never bent, and `image.mc` resolves them itself. Addressing is **pc-relative** and not
`lui`+`addi`, because `lui t2, 0x80000` on RV64 sign-extends to `0xFFFFFFFF80000000`: the absolute
route is wrong at exactly the address this board loads at.

## What the machine pays that the compiler does not

RV's load/store displacement is a **signed** 12-bit field and reaches 2047; the walker's
language-wide frame limit is 4095, which is AArch64's *unsigned* 12-bit. The contract keeps that
limit uniform across targets on purpose, so the machine pays: above 2047 it materialises the
offset in `t2` and adds. `main.mc`'s `big_frame_sum()` has a 3000-byte local array precisely to
exercise it, and checks its own checksum at run time — if the fallback were wrong the transcript
would say `frame FAIL`.

The other thing the machine pays for itself is **range**. `jal`'s immediate is a signed 21-bit
displacement, so an unconditional jump — which is what every `if`, `loop`, `break` and `continue`
becomes — reaches 1 MiB and no further, where AArch64's `b` reaches 128 MiB. `rv_put_j` would mask
a larger one into the field and produce a jump to the wrong place, so `rv_jal_off()` refuses it
with `riscv jal out of range`, the way `src/machine_arm64.mc`'s `br_off()` refuses a branch too
far. The check runs on the ENCODE pass only: `MTASK_INS_SIZE` measures with no label vector, and
both jump forms are fixed width, so the size does not depend on the answer. `test.sh` step 6b
builds one `if` over 1.4 MiB of code and asserts the diagnostic — without it that source compiles,
boots and stops at `mcause=2`, having jumped 1440004 bytes forward as `j -657148`.

That is also why `MTASK_INS_SIZE` runs the real encoder over a scratch buffer instead of a
`switch` on the opcode. RV64 is fixed width almost everywhere, which makes a switch tempting; but
`li`, the frame reserve and the four big-offset fallbacks are not, and a one-byte disagreement
between the size task and the encoder would move every later branch and produce a plausible image
that jumps into the middle of an instruction.

## Limits, on the record

* ~~**`mc build` cannot drive a bare target.**~~ — gap G1 of `docs/specs/M39.md`, **taken in
  M39.5**. `[target]` is no longer resolved when the TOML is read: `drv_run` keeps `os`/`arch` as
  strings, `drv_entry` asks for a role (object or executable), and `drv_backend_for` consults the
  registry inside `drv_parse`, right after `user_init()`. So `mc.toml` names
  `os = "none" / arch = "riscv64"`, `mc-kernel.mc` registers it with
  `target("none", "riscv64", "rv-image", "rv-image")`, and `mc build examples/kernel` writes
  `build/kernel.bin` end to end. `rv-image` fills the **exe** slot because a bare board has no
  separable object step — which is what lets `kind = "exe"` work with no `[linker]`. The one
  visible consequence is that an unknown pair is now reported after the entry has been opened and
  lexed, so the `compile x -> y` step line comes first; the message itself is unchanged.
* **No `linux/riscv64` ELF.** That needs a second relocation against a local label
  (`%pcrel_lo` naming the `auipc`) and a third branch in the ELF writer's relocation map — gaps G3
  and G8, ~52 core lines and contract version 3.
* **A function's code is bounded by 1 MiB.** Not the image, not the program: the distance from a
  jump to its target, which is inside one function. Past it the machine refuses to encode rather
  than truncating (`riscv jal out of range`). Lifting it means a two-instruction long jump —
  `auipc`+`jalr` — chosen by the encode pass, and the label pass would have to know the size
  before the address is final. No source in this repository comes near it.
* **`mc limits examples/kernel` is exit 3 cold and exit 0 remembered**, the shape M23 recorded for
  `examples/api`. `[limits] tolerance = 1.0` is what keeps the COMPILER half at `grow 0`; the
  ENTRY half is 90 lines of source whose taught words and `#rule` prelude expand into about five
  times the nodes a byte-count estimate predicts, which no tolerance in `[0, 1]` covers. The
  usage `mc build` remembers in `build/.mc-usage.toml` is what does. `test.sh` step 8 asserts both
  phases.
* **One hart, no interrupts.** `mcause == 11` and nothing else: no CLINT, no timer, no PMP, no
  S-mode, no MMU.
* **The scheduler is two tasks and no policy.** The point is the switch.
* **`reloc()` is never used**, so gap G2 (the four hard-coded relocation kinds a source may name)
  does not bite. The image writer synthesizes the reset stub, and `_start` calls `kmain` as an
  ordinary call.

## And the question that started it

MIPS64 lands in this shape almost exactly: fixed 32-bit instructions, a flat register file,
`hi`/`lo` as a machine detail, branch delay slots fillable from `MTASK_ENCODE`. No new gap.

AVR and PIC do not, and the blocker is **not** the instruction set — it is the data model.
`type_width` returns 8 and `slot_new(8)` is unconditional, so a ten-local function costs an
80-byte frame on a chip with 2048 bytes of SRAM. Changing what a word means is a milestone of its
own. [`docs/guide/97-a-new-architecture.md`](../../docs/guide/97-a-new-architecture.md) says which
families that excludes today, and why.
