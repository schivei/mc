# Emitting bytes: sections, opcodes, passes and backends

[30-teaching.md](30-teaching.md) changed what the compiler *parses*. This page changes what it
*emits* — from one raw instruction up to a complete replacement of the code generator and the
object writer.

Four escalating levels again:

| level | you write | you control |
|---|---|---|
| 1 | `#section` | where bytes go |
| 2 | `#opcode`, `emit()`, `reloc()` | individual instructions and relocations |
| 3 | `pass(&f)` | the AST, before codegen |
| 4 | `backend("name", &f)` | the whole output |

Levels 1 and 2 are directives and work in every compiler, the frozen C seed included. Levels 3
and 4 are registrations in a taught compiler, exactly like [30-teaching.md](30-teaching.md)'s.

---

## `#section` — where the bytes go

Everything emitted after a `#section` — functions and globals alike — lands there, until the next
one. With no arguments it returns to the defaults: `__TEXT,__text` for code, `__DATA,__data` and
`__DATA,__bss` for globals.

```mc
// expect-exit: 42
#section __DATA __tbl 0 3
u64 tbl[4] = {40, 1, 1, 0};        // real bytes, in __DATA,__tbl

#section __DATA __zt 1 4           // flags 1 = S_ZEROFILL: counted, no file space
u64 zt[2];

#section __TEXT __hot 0x80000400 2
i64 hot(i64 x) { return x + 2; }   // this function lands in __TEXT,__hot

#section                           // back to the defaults
i64 main() {
    st64(zt, ld64(tbl));
    return hot(ld64(zt));
}
```

`FLAGS` is the Mach-O section flags word and `ALIGN` is a log2 (default 3). Confirm with
`mc --dump-syms`, or `otool -l` on the object. On Linux targets the same sections come out as
`.seg.sect` in the ELF ([50-cross-compile.md](50-cross-compile.md)).

Two things are refused: a function in a zerofill section, and an initialised global in one —
both need file bytes that a zerofill section does not have.

---

## `#opcode` — teaching one instruction

An `#opcode` is a 32-bit word template over its parameters. Called with **constant** arguments,
it folds the word and drops it straight into the current function's instruction stream. It is not
a function and it has no symbol; `--dump-asm` shows it as `.word`.

```mc
// expect-exit: 0
// expect-stdout: hi
#opcode mov16(rd, imm) 0xD2800000 | (imm << 5) | rd
#opcode svc(imm)       0xD4000001 | (imm << 5)

#define SYS_WRITE 4

i64 sys_write(i64 fd, uptr buf, i64 n) {
    mov16(16, SYS_WRITE);          // x16 = the syscall number
    svc(0x80);                     // x0..x2 already carry fd, buf, n
}

i64 main() {
    sys_write(1, "hi\n", 3);
    return 0;
}
```

That program calls the kernel with no libc anywhere. It works because of two deliberate
properties of the calling convention: the prologue writes the parameters to the frame **without
touching `x0..x7`**, and the epilogue **does not touch `x0`**. So a function whose whole body is
`#opcode` calls sees its arguments where the ABI put them, and returns whatever the kernel left
in `x0`.

```
$ mc --dump-asm sys.mc
_sys_write:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #32
  str x0, [sp, #24]
  str x1, [sp, #16]
  str x2, [sp, #8]
  .word 0xd2800090
  .word 0xd4001001
L1:
  add sp, sp, #32
  ldp x29, x30, [sp], #16
  ret
```

This is exactly how `<sys_svc>` and `<sys_linux>` are written.

## `emit()` and `reloc()` — what `#opcode` cannot reach

`emit(CONST)` writes one raw word. `reloc(TYPE, "symbol")` attaches a relocation to the **next**
word emitted in the function, with `TYPE` one of `BRANCH26`, `PAGE21`, `PAGEOFF12`, `UNSIGNED`.
An unknown symbol simply becomes an undefined external.

```mc
// expect-exit: 42
i64 helper() { return 42; }

i64 call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);              // a raw bl; the offset comes from the relocation
}

i64 main() { return call_helper(); }
```

`otool -r` on the object shows that relocation next to the one the compiler's own `bl` generated
for the call in `main` — they are the same kind of record, because there is only one mechanism.

`UNSIGNED` is accepted as a constant but **refused here**: it is an 8-byte relocation over a
4-byte word and would overrun the next instruction. An 8-byte address is written as a global
array initializer instead, which puts the relocation where it belongs:

```mc
// expect-error: reloc UNSIGNED requires 8 bytes
i64 main() {
    reloc(UNSIGNED, "_main");
    emit(0x00000000);
}
```

---

## `pass(&f)` — rewriting the AST

A pass is a function `i64 f(i64 root)` registered in `user_init`. Passes run right after the
parse, in registration order, each receiving what the previous returned — and **before** constant
folding and before `--dump-ast`. That ordering is deliberate: a pass sees the tree in the
source's own shape, and folding cleans up whatever it produces.

```c
// lib/pass_demo.mc — rewrite `x * 1` into `x`
i64 pass_mul1(i64 root) {
    i64 n = 1;
    while (n < nnodes) {
        if (nd_kind(n) == N_BINARY && nd_op(n) == K_MUL
            && nd_kind(nd_b(n)) == N_INT && nd_val(nd_b(n)) == 1) {
            i64 keep = nd_next(n);           // the sibling list is not ours to move
            node_assign(n, nd_a(n));
            set_nd_next(n, keep);
        }
        n = n + 1;
    }
    return root;
}

void user_init() { pass(&pass_mul1); }
```

The core does not do this — `fold()` only folds constant against constant — and
`tests/061-pass.mc` shows the difference in `--dump-ast` with and without the module wired in.

A pass is also the answer to "I need a hook the compiler does not have": walking the finished
tree is always available. When what you want is to see each statement *as it is parsed*, use the
per-statement hook instead — `on_stmt(&f)` in
[../reference/hooks.md](../reference/hooks.md#void-on_stmt-uptr-fn-every-statement-core-or-taught).

---

## `backend("name", &f)` — writing the output yourself

A backend is `void f(i64 root, uptr out)`, selected with `--backend=NAME`. Three are registered
before `user_init()` even runs:

| name | writes | alias |
|---|---|---|
| `macho` (default) | `MH_OBJECT`, the `.o` the system linker takes | — |
| `macho-exe` | an ad-hoc signed `MH_EXECUTE`, no `ld` | `--exe` on a macOS host |
| `elf-obj` | ELF64 `ET_REL` for `EM_AARCH64` | — |

An unknown name lists what exists:

```
$ mc --backend=xyz prog.mc -o x.o
unknown backend: xyz
registered: macho macho-exe elf-obj
```

### The seam: `gen_lower` and `gen_encode_all`

The default backend is literally three calls:

```c
void backend_macho(i64 unit, uptr out) {
    gen_lower(unit);        // AST -> per-function Ins buffers, sections, globals, strings, symbols
    gen_encode_all();       // ... and only now, the 32-bit words and their relocations
    macho_write(out);       // the file
}
```

`gen_lower` encodes nothing: when it returns, `__text` is still empty and every symbol exists but
has no value. That is the seam. A backend calls `gen_lower` and replaces either or both of the
other two, reading the lowered form through a handful of accessors:

```c
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

and writes with the object primitives — `sec_new`, `sec_data`, `sym_new`, `sym_ref`,
`sym_set_value`, `reloc_add`, `buf_u32`, `macho_write`. Every one of them is an ordinary
function; the complete list is [../reference/objects.md](../reference/objects.md).

```c
// my_backend.mc
void my_write(i64 root, uptr out) {
    gen_lower(root);
    my_encode();
    macho_write(out);
}

void user_init() { backend("mine", &my_write); }
```

### The proof: `arm64-surface`

`lib/backend_arm64.mc` registers a backend called `arm64-surface` that calls `gen_lower` and then
**reimplements the entire AArch64 encoder in `mc`** — its own opcode tables, its own label
resolution, its own `reloc_add` and `buf_u32` calls — on top of nothing but the public API. The
encoding formulas are the same ones the core uses, copied on purpose: the point is that they are
reachable from outside, not that they are different.

The acceptance criterion, run by `make check-surface`, is byte equality across the whole test
corpus:

```
$ mc --backend=arm64-surface X -o a.o
$ mc                          X -o b.o
$ cmp a.o b.o
32/32 objects identical (arm64-surface vs macho)
```

If a backend written from outside the compiler can produce the same bytes as the one inside it,
the seam is real rather than asserted. That was the whole reason this milestone existed.

`src/backend_exe.mc` — the `--exe` writer — is built the same way, and it is the more convincing
demonstration, because it does what `ld` used to do: segment layout on 16 KiB pages, its own
resolution of the four relocations, `__TEXT,__stubs` and `__DATA,__got` per imported symbol with
`dyld` bind opcodes, rebase entries for every `UNSIGNED`, thirteen load commands, and an ad-hoc
`CS_CodeDirectory` with SHA-256 per 4 KiB page — the SHA-256 itself written in the language, in
`src/sha256.mc`. It is part of the compiler rather than a demo, but it uses no private access at
all.

### What `--exe` does that `.o` + `ld` does not

- **`&name` on a dylib `extern` works.** In the `.o` path `ld` refuses it: an imported symbol
  only has an address through `__got`, and the core does not emit `GOT_LOAD_PAGE21`. In `--exe`,
  `mc` resolves the relocation itself and points the `adrp`/`add` at the symbol's stub.
- **The binary comes out `0755` and signed**, with no link step and no `codesign` step.

And one thing it refuses: a relocated pointer inside `__TEXT`, because that segment is `r-x` and
`dyld` will not rebase it.

---

## The seed is not teachable, and that is the point

`pass()` and `backend()` exist only in the self-hosted compiler. The C seed accepts
`--backend=macho` so the command line stays the same, and nothing else — `--exe` does not exist
there either.

That is not a gap. Tier 2 costs **zero lines of C** precisely because the compiler being taught
is the one written in the language itself. What C had to gain for any of this to work was only
what the *language* needs to express a hook: `&function`, `callp`, and splitting the code
generator into two halves.

## Next

The `elf-obj` backend in action: [50-cross-compile.md](50-cross-compile.md).
