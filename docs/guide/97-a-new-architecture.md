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

**AVR reaches it too, and it took one more mechanism.** When this page was first written the
blocker was not the instruction set but the data model: `type_width` answered 8 for everything
that reached a frame slot, so a ten-local function cost an 80-byte frame on a part with 2048 bytes
of SRAM. M41 made that one decision overridable -- `type_set_width(TY_UPTR, 2)`, declared from
`user_init` and followed by the slot granule, the frame alignment, the local-array bound and the
size of a pointer in a `uptr[]` initializer -- and M40 is the caller.
[`examples/avr`](../../examples/avr/README.md) is an ATmega328P firmware built by a compiler that
declares it: a blink, a UART transcript, a TIMER1 interrupt and an exit code, running under both
simavr and `qemu-system-avr`, with `git diff --stat src/ stage0/ lib/ tests/` empty.

Everything else about that part is a machine's own business and needs no core change: a 64-bit ALU
synthesised from 8-bit operations, multiply and divide through helper routines the module ships in
the language itself, the Harvard flash-to-SRAM startup copy (through an `lpm8` the machine
registers with `intrinsic()`), 6-bit `ldd Y+q` displacements with a fallback past them, mixed 16-
and 32-bit instruction words, and an interrupt frame written with `#opcode`. Two of its answers
are worth reading before you copy it: **a depth is a frame slot and not a register** (32 eight-bit
registers cannot hold four 64-bit depths, so the machine is an accumulator machine and
`save_live`/`restore_live` do not exist in it), and **arithmetic happens at the depth's declared
width**, which is what M24's `walk_depth_type` is for and what makes `u16 + u16` two instructions
instead of eight. The second one diverges from the 64-bit machines on purpose, it is written down
in [`reference/machine.md`](../reference/machine.md), and `examples/avr/tests/sweep_b.mc` asserts
both answers.

**PIC does not, and it is excluded permanently.** Not "future work": the frame model in
`src/gen_walk.mc` is one contiguous byte-addressed frame handed out by `slot_new`, addressed by a
displacement off a frame pointer, plus arbitrary recursion on a software stack. A PIC's data
memory is BANKED -- an address means nothing without a bank-select register, so a single
displacement does not name a slot -- and its call stack is HARDWARE, 8 to 31 levels deep and not
addressable, so a return address cannot be pushed to a frame and recursion is bounded by silicon.
There is no lowering of `MTASK_PROLOGUE` and `MTASK_LOCAL_LOAD` that is both correct and cheap.
That is a different frame model, not a machine (`docs/specs/M40.md` D9).

So: a load/store architecture with a flat register file is a module, an 8-bit part with a narrow
pointer is a module plus one declared width, and a banked machine with a hardware stack is neither.

---

* [`reference/machine.md`](../reference/machine.md) — the 31 tasks, and the three machines side by side
* [`reference/objects.md`](../reference/objects.md) — what a writer reads, and the ABI each machine states
* [`reference/hooks.md`](../reference/hooks.md) — `machine`, `backend`, `target`, and the rest of the surface
* [`40-backends.md`](40-backends.md) — replacing the writer without replacing the machine
* [`../../examples/kernel/README.md`](../../examples/kernel/README.md) — the worked case, with its limits on the record
* [`../../examples/avr/README.md`](../../examples/avr/README.md) — the second one: 8 bits, a two-byte word, and a compiler recreated for it
* [`98-recreating-the-compiler.md`](98-recreating-the-compiler.md) — assembling a compiler out of the parts, which is how that one is built
