# A new architecture — from "I have an ISA" to "my image boots"

You have an instruction set `mc` does not know. MIPS64, maybe, or a RISC-V board, or something in
a manual on your desk. This page is the path from that to a program running on it, and the short
version is: **you write a module, and you do not touch the compiler.**

`examples/kernel` is the worked case, end to end — a bare-metal RISC-V 64 micro-kernel that boots
under QEMU, prints, takes a trap, switches between two stacks and exits with a code you chose.
Every line of the architecture is under `examples/`; `src/`, `stage0/`, `lib/` and `tests/` gained
nothing. Read it alongside this page.

## What you actually have to write

Four registrations, and they are the whole seam:

```c
void user_init() {
    machine_riscv64_init();                  // 1. the instruction set
    backend("rv-image", &backend_rv_image);  // 2. how the bytes leave
    target("none", "riscv64", "rv-image", "rv-image");   // 3. what [target] means
    kernel_syntax_init();                    // 4. optional: words your target wants
}
```

That file is your compiler. `mc build DIR` assembles it out of the bundle inside the `mc` you
already have (`#include <mc/core>`) plus your modules, then spawns it to compile your program —
one command for both halves. (`--compiler-only` stops after the first and prints the compiler's
path, which is what you want when a `test.sh` drives it over a suite of its own.)

The third line is what makes `[target] os = "none" / arch = "riscv64"` in your `mc.toml` mean
something. `target(os, arch, obj, exe)` fills two roles; on a bare board they are the same
backend, because the image *is* the artefact — putting it in the **exe** slot is what lets
`kind = "exe"` write it with no `[linker]`. Since M39.5 the pair is looked up after `user_init()`
has run, so a target only your module knows is a target `mc build` can drive.

### 1. The machine — instruction selection

`src/gen_walk.mc` walks the AST and knows nothing about registers. It speaks in **depths**: "the
value is at depth 2, add depth 3 to it, the result stays at depth 2." A machine is a table of 31
function pointers, one per task, and it decides that depth 2 is `t5` and that the addition is
`add t5, t5, t6`. [`reference/machine.md`](../reference/machine.md) is the contract: every slot,
its signature, and the line between what the walker keeps and what you own.

The tasks are small. `MTASK_BIN` on RISC-V is one line — a table lookup and one R-type instruction
for all thirteen operations. `MTASK_CONST`, `MTASK_LOAD`, `MTASK_JUMP` are two or three each. The
ones that take real thought are the four that touch the frame (`PROLOGUE`, `PARAM`, `EPILOGUE`,
`FRAME_FIX`) and the two calls, and even those are twenty lines apiece.

Four rules earn their keep:

* **Depths go in caller-saved registers that are not argument registers.** That is the rule that
  produced `x9..x15` on AArch64, `r8..r11` on x86-64 and `t3..t6` on RISC-V; it is what lets a
  call save the live depths to the frame and restore them without an ABI argument.
* **`MTASK_INS_SIZE` must run the real encoder** over a scratch buffer, not a `switch` on the
  opcode. Even a fixed-width machine has variable pieces — a materialised constant, a frame
  reserve, an offset that does not fit its field — and a one-byte disagreement between the size
  the label pass reserves and the bytes the encoder writes moves every later branch and produces
  a plausible image that jumps into the middle of an instruction. If size and bytes come out of
  one function they cannot disagree.
* **You may invent relocation kinds.** `src/machine_x86_64.mc` uses 16 and 17,
  `examples/kernel/machine_riscv64.mc` uses 32 and 33; they travel opaquely in the same `Reloc`
  record and only your writer has to understand them.
* **You may fuse.** RISC-V's `auipc` + `addi` pair is ONE `Ins` of eight bytes carrying ONE
  relocation, because the alternative — a second relocation against a local label naming the
  `auipc` — is a shape the object model has no name for. If two instructions are always adjacent
  and always relocate together, make them one.

Write your own two-line setter. `machine_task` in `src/machine_arm64.mc` writes into `m_arm64`
**by name**; copying it would corrupt AArch64's table instead of filling yours.

```c
uptr m_mine[MTASK_COUNT];
void my_task(i64 task, uptr fn) { st64(m_mine + task * 8, fn); }
```

### 2. The writer — how the bytes leave

`backend("name", &f)` registers `void f(i64 root, uptr out)`, and the body is short:

```c
void my_write(i64 root, uptr out) {
    machine_use("mine");     // an object backend names its machine first
    gen_lower(root);         // AST -> Ins buffers, sections, symbols, relocations
    gen_encode_all();        // the machine's encoder fills the section buffers
    my_emit_file(out);       // yours
}
```

Everything `my_emit_file` needs is public and documented in
[`reference/objects.md`](../reference/objects.md) §§ 2, 5–9: the sections and their buffers, the
symbols, the relocation array. `examples/kernel/image.mc` is 246 lines and does what `ld` plus a
linker script would have done — place the sections from a fixed base, rebase every symbol,
resolve its own relocations in place, synthesize the four bytes of reset vector — because on bare
metal the file *is* the address space and there is nothing to link against.

If your target has a real object format instead, `src/backend_elf.mc` is the model, and
`lib/backend_arm64.mc` is the standing proof that a writer built entirely from outside the
compiler reproduces the built-in one's bytes.

### 3. The syntax — optional, and last

`mmio UART 0x10000000;`, `csrw mtvec, x;`, `yield;`. Four registrations in
`examples/kernel/kernel_syntax.mc`, none of them a code generator: each one produces ordinary
nodes, and what they buy is a diagnostic at the point of use instead of an undefined symbol at
the end of the build. [`30-teaching.md`](30-teaching.md) is the whole surface.

## State your ABI, and let a script assert it

[`reference/objects.md`](../reference/objects.md) § 4 says the register and frame contract is
**per machine**. A runtime written with `#opcode` — a syscall wrapper, an atomic, a trap handler,
a stack switch — is built on it, and violating it fails at run time with no diagnostic at all. So
write it down, and then make a script check it against `--dump-asm --machine=NAME` over a real
program.

`examples/kernel/test.sh` asserts seven claims over the whole kernel: the unconditional frame
record, the fixed epilogue, zero mentions of the callee-saved registers, no argument register
written by a prologue, an empty frame for a zero-parameter leaf, stack parameters at the
documented offsets, and a frame slot past the field width that forces the fallback path.

It pays for itself immediately. `examples/kernel`'s context switch is **two instructions** —
`sd s0, 0(a0)` and `ld s0, 0(a1)` — and that is only legitimate because three documented
guarantees hold: the callee-saved registers are never written, `ra` and `s0` are already on the
suspended task's own stack (the frame record is unconditional), and `sp` is derived from `s0` by
the epilogue. Without the contract it would be a trick that happens to work.

## Prove the encoder against something that is not you

An encoder that is wrong in the same way twice — in `MTASK_ENCODE` and in `MTASK_DUMP` — is
invisible to any test you write out of your own head. Use an assembler you did not write:

```sh
# disassemble the .text you produced, one instruction per line...
llvm-mc --disassemble -triple=riscv64 -mattr=+m text.hex > dis.txt
# ...and assemble every DISTINCT line back, comparing bytes
llvm-mc -triple=riscv64 -mattr=+m --show-encoding distinct.s
```

That is the shape M17 used for x86-64 (948 instructions), M20 for Win64 (967) and M39 for RISC-V
(234 from the kernel, 262 from a source written to emit everything, 1057 from 800 generated
functions). Check the pc-relative displacements separately and arithmetically — recompute where
each symbol landed and assert `target - address` — because a displacement that is consistently
wrong round-trips perfectly.

Then run it. `examples/kernel`'s oracle is
`qemu-system-riscv64 -machine virt -bios none -nographic -kernel image.bin`, and it asserts the
exact transcript **and** the process exit code, which QEMU's SiFive test device passes straight
through from the guest. An oracle that only looks at stdout is half an oracle.

## What this does not buy yet

*(`mc build` driving a bare target used to be on this list. M39.5 took it: the resolution moved
to just after `user_init()`, so the pair your module registers counts. The one thing to know is
that an unknown `[target]` is now reported after your entry source has been opened, so the
`compile x -> y` step line comes out first.)*

**A source cannot name your relocation kinds.** `reloc(TYPE, "sym")` accepts four hard-coded
values. If your entry shim needs to name a call the way `lib/sys_linux.mc` names `BRANCH26`, you
need a registry that does not exist yet; `examples/kernel` sidesteps it by having the image writer
synthesize the reset stub and by calling `kmain` as an ordinary call.

## Which families this reaches, honestly

**MIPS64 lands in this shape almost exactly.** Fixed 32-bit instructions, a flat register file,
`hi`/`lo` as a detail inside `MTASK_BIN`, branch delay slots fillable from `MTASK_ENCODE`. No new
gap in the compiler. If you came here from that question, the answer is yes, and
`examples/kernel/machine_riscv64.mc` is the file to copy.

**AVR and PIC do not, and the blocker is not the instruction set.** It is the data model. `mc` has
one integer width: `type_width` returns 8 for every type that reaches a frame slot, and
`slot_new(8)` is unconditional. So a ten-local function costs an 80-byte frame on a chip with
2048 bytes of SRAM, and a 4096-byte array does not fit at all. Everything *else* about AVR is
reachable from inside a machine with no core change — a 64-bit ALU synthesised from 8-bit
operations, multiply and divide through helper routines the module ships, the Harvard
flash-to-SRAM startup copy, 6-bit `ldd Y+q` displacements, mixed 16- and 32-bit instruction
words. It is the word size that is out of reach, and changing what a word means is a milestone of
its own, not a module.

PIC is further still: banked memory and a hardware call stack of 8 to 31 levels have no cheap
lowering for an unconditional frame record and arbitrary recursion.

So: a 32-bit or 64-bit load/store architecture with a flat register file is a module. A small
microcontroller is a conversation about the data model first.

---

* [`reference/machine.md`](../reference/machine.md) — the 31 tasks, and the three machines side by side
* [`reference/objects.md`](../reference/objects.md) — what a writer reads, and the ABI each machine states
* [`reference/hooks.md`](../reference/hooks.md) — `machine`, `backend`, `target`, and the rest of the surface
* [`40-backends.md`](40-backends.md) — replacing the writer without replacing the machine
* [`../../examples/kernel/README.md`](../../examples/kernel/README.md) — the worked case, with its limits on the record
