# objects.md — the object model and the codegen API

Between the AST and the file on disk there is one format-neutral layer: sections, symbols and
relocations in `src/macho.mc`, and a per-function buffer of `Ins` records in `src/gen_arm64.mc`.
Three backends are built on nothing but this — `macho`, `macho-exe` and `elf-obj` — and so is
`lib/backend_arm64.mc`, which reimplements the whole AArch64 encoder from outside and produces
byte-identical objects.

Everything here is an ordinary function. There is no plugin ABI: a backend is a `.mc` module
compiled into the compiler, registered with `backend("name", &f)` ([hooks.md](hooks.md)).

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
still empty when it returns.

The order in which it creates symbols is deliberate and load-bearing — it fixes the symbol table
layout, which is what lets the objects stay byte-identical across refactors.

### `void gen_encode_all()`

Walks the lowered functions, aligns each one to 4, fixes its symbol's value, resolves the labels,
and writes the 32-bit words together with their relocations.

A backend that wants a different encoder calls `gen_lower` and replaces this half — that is
exactly what `lib/backend_arm64.mc` does.

### `void gen_dump_asm()`

Prints the lowered buffer, one function per label. `--dump-asm` is `gen_lower` + this.

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
`I_BLR`, … The whole list is at the top of `src/gen_arm64.mc`; `I_LABEL` marks a label position
and `I_NOP` is erased during the frame fixup and generates no word.

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

| function | lowers |
|---|---|
| `gen_expr(n, depth)` | any expression node into depth register `depth` |
| `gen_value(n, depth)` | an expression where a value is mandatory (rejects `void`) |
| `gen_binary(n, depth)` | `+ - * / % & \| ^ << >>` and the comparisons |
| `gen_logic(n, depth)` | `&&` and `\|\|`, with their short-circuit branches |
| `gen_unary(n, depth)` | `- ~ !` |
| `gen_cast(rd, ty)` | the mask for a narrowing cast |
| `gen_ident(n, depth)` | a name: local, global, or the address of a function |
| `gen_addr(n, depth)` | `&x` |
| `gen_str(n, depth)` | a string literal's address |
| `gen_intrin(n, depth, in)` | `ld8..ld64` / `st8..st64` |
| `gen_call(n, depth)` | a direct call (`bl`), including the spill of live depths |
| `gen_callp(n, depth)` | `callp(p, …)` (`blr x16`) |
| `gen_imm(rd, v)` | a 64-bit immediate as `movz`/`movk`/`movn` |
| `gen_gaddr(rd, sym)` | `adrp` + `add` for a symbol's address |
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
| `gen_globals(unit)` | allocates every global and writes its initializer |
| `gen_sections(unit)` | creates the sections the `#section` directives asked for |
| `gen_encode_one(f)` | encodes one lowered function into its section |

Depth registers are `x9..x15` for depths 0..6; deeper values spill to the frame. `x16` carries
the pointer for `callp`. Locals live at `[sp, #k]`.

---

## 4. Sections

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

## 5. Symbols

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

## 6. Relocations

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

## 7. Writing the file

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

Two things `--exe` does that `.o` + `ld` does not: `&name` for a dylib `extern` works (it points
the `adrp`/`add` at the symbol's stub), and the binary comes out `0755` and signed, ready to run.
One thing it refuses: a relocated pointer inside `__TEXT`, because that segment is `r-x` and
`dyld` will not rebase it.

---

## 8. Writing a backend

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

`lib/backend_arm64.mc` is the worked proof: it registers `arm64-surface`, calls `gen_lower`, and
then reimplements the entire AArch64 encoder in `.mc` — its own opcode tables, its own label
resolution, its own `reloc_add`/`buf_u32` calls — using nothing but the API on this page. The
acceptance criterion, run by `make check-surface`, is that for **every** test in `tests/` the
object it writes is byte-for-byte identical to the built-in backend's.

That is the whole point of this layer: if a backend written from outside can produce the same
bytes, the seam is real.
