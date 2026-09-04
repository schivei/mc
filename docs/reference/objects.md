# The object model and the codegen API

Between the AST and the file on disk there is one format-neutral layer: sections, symbols and
relocations in `src/objmodel.mc`, and a per-function buffer of `Ins` records in `src/gen_walk.mc`.
Five backends are built on nothing but this — `macho`, `macho-exe`, `elf-obj`, `elf-obj-x86_64`
and `coff-obj-arm64` — and so is `lib/backend_arm64.mc`, which reimplements the whole AArch64
encoder from outside and produces byte-identical objects.

Everything here is an ordinary function. There is no plugin ABI: a backend is a `.mc` module
compiled into the compiler, registered with `backend("name", &f)` ([hooks.md](hooks.md)).

Since M17 the generator is four files, not one. `src/gen_resolve.mc` binds names and types
expressions; `src/gen_walk.mc` walks the AST and knows nothing about registers;
`src/machine_arm64.mc` and `src/machine_x86_64.mc` are the two machines behind the walker's task
table ([machine.md](machine.md)). None of that moved a public name: `gen_lower`, `gen_encode_all`
and every `gen_*` accessor below mean exactly what they meant before.

---

## 1. The two halves of the gen

```c
void backend_macho(i64 unit, uptr out) {
    gen_lower(unit);
    gen_encode_all();
    macho_write(out);
}
```

### `void gen_lower(i64 unit)`

Walks the AST and produces, for every function, a linear buffer of `Ins` records — the same one
`--dump-asm` prints. It also creates the sections, allocates the globals, emits the string
literals into `__TEXT,__cstring`, and creates every symbol. It **encodes nothing**: `__text` is
still empty when it returns. It calls `gen_resolve(unit)` first, which is idempotent, so a backend
that only knows these two halves needs no change.

The order in which it creates symbols is deliberate and load-bearing — it fixes the symbol table
layout, which is what lets the objects stay byte-identical across refactors.

### `void gen_encode_all()`

Walks the lowered functions, aligns each one to 4, fixes its symbol's value, resolves the labels,
and writes the words together with their relocations. How wide an instruction is and how it is
encoded are the machine's answers (`MTASK_INS_SIZE`, `MTASK_ENCODE`, `MTASK_RELOC_KIND`); the
label pass, the section placement and `reloc_add` are not.

A backend that wants a different encoder calls `gen_lower` and replaces this half — that is
exactly what `lib/backend_arm64.mc` does.

### `void gen_dump_asm()`

Prints the lowered buffer, one function per label. `--dump-asm` is `gen_lower` + this.

---

## 1b. `gen_resolve` — names and types, before any instruction

```c
void gen_resolve(i64 unit);
```

Runs before `gen_lower` (which calls it) and answers, for every node, what a name resolved to and
what type an expression has. Until M17 both were side effects of AArch64 instruction selection —
18 `set_nd_type` calls scattered through the walk — which meant a backend that did not want that
walk could not get the answers. A backend that consumes the AST directly calls `gen_resolve(unit)`
and never calls `gen_lower` at all.

The answers go into a **side table indexed by node**, never into a node field: `ND_SIZE` stays 104
and `--dump-ast` does not move. Out-of-range nodes — one a module built itself, or one a `#opcode`
template folded after the table was sized — answer neutrally rather than faulting.

| function | returns |
|---|---|
| `i64 res_type(i64 n)` | the resolved type of an expression node (`TY_*`), `TY_VOID` when it has none |
| `i64 res_kind(i64 n)` | what the name bound to: `RK_NONE`, `RK_LOCAL`, `RK_GLOBAL`, `RK_FUNC`, `RK_INTRIN`, `RK_OPCODE` |
| `i64 res_decl(i64 n)` | the index in the table `res_kind` names — a local, a global, a signature, an `IN_*` id or a `#opcode` |
| `i64 res_local_slot(i64 n)` | `res_decl` when the node binds a local, else `-1` |
| `i64 res_bind(i64 n)` | the same binding as one number: local `i`, `-(global + 1)`, or `RES_FN + function` |
| `i64 res_intrin(i64 n)` | the `IN_*` id of an `N_CALL`, or `IN_NONE` |
| `i64 res_addr_taken(i64 n)` | 1 when the DECLARING node — an `N_PARAM`, `N_VAR`, `N_FUNC` or `N_EXTERN` — is the operand of some `&` |
| `i64 res_fn_addr_taken(i64 fi)` | the same question about function `fi`, by signature index |

An `N_VAR` binds itself: `res_local_slot` of the declaration is the index the local is about to
take, which is how a consumer goes from a declaration to its slot without walking the body again.

A local's index is its position in the function's flat local stack **at that point in the walk**.
Two sibling blocks reuse the same index for different locals — the names disappear at a closing
brace, the frame slots do not — which is why `res_addr_taken` is keyed by the declaring node and
not by that index. `gen_walk.mc` builds its own local table in exactly the same order, so the index
is a direct subscript into it and nothing searches by name during lowering.

`gen_resolve` also owns the two module-wide name tables: the signatures (`func_find`, `func_add`,
`fs_*`) and the globals (`global_find`, `global_add`, `glb_*`), with `GLB_SYM` filled in later by
`gen_globals` when it places the data. Every diagnostic that is about a name rather than about an
instruction is raised here — `unknown name`, `call to unknown function`, `wrong number of
arguments`, `wrong arity in intrinsic`, `callp expects 1 to 12 arguments`, `assignment to array`,
`at most 12 parameters`, `function declared twice`, `declaration does not match prototype`,
`prototype with no definition`, `global name declared twice` — in the order `gen_lower` raised
them: signatures, then globals, then each body.

---

## 2. Reading what `gen_lower` produced

| function | returns |
|---|---|
| `i64 gen_func_count()` | how many functions were lowered |
| `uptr gen_func_name(i64 f)` | the function's symbol name (`_name`) |
| `i64 gen_func_sec(i64 f)` | the section index it belongs to |
| `i64 gen_func_sym(i64 f)` | its symbol index, for `sym_set_value` |
| `i64 gen_func_labels(i64 f)` | how many labels the function used |
| `i64 gen_ins_count(i64 f)` | how many instructions it holds |
| `uptr gen_ins_at(i64 f, i64 i)` | instruction `i` of function `f`, as an `Ins` record |
| `i64 gen_prel_count(i64 f)` | how many raw `reloc()` relocations the function carries |
| `i64 gen_prel_ins(i64 f, i64 k)` | which instruction the k-th one attaches to |
| `i64 gen_prel_sym(i64 f, i64 k)` | its symbol index |
| `i64 gen_prel_type(i64 f, i64 k)` | its relocation type |
| `i64 gen_global_count()` | how many globals were allocated |
| `i64 gen_global_sym(i64 g)` | the symbol index of global `g` |
| `i64 gen_str_count()` | how many string literals were emitted |
| `i64 gen_str_sym(i64 s)` | the symbol index of literal `s` (`l_strN`) |

An `Ins` record is read with the accessors `ins_op`, `ins_rd`, `ins_rn`, `ins_rm`, `ins_imm`,
`ins_label`, `ins_sym` (and written with the matching `set_ins_*`). `ins_op` is one of the `I_*`
constants — `I_LABEL`, `I_MOVZ`, `I_ADD`, `I_BL`, `I_ADRP`, `I_ADDLO`, `I_LDR`, `I_EMIT`,
`I_BLR`, … The whole list is at the top of `src/machine_arm64.mc`; `I_LABEL` is opcode 0, belongs
to `src/gen_walk.mc` and marks a label position, and `I_NOP` is erased during the frame fixup and
generates no word. The `Ins` record itself is machine-neutral — the x86-64 machine fills the same
seven fields with its own `X_*` opcodes, which start at 1 for the same reason (`I_LABEL` is the
walker's) and are read with the same accessors. Which vocabulary an `Ins` holds is whichever
machine was in effect when `gen_lower` ran.

```c
// walking everything a backend has to encode
i64 f = 0;
while (f < gen_func_count()) {
    i64 i = 0;
    while (i < gen_ins_count(f)) {
        uptr e = gen_ins_at(f, i);
        if (ins_op(e) == I_BL) { /* a call to ins_sym(e) */ }
        i = i + 1;
    }
    f = f + 1;
}
```

---

## 3. The lowering functions

`gen_lower` is a plain recursive walk, and every step of it is a named function. A module rarely
calls these directly — they are listed because they *are* the public surface of the file, and
because a backend that wants to lower one construct differently needs to know where the seam is.
Everything down to `gen_encode_one` lives in `src/gen_walk.mc` and emits nothing itself: it calls
machine tasks ([machine.md](machine.md)). The last three — `gen_imm`, `gen_gaddr` and `gen_cast` —
are AArch64 and live in `src/machine_arm64.mc`.

| function | lowers |
|---|---|
| `gen_expr(n, depth)` | any expression node into depth register `depth` |
| `gen_value(n, depth)` | an expression where a value is mandatory (rejects `void`) |
| `gen_binary(n, depth)` | `+ - * / % & \| ^ << >>` and the comparisons |
| `gen_logic(n, depth)` | `&&` and `\|\|`, with their short-circuit branches |
| `gen_unary(n, depth)` | `- ~ !` |
| `gen_cast(rd, ty)` | the mask for a narrowing cast (arm64) |
| `gen_ident(n, depth)` | a name: local or global, read through `res_kind`/`res_decl` |
| `gen_addr(n, depth)` | `&x` |
| `gen_str(n, depth)` | a string literal's address |
| `gen_intrin(n, depth, in)` | `ld8..ld64` / `st8..st64` |
| `gen_call(n, depth)` | a direct call (`bl`), including the spill of live depths |
| `gen_callp(n, depth)` | `callp(p, …)` (`blr x16`) |
| `gen_imm(rd, v)` | a 64-bit immediate as `movz`/`movk`/`movn` (arm64) |
| `gen_gaddr(rd, sym)` | `adrp` + `add` for a symbol's address (arm64) |
| `gen_word(n, w)` | one raw 32-bit word, with the pending `reloc()` if any |
| `gen_emit(n)` | the `emit()` intrinsic |
| `gen_opcode(n, oi)` | a `#opcode` call: folds the template and emits the word |
| `gen_reloc(n)` | the `reloc()` intrinsic: records the pending relocation |
| `gen_stmt(n, lepi)` | any statement (`lepi` is the function's epilogue label) |
| `gen_var(n)` | a local declaration |
| `gen_assign(n)` | an assignment statement |
| `gen_if(n, lepi)` | `if` / `else` |
| `gen_loop(n, lepi)` | `loop`, `break N` and `continue` |
| `gen_func(f, text)` | one function: prologue, body, epilogue, frame fixup |
| `gen_globals(unit)` | places every global, writes its initializer and fills in its symbol |
| `gen_sections(unit)` | creates the sections the `#section` directives asked for |
| `gen_encode_one(f)` | encodes one lowered function into its section |

Depth registers are `x9..x15` for depths 0..6; deeper values spill to the frame. `x16` carries
the pointer for `callp`. Locals live at `[sp, #k]`. All three sentences are the arm64 machine's
policy, not the walker's — see [machine.md](machine.md) for what each side owns, and for the
x86-64 machine's answers to the same three questions (`r8..r11`, `rax`, `[rbp - k]`).

---

## 4. The ABI the generated code guarantees

`gen_lower` is not only an implementation: a **taught runtime** — a syscall wrapper written with
`#opcode`, an atomic, a thread entry point handed out as `&f`, a debugger walking frames — depends
on the register and frame conventions below, and violating one of them fails at run time with no
diagnostic at all. They are written down here so that a change to the code generator is a change to
a documented contract, and `scripts/check-surface.sh` asserts every claim on this page against
`--dump-asm`, one function at a time.

### Parameters 1..8 arrive in `x0..x7` and the prologue does not clobber them

At most twelve parameters (`MAXPARAMS`, `at most 12 parameters`); the first eight in `x0..x7`, the
rest on the stack. The prologue is three instructions, then one store per parameter, in declaration
order, and it **reads** the argument registers without writing any of them:

```
_abi8:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #64
  str x0, [sp, #56]
  ...
  str x7, [sp]
```

That is what lets `lib/sys_svc.mc` write a whole syscall as two `#opcode` words: when
`write(i64 fd, uptr buf, i64 n)` reaches its first body instruction, `x0`, `x1` and `x2` still hold
the caller's arguments, and only `x16` has to be set.

### Parameters 9..12 arrive on the stack, at `[x29 + 16 + 8*(i-8)]`

M38 raised `MAXPARAMS` from 8 to 12 so that a Windows-hosted compiler could declare
`CreateProcessA`, which takes ten ([M38](../specs/M38.md) § 1). The **callee** reads the extra ones
just above its own frame record — `[x29, #16]` is the ninth, `[x29, #24]` the tenth, and so on —
because `stp x29, x30, [sp, #-16]!` is what moved `sp` by 16, so `x29 + 16` is the caller's `sp`.
Each is loaded through `x16` and stored into its slot with the parameter's own width, exactly as a
register parameter is:

```
_abi12:
  ...
  str x7, [sp, #32]
  ldr x16, [x29, #16]      // the ninth
  str x16, [sp, #24]
  ldr x16, [x29, #40]      // the twelfth
  str x16, [sp]
```

The **caller** leaves them at `[sp, #0]`, `[sp, #8]`, … — the bottom of its own frame — and writes
them **before** it fills `x0..x7`, so the stores can still read the depth registers and use `x16` to
carry a spilled one. Those bytes are part of the frame, not a `sub sp` around the call: every slot
is addressed through the fictitious `REG_FRAME` base that `fix_frame()` turns into `sp + (frame -
off)` only at the end of the function, so an `sp` that moved inside the body would make every
spilled depth read the wrong address. `a64_frame_fix` adds the outgoing area (16 or 32 bytes,
always a multiple of 16) to the frame, which keeps the lowest `slot_new()` offset above it. A
function that never passes more than eight arguments reserves nothing and its frame is byte for byte
what it was before M38.

The frozen C seed keeps `MAXPARAMS 8` and refuses a thirteenth… and a ninth: `stage0` only ever
compiles `src/mc.mc`, which has no function with more than eight parameters. That is why
`tests/mc/080-twelve-params.mc` lives in `tests/mc/` — the four cross-checks that compare `mc0` with
`mc1` over `tests/*.mc` would otherwise report the divergence as a failure. It runs on all five
targets: macOS, `linux/{aarch64,x86_64}` and `windows/{arm64,x86_64}`.

### The epilogue leaves `x0` alone

The epilogue is `add sp, sp, #F` (absent when `F == 0`), then exactly `ldp x29, x30, [sp], #16` and
`ret`. None of the three touches `x0`, so a function whose body ends without a `return` hands back
whatever `x0` holds — how `svc` returns the kernel's value, and how an `#opcode` sequence returns a
result the compiler never materialised.

### A zero-parameter, zero-local function has `frame == 0`

The frame is `(frame_off + 15) & ~15`; when it comes out 0 the `sub`/`add sp` pair becomes `I_NOP`
and no word is emitted for it. The `stp`/`ldp` pair is **always** emitted, even for a leaf: the frame
record is unconditional, which is what makes a stack walk possible.

```
_abileaf:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  movz x9, #7
  mov x0, x9
  b L1
L1:
  ldp x29, x30, [sp], #16
  ret
```

`sp` is 16-byte aligned at every instruction, and a frame over 4095 bytes is `frame too large`.

### The register partition

| registers | role |
|---|---|
| `x0..x7` | arguments in, `x0` the result out |
| `x8` | scratch, used only for the quotient of `%` (`REG_TMP`) |
| `x9..x15` | expression depths 0..6 (`REG_BASE 9`, `REG_MAX 6`) |
| `x16`, `x17` | spill scratch (`REG_S1`/`REG_S2`), and `x16` carries the pointer of `callp` |
| `x18..x28` | **never written, never read** |
| `x29`, `x30` | frame pointer and link register, saved and restored by every function |
| `sp` | the frame; locals live at `[sp, #k]` |

Depth 7 and beyond spills to the frame through `x16`/`x17`. `x18..x28` are the callee-saved half of
the ABI that generated code never uses: `--dump-asm src/mc.mc` is 58 355 lines and mentions none of
them. A taught runtime may therefore keep state in `x19..x28` across generated code — a coroutine
switch, a thread pointer — and a future register allocator that spent them would silently break
every such runtime, which is exactly why the claim is written down and tested.

### `callp(p, a1..a11)`

The pointer goes to `x16`, the arguments follow the ordinary rule — `x0..x7`, then the outgoing
area — because the callee is an ordinary function and reads them where a `bl` would have left them.
`x16` is not an argument register, so `callp` carries one argument fewer than `MAXPARAMS`, not one
fewer per register. The call is `blr x16`; the result is read from `x0` as `i64`. Live depths are spilled
around it exactly as they are around a `bl`.

```
  mov x16, x9          // the pointer
  mov x0, x10          // the first argument
  blr x16
  mov x9, x0           // the result
```

An mc `uptr f(uptr)` is therefore a C `void *(*)(void *)`: one integer in, one out, no shim.

### `#opcode` names registers, the compiler allocates none

An `#opcode` word folds to one raw 32-bit instruction whose operands are **constants**
(`#opcode argument not constant`); the register numbers in it are written by the author, not chosen
by the compiler. The rule that makes such a word usable is the one above: the compiler emits it
where it stands, between the prologue's parameter stores and whatever follows, and never inserts an
instruction of its own in the middle. A sequence that must not be interrupted therefore has to fit
in **one** function body — splitting an `ldxr`/`stxr` pair across two one-word `#opcode` functions
puts a frame store and a `ret` between them.

---

## 4b. The same contract on x86-64

§ 4 is the AArch64 machine's contract, and `scripts/check-surface.sh` asserts it against
`--dump-asm` on the host. The x86-64 machine (M17 step B) makes the same four promises in its own
register vocabulary; they are written here for the same reason — a taught runtime depends on them
and nothing would diagnose a violation.

- **Parameters arrive in `rdi rsi rdx rcx r8 r9`** (the seventh and later at `[rbp+16]`,
  `[rbp+24]`, … up to the twelfth, pushed by the caller) **and the prologue does not clobber them.** The prologue is
  `push rbp; mov rbp, rsp; sub rsp, N`, then one store per parameter in declaration order.
- **The epilogue leaves `rax` alone.** It is exactly `leave; ret`, so a body that ends without a
  `return` hands back whatever `rax` holds.
- **The frame record is unconditional.** `push rbp; mov rbp, rsp` is emitted even for a leaf; only
  the `sub rsp, N` disappears when `N == 0`. `rsp` is 16-byte aligned at every `call`.
- **The register partition.**

| registers | role |
|---|---|
| `rdi rsi rdx rcx r8 r9` | arguments in, `rax` the result out |
| `rax` | spill scratch (left/destination), the `callp` pointer, the quotient of `idiv`/`div` |
| `rcx` | spill scratch (right), and the count of every shift |
| `rdx` | the remainder of `idiv`/`div`; zeroed before an unsigned one |
| `r8..r11` | expression depths 0..3 |
| `rbx`, `r12..r15` | **never written, never read** — the callee-saved half |
| `rbp` | the frame pointer; locals live at `[rbp - k]` |
| `rsp` | moved only by the prologue, the epilogue and the two-slot argument area of a call |

Depth 4 and beyond spills to the frame through `rax`/`rcx`. The `frame too large` limit (4095
bytes) is AArch64's 12-bit immediate and x86 has no such bound, but the walker keeps it so the
diagnostic is the same on every target.

`callp(p, a1..a11)` puts the pointer in `rax` and the arguments in `rdi..r9`; a seventh and later go
on the stack, through the same `x86_push_args` a direct call uses. `#opcode` writes a raw 4-byte little-endian word wherever it stands, exactly as on AArch64 —
but the words themselves are an instruction set, so a source that uses it is not portable between
the two.

---

## 4c. The same contract on x86-64, Win64

`windows/x86_64` uses the same x86-64 machine through a second task table, `x86_64-win` (M20). Every
encoder, the size task, the dump and the two relocation tasks are shared with § 4b; what changes is
the calling convention, and it changes in exactly five places
([machine.md](machine.md) § The x86-64 implementation).

- **Parameters arrive in `rcx rdx r8 r9`**, and the fifth and later (up to the twelfth) at
  `[rbp+48]`, `[rbp+56]`, … —
  16 bytes for the saved `rbp` and the return address, plus the 32 bytes of **shadow space** the
  caller reserved below them. The prologue does not clobber them; it is the same
  `push rbp; mov rbp, rsp; sub rsp, N` followed by one store per parameter in declaration order.
- **The caller reserves 32 bytes of shadow space below the arguments** before every `call`, and
  gives them back with the stack arguments in one `add rsp, N` afterwards. `rsp` is 16-byte aligned
  at the `call`: `8*np + 32` is `0 mod 16` exactly when `np`, the number of stack arguments, is
  even, which is the same "pad 8 when the count is odd" rule § 4b already had.
- **The epilogue leaves `rax` alone**, and **the frame record is unconditional** — unchanged.
- **The register partition** is unchanged from § 4b except for the argument column: `rax`, `rcx`,
  `rdx` and `r8..r11` are volatile in both ABIs, so the depths stay in `r8..r11` and the scratch
  stays `rax`/`rcx`/`rdx`. `rdi` and `rsi` become callee-saved on Win64 and the machine simply
  stops naming them — they appear only in the System V argument table.

| registers | role |
|---|---|
| `rcx rdx r8 r9` | arguments in, `rax` the result out; the fifth and later on the stack above the shadow space |
| `rax` | spill scratch (left/destination), the `callp` pointer, the quotient of `idiv`/`div` |
| `rcx` | spill scratch (right), and the count of every shift |
| `rdx` | the remainder of `idiv`/`div`; zeroed before an unsigned one |
| `r8..r11` | expression depths 0..3 |
| `rbx`, `rsi`, `rdi`, `r12..r15` | **never written, never read** — the callee-saved half |
| `rbp` | the frame pointer; locals live at `[rbp - k]` |
| `rsp` | moved only by the prologue, the epilogue and the argument area of a call |

**`r8` and `r9` are argument registers 3 and 4 and depth registers 0 and 1 at the same time, and
that is safe.** The argument table is written in **ascending** index, and each depth register's own
argument index is smaller than its position in the table: `argreg[2]` is `r8`, the register of depth
0, whose index is `-dbase <= 0 < 2`; `argreg[3]` is `r9`, depth 1, index `1 - dbase <= 1 < 3`. So
the source has always been consumed before the destination is written. For `callp` the pointer
moves to `rax` before any argument register is touched, because it may itself be living in
`r8..r11`, and the same argument then holds with `dbase + 1`. `tests/windows/071-nested-args.mc`
makes it executable rather than only written down; `tests/windows/072-six-params.mc` does the same
for the shadow space and the `[rbp+48]` offsets, against a real seven-argument kernel32 call.

The `callp` pointer, `#opcode`, the `frame too large` bound and the division caveats are all
exactly as § 4b states them.

---

## The division caveat

One promise § 4 does **not** make on any machine: nothing is guaranteed about a division whose
divisor is zero, or about `INT64_MIN / -1`. `x86_divmod` emits `cqo; idiv r` and
`xor edx, edx; div r` with no check, so both cases raise `SIGFPE` and kill the process, where
AArch64's `sdiv`/`udiv` answer `0`, `x` and `INT64_MIN` without trapping. That divergence is the
ISA's and is documented rather than guarded —
[../core-language.md](../core-language.md) § "Division by zero, and `INT64_MIN / -1`".

---

## 5. Sections

A `Section` is a flat record: two inline 16-byte names, flags, alignment (log2), an inline
buffer, a zerofill size, and the relocation array.

| function | meaning |
|---|---|
| `i64 sec_new(uptr seg, uptr sect, i64 flags, i64 align)` | find or create a section; returns its index. Names are zero-padded to 16 bytes |
| `i64 sec_find(uptr seg, uptr sect)` | index, or -1 |
| `uptr sec_at(i64 i)` | the record for index `i` |
| `uptr sec_seg(uptr s)` · `uptr sec_sect(uptr s)` | the two inline names (16 bytes, possibly without a NUL) |
| `uptr sec_data(uptr s)` | the inline buffer — write into it with `buf_u8/u16/u32/u64`, `buf_put`, `buf_pad` |
| `i64 sec_flags(uptr s)` · `void set_sec_flags(uptr s, i64 v)` | the Mach-O section flags word |
| `i64 sec_align(uptr s)` · `void set_sec_align(uptr s, i64 v)` | alignment, as log2 |
| `i64 sec_zsize(uptr s)` · `void set_sec_zsize(uptr s, i64 v)` | size when `S_ZEROFILL`: counted, never written to the file |
| `uptr sec_rel(uptr s)` · `void set_sec_rel(uptr s, uptr v)` | the relocation array |
| `i64 sec_nrel(uptr s)` · `void set_sec_nrel(uptr s, i64 v)` | how many relocations it holds |
| `i64 sec_relcap(uptr s)` · `void set_sec_relcap(uptr s, i64 v)` | the array's capacity |

The parser keeps its own pending list of what `#section` asked for, so that sections are created
in a fixed order at lowering time rather than in parse order:

| function | meaning |
|---|---|
| `i64 sec_pending()` | how many `#section` entries the parser recorded |
| `i64 sec_ent(uptr seg, uptr sect, i64 flags, i64 align)` | find or add a pending entry; returns its index |
| `i64 sec_make(i64 i)` | turn pending entry `i` into a real section (`sec_new`) |

The four sections the core itself uses are `__TEXT,__text` (flags `0x80000400`),
`__TEXT,__cstring` (`S_CSTRING_LITERALS`), `__DATA,__data` and `__DATA,__bss` (`S_ZEROFILL`).

---

## 6. Symbols

A `Symbol` is `(name, sect, value, global)`, where `sect` is 1-based and `0` means undefined.

| function | meaning |
|---|---|
| `i64 sym_new(uptr name, i64 sect, i64 value, i64 global)` | find or create. Defining a name that is already defined is `duplicate symbol`; defining one that exists as undefined fills it in |
| `i64 sym_ref(uptr name)` | find, or create as **undefined external** — how an `extern` enters |
| `i64 sym_find(uptr name)` | index, or -1 |
| `uptr sym_at(i64 i)` | the record for index `i` |
| `uptr sym_name(uptr s)` · `void set_sym_name(uptr s, uptr v)` | the name, with the leading `_` already applied |
| `i64 sym_sect(uptr s)` · `void set_sym_sect(uptr s, i64 v)` | 1-based section, 0 = undefined |
| `i64 sym_value(uptr s)` · `void set_sym_value(uptr s, i64 v)` | the offset inside the section |
| `i64 sym_global(uptr s)` · `void set_sym_global(uptr s, i64 v)` | external or local |
| `void sym_set_value(i64 sym, i64 value)` | set the value by index. A function's address only exists after encoding: `gen_lower` creates the symbol (fixing the symtab order) and `gen_encode_all` fills the value in |
| `i64 sym_class(uptr s)` | 0 = local, 1 = defined external, 2 = undefined |
| `void sym_order(uptr order, uptr pos, uptr count)` | the final symbol table order: a **stable partition** into locals, defined externals and undefined, writing the permutation into `order`, the inverse into `pos`, and the three counts into `count` |

`sym_order` is not an optimisation — `LC_DYSYMTAB` requires exactly that grouping, and ELF
requires the same one for `sh_info`. It is a stable partition and never a sort, because a sort
would make the output depend on something other than creation order
(`docs/determinism.md`, rule 2). `src/backend_elf.mc` reuses it verbatim.

`void dump_syms()` prints the sections in creation order and the symbols in the final order; that
is what `--dump-syms` is.

---

## 7. Relocations

```c
void reloc_add(i64 sec, i64 off, i64 sym, i64 type, i64 pcrel, i64 len);
```

Appends a relocation to section `sec`: at byte offset `off`, against symbol `sym`, of kind
`type`, with `pcrel` and `len` as Mach-O defines them (`len` is a log2 of the size: 2 for a
4-byte word, 3 for an 8-byte pointer). The array doubles on demand.

The core emits exactly four kinds:

| name | value | used by | size |
|---|---|---|---|
| `BRANCH26` | 2 | `bl` | 4 bytes, pc-relative |
| `PAGE21` | 3 | `adrp` | 4 bytes, pc-relative |
| `PAGEOFF12` | 4 | the `add`/`ldr`/`str` after an `adrp` | 4 bytes |
| `UNSIGNED` | 0 | a pointer in `__data` | 8 bytes |

`ADDEND` (10) precedes one of them when there is an addend. Relocations are emitted in decreasing
address order in the Mach-O file, and in increasing order in ELF; both come out of the same array,
because the encoder already appends them in order.

`reloc(TYPE, "sym")` in a source ([directives.md](directives.md)) is the surface form of this,
restricted to the three 4-byte kinds.

---

## 8. Writing the file

`void macho_write(uptr path)` writes the `MH_OBJECT`. Every field goes out byte by byte in
little-endian through `buf_u8/u16/u32/u64` — never a struct write — which is what makes the
writer transliterate 1:1 into a language with no `struct`, and what makes the output identical on
any host.

The other two backends are the same idea with a different envelope:

| backend | writes | notes |
|---|---|---|
| `macho` | `MH_OBJECT` for `ld` | the default |
| `macho-exe` | ad-hoc signed `MH_EXECUTE` | does what `ld` did: segment layout on 16 KiB pages, its own resolution of the four relocations, `__TEXT,__stubs` + `__DATA,__got` per imported symbol with bind opcodes, rebase entries for every `UNSIGNED`, 13 load commands, and a `CS_CodeDirectory` with SHA-256 per 4 KiB page |
| `elf-obj` | ELF64 `ET_REL`, `EM_AARCH64` | section names mapped (`__TEXT,__text` → `.text`, `__TEXT,__cstring` → `.rodata`, …), the leading `_` dropped from symbols, `l_strN` → `.LstrN`, the four relocations mapped to `CALL26`/`ADR_PREL_PG_HI21`/`ADD_ABS_LO12_NC`/`LDST*_ABS_LO12_NC`/`ABS64`, and one section that is not a module section: `.note.GNU-stack` (below) |
| `elf-obj-x86_64` | the same file, `EM_X86_64` | `R_X86_64_64` / `PC32` / `PLT32`, addend −4 on both pc-relative kinds because a `rel32` counts from the end of its field |
| `elf-exe` | dynamic ELF64 `ET_EXEC`, `EM_AARCH64` | `src/backend_elf_exe.mc` (M42): [§ 8b](#8b-the-elf-executable-elf-exe-and-elf-exe-x86_64) |
| `elf-exe-x86_64` | the same file, `EM_X86_64` | same writer, `ee_em` selects the machine, the page size, the PLT shape and the `JUMP_SLOT` number |
| `coff-obj-arm64` | COFF, `IMAGE_FILE_MACHINE_ARM64` | `src/backend_coff.mc` (M19): `.text`/`.rdata`/`.data`/`.bss`, alignment as three bits of `Characteristics`, no leading `_` on a symbol, `l_strN` → `$str.N`, and the four relocations mapped to `BRANCH26`/`PAGEBASE_REL21`/`PAGEOFFSET_12A`/`PAGEOFFSET_12L`/`ADDR64`. `TimeDateStamp` is 0 |
| `coff-obj-x86_64` | the same file, `IMAGE_FILE_MACHINE_AMD64` | M20: `coff_machine` selects the header value and the relocation table, the way `elf_em` does in the ELF writer. `R_X86_PLT32` and `R_X86_PC32` both become `IMAGE_REL_AMD64_REL32` (`0x0004`) and `R_UNSIGNED` becomes `IMAGE_REL_AMD64_ADDR64` (`0x0001`, **not** ARM64's `0x000E`). The backend names the `x86_64-win` machine as its first statement |

**Why COFF carries no addend where ELF carries −4.** `IMAGE_REL_AMD64_REL32` is defined as the
32-bit relative address from the byte **following** the four-byte field — `S + A - (P + 4)` — where
ELF's `R_X86_64_PC32` computes `S + A - P` from the field's **start**. The −4 that
`elf_rel_addend` writes is exactly that difference, and it is already inside COFF's definition.
The addend `A` is whatever the field holds in place, and mc leaves it zero: both relocated
instructions put their `disp32` at the very end (`call rel32` is `E8` plus four bytes, reloc offset
1; `lea r, [rip+disp32]` is `REX.W 8D modrm` plus four, reloc offset 3), and the encoder writes
`buf_u32(o, 0)` in both. `IMAGE_REL_AMD64_REL32_1..5`, for a field followed by 1..5 further bytes
of immediate operand, are never needed: mc emits no such shape.

### `.note.GNU-stack` in every ELF object (post-M41 review)

Both ELF backends append one section that corresponds to no module section:

```
Name: .note.GNU-stack
Type: SHT_PROGBITS
Flags [ (0x0) ]          no SHF_EXECINSTR, and not even SHF_ALLOC
Size: 0
AddressAlignment: 1
```

which is field for field what `clang --target=aarch64-linux-musl -c` emits for any C file
(checked with `llvm-readobj --sections`). Its absence is not neutral: a toolchain reads it as
"built before the marker existed, assume an executable stack". Measured, same source, one compiler
apart:

| linker | before | after |
|---|---|---|
| GNU ld 2.35.2 (Debian bullseye), x86-64, mc object + musl `crt1.o` | `PT_GNU_STACK RWE` | `PT_GNU_STACK RW` |
| GNU ld 2.38 (Ubuntu 22.04), aarch64, `-nostdlib` | no `PT_GNU_STACK` header at all | `PT_GNU_STACK RW` |
| GNU ld 2.45.1, `ld.lld` 22 | `PT_GNU_STACK RW` (they no longer infer it) | `PT_GNU_STACK RW` |

Nothing mc compiles ever needs an executable stack: the language has no nested function and no
trampoline.

**Where it sits, and why that matters.** A module section's ELF index is its own index plus one and
`st_shndx` is `sym_sect` unchanged ([§ 6](#6-symbols)), so the note is appended **after** every
content section — before the `.rela.*` block, which is indexed by variables computed at that point.
Adding it moved no symbol: `llvm-readobj --symbols` of `src/mc_linux.mc`'s object is identical
before and after, and the only difference in `--relocs` is that `.rela.text`/`.rela.data` are
sections 6 and 7 instead of 5 and 6.

**What the two assertions in `scripts/test-linux.sh` are worth.** They are not the same kind of
check, and the difference matters when reading a green run:

| assertion | what it looks at | fails against a compiler that does not write the note? |
|---|---|---|
| `check_note` | the section's type, flags and size in **every object** | **yes** — this is the regression guard |
| `check_stack` | `PT_GNU_STACK` present and not `X` in **every linked binary** | **no**, not with the linker this script uses |

`scripts/test-linux.sh` and the CI legs link with `ld.lld`, which is one of the linkers in the third
row of the table above: it writes `PT_GNU_STACK RW` whether or not the inputs carry the note.
Measured here with `ld.lld` 22.1.7 on the same source compiled by the two compilers, one commit
apart — the object without the section and the object with it — `llvm-readelf -lW` of the two
linked binaries is **byte-identical**, `GNU_STACK ... RW`. So `check_stack` is an **end-state**
assertion: it states, on whatever linker is in use, the property that actually matters (nothing mc
links has an executable stack). Only `check_note` regresses if the backend stops emitting the
section. The linkers where the note changes the outcome are the older binutils in the first two
rows, which is where the exposure was measured and which this suite does not run against — the
baseline here is the newest toolchains, and old binutils is a reproduction, not a supported target.

## 8b. The ELF executable (`elf-exe` and `elf-exe-x86_64`)

`src/backend_elf_exe.mc` writes a **dynamically linked ELF64 `ET_EXEC`** with no linker, no crt
object and no sysroot — the ELF counterpart of what `macho-exe` did for Mach-O at M11. It is what
fills the executable slot of `linux/aarch64` and `linux/x86_64` in the target registry, so
`mc --exe prog.mc -o prog` works on a Linux host and `mc build` with `kind = "exe"` for a Linux
target needs **no `[linker]` section and no sysroot at all**.

The reason a dynamic executable needs no sysroot is that it needs *names*, not files: the
interpreter path, the `DT_NEEDED` soname, and the symbol names. `scripts/sysroot-linux.sh` fetches
`crt1.o`, `crti.o`, `crtn.o` and `libc.a`; all four exist only to serve a **static** external link,
which `[linker]` still does ([`docs/build.md`](../build.md) § Linux targets).

### The shape

Two decisions, both refusing the optional half of the format:

* **`ET_EXEC` at `0x400000`, not `ET_DYN`.** A PIE would need an `R_*_RELATIVE` dynamic relocation
  for every absolute address in the image; a fixed base needs none, because the writer knows every
  address when it places the segments. **The cost is no ASLR** — a real security property, named
  here and priced as a follow-up, not hidden.
* **`DT_BIND_NOW` + `DF_1_NOW`, no lazy binding.** Every `JUMP_SLOT` is resolved before the entry
  point runs, so a PLT stub is a plain indirect jump through its GOT slot: no PLT0, no resolver
  trampoline, no second GOT reservation, and an import that does not exist fails at load time
  instead of at the first call.

### The layout, in file order

| region | segment | contents |
|---|---|---|
| ELF header, program headers | LOAD r-x | 64 bytes + 56 × `e_phnum` |
| `.interp` | LOAD r-x | the loader path, NUL-terminated; **dynamic only** |
| `.dynsym`, `.dynstr`, `.hash`, `.rela.plt` | LOAD r-x | **dynamic only** |
| the module's `__TEXT` sections | LOAD r-x | `.text`, `.rodata`, and any `#section __TEXT ...` |
| `.plt` | LOAD r-x | one stub per import; **dynamic only** |
| `.text.mcstart` | LOAD r-x | the synthesized entry point; only when the program has no `_start` |
| the module's writable sections | LOAD rw- | `.data`, and any `#section` outside `__TEXT` |
| `.got` | LOAD rw- | exactly one 8-byte slot per import; **dynamic only** |
| `.dynamic` | LOAD rw- | **dynamic only** |
| the module's zerofill sections | LOAD rw- | `.bss`, as the gap between `p_filesz` and `p_memsz` |
| `.symtab`, `.strtab`, `.shstrtab` | — | not loaded, and not read by any loader |
| section headers | — | on 8 |

One `PT_LOAD` per distinct Mach-O segment name, in order of first appearance, exactly as
`macho-exe` groups them: `__TEXT` becomes `PF_R|PF_X` and everything else `PF_R|PF_W`. `#section`
with a segment of its own therefore gets a `PT_LOAD` of its own. Each segment starts on a page in
VM *and* in the file, which is what makes `p_offset ≡ p_vaddr (mod p_align)` hold by construction.

Program headers, in order: `PT_PHDR`, `PT_INTERP`, one `PT_LOAD` per segment, `PT_DYNAMIC`,
`PT_GNU_STACK`. **`PT_GNU_STACK` is `RW` and never `E`** — the executable-side counterpart of the
`.note.GNU-stack` an object carries; without it a loader may fall back to an executable stack.

`p_align` is **64 KiB on aarch64 and 4 KiB on x86-64**. An aarch64 kernel may be configured with
64 KiB pages and would refuse a 4 KiB-aligned image; the M42 § 0 probe measured that a 64 KiB
`p_align` loads and runs unchanged on the 4 KiB kernels available, so aarch64 pays the larger
alignment (a file up to 64 KiB bigger) and x86-64, which has no such configuration, does not.

### The static case is the degenerate case

It is decided by **counting imports**, never by a flag. A program whose undefined-symbol set is
empty — anything built on `lib/sys_linux.mc`, including `tests/linux/070-nolibc.mc` — gets no
`PT_INTERP`, no `PT_DYNAMIC`, no `.dynsym`/`.dynstr`/`.hash`/`.rela.plt`, no PLT and no GOT, and
what comes out is a static executable the kernel runs with no loader involved.

### The entry point

The kernel enters `_start`, not `main`, and there is no `crt1.o` here.

* A program that defines `_start` itself keeps it: `e_entry` is that symbol and nothing is
  synthesized. `#include <sys_linux>` is that case.
* Otherwise the writer emits `.text.mcstart`, seven AArch64 instructions or 34 x86-64 bytes:
  `argc` from `[sp]`, `argv` = `sp + 8`, `envp` = `sp + 16 + 8*argc`, a direct `bl`/`call` to
  `main`, and `exit_group` by **raw syscall** — so the stub costs no import and works in the static
  case too.
* With neither `_start` nor `main`, the writer says
  `no main and no _start: cannot generate an executable`.

Both libcs initialise themselves inside the loader before transferring to the entry point, which is
what makes a crt-less `_start` legitimate: `errno` (thread-local in both), `malloc` and stdio all
work from the first instruction. That is measured, not assumed — `tests/linux/071-errno-malloc.mc`
is the test, and it runs under musl and glibc on both architectures.

### Imports, the PLT and the GOT

Every undefined symbol is an import, in symbol-table creation order. Each gets

* one `.dynsym` entry (`STB_GLOBAL`, `STT_FUNC`, `SHN_UNDEF`, index k + 1), with the compiler's
  leading `_` dropped exactly as the object writer drops it;
* one 8-byte `.got` slot, written zero;
* one `R_AARCH64_JUMP_SLOT` (1026) / `R_X86_64_JUMP_SLOT` (7) in `.rela.plt`, addend 0, pointing at
  that slot;
* one PLT stub — `adrp x16, slot@page ; ldr x17, [x16, #slot@pageoff] ; br x17 ; nop` (16 bytes) or
  `jmp qword ptr [rip + slot] ; int3 ; int3` (8 bytes).

**`JUMP_SLOT` is the only dynamic relocation kind in the file.** A reference to an import resolves,
in place, to its **PLT stub address** — a call, and equally `&write`, which is precisely the
canonical address a linker gives an imported function in a non-PIE executable. There is no
`GLOB_DAT` and no `COPY`: mc has no imported *data*, only imported functions.

`DT_NEEDED` names come from the same two places Mach-O's `LC_LOAD_DYLIB` comes from — `#dylib`
(M12) and `[libs]`/`[externs]` (M14) — with the default library first, the way libSystem is always
ordinal 1. The default and the interpreter path are `[target].libc` and `[target].interp` in
`mc.toml` ([`toml.md`](toml.md#target)), defaulting to musl.

`DT_HASH` and not `DT_GNU_HASH`: the SysV table is nine lines and every loader accepts it, while
`DT_GNU_HASH` is a bloom filter plus sorted buckets for a lookup speed that does not matter at
these symbol counts. `nbucket = nchain = 1 + imports`, a real table rather than the legal
single-bucket one, and the chains are built by prepending, so the arrays are a function of the
names alone.

The `.dynamic` vector, in this order: one `DT_NEEDED` per library, `DT_STRTAB`, `DT_SYMTAB`,
`DT_STRSZ`, `DT_SYMENT`, `DT_HASH`, `DT_PLTGOT`, `DT_JMPREL`, `DT_PLTRELSZ`, `DT_PLTREL` (`DT_RELA`),
`DT_FLAGS` (`DF_BIND_NOW`), `DT_FLAGS_1` (`DF_1_NOW`), `DT_NULL`.

### Relocations, resolved in place

Every reference to a **defined** symbol becomes a final address, with the same four patchers
`macho-exe` uses — they encode instructions, and an instruction has no file format:
`exe_fix_branch26`, `exe_fix_page21`, `exe_fix_pageoff12` (which classifies `add` versus `ldr`/`str`
by the access width in bits 31:30, the same classification `elf_pageoff12` makes for the object) and
a plain `st64` for `R_UNSIGNED`. On x86-64 `R_X86_PC32` and `R_X86_PLT32` are patched as
`target - (field + 4)`, which is why the object writer's −4 addend has no counterpart here.

### Section headers, and why they are written

No loader reads them: `PT_LOAD` and `PT_DYNAMIC` are the whole contract, and the M42 § 0 probe ran
with none. They are written anyway — including a full `.symtab`/`.strtab` with final addresses —
because they cost a few kilobytes and they are what makes `llvm-readelf --sections`,
`llvm-nm`, `llvm-objdump -d` and a debugger's backtrace read an mc binary, and what lets
`--dump-syms` be compared against the file. An undefined symbol stays `SHN_UNDEF` with value 0 in
`.symtab`: honest, rather than aliased to its stub.

### The cross-check

The same discipline as [`docs/macho-notes.md`](../macho-notes.md) § M11: every field was read back with LLVM's tools and
compared against a `ld.lld`-produced binary of the same shape.

```
$ llvm-readelf -h -l -d -r --hash-table --dyn-syms build/t013
Type:                              EXEC (Executable file)
Machine:                           AArch64
Entry point address:               0x4003c0
  PHDR  0x000040 0x0000000000400040 ... R   0x8
  INTERP 0x000190 0x0000000000400190 ... R   0x1
      [Requesting program interpreter: /lib/ld-musl-aarch64.so.1]
  LOAD  0x000000 0x0000000000400000 ... 0x0003dc 0x0003dc R E 0x10000
  LOAD  0x010000 0x0000000000410000 ... 0x0000d8 0x0000d8 RW  0x10000
  DYNAMIC 0x010008 0x0000000000410008 ...            RW  0x8
  GNU_STACK 0x000000 0x0000000000000000 ...          RW  0x10
  0x0000000000000001 (NEEDED)   Shared library: [libc.so]
  0x000000000000001e (FLAGS)    BIND_NOW
  0x000000006ffffffb (FLAGS_1)  NOW
0000000000410000  0000000100000402 R_AARCH64_JUMP_SLOT  0000000000000000 write + 0
HashTable { Num Buckets: 2  Num Chains: 2  Buckets: [0, 1]  Chains: [0, 0] }
```

`GNU_STACK` is `RW`, never `E`. The SysV hash arrays the writer computes are array-identical to
what `ld.lld --hash-style=sysv` produces for a reference binary of the same shape, on both
architectures.

### No `.pdata`/`.xdata` (accepted M19 gap, M20 included)

Neither `coff-obj-arm64` nor `coff-obj-x86_64` writes unwind data. Windows on ARM64 has no frame-pointer-walking fallback: the
OS unwinder (`RtlLookupFunctionEntry` / `RtlVirtualUnwind`) finds a function's frame shape through
the exception directory, a `.pdata` array of `RUNTIME_FUNCTION` records pointing at `.xdata` unwind
codes. `clang --target=aarch64-windows-msvc -c` of a non-leaf function emits both sections; mc emits
neither, for any function — verified with `llvm-readobj --sections` on the two objects for the same
source.

What that costs: a function of mc's has the standard `stp x29, x30, [sp, #-16]!` frame
([§ 4](#4-the-abi-the-generated-code-guarantees)), and with no record for it the unwinder treats it as a leaf whose
return address is still in `x30`. Nothing in the language raises or catches, `/nodefaultlib` links
no C runtime, and a program that only returns an exit code never unwinds — which is why the whole
`windows/aarch64` suite passes without it. It matters the moment something else unwinds *through* an
mc frame: a hardware fault, a `RaiseException` from a Windows API called through `extern`, or a
debugger's stack walk. Emitting it means one `RUNTIME_FUNCTION` per function plus an
`IMAGE_REL_ARM64_ADDR32NB` relocation each, and either the packed form (which cannot describe mc's
prologue when the frame is small enough that MSVC would fold the allocation into the `stp`) or the
full unwind codes — a milestone of its own, not a field of this writer.

x64 Windows is the same gap for the same reason: its unwinding is table-driven too, with no
frame-pointer fallback, and `clang --target=x86_64-windows-msvc -c` emits `.pdata` and `.xdata` for
every non-leaf function. `coff-obj-x86_64` emits neither. What that costs and when it starts to
matter is unchanged from the paragraph above; it is recorded here rather than opened as a second
gap note.

Two things `--exe` does that `.o` + `ld` does not: `&name` for a dylib `extern` works (it points
the `adrp`/`add` at the symbol's stub), and the binary comes out `0755` and signed, ready to run.
One thing it refuses: a relocated pointer inside `__TEXT`, because that segment is `r-x` and
`dyld` will not rebase it.

---

## 9. Writing a backend

```c
// my_backend.mc
void my_write(i64 root, uptr out) {
    gen_lower(root);                 // the AST becomes Ins buffers, sections, symbols
    my_encode();                     // your encoder, over gen_ins_at / gen_prel_*
    macho_write(out);                // or your own writer, over sec_* / sym_* / reloc_add
}

void user_init() {
    backend("mine", &my_write);      // mc --backend=mine prog.mc -o prog.o
}
```

The writers the core registers itself have exactly this shape and no other: `backend_exe(root, out)`,
`backend_elf(root, out)` / `backend_elf_x86(root, out)`,
`backend_elf_exe(root, out)` / `backend_elf_exe_x86(root, out)` and `backend_coff(root, out)` /
`backend_coff_x86(root, out)` each name their machine with `machine_use` — `arm64`, `x86_64`, or
`x86_64-win` for the last — call `gen_lower` and `gen_encode_all`, and then write. An object
backend picks the machine because the file format already records the architecture; a backend that
consumes the AST directly needs none.

`lib/backend_arm64.mc` is the worked proof: it registers `arm64-surface`, calls `gen_lower`, and
then reimplements the entire AArch64 encoder in `.mc` — its own opcode tables, its own label
resolution, its own `reloc_add`/`buf_u32` calls — using nothing but the API on this page. The
acceptance criterion, run by `make check-surface`, is that for **every** test in `tests/` the
object it writes is byte-for-byte identical to the built-in backend's.

That is the whole point of this layer: if a backend written from outside can produce the same
bytes, the seam is real.
