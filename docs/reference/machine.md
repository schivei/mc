# machine.md — the machine task contract

> **Status: specified, not yet implemented.** No `machine*` function exists in `src/` in this
> checkout. The contract below is what `docs/specs/M17.md` (the walker/machine split and the
> x86-64 machine) and `docs/specs/M24.md` (floats and `#machine`) fix, and it is documented here
> so that a module author can see the shape the seam will have. Today there is exactly one code
> generator, `src/gen_arm64.mc`, and it mixes the AST walk with AArch64 instruction selection;
> its public surface is [objects.md](objects.md).

## Why the split exists

`gen_lower` currently does two things at once: it walks the AST (frames, the depth stack, labels,
calls, name resolution) and it selects AArch64 instructions (`I_*` opcodes, `x9..x15` as depth
registers, `x16`/`x17` as scratch). A second instruction set cannot be added without separating
them, and separating them must not change a single byte of the objects the first one produces —
which is why the acceptance criterion is that `check-obj` and `check-asm` stay identical against
the frozen C seed.

After the split:

- **`src/gen_walk.mc`** — the walker. It knows nothing about registers. It owns the depth stack,
  the label counter and the frame layout in bytes, and it drives a **machine table**: one `&fn`
  per task, registered with `machine(name, mtab)` and invoked through `callp`.
- **`src/machine_arm64.mc`** — today's selection and encoders, moved behind that table.
- `gen_encode_all` and the three format writers are unchanged. Each machine supplies its
  `cputype` / `e_machine` and its relocation kinds through the same `Reloc` records.

## The integer tasks (M17)

Every task takes **depth indices**, never registers: the walker says "the value is at depth 2",
and whether depth 2 lives in a register or in a frame slot is the machine's decision.

| task | meaning |
|---|---|
| `m_func_begin(sym)` · `m_func_end()` | open and close a function |
| `m_prologue(frame, nparams)` · `m_epilogue()` | frame set-up and tear-down |
| `m_const(d, imm)` | materialise a constant at depth `d` |
| `m_bin(op, d, d2)` | `add sub mul sdiv udiv smod umod and or xor shl shr sar` |
| `m_un(op, d)` | `not`, `neg` |
| `m_cmp(cond, d, d2)` | a comparison producing 0/1 |
| `m_cast(width, d)` | narrow to 1, 2 or 4 bytes |
| `m_load(width, d, dbase)` · `m_store(width, dval, dbase)` | `ld*` / `st*` |
| `m_local_addr(d, off)` | the address of a frame slot |
| `m_local_load(width, d, off)` · `m_local_store(width, d, off)` | a frame slot |
| `m_global_addr(d, sym)` · `m_str_addr(d, sym)` | a symbol's address |
| `m_call(sym, nargs, …)` | a direct call; arguments are depths `dbase..dbase+nargs-1` |
| `m_callp(dptr, nargs)` | an indirect call |
| `m_ret(d)` | return |
| `m_label(l)` · `m_jump(l)` · `m_jz(d, l)` · `m_jnz(d, l)` | control flow |
| `m_word(imm)` | one raw word, plus any pending relocation — what `emit()` and `#opcode` reach |
| `m_arg_move(d, i)` | move a depth into argument position `i`, where a machine needs it |

The x86-64 machine (`src/machine_x86_64.mc`, M17 step B) implements the same list for the SysV
ABI: depths 0..3 in `r8..r11` with the rest spilled, `rax`/`rcx`/`rdx` as scratch, arguments in
`rdi rsi rdx rcx r8 r9` with the seventh and eighth on the stack, and `R_X86_64_64` / `PC32` /
`PLT32` relocations. `#opcode` is architecture-specific by nature, so tests that use it carry a
`// skip-x86_64` header.

## The float tasks (M24)

`f32` and `f64` add their own tasks, with their own register set (`v16..v23` on arm64) and a
depth stack that tracks the type of each depth:

`mf_const(d, bits, width)` · `mf_bin(op, d, d2, width)` · `mf_neg(d, width)` ·
`mf_cmp(cond, d, d2, width)` · `mf_load(width, d, dbase)` · `mf_store(width, d, dbase)` ·
`mf_local_load` · `mf_local_store` · `mf_cvt(from, to, d)` · `mf_arg_move` · `mf_ret` ·
`mf_call_save` · `mf_call_restore`

On arm64 these map to `fmov/fadd/fsub/fmul/fdiv/fcmp/fcvt/scvtf/ucvtf/fcvtzs/fcvtzu/ldr d/str
d/fneg/fabs/fsqrt`; a constant materialises through `movz`/`movk` into an `x` register and then
`fmov d, x`, so there are no literal pools and no relocations. On x86-64 they map to SSE2
(`addsd`, `mulsd`, `ucomisd`, `cvtsi2sd`, `cvttsd2si`, `sqrtsd`) with arguments in `xmm0..7`.

## `#machine` — naming the instruction for a task

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
- The general escape is a `.mc` function registered at `user_init` with
  `machine_task(arch, "fadd_f64", &f)`.
- A module's `#machine` overrides the bundled implementation for that task, and
  `--dump-machine` lists every task per architecture with its origin (`bundled`, or
  `module file:line`) and the bytes it emits for a sample operand set — so the developer can
  audit what the compiler will actually use.

## What a module can do today instead

Until the split lands, the seam that exists is the one in [objects.md](objects.md): call
`gen_lower(root)` and replace `gen_encode_all()` with your own encoder over `gen_ins_at` and
`gen_prel_*`. `lib/backend_arm64.mc` does exactly that and proves the seam is real by producing
byte-identical objects. That is a *whole-encoder* replacement rather than a per-task one, which
is precisely the gap M17 closes.
