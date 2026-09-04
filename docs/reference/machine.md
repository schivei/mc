# The machine task contract

> **Contract version 2 — the integer tasks, for two instruction sets (M17).**
> `src/gen_walk.mc` is the target-independent walker; `src/machine_arm64.mc` (step A) and
> `src/machine_x86_64.mc` (step B, and M20's Win64 half) are the three machines behind it —
> `arm64`, `x86_64`, `x86_64-win` — and `machine(name, tab)` in
> `src/hooks.mc` is the seam. The float tasks at the end of this page are still specification
> (`docs/specs/M24.md`), and so is `#machine`.
>
> A version is the list of `MTASK_*` slots below, in that order and with those signatures. Adding a
> task appends a slot and bumps the version; changing one's signature is a breaking change to every
> machine, and there is exactly one place to look for the answer — this page.
>
> **Version 1 → 2** appended exactly one slot, `MTASK_RELOC_OFF`. Version 1 assumed a relocation
> patches the instruction from its first byte, which is true of every fixed-width encoding and
> false of x86: `call rel32` carries its field one byte in, `lea r, [rip + disp32]` three. The
> walker now asks. AArch64 answers 0 and its objects did not move a byte. The float tasks will be
> version 3.

## Why the split exists

Until M17 `gen_lower` did two things at once: it walked the AST (frames, the depth stack, labels,
calls, name resolution) and it selected AArch64 instructions (`I_*` opcodes, `x9..x15` as depth
registers, `x16`/`x17` as scratch). A second instruction set cannot be added without separating
them, and separating them must not change a single byte of the objects the first one produces —
which is why the acceptance criterion is that `check-obj` (32/32) and `check-asm` (73/73) stay
identical against the frozen C seed, which is still one monolithic generator.

After the split:

- **`src/gen_resolve.mc`** — resolution and typing, in a side table indexed by node. Every name is
  bound and every expression typed before a single instruction is selected
  ([objects.md](objects.md) § 2).
- **`src/gen_walk.mc`** — the walker. It knows nothing about registers. It owns the `Ins` buffer,
  the frame in bytes, the label counter, the loop stack, the block scoping of locals, the sections,
  the globals, the string literals and every symbol; and it drives a **machine table**: one `&fn`
  per task, invoked through `callp`.
- **`src/machine_arm64.mc`** — the register partition, the spill policy, the selection, the
  encoders and the `--dump-asm` text, moved behind that table. **`src/machine_x86_64.mc`** (step B)
  is a second one of exactly that shape.
- `gen_lower`, `gen_encode_all` and the three format writers keep their names and their behaviour,
  so `lib/backend_arm64.mc`, `src/backend_exe.mc` and `src/backend_elf.mc` did not change a line in
  step A; step B added an `EM_X86_64` entry point to the ELF writer and touched neither of the other
  two.

---

## 1. Registering a machine

```c
void machine(uptr name, uptr tab)   // tab: MTASK_COUNT entries of &fn, in MTASK_* order
i64  machine_find(uptr name)        // index, or -1; searches back to front
void machine_use(uptr name)         // make that machine the one in effect
```

`machine()` appends to a linear table in registration order and **also makes the machine the one in
effect** — unlike `backend()`, a machine is not chosen by a flag but by the target, and the compiler
always has exactly one. The ceiling is fixed (`MAXMACHINES 8`): a machine does not scale with the
program being compiled, so M23's "no MAX* on tables that grow with the input" does not apply.

`src/machine_arm64.mc` builds its own table with two helpers and registers it from `main()`, before
any backend can lower:

```c
void machine_task(i64 task, uptr fn)   // one slot of m_arm64
void machine_arm64_init()              // fills all 31 slots, then machine("arm64", m_arm64)
```

`src/machine_x86_64.mc` is the same two functions under its own names, `x86_task` and
`machine_x86_64_init()` — which registers `x86_64` and then, from a copy of the same table with
`MTASK_PROLOGUE` replaced, `x86_64-win` (M20).

The walker reaches the table through `uptr mach(i64 task)`, which is the only place that reads
`mach_tab`. A machine that is missing is `no machine registered`, not a crash.

**How a machine is chosen (settled in step B).** `main()` registers every machine and then names
the host's, because every `machine()` call also makes its own table current:

```c
machine_arm64_init();
machine_x86_64_init();
machine_use("arm64");
```

From there **the object backend picks**, as its first statement — `backend_elf` does
`machine_use("arm64")`, `backend_elf_x86` does `machine_use("x86_64")`, and `backend_coff_x86` does
`machine_use("x86_64-win")`, which is how the Win64 ABI is reached without `target()` growing a
fifth column. Step A left two shapes
open: a fifth column on `target()`, or `machine_use` from the backend. The backend won, for three
reasons. `target()` keeps the four columns `docs/specs/M33.md` § 1 wrote down. An AST-consuming
backend (wasm) needs no machine at all, so a mandatory machine column on every target would be a
column it has to leave empty. And the file format already records the architecture — `e_machine`,
`cputype` — so the writer that fills that field is exactly the code that knows which instruction
set produced the bytes; splitting the two across a registry row would let them disagree.

The `--dump-*` modes never reach a backend, so `--machine=NAME` ([cli.md](cli.md)) is what points
them at a machine other than the host's: `mc --dump-asm --machine=x86_64 f.mc`.

---

## 2. The integer tasks (version 2)

Every task takes **depth indices**, never registers: the walker says "the value is at depth 2", and
whether depth 2 lives in a register or in a frame slot is the machine's decision. `ty` is a core
type constant (`TY_U8`, `TY_U16`, `TY_U32`, `TY_U64`, `TY_I64`, `TY_UPTR`) and stands for the access
width; `l` is a label number; `sym` a symbol index; `e` an `Ins` record.

| slot | signature | meaning |
|---|---|---|
| `MTASK_PROLOGUE` | `void f()` | open the frame: the frame record, and a reserve whose size is not known yet |
| `MTASK_PARAM` | `void f(i64 ty, i64 i, i64 off)` | argument `i` into the frame slot at `off` |
| `MTASK_EPILOGUE` | `void f()` | release the frame and return |
| `MTASK_FRAME_FIX` | `void f(i64 frame)` | the frame size, known only after the whole body |
| `MTASK_CONST` | `void f(i64 d, i64 imm)` | materialise a constant at depth `d` |
| `MTASK_BIN` | `void f(i64 op, i64 d, i64 d2)` | `MOP_*` of depths `d` and `d2`, result at `d` |
| `MTASK_CMP` | `void f(i64 cond, i64 d, i64 d2)` | `MCOND_*`, result 0/1 at `d` |
| `MTASK_UN` | `void f(i64 op, i64 d)` | `MUN_*` in place |
| `MTASK_BOOL` | `void f(i64 d)` | `d = (d != 0)` — the normalisation `&&`/`\|\|` needs |
| `MTASK_CAST` | `void f(i64 ty, i64 d)` | narrow depth `d` to that width |
| `MTASK_LOAD` | `void f(i64 ty, i64 d)` | `d = [d]`, zero-extended (`ld8..ld64`) |
| `MTASK_STORE` | `void f(i64 ty, i64 d)` | `[d] = d + 1` (`st8..st64`) |
| `MTASK_LOCAL_ADDR` | `void f(i64 d, i64 off)` | the address of a frame slot |
| `MTASK_LOCAL_LOAD` | `void f(i64 ty, i64 d, i64 off)` | read a frame slot into `d` |
| `MTASK_LOCAL_STORE` | `void f(i64 ty, i64 d, i64 off)` | write depth `d` into a frame slot |
| `MTASK_SYM_ADDR` | `void f(i64 d, i64 sym)` | a symbol's address — a global, a string literal, or a function taken with `&` |
| `MTASK_GLOBAL_LOAD` | `void f(i64 ty, i64 d, i64 sym)` | read the global at `sym` into `d` |
| `MTASK_GLOBAL_STORE` | `void f(i64 ty, i64 d, i64 sym)` | write depth `d` into the global at `sym` |
| `MTASK_CALL` | `void f(i64 d, i64 nargs, i64 sym)` | a direct call; the arguments are depths `d .. d+nargs-1`, the result lands at `d` |
| `MTASK_CALLP` | `void f(i64 d, i64 nargs)` | an indirect call; the pointer is argument 0, at depth `d` |
| `MTASK_RET` | `void f(i64 d)` | depth `d` into the return position (the walker emits the jump to the epilogue itself) |
| `MTASK_JUMP` | `void f(i64 l)` | unconditional jump |
| `MTASK_JZ` · `MTASK_JNZ` | `void f(i64 d, i64 l)` | jump when depth `d` is zero / non-zero |
| `MTASK_LABEL` | `void f(i64 l)` | place label `l` |
| `MTASK_WORD` | `void f(i64 w)` | exactly one raw word — what `emit()` and `#opcode` reach |
| `MTASK_INS_SIZE` | `i64 f(uptr e)` | how many bytes instruction `e` will occupy; `0` for what emits nothing |
| `MTASK_ENCODE` | `void f(uptr e, i64 pc, uptr lab, uptr buf)` | write instruction `e` into the section buffer `buf` |
| `MTASK_RELOC_KIND` | `i64 f(uptr e)` | the relocation this instruction always carries (`R_*`), or `-1` |
| `MTASK_RELOC_OFF` | `i64 f(uptr e)` | how many bytes into the instruction that relocation's field starts |
| `MTASK_DUMP` | `void f(uptr e)` | one `--dump-asm` line |

The operator vocabulary the tasks speak:

```
MOP_ADD MOP_SUB MOP_MUL MOP_SDIV MOP_UDIV MOP_SMOD MOP_UMOD
MOP_AND MOP_OR MOP_XOR MOP_SHL MOP_SHR MOP_SAR
MUN_NEG MUN_NOT MUN_LNOT
MCOND_EQ MCOND_NE MCOND_LT MCOND_LE MCOND_GT MCOND_GE
```

Signed and unsigned are **separate operations**, not a flag: the walker picks `MOP_SDIV` over
`MOP_UDIV` (and `MOP_SAR` over `MOP_SHR`) from `res_type` of the left operand, which is mc's actual
rule — only `i64` divides and shifts with sign. Comparisons are always signed, so there is one set
of six.

The four divide operations say nothing about a **zero divisor** or about `INT64_MIN / -1`: a
machine emits its target's divide instruction and the ISA answers, so a new machine owes no guard
and is not judged on the answer it gives
([../core-language.md](../core-language.md) § "Division by zero, and `INT64_MIN / -1`"). Shift
counts are the opposite case: mc and both machines mask them modulo 64.

### What the walker keeps, and what it hands over

| the walker owns | the machine owns |
|---|---|
| the depth stack and `MAXDEPTH` (64, an error not a table) | which depths live in registers, and where the rest spill |
| the frame in bytes: `slot_new(size)` | asking for a spill slot, at most once per depth |
| the label counter, the loop stack, block scoping | nothing about control flow but the encoding |
| the `Ins` buffer, `ins_add` and `e0/e2/e3/ei/el/elr/em` | which `I_*` goes in it |
| `I_LABEL` (opcode 0, reserved) and the pending-`reloc()` list | every other opcode |
| sections, globals, string literals, symbols, `reloc_add` | `MTASK_RELOC_KIND` alone |
| `frame too large` (over 4095 bytes) | the reason it is 4095 |

`frame too large` is deliberately kept in the walker even though the 12-bit limit is AArch64's:
`docs/specs/M17.md` § step B says a machine with no such limit should keep the language limit
anyway, so the diagnostic is the same on every target.

### The AArch64 implementation

The thirty-one slots are filled by `a64_prologue`, `a64_param`, `a64_epilogue`, `a64_frame_fix`,
`a64_const`, `a64_bin`, `a64_cmp`, `a64_un`, `a64_bool`, `a64_cast`, `a64_load`, `a64_store`,
`a64_local_addr`, `a64_local_load`, `a64_local_store`, `a64_sym_addr`, `a64_global_load`,
`a64_global_store`, `a64_call`, `a64_callp`, `a64_ret`, `a64_jump`, `a64_jz`, `a64_jnz`,
`a64_label`, `a64_word`, `a64_ins_size`, `a64_encode`, `dump_ins`, `a64_reloc_kind` and
`a64_reloc_off` (which returns 0: the word *is* the field). Under them sit the pieces a backend can
still call by name: `gen_imm(rd, v)`, `gen_cast(rd, ty)` and `gen_gaddr(rd, sym)`
([objects.md](objects.md) § 3).

### Deviations from `docs/specs/M17.md`'s sketch

The spec's list is the same contract with three names collapsed, and this page is the normative
one:

- `m_global_addr` and `m_str_addr` are **one** task, `MTASK_SYM_ADDR`: both are "the address of this
  symbol", and `&fn` is the third caller of it.
- `m_arg_move(d, i)` is **not** a slot. The walker lowers the arguments to depths and then calls
  `MTASK_CALL` / `MTASK_CALLP` once; where each argument goes, and what has to be saved around the
  call, is entirely the machine's — which is what lets `callp` put its pointer in `x16` without the
  walker knowing.
- `m_prologue(frame, nparams)` is split into `MTASK_PROLOGUE` (no arguments), one `MTASK_PARAM` per
  parameter and `MTASK_FRAME_FIX(frame)`, because the frame size is only known after the body: the
  spill slots are allocated while it is being walked.

### The x86-64 implementation (M17 step B)

`src/machine_x86_64.mc` fills the same thirty-one slots, and registers **two** machines out of one
set of functions: `x86_64` (System V, M17 step B) and `x86_64-win` (Win64, M20). It is the proof
that the split is real: **not one line of `src/gen_walk.mc` is architecture-specific**, and the ELF
writer is shared with aarch64 down to the section table.

| | AArch64 | x86-64 System V | x86-64 Win64 |
|---|---|---|---|
| machine name | `arm64` | `x86_64` | `x86_64-win` |
| depth registers | `x9..x15` (0..6) | `r8..r11` (0..3) | the same — volatile in both ABIs |
| why those | caller-saved, not argument registers | the same rule leaves exactly four | — |
| scratch | `x16`, `x17`, `x8` | `rax` (S1), `rcx` (S2), `rdx` | the same |
| why three | — | `idiv` writes `rdx`, `div` needs it zeroed, shifts count in `cl` | — |
| locals | `[sp, #k]`, fixed up at the end | `[rbp - k]`, correct from the first instruction | the same |
| frame | `stp x29, x30` + `sub sp` | `push rbp; mov rbp, rsp; sub rsp` / `leave` | the same |
| arguments | `x0..x7` | `rdi rsi rdx rcx r8 r9`, then `[rsp]`, `[rsp+8]` | `rcx rdx r8 r9`, then `[rsp+32]`, … |
| stack parameters | — | `[rbp+16]`, `[rbp+24]` | `[rbp+48]`, `[rbp+56]`, … |
| shadow space | — | none | 32 bytes, reserved by the caller |
| callee-saved, never touched | `x18..x28` | `rbx`, `r12..r15` | those plus `rsi`, `rdi` |
| result | `x0` | `rax` | `rax` |
| `callp` pointer | `x16`, `blr x16` | `rax`, `call rax` | the same |
| instruction width | 4 bytes | 1..10 bytes | the same |
| `x / 0`, `x % 0`, `INT64_MIN / -1` | `sdiv`/`udiv`: `0`, `x`, `INT64_MIN`, no trap | `idiv`/`div`: `SIGFPE`, the process dies | the same |
| relocations | `BRANCH26` `PAGE21` `PAGEOFF12` `UNSIGNED` | `R_X86_64_PLT32` `PC32` `64` | `IMAGE_REL_AMD64_REL32` `ADDR64` |
| relocation offset | 0 | 1 (`call`), 3 (`lea [rip+d32]`) | the same |

**The two ABIs are two machines, not a flag.** `m_x86_64_win` is a copy of `m_x86_64` with one slot
replaced, `MTASK_PROLOGUE`; the other thirty entries are literally the same `&fn`, because
`MTASK_INS_SIZE`, `MTASK_ENCODE`, `MTASK_DUMP`, `MTASK_RELOC_KIND` and `MTASK_RELOC_OFF` are pure
functions of the `Ins` record and know nothing about a calling convention. The convention itself
lives in three globals — the argument table, how many arguments travel in registers, and the
caller's shadow space — set by that prologue, which `gen_func` always runs before the first
`MTASK_PARAM` and before any `MTASK_CALL`, so they can never be stale. Two machines rather than a
runtime flag because `--dump-asm --machine=x86_64-win` has to be able to show the Win64 sequence,
and a flag the backend sets could not.

Two consequences of variable-length encoding, both already in the contract:

- `MTASK_ENCODE` writes into the section buffer instead of returning a word, and `MTASK_INS_SIZE`
  is what the label pass asks. There is exactly **one** encoder, `x86_put`: `MTASK_ENCODE` is that
  function, and `MTASK_INS_SIZE` runs the same function over a scratch buffer and returns its
  length. The two therefore cannot disagree — and a one-byte disagreement would silently move every
  later branch, so "cannot" is worth more than "is checked".
- One descriptor table drives all three readers of an opcode. `x86_desc` holds six columns per
  opcode — form, `REX.W`, the opcode byte(s), the ModRM extension, an optional `0x66` prefix, and
  whether REX is forced — and `x86_put` and the `--dump-asm` printer both dispatch on the form.
  Thirty of the forty-five opcodes need no code of their own at all.
- Functions are still aligned to 4 (`gen_encode_one`), so up to three zero bytes sit between them.
  They are never executed — every function ends in `ret` — but a disassembler decodes them as
  `add %al, (%rax)`.

The arguments past the register table are pushed with `push r/m64`, straight from the frame slot, so
no scratch register is spent on them; an odd count reserves an extra 8 bytes first, because `rsp`
has to be 16-byte aligned at the `call`. On Win64 the 32 bytes of shadow space are subtracted
**last**, so they end up below the pushed arguments and the fifth argument lands at `[rsp+32]` — the
place the callee's `MTASK_PARAM` reads it from. The alignment rule does not change: `8*np + 32` is
`0 mod 16` exactly when `np` is even. [objects.md](objects.md) § 4c is the full Win64 contract,
including why `r8`/`r9` being argument registers 3 and 4 **and** depth registers 0 and 1 is safe.

`#opcode`, `emit()` and `reloc()` are architecture-specific by nature — a source full of
hand-encoded AArch64 words is portable to Linux arm64 and nowhere else — so the tests that use them
carry a `// skip-x86_64:` header with the reason, which `scripts/test-linux.sh --arch x86_64`
prints.

**Verification.** Every distinct instruction the machine emitted while compiling `src/mc.mc` for
x86-64 — 948 of them — was fed back through `llvm-mc -triple=x86_64-linux-musl` and came out
byte-identical; the relocation shapes (`R_X86_64_PC32` at instruction + 3 with addend −4,
`R_X86_64_PLT32` at instruction + 1 with addend −4) match `clang --target=x86_64-linux-musl -c` of
equivalent C, field for field. The suite itself runs: `make test-linux-x86_64`.

The Win64 half was swept the same way (M20): the **967** distinct instructions the machine emits
while compiling `src/mc.mc` for `windows/x86_64` re-assemble byte-identically under
`llvm-mc -triple=x86_64-windows-msvc`, and the 9361 pc-relative displacements it wrote were checked
against `target - (address + length)`. The relocation shapes match
`clang --target=x86_64-windows-msvc -c` of equivalent C: `IMAGE_REL_AMD64_REL32` at instruction + 1
for a `call` and at instruction + 3 for a `lea r, [rip+d32]`, with the in-place field zero and no
addend anywhere ([objects.md](objects.md) § 8). The suite itself runs on the `windows-latest` CI
leg: `make test-windows-x86_64` cross-compiles it.

---

## 3. The float tasks (M24) — specified, not implemented

`f32` and `f64` add their own tasks, with their own register set (`v16..v23` on arm64) and a depth
stack that tracks the type of each depth:

`mf_const(d, bits, width)` · `mf_bin(op, d, d2, width)` · `mf_neg(d, width)` ·
`mf_cmp(cond, d, d2, width)` · `mf_load(width, d, dbase)` · `mf_store(width, d, dbase)` ·
`mf_local_load` · `mf_local_store` · `mf_cvt(from, to, d)` · `mf_arg_move` · `mf_ret` ·
`mf_call_save` · `mf_call_restore`

On arm64 these map to `fmov/fadd/fsub/fmul/fdiv/fcmp/fcvt/scvtf/ucvtf/fcvtzs/fcvtzu/ldr d/str
d/fneg/fabs/fsqrt`; a constant materialises through `movz`/`movk` into an `x` register and then
`fmov d, x`, so there are no literal pools and no relocations. On x86-64 they map to SSE2
(`addsd`, `mulsd`, `ucomisd`, `cvtsi2sd`, `cvttsd2si`, `sqrtsd`). Adding them appends slots and
makes the contract version 3.

## 4. `#machine` — naming the instruction for a task — specified, not implemented

The directive that makes the table teachable from a source file, in the same spirit as `#opcode`:

```
#machine arm64  fadd_f64(rd, rn, rm)  0x1E602800 | (rm << 16) | (rn << 5) | rd
#machine arm64  fsqrt_f64(rd, rn)     0x1E61C000 | (rn << 5) | rd
#machine x86_64 fadd_f64(rd, rn, rm)  bytes(0xF2, 0x0F, 0x58) modrm(rd, rn)
```

- The fixed-width form is a 32-bit word template with parameters, exactly like `#opcode`, and it
  registers an encoder for `task` on `arch` in the table the walker drives.
- The variable-length form for x86 uses a small byte-template language — `bytes(...)`,
  `modrm(reg, rm)`, `rex_w`, `imm32(x)`.
- The general escape is already here: a `.mc` function registered at `user_init` with
  `machine_task(MTASK_X, &f)` over a copy of the table, then `machine("mine", tab)`.
- A module's `#machine` overrides the bundled implementation for that task, and `--dump-machine`
  lists every task per architecture with its origin (`bundled`, or `module file:line`) and the
  bytes it emits for a sample operand set.

---

## 5. What a module can do instead of writing a machine

The other seam is the one in [objects.md](objects.md): call `gen_lower(root)` and replace
`gen_encode_all()` with your own encoder over `gen_ins_at` and `gen_prel_*`. `lib/backend_arm64.mc`
does exactly that and proves the seam is real by producing byte-identical objects — a
*whole-encoder* replacement rather than a per-task one. Both seams are live and neither replaces
the other: a machine changes what instructions are chosen, a backend changes how they are written
out.

What a *runtime* — rather than a backend — may rely on is the register and frame contract in
[objects.md](objects.md) § 4: parameters in `x0..x7` untouched by the prologue, `x0` untouched by
the epilogue, depths in `x9..x15`, scratch in `x8`/`x16`/`x17`, `x18..x28` never written, and the
unconditional `stp x29, x30` frame record. Every machine added here has to keep those or say
plainly that it does not — they are what a `#opcode` syscall wrapper, an atomic and a stack walker
are built on, and `scripts/check-surface.sh` asserts them against `--dump-asm`.

That contract is **per machine**, and the assertions are AArch64's. The x86-64 machine states its
own, in the table above and in [objects.md](objects.md) § 4b: parameters untouched in
`rdi rsi rdx rcx r8 r9`, `rax` untouched by `leave; ret`, depths in `r8..r11`, scratch
`rax`/`rcx`/`rdx`, `rbx` and `r12..r15` never written, an unconditional `push rbp; mov rbp, rsp`
frame record. A runtime written with `#opcode` is bound to one instruction set anyway.
