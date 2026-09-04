# The object model and the codegen API

Between the AST and the file on disk there is one format-neutral layer: sections, symbols and
relocations in `src/macho.mc`, and a per-function buffer of `Ins` records in `src/gen_walk.mc`.
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
arguments`, `wrong arity in intrinsic`, `callp expects 1 to 8 arguments`, `assignment to array`,
`at most 8 parameters`, `function declared twice`, `declaration does not match prototype`,
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

### Parameters arrive in `x0..x7` and the prologue does not clobber them

At most eight parameters, never one on the stack (`MAXPARAMS`, `at most 8 parameters`). The
prologue is three instructions, then one store per parameter, in declaration order, and it **reads**
the argument registers without writing any of them:

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

### `callp(p, a1..a7)`

The pointer goes to `x16`, the arguments to `x0..x6` — one fewer than a direct call, because `x16`
is taken — and the call is `blr x16`; the result is read from `x0` as `i64`. Live depths are spilled
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

- **Parameters arrive in `rdi rsi rdx rcx r8 r9`** (the seventh and eighth at `[rbp+16]` and
  `[rbp+24]`, pushed by the caller) **and the prologue does not clobber them.** The prologue is
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

`callp(p, a1..a6)` puts the pointer in `rax` and the arguments in `rdi..r9`; a seventh goes on the
stack. `#opcode` writes a raw 4-byte little-endian word wherever it stands, exactly as on AArch64 —
but the words themselves are an instruction set, so a source that uses it is not portable between
the two.

One promise § 4 does **not** make on either machine: nothing is guaranteed about a division whose
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
| `elf-obj` | ELF64 `ET_REL`, `EM_AARCH64` | section names mapped (`__TEXT,__text` → `.text`, `__TEXT,__cstring` → `.rodata`, …), the leading `_` dropped from symbols, `l_strN` → `.LstrN`, and the four relocations mapped to `CALL26`/`ADR_PREL_PG_HI21`/`ADD_ABS_LO12_NC`/`LDST*_ABS_LO12_NC`/`ABS64` |
| `elf-obj-x86_64` | the same file, `EM_X86_64` | `R_X86_64_64` / `PC32` / `PLT32`, addend −4 on both pc-relative kinds because a `rel32` counts from the end of its field |
| `coff-obj-arm64` | COFF, `IMAGE_FILE_MACHINE_ARM64` | `src/backend_coff.mc` (M19): `.text`/`.rdata`/`.data`/`.bss`, alignment as three bits of `Characteristics`, no leading `_` on a symbol, `l_strN` → `$str.N`, and the four relocations mapped to `BRANCH26`/`PAGEBASE_REL21`/`PAGEOFFSET_12A`/`PAGEOFFSET_12L`/`ADDR64`. `TimeDateStamp` is 0 |

### No `.pdata`/`.xdata` (accepted M19 gap)

`coff-obj-arm64` writes no unwind data. Windows on ARM64 has no frame-pointer-walking fallback: the
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

The three writers the core registers itself have exactly this shape and no other: `backend_exe(root, out)`,
`backend_elf(root, out)` / `backend_elf_x86(root, out)` and `backend_coff(root, out)` each name
their machine with `machine_use`, call `gen_lower` and `gen_encode_all`, and then write. An object
backend picks the machine because the file format already records the architecture; a backend that
consumes the AST directly needs none.

`lib/backend_arm64.mc` is the worked proof: it registers `arm64-surface`, calls `gen_lower`, and
then reimplements the entire AArch64 encoder in `.mc` — its own opcode tables, its own label
resolution, its own `reloc_add`/`buf_u32` calls — using nothing but the API on this page. The
acceptance criterion, run by `make check-surface`, is that for **every** test in `tests/` the
object it writes is byte-for-byte identical to the built-in backend's.

That is the whole point of this layer: if a backend written from outside can produce the same
bytes, the seam is real.
