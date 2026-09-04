# surface.md — the teaching surface

Source: `docs/plan.md` § "Teaching surface" and
`docs/specs/M1.md`/`M5.md`/`M5.5.md`/`M9.md`/`M10.md`/`M16.md`/`M21.md`.
State at this milestone (**M16, M21, M21.5, M22 and M23 closed**): `#token`, `#infix`/`#prefix`, `#rule`, `#section`,
`#opcode`, `emit()`/`reloc()` implemented and actually tested with `build/mc0` **and** with the
self-hosted compiler `build/mc1` (the mechanism exists on both sides: `stage0/parse.c` and
`src/parse.mc`). Programmatic Tier 2 (`pass()`/`backend()`) is also **implemented**, but only in
the `.mc` compiler — the C stage0 is the seed and isn't teachable via Tier 2. Tier 3
(`syntax`/`syntax_stmt`/`syntax_expr`/`syntax_infix`, `type_alias`, `on_stmt`, `#dylib`, and M21's record and
replay: `p_skip_balanced`/`p_push_source`/`p_subst_*`/`p_resplit_punct`) is likewise implemented,
`.mc`-only, and proven end to end by `examples/api` and by `lib/user_syntax_demo.mc`. See the
section at the end, which also describes the three built-in backends: `macho` (the `.o`, default),
`macho-exe` (M11's direct executable, alias `--exe`) and `elf-obj` (M16's ELF64 relocatable for
Linux arm64).

## Tier 1 — `#...` directives

Processed at compile time, in order of appearance, mutating the core's tables.

Two of them, `#include <name>` and `#embed`, exist **only in the self-hosted compiler**: the C
seed is frozen and does not have them (`build/mc0` answers `#include expects a string` and
`unknown directive`). That is why their tests live in `tests/mc/` instead of `tests/` — the four
cross-checks that compare `mc0` against `mc1` over `tests/*.mc` are supposed to find no
difference, and these two are a difference on purpose. `scripts/check-mc.sh` runs them with the
self-hosted compiler and asserts that the seed rejects them.

### `#token` — implemented
Registers a new lexeme. Punctuation/operator matching is by longest prefix, scanning the table
linearly (deterministic, rule 1 of `docs/determinism.md`).

```c
#token "<+>"
```

### `#infix` / `#prefix` — implemented
Extend the expression Pratt table. `$1`/`$2` are the operands; the template is parsed right away
by the parser that already exists and becomes an AST with "holes" (`N_HOLE`) — never textual
substitution. Tested (`tests/003-infix.mc`, runs and returns 42):

```c
#token "<+>"
#infix "<+>" 9 left ($1 + $2) * 2
i64 main() { return 10 <+> 11; }   // (10 + 11) * 2 = 42
```

### `#rule` — implemented (M9)
Statement parser: matches a flat pattern against a template. The pattern is a sequence of items,
each one either a **literal token** (any lexeme, including ones created by `#token`) or
`nt $name`, with `nt ∈ { expr, stmt, block, ident }`. The template is **one statement**, parsed by
the normal parser at definition time — the `$name`s become holes right there, so expansion is a
tree copy (`node_copy_subst`), never textual substitution.

```c
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }
```

**Dispatch by token, no backtracking.** The rule table is linear and indexed by the token that
opens the statement; the last rule defined for the same token wins. Once a rule is chosen, every
item has to match — there's no going back. If the literal item is an identifier (`while`, `for`,
`repeat`), it gets registered in the lexer (`tok_add`, a *word* entry) and **becomes a reserved
word** from then on: `i64 while = 1;` after the `#include` is an error
(`tests/err/055-keyword.mc`).

**`ident $x` before the dispatch token.** This is the only case where the pattern's first item
isn't a literal, and it serves compound forms:

```c
#rule stmt: ident $x += expr $e ;   => $x = $x + $e;
#rule stmt: ident $x ++ ;           => $x = $x + 1;
```

Zero-backtracking still holds: when `+=` shows up, the name to its left has **already been read**
as an expression by `parse_stmt`'s normal path, and dispatch happens on the literal token (`+=`,
`++`). After the opening `ident $x`, the next item must be a literal.

**Two kinds of hole.** `expr`/`stmt`/`block` become `N_HOLE` and travel via the tree copy.
`ident $x` and the gensym `$$t` become **names**: in the template they're an `N_IDENT` with a
unique marker, and expansion swaps the marker for the real name. That's what lets `$x` appear
where the AST holds a name rather than a node — the left side of an assignment (`$x = ...`) and a
local declaration (`i64 $$t = ...`).

**Hygiene: gensym only.** `$$name` in the template becomes a new local per expansion, `$g1`,
`$g2`, ... (a global counter, deterministic). The `$` in the name isn't decoration: the lexer
never forms an identifier with `$`, so **no name the user writes can collide with a gensym** — the
capture is impossible by construction, not merely unlikely. (Until M9 the prefix was `__g`, a
legal identifier: `i64 __g1 = 42; mk(1); return __g1;` would return the gensym's value. That's
`tests/056-gensym-nocapture.mc`.) Two expansions of the same rule in the same block also don't
collide — `tests/053-gensym.mc`:

```c
#rule stmt: swap ( ident $a , ident $b ) ;
    => { i64 $$t = $a; $a = $b; $b = $$t; }
```

**The dispatch literal can't be a core keyword.** The types (`u8`..`void`) and the control words
(`if`, `else`, `loop`, `break`, `continue`, `return`, `extern`) are refused with
`cannot redefine core keyword`: a rule opened by `if` would hijack the core's own statement
parser, and nothing else in the file would compile anymore. Punctuation remains free —
`#rule stmt: ident $x [ expr $i ] = expr $e ;` is legitimate, and a new `#token` too.

```
$ build/mc0 hijack.mc -o x.o          # #rule stmt: if ( expr $c ) block $b => ...
hijack.mc:1: cannot redefine core keyword
```

**Two failure modes worth knowing.**

1. *A compound literal needs a `#token` first.* A pattern that opens (or continues) with `+=`
   without a prior `#token "+="` sees no `+=` at all: the lexer hands out `+` and `=`, `+` is
   already infix, and the Pratt parser consumes `a +` looking for the right-hand operand before
   any dispatch happens. The error surfaces far from the cause:

   ```
   $ build/mc0 noplus.mc -o x.o       # #rule stmt: ident $x += expr $e ;  (no #token)
   noplus.mc:3: expression expected
   ```

   With `#token "+="` in front, the same rule works (which is what `lib/prelude.mc` does).

2. *The opening word becomes a keyword for the rest of the unit — even over names already
   declared.* `tok_add` registers the identifier in the lexer's table; from then on it's never a
   `T_IDENT` again. A `repeat` function declared **before** `#rule stmt: repeat ...` stays in the
   `.o` (the symbol `_repeat` exists), but nobody can call it anymore: the call is no longer an
   expression.

   ```
   $ build/mc0 kw2.mc -o x.o          # i64 repeat(...) ...; #rule stmt: repeat ...
   kw2.mc:3: expression expected      #  ... i64 x = repeat(7);
   ```

   It's the same rule as `tests/err/055-keyword.mc`, seen from the other side: there the name is
   declared after the rule, here before. Choose opening words you don't intend to use as names.

**A rule using a rule.** The template is parsed with a parser that already knows the earlier
rules, so `#rule` on top of `while` works naturally, and the expansion happens **at definition
time** (`tests/054-rule-in-rule.mc`). There's no textual re-expansion of the result: infinite
recursion is impossible by construction. Nesting at definition time is capped at 64 levels.

**Out of scope for M9** (decision recorded in `docs/specs/M9.md`): the `#rule expr:` category
(reserved — using it is a clear error) and the `type $t` hole (using `type` in the pattern is the
error `nt \`type\` out of scope for M9`). `type $t` would only be useful for generic declarations
(`type $t ident $x = expr $e;`) and would need a new `N_TYPE` plus the type hole in `parse_var`
and in codegen — more than the "20 lines" the spec allowed. Without `type $t` there's no `struct`,
which is also out of scope for M9.

### `--dump-rules` — implemented (M9)
Lists a source's registered rules, in definition order: the opening token, the items, and the
template's size in nodes. Real output of `build/mc0 --dump-rules tests/053-gensym.mc` (the first
six come from `lib/prelude.mc`, the last from the test itself):

```
rule 0: stmt: while ( expr $1 ) block $2 => 7 nodes
rule 1: stmt: for ( stmt $1 expr $2 ; ident $0 = expr $3 ) block $4 => 11 nodes
rule 2: stmt: ident $0 += expr $1 ; => 4 nodes
rule 3: stmt: ident $0 -= expr $1 ; => 4 nodes
rule 4: stmt: ident $0 ++ ; => 4 nodes
rule 5: stmt: ident $0 -- ; => 4 nodes
rule 6: stmt: swap ( ident $0 , ident $1 ) ; => 7 nodes
```

`ident $N` in the dump is the Nth **name** hole; `expr/stmt/block $N` is the Nth **node** hole.
Rules 2-5 are the `ident $x`-at-the-opening ones: the `ident $0` shown before the literal is the
name already read.

**Since M21 the dump continues with the whole Pratt table** (decision 7.2 of `docs/specs/M21.md`),
in table order — core operators, the ones `#infix`/`#prefix` created and the ones `syntax_infix`
taught, in one place, which is the point of their sharing a table. `template` marks an entry that
came from `#infix`/`#prefix`; `handler` marks one that carries a `syntax_infix` handler:

```
infix || prec 1 left
...
infix % prec 10 left
infix <+> prec 9 left template
prefix -
prefix ~
prefix !
prefix &
```

This half exists only in the self-hosted compiler: the frozen `stage0/parse.c` has no Tier 3 and
therefore no handler column to report. The rules half is still byte-for-byte the same on both.

### `--dump-ast` shows the expanded AST
Expansion happens in the parser, so `--dump-ast` is already post-`#rule`. `while (i < 3) { s += i; i++; }`
with the prelude (real output of `build/mc0 --dump-ast`, trimmed):

```
    LOOP
      BLOCK
        IF
          UNARY op=!
            BINARY op=<
              IDENT type=i64 name=i
              INT val=3 type=i64
          BREAK val=1
        BLOCK
          ASSIGN name=s
            BINARY op=+
              IDENT type=i64 name=s
              IDENT type=i64 name=i
          ASSIGN name=i
            BINARY op=+
              IDENT type=i64 name=i
              INT val=1 type=i64
```

That `!` is what makes the prelude's `while` cost two more instructions per loop test than a
hand-written `loop { if (i >= 3) break; ... }`: the core doesn't simplify `!(a < b)` into `a >= b`
(there's no AST peephole at M9), and the prelude's rule is literally
`loop { if (!$c) break; $b }`. See `docs/core-language.md` § Prelude.

### `#include <name>` — implemented (M15)
A second form of `#include`, served by the **bundle inside the binary** and never by the
filesystem:

```c
#include <sys>            // lib/sys.mc
#include <prelude>        // lib/prelude.mc
#include <lz>             // src/lz.mc
#include <mc/core>        // src/core.mc: the whole compiler minus user_init
```

The lexer does **not** tokenize `<name>` specially — it is `<`, the lexemes of the name and `>`,
put back together by the parser. That is deliberate: `--dump-tokens` stays byte for byte what the
frozen `stage0/lex.c` produces, so `scripts/check-lex.sh` keeps comparing the two lexers over
every source in the repository.

An unknown name is an error and lists nothing else (`unknown bundled include: <name>`); a bundled
file appears in diagnostics under its bundled name (`syntax_demo_test:10: ...`); and a relative
`#include "x"` written *inside* a bundled file is resolved by name in the bundle, which is how
`src/core.mc`'s own `#include "arena.mc"` works identically from `src/` and from `<mc/core>`.
Full description, the manifest and the format: `docs/build.md` § M15.

### `#embed` — implemented (M15)
```c
#embed NAME "path" [lz]
```
Declares `u8 NAME[]` with the file's bytes (or the LZ stream, with `lz`), `#define NAME_size` (the
bytes in the array) and `#define NAME_raw` (the original size). The path resolves like
`#include "x"`, relative to the file that **wrote the directive** — including when that file came
from the bundle, in which case the payload is served by the bundle too and has to be an entry of
`tools/bundle.list` (`tests/mc/073-embed-bundle.mc`). Programs decompress with `<lz>`:

```c
#include <lz>
#embed packed "data.txt" lz
u8 out[8192];
i64 main() { return lz_inflate(packed, packed_size, out, packed_raw); }
```

Ceiling 16 MiB; an empty file is an error. `docs/build.md` § M15 — `#embed`.

**Cost: one AST node (M21.5).** The payload used to become one `N_INT` node per byte — 104 bytes
of arena for every byte of file, which put a hard practical ceiling well under the declared 16 MiB
and is why `src/bundle_data.mc` spells the bundle out as `u64 ... = { ... }` instead of embedding
it. Since M21.5 the initializer is a single `N_BLOB` node holding the address and the length, and
`glob_place` copies the bytes straight into the section. The object is byte for byte what it was;
`--dump-ast` shows `BLOB val=<bytes>` where thousands of `INT` lines used to be. This is what lets
the bundle carry itself as `#embed` (`docs/build.md` § `mc/bundle_data`).

### `lib/prelude.mc` — the surface library
`while`, `for`, `+=`, `-=`, `++`, `--`: six `#rule`s and four `#token`s, 36 lines, entering only
via an explicit `#include`. `src/macho.mc` is the compiler's own first module to use it (M9);
`docs/core-language.md` § Prelude documents the syntax, the `continue` that skips the `for`'s
step, and why the step is `ident $x = expr $step`.

### `#section` — implemented
Placement: sets the destination section for bytes emitted afterward (functions and globals),
until the next `#section`. `#section` with no arguments returns to the default
(`__TEXT,__text` for code, `__DATA,__data`/`__DATA,__bss` for globals). `ALIGN` is a log2 and
defaults to 3 (8 bytes) when omitted. Tested (`tests/030-section.mc`, runs and returns 42;
`otool -l` confirms the sections):

```c
#section __DATA __tbl 0 3
u64 tbl[4];                       // __DATA,__tbl, S_REGULAR — occupies real bytes in the file

#section __DATA __zt 1 4          // flags=1 = S_ZEROFILL: only counts zsize, no file space
u64 zt[2];

#section __TEXT __hot 0x80000400 2
i64 hot(i64 x) { return x + 2; }  // the function goes to __TEXT,__hot

#section                          // no arguments: back to the default
i64 base = 30;                    // __DATA,__data
```

### `#opcode` — implemented
Teaches one instruction. Called with constant arguments (otherwise error
"#opcode argument not constant"), it folds the template with the parameters substituted in and
emits the 32-bit word directly into the current function's code stream (`I_RAW`, `.word` in
`--dump-asm`) — it's not a symbol. This is how `lib/sys_svc.mc` implements the core's five
syscalls (`open/read/write/close/exit`) without depending on libSystem, tested end to end in
`tests/032-svc.mc` (`write(1, "hi\n", 3)` via `svc`, stdout `hi`, exit 0):

```c
// lib/sys_svc.mc
#opcode mov16(rd, imm) 0xD2800000 | (imm << 5) | rd
#opcode svc(imm)       0xD4000001 | (imm << 5)

#define SYS_WRITE 4

i64 write(i64 fd, uptr buf, i64 n) {
    mov16(16, SYS_WRITE);   // x16 = the syscall number; x0..x2 already have fd/buf/n
    svc(0x80);              // enter the kernel; the result ends up in x0 = the return value
}
```

`--dump-asm` of `write`'s body above (actually run):
```
_write:
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
The epilogue doesn't touch `x0`: since the function has no `return`, the return value is whatever
`x0` the `svc` left there — the same promise holds for the prologue (writes the parameters to the
frame without altering `x0..x7`).

### `emit()` / `reloc()` — implemented
Raw bytes and relocations, for what `#opcode` doesn't cover. `emit(CONST)` writes the 32-bit word
(the same `I_RAW` as `#opcode`); `reloc(TYPE, "symbol")` registers a relocation for the **next**
word emitted in the function. `TYPE` ∈ `BRANCH26 PAGE21 PAGEOFF12 UNSIGNED`, constants predefined
internally in the surface's `#define` table (same values as `docs/macho-notes.md`:
`BRANCH26=2 PAGE21=3 PAGEOFF12=4 UNSIGNED=0`). An unknown symbol becomes an undefined external.

`UNSIGNED` is accepted as a constant but **refused in this position**: it's an 8-byte relocation
(`length 3`), and the word `emit()`/`#opcode` place in the stream is 4 bytes, so it would overrun
the next instruction. The error is `reloc UNSIGNED requires 8 bytes: use a global array
initializer`, on both sides (`stage0/gen_arm64.c` and `src/gen_walk.mc`) — the case is in
`tests/err/062-reloc-unsigned.mc`. An 8-byte address is written as a global array initializer,
which generates the `R_UNSIGNED` in the right place (`tests/040-arrinit.mc`,
`tests/060-callp.mc`).

Tested
(`tests/033-reloc.mc`, runs and returns 42; `otool -r` shows the relocation `R_BRANCH26` generated
by `reloc()` next to the one the compiler's own `bl` generates for the call in `main`):

```c
i64 helper() {
    return 42;
}

i64 call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);          // raw bl (offset filled in by the relocation above)
}

i64 main() {
    return call_helper();      // 42
}
```

## The 7 rules that keep the mechanism small

1. A `#rule` pattern is a flat sequence — no alternation, optional items, or recursion in the
   pattern.
2. The first item is a literal token → indexed by token, no backtracking.
3. The template is parsed by the existing parser at definition time (`$name` becomes `Hole(i)`);
   expansion is a tree copy — never textual substitution, so there are no precedence bugs.
4. Hygiene: gensym only — `$$tmp` in the template becomes a fresh local on every expansion.
   Nothing else.
5. Re-expansion of the result, capped at 64 levels.
6. Frame size is computed after expansion (gensyms are locals).
7. `#define` is a folded constant, not a textual macro — implemented. `#opcode` only accepts
   constant arguments, otherwise it's an error — implemented.

State of the seven after M9: **1, 2, 3, 4, 6, and 7 are implemented and tested.** Rule 5
("re-expansion of the result, capped at 64 levels") was satisfied more strongly than the text
says: **there is no re-expansion of the result at all.** The template is parsed — and therefore
already expanded — at definition time, so a rule that uses another rule is resolved right there;
the 64-level cap applies to nesting *at definition time*. That makes infinite recursion impossible
by construction, rather than merely bounded.

Rule 2 gained a declared exception: the pattern may start with a single `ident $name` before the
literal dispatch token (which is what `+=`/`++` require, and is the form `docs/plan.md` itself
uses in its examples). Dispatch is still by literal token and still has no backtracking — the
name has already been read as an expression by the time the token appears.

## Tier 2 — programmatic (`pass()` / `backend()`) — implemented (M10)

From M6 on, the compiler is written in `.mc`. A new AST pass or backend is, therefore, **just a
`.mc` module compiled alongside the compiler**: no interpreter, no dylib, no plugin ABI. Teaching
the compiler means editing a file and running `make mc1`.

### The actual step by step

1. **Write the module** under `lib/` (or wherever). It defines its functions and a `user_init`
   that registers them:

   ```c
   // lib/user_demo.mc
   #include "backend_arm64.mc"
   #include "pass_demo.mc"

   void user_init() {
       backend("arm64-surface", &sur_backend);   // --backend=arm64-surface
       pass(&pass_mul1);                          // runs over every source's AST
   }
   ```

2. **Wire the module in** by swapping `src/user.mc`'s `#include` — it's the only seam between the
   compiler and whoever teaches it:

   ```c
   // src/user.mc
   #include "../lib/user_demo.mc"      // default: ../lib/user_default.mc
   ```

3. **Recompile the compiler**: `make mc1`. The `build/mc1` that comes out already has the pass
   and the backend built in.

4. **Use it**: `build/mc1 --backend=arm64-surface prog.mc -o prog.o`. Without `--backend=`, the
   default is the built-in `macho` backend. An unknown name is an error and lists what exists:

   ```
   $ build/mc1 --backend=xyz tests/001-return42.mc -o x.o
   unknown backend: xyz
   registered: macho arm64-surface
   ```

`make check-surface` does steps 2-4 by itself (wires up the demo, recompiles into `build/mc1s`,
compares the objects, and restores `src/user.mc` to how it was). The repository's default is
`lib/user_default.mc`, with `void user_init() { }`: the demo is **opt-in**.

### The two signatures

| registration | signature you write | when it runs |
|---|---|---|
| `pass(&f)` | `i64 f(i64 root)` — returns the root (the same one, or a different one) | right after `parse_unit`, before `fold` and `--dump-ast` |
| `backend("name", &f)` | `void f(i64 root, uptr out)` | in place of `macho`, when `--backend=name` |

Both come in as `uptr` (what `&name` produces) and are called via `callp` — see
`docs/core-language.md` § `&function` and `callp`. The tables in `src/hooks.mc` are linear and
walked in registration order: passes run in the order they were registered; for backends sharing
a name, the last registration wins.

The pass runs **before** `fold` (and therefore before `--dump-ast`): that way the pass sees the
tree in the source's own shape, and constant folding cleans up whatever the pass produces. That's
why `--dump-ast tests/061-pass.mc` changes when the demo is wired in.

### The gen split in two halves

The built-in `macho` backend is literally `gen_lower` + `gen_encode_all` + `macho_write`:

- **`gen_lower(root)`** lowers the AST into a per-function `Ins` buffer (the same one
  `--dump-asm` prints), creates sections, allocates globals, emits strings into `__cstring`, and
  creates the symbols — but **encodes nothing**. `__text` stays empty.
- **`gen_encode_all()`** walks the functions, aligns each one to 4, fixes the symbol's value,
  resolves the labels, and writes the 32-bit words with their relocations.

A surface backend calls `gen_lower` and replaces the second half. To do that, it reads the buffer
through `src/gen_walk.mc`'s public accessors:

```
gen_func_count()            how many functions were lowered
gen_func_name(f)             the symbol's name (_name)
gen_func_sec(f)               destination section
gen_func_sym(f)               symbol index (for sym_set_value)
gen_func_labels(f)            how many labels the function used
gen_ins_count(f)               instructions in the function
gen_ins_at(f, i)               instruction i -> ins_op/ins_rd/ins_rn/ins_rm/ins_imm/ins_label/ins_sym
gen_prel_count(f)              raw reloc() relocations in the function
gen_prel_ins/sym/type(f,k)     each one of them
gen_global_count()/gen_global_sym(g)   globals already allocated
gen_str_count()/gen_str_sym(s)         literals already emitted into __cstring
```

and writes with the primitives in `src/macho.mc`, which are ordinary functions: `sec_new`,
`sec_at`, `sec_data`, `sym_new`, `sym_ref`, `sym_set_value`, `reloc_add`, `buf_u32`, `buf_pad`,
`buf_len`, `macho_write`.

### The proof: `lib/backend_arm64.mc`

`lib/backend_arm64.mc` registers the `arm64-surface` backend. It calls `gen_lower` and then
**re-implements the whole encoder in `.mc`**, with its own opcode tables (`sur_rrr_base`,
`sur_mem_base`, ...), its own label resolution, and its own `reloc_add`/`buf_u32` calls — all on
top of the API above, nothing from the core's `static`. The encoding formulas are the same ones
`encode` uses (copied on purpose: the point is that they're reachable from outside, not that
they're different).

Acceptance criterion, run by `make check-surface`: for **every** `tests/*.mc`,

```
build/mc1s --backend=arm64-surface X -o a.o
build/mc1s                         X -o b.o
cmp a.o b.o        # byte for byte identical, 32/32
```

`lib/pass_demo.mc` is the AST-side counterpart of the backend: a pass that scans `1..nnodes-1`
and replaces `x * 1` with `x`, rewriting the node in place (preserving `next`, which belongs to
the sibling list). The core doesn't do this — `fold` only folds constant against constant — and
`tests/061-pass.mc` shows the difference in `--dump-ast`.

### The third seam, since M17: the machine table

Replacing the *whole* encoder is what `lib/backend_arm64.mc` does. M17 opened the seam one level
finer: `gen_lower` itself is now two files, and what stands between them is a table of `&fn`, one
per instruction-selection task, registered with `machine("arm64", tab)` and called through `callp`
— the same linear-table-of-function-pointers idea as `pass()` and `backend()`.

- `src/gen_resolve.mc` binds every name and types every expression into a side table indexed by
  node, before a single instruction exists. `res_type`, `res_kind`, `res_decl`, `res_bind`,
  `res_addr_taken` are what a backend that consumes the AST directly reads, and it never has to
  call `gen_lower` at all.
- `src/gen_walk.mc` is the walk: frames, the depth stack, labels, calls, sections, globals,
  strings, symbols. It mentions no register.
- `src/machine_arm64.mc` is the AArch64 machine: the register partition, the spill policy, the
  encoders, the dump.

`docs/reference/machine.md` is the contract — thirty slots, versioned. Nothing about the surface
changed: `gen_lower`, `gen_encode_all` and every `gen_*` accessor kept their names and their
behaviour, and `make check-surface` still compares `arm64-surface` against the built-in backend
byte for byte, 32/32. The acceptance of the split was that the frozen C seed, still one monolithic
generator, keeps producing **identical** objects (`check-obj` 32/32) and identical `--dump-asm`
(`check-asm` 73/73).

The other half of M17's step A is `target(os, arch, obj_backend, exe_backend)`: `src/driver.mc`
used to carry the whitelist itself (`only macos, linux and windows`, `only aarch64`), and now reads a
registry filled in `src/main.mc`, with those same messages generated from it.

M17's **step B** is the payoff: `src/machine_x86_64.mc`, a second machine behind the same walker,
and `linux/x86_64` as a third registered target. Not one line of `src/gen_walk.mc` is
architecture-specific, and the ELF writer is shared down to the section table — the whole
difference is a register partition, an ABI and thirty-odd encoders
(`docs/reference/machine.md` § The x86-64 implementation).

**M39 is the seam's real test, because the machine is not in the compiler.**
`examples/kernel/machine_riscv64.mc` registers `riscv64` from a module under `examples/`, and
`examples/kernel/image.mc` registers `rv-image`, a writer that lays a flat bare-metal image out
itself — no linker, no object format, no header. Together with four Tier 3 words they make
`build/mc-kernel`, a compiler that turns `examples/kernel/main.mc` into an image that boots under
QEMU, prints, takes a trap, switches between two stacks and exits with a code of its own choosing.
`src/`, `stage0/`, `lib/` and `tests/` gained **zero lines**: `git diff --stat` over those four is
the milestone's headline. Two ways in and out of the compiler — a machine and a backend — plus
`syntax`/`syntax_stmt`/`syntax_expr` are enough for an architecture the language had never heard
of. [`docs/guide/97-a-new-architecture.md`](guide/97-a-new-architecture.md) is the path for
somebody doing it again.

### The five built-in backends: `macho`, `macho-exe`, `elf-obj`, `elf-obj-x86_64` and `coff-obj-arm64`

`src/main.mc` registers four backends before calling `user_init()`:

| name | writes | alias |
|---|---|---|
| `macho` (default) | `MH_OBJECT` — the `.o` that `scripts/link.sh` links with `ld` | — |
| `macho-exe` (M11) | ad-hoc signed arm64 `MH_EXECUTE`, no `ld` | `--exe` |
| `elf-obj` (M16) | ELF64 `ET_REL` for `EM_AARCH64` — the `.o` a Linux linker takes | — |
| `elf-obj-x86_64` (M17) | the same file for `EM_X86_64` | — |
| `coff-obj-arm64` (M19) | COFF `IMAGE_FILE_MACHINE_ARM64` — the `.obj` a Windows linker takes | — |

```
$ build/mc1 --exe tests/001-return42.mc -o tmp/t1 && tmp/t1; echo $?
42
$ build/mc1 --backend=macho-exe tests/001-return42.mc -o tmp/t1    # the same thing
$ build/mc1 --backend=xyz tests/001-return42.mc -o x.o
unknown backend: xyz
registered: macho macho-exe elf-obj elf-obj-x86_64 coff-obj-arm64
```

`elf-obj` lives in `src/backend_elf.mc` and is built the same way `macho-exe` is: `gen_lower` +
`gen_encode_all` and then only the public API of `src/macho.mc` (sections, symbols, relocations,
`sym_order`). It is the proof that the object model in the middle of the compiler really is
format-neutral — see `docs/build.md` § Linux targets for the whole mapping, and
`scripts/test-linux.sh` for the suite it passes. `elf-obj-x86_64` is the same file: it names its
machine (`machine_use("x86_64")`), sets `e_machine`, and shares every other line.

`coff-obj-arm64` (M19) is the third writer over the same lowering, in `src/backend_coff.mc`: same
machine as macOS, a different envelope — `.text`/`.rdata`/`.data`/`.bss`, alignment as three bits
of `Characteristics`, no leading underscore on a symbol, and the four relocations in COFF's
numbering. `docs/build.md` § Windows targets has the whole mapping.

`macho-exe` lives in `src/backend_exe.mc` and is **part of the compiler**, not a user module: it's
M11's answer, not a Tier 2 demo. But it's written exactly the way a surface backend would be — it
calls `gen_lower(root)` and `gen_encode_all()` (the gen's two public halves) and then only uses
`src/macho.mc`'s public API to read sections, symbols, and relocations. What it adds on top is
what `ld` used to do: choosing addresses, resolving the four relocations, creating
`__TEXT,__stubs` + `__DATA,__got` for imported symbols, emitting `dyld`'s bind/rebase opcodes, and
signing ad-hoc (its own SHA-256, in `src/sha256.mc`). The fields, with verified values, are in
`docs/macho-notes.md` § M11; the `ld`-free chain is in `docs/bootstrap.md`.

Two things `--exe` does that `.o` + `ld` doesn't:

- **`&name` for a dylib `extern` works.** In the `.o`, `ld` refuses (an imported symbol only has
  an address via `__got`, and the core doesn't emit `GOT_LOAD_PAGE21` — M10's known limit in
  `docs/core-language.md`). In `--exe`, `mc` itself does the resolving, and it points the
  `adrp`/`add` at the symbol's stub, a callable address.
- **The binary comes out executable (`0755`) and signed**, ready to run; there's no link step and
  no `codesign` step.

One thing it **doesn't** do: `#section` in a segment other than `__TEXT` gets its own `rw-`
segment, and a relocated pointer (`R_UNSIGNED`) inside `__TEXT` is refused with
`relocated pointer in __TEXT: the segment is r-x and dyld will not rebase it`.

`scripts/test-exe.sh` (target `make test-exe`, inside `make check`) runs the whole `tests/*.mc`
suite along this path — compiles with `--exe`, checks the signature with `codesign --verify`, and
compares exit code and stdout against each source's header: **32/32**.

### stage0 is not teachable

`pass()`/`backend()` only exist in the `.mc` compiler. The C stage0 is the seed: the driver
accepts `--backend=macho` (so the command line stays the same) and nothing else —
`--backend=arm64-surface` with `build/mc0` is `unknown option`. **`--exe` doesn't exist in stage0
either**: M11's direct executable (`src/backend_exe.mc` + `src/sha256.mc`, 1035 lines of `.mc`)
wouldn't fit inside the 3000-line C budget, and it doesn't need to — the seed only has to produce
`mc1`. This is deliberate: Tier 2 costs **zero** lines of mechanism in C precisely because the
compiler being taught is the one written in the language itself. What C needed to gain at M10 was
only what the language needs to express a hook: `&function`, `callp`, and splitting the gen into
two halves.

## Tier 3 — syntax taught by code (`syntax` / `syntax_stmt` / `syntax_expr` / `syntax_infix` / `type_alias` / `on_stmt` / `on_jump` / `#dylib`) — implemented (M12, completed in M21, extended in M21.5 and M31)

Tier 1's `#rule stmt:` is a hygienic macro: it matches a **fixed** token sequence in **statement**
position and returns an already-parsed template. That's enough for `while`, `for`, `+=`. It's not
enough for `class` or `interface`: those are top-level declarations, have variable-length lists,
and their effect is generating *several* derived names (`Todo_ID`, `todo_json`, `todo_new`) —
things a template can't express. Tier 3 is the answer, and it's the same idea as Tier 2: **the
user writes a `.mc` module that runs inside the compiler**, this time during *parsing*, using the
parser's public API.

### The seven registrations

| registration | what you write | when it runs |
|---|---|---|
| `syntax("class", &f)` | `void f()` (or `i64 f()`, the return value is ignored) | `parse_top`, before a type is required |
| `syntax_stmt("unless", &f)` | `i64 f()` — returns the statement node's index (0 = none) | `parse_stmt`, before `#rule` dispatch |
| `syntax_expr("bits", &f)` | `i64 f()` — returns the expression node's index | `parse_primary`, before `T_INT`/`T_STR`/`T_IDENT` (M21) |
| `syntax_infix(".+", 9, &f)` | `i64 f(i64 left)` — returns the expression node's index | `parse_expr`'s Pratt loop, at the entry's precedence (M21) |
| `type_alias("bool", TY_U8)` | — | `type_of_token`, after the core's own words |
| `on_stmt(&f)` | `i64 f(i64 n)` — returns the node, a replacement, or 0 | `parse_stmt`, after **every** statement node exists (M21.5) |
| `on_jump(&f)` | `i64 f(i64 n, i64 kind, i64 depth)` — same three answers | `parse_stmt_core`, as it builds a `return`/`break`/`continue` (M31) |

The first five register the word in the lexer (`tok_add`), the same as `#rule` does with its
dispatch literal, and all five **refuse a core keyword** (`K_U8`..`K_EXTERN`); the last two claim
no word at all — they observe nodes the parser has just built:

```
$ build/mc1 --exe my_compiler.mc -o my-mc && ./my-mc x.mc -o x.o
mc: cannot redefine core keyword: if
```

The handler receives the parser stopped **right on the word itself** (it consumes it itself with
`p_next()`) and returns control with the next token already in the lookahead. The tables in
`src/hooks.mc` are linear, in registration order, walked back to front — the last registration
for a given name wins, same as the backend table. No hashing, no backtracking:
`docs/determinism.md`, rule 1.

**Consuming at least one token is the handler's job.** If it returns control without having
advanced, the parser finds the same token and calls the same handler again — forever, at the top
level, until `arena exhausted` at a statement position. `parse_top` and `parse_stmt` compare the
lexer's cursor (and the current token) before and after the call and refuse:

```
$ ./my-mc --exe prog.mc -o prog
prog.mc:1: syntax handler consumed no tokens: bad2
```

### `on_stmt(&f)` — every statement, core or taught — implemented (M21.5)

`on_stmt` is the one registration that is **not** keyed by a word: it reserves nothing, teaches
nothing, and sees everything. `parse_stmt` calls each registered hook, in registration order, with
the index of the statement node it has just produced — the core's `i64 x = ...;`, `return`,
`break`, `continue`, `if`, an assignment, an expression statement, and a taught statement too.

```c
i64 my_count(i64 n) {
    nstmt = nstmt + 1;
    return n;                       // the same node: rewrites nothing
}
void user_init() { on_stmt(&my_count); }
```

The handler returns **the same node**, **a replacement**, or **0 to drop it** — in which case the
parser puts an empty `N_BLOCK` there, exactly as it does for a `syntax_stmt` handler that returns
0, so the sibling list of whoever called it never breaks.

**Order is fixed**: the `syntax_stmt` handler for the word runs *first* and builds the node, then
every `on_stmt` hook runs over the result, in registration order. So a module can teach `unless`
and observe it in the same compiler without the two racing; the node the hook sees is the `N_IF`
the handler built, not the word.

What it is for: wrapping, rewriting or merely watching the **core** statements without re-teaching
them. Scope tracking, instrumentation, ownership and borrow rules, coverage — all of them used to
mean walking the tree afterwards, from inside whatever block handler the module happened to own.
A **core-declared local** (`i64 n = 0;`) is observable here as the `N_VAR` node: that is the
intended way to see it, and there is no separate hook for it.

With nothing registered the parser does not even make the call (`nonstmt == 0`), which is what
keeps an untaught compiler byte for byte what it was — `scripts/check-surface.sh`'s inertness
check still compares against the frozen seed.

### `parse_block()` dispatches through `syntax_stmt("{")` — implemented (M21.5)

`{` is a token like any other, so `syntax_stmt("{", &f)` has always been legal (`K_LBRACE` is 272,
outside the `K_U8..K_EXTERN` range `word_add` refuses) and is how `examples/lang` makes a reference
release happen per scope instead of per function. Until M21.5 it only caught the blocks that
reached the **statement position**. A function body goes through `parse_function` → `parse_block`,
and a `#rule`'s `block $b` hole goes through `parse_block` too, so both were invisible: a scope
opened inside `while (c) { ... }` — a `#rule` in `lib/prelude.mc` — never reached the module.

`parse_block` now consults `syntax_stmt_find(K_LBRACE)` first and calls the handler when there is
one. Two consequences for whoever registers `{`:

- the handler **consumes the `{` itself**, like every other `syntax_stmt` handler;
- the handler must **not** call `parse_block()` — that is now a call to itself. It writes the loop
  (`parse_stmt()` until `K_RBRACE`) directly; `lib/user_syntax_demo.mc`'s `sd_block` is the core's
  own loop with two lines of bookkeeping added, and is 20 lines.

With nothing registered `syntax_stmt_find` answers -1 and `parse_block` is what it was.

### Registration reserves the word for the whole program

All five word registrations are global and permanent (`on_stmt` registers no word and reserves
nothing): from `word_add` on, the word stops lexing as
`T_IDENT` **anywhere**, not just at the handler's grammatical position. Whoever registers
`syntax_stmt("log", &f)` removes `log` from the identifier vocabulary of the compiled source —
`i64 log(i64 x)`, `i64 sum(i64 log, i64 b)`, and `i64 log = 1;` all become errors, even without
using the new syntax at all.

This is a design decision, not an oversight: the lexer has a single word table, and `user_init()`
runs **before** the source's first token is read — at registration time there's no way to know
the program would use that name. What the compiler does is name the reason, instead of an
unrelated "name expected":

```
$ ./my-mc --exe user_prog.mc -o user_prog
user_prog.mc:1: name reserved by a syntax/type_alias registration: log
```

A `syntax_infix` on a **word-shaped** operator (`is`, `as`) reserves it the same way and is blamed
the same way; one on punctuation (`.+`, `~>`) reserves nothing an identifier could have used. The
core operators are in the same table and are never blamed: `infix_is_taught` only answers for an
entry that carries a handler.

In practice: choose words a source wouldn't use as an identifier (`class`, `interface`, `unless`,
`enum`), and prefer capitalized names for `type_alias` (`Todo`, `Request`).

### The parser's public API

Fixed names, in `src/parse.mc` (section "public API of the parser", right before "---- top
----"). A module that teaches syntax depends only on this, on `node_new`/`nd_*`/`set_nd_*` from
`src/ast.mc`, and on the registrations in `src/hooks.mc`:

```
i64  p_id()                       current token's id
i64  p_val()                      value (T_INT / T_CHAR / T_DIR / T_HOLE)
uptr p_name()                     current lexeme, copied into the arena
i64  p_line()                     uptr p_file()
void p_next()                     advance one token
i64  p_accept(id)                 consume if it matches; 1/0
void p_expect(id, msg)            require the token, otherwise err_at
uptr p_ident()                    require T_IDENT (and not a #define), return the name and advance
i64  p_type()                     require a type — core or alias — return TY_*, advance

i64  parse_expr(0)                the same four descents the core itself uses
i64  parse_stmt()
i64  parse_block()
i64  parse_params()               reads `( ... )` and returns the N_PARAM list

i64  parse_function(ty, name, params)   reads the block and returns the assembled N_FUNC
void top_add(n)                   appends an N_FUNC/N_GLOBAL/N_EXTERN/N_PROTO to the unit, in order
void def_add(name, val, line, fl) registers a #define (refuses a repeated name)
i64  param_new(ty, name)          a standalone N_PARAM, to prepend `self`
i64  list_append(head, n)         appends n to the end of the list and returns the head

                                  ---- M21: read, record, replay ----
uptr p_start()                    where the current token starts in the source
i64  p_depth()                    lexer stack depth (frames pushed)
uptr p_skip_balanced(open, close, plen)  record a delimited region without parsing it
void p_push_source(name, text, len)      parse a second source, `#include`'s semantics
void p_subst_reset()              drop the substitutions pending for the next push
void p_subst_name(from, to)       identifier `from` becomes the name `to` (resolved by word_id)
void p_subst_int(from, v)         identifier `from` becomes a T_INT token with the value v
void p_resplit_punct(n)           the current punctuation becomes its first n bytes (`>>` -> `>`)
```

`parse_function` takes the parameter list **already built** — that's how a `class` handler
manages to prepend `self` to every method before reading its body. `top_add` is the only way out
for a `syntax` handler: it produces zero, one, or many declarations, and `parse_top` returns 0.
A `syntax_stmt` handler returns the node directly; if it returns 0, the parser puts an empty
`N_BLOCK` there instead, so as not to break the sibling list of whoever called it. Since M21.5,
`parse_stmt` then hands that node to every `on_stmt` hook (see above), and `parse_block` routes
through the `{` handler when one is registered.

### A taught compiler is one file, not an edit to `src/`

Tier 2 (M10) taught the compiler by swapping `src/user.mc`'s `#include`. M12 splits the compiler
into two files so that stops being necessary:

- **`src/core.mc`** — the compiler's `#include` list **without** `user.mc`. It's the compiler
  minus exactly one function: `void user_init()`.
- **`src/mc.mc`** — `#include "core.mc"` + `#include "user.mc"`. This is the default compiler,
  and `src/user.mc` remains the seam for whoever prefers to teach *this one*.

A taught compiler is its own file, outside `src/`:

```c
// lib/mc_syntax_demo.mc
#include "../src/core.mc"
#include "user_syntax_demo.mc"      // defines the handlers and user_init
```

```
$ build/mc1 --exe lib/mc_syntax_demo.mc -o build/mc-syntax-demo
$ build/mc-syntax-demo --exe lib/syntax_demo_test.mc -o /tmp/t && /tmp/t; echo $?
42
$ build/mc1 lib/syntax_demo_test.mc -o /tmp/t.o
lib/syntax_demo_test.mc:7: type expected at top level
```

That last line is the point: the syntax belongs to the module, not to the core.
`make check-surface` runs these three commands.

### The proof: `lib/user_syntax_demo.mc`

The module teaches a small toy that is deliberately **not** a class or a generic system: the same
mechanisms have to carry a language that looks nothing like the one they were designed against.
M12's three registrations (`unless`, `enum`, `bool`) and M21's six (`bits`, `pipe`, `.+`, `~>`,
`tmpl`, `make`) live in one file, and `lib/syntax_demo_test.mc` uses all nine and exits 42.

The three from M12, which `#rule` can't reach:

```c
// unless (cond) block  ->  if (!cond) block
i64 sd_unless() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the word `unless`
    p_expect(K_LPAR, "expected ( after unless");
    i64 c = parse_expr(0);
    p_expect(K_RPAR, "expected ) after unless condition");
    i64 b = parse_block();
    i64 neg = node_new(N_UNARY, line, fl);       // !cond
    set_nd_op(neg, K_BANG);
    set_nd_a(neg, c);
    i64 n = node_new(N_IF, line, fl);
    set_nd_a(n, neg);
    set_nd_b(n, b);
    return n;
}

// enum Name { A, B, C }  ->  #define A 0, #define B 1, #define C 2
// and `Name` becomes an alias for i64. Produces no declaration: doesn't call top_add.
void sd_enum() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the word `enum`
    uptr name = p_ident();
    p_expect(K_LBRACE, "expected { in enum");
    i64 v = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        def_add(p_ident(), v, line, fl);
        v = v + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RBRACE, "expected } in enum");
    if (v == 0) err_at(fl, line, "enum with no members");
    type_alias(name, TY_I64);
}

void user_init() {
    syntax("enum", &sd_enum);                    // top-level position
    syntax_stmt("unless", &sd_unless);           // statement position
    type_alias("bool", TY_U8);                   // new type, no new syntax
    on_stmt(&sd_count);                          // M21.5: every statement
    syntax_stmt("{", &sd_block);                 // M21.5: every block
    // ... and M21's six, below
}
```

`unless` would fit in a `#rule stmt:` — it's there on purpose, to show the same result both ways.
`enum` doesn't fit: it's top-level position, the list has variable length, and its effect is
registering constants, not producing a node. `bool` doesn't either: `#rule` has no `type $t` hole.

### `type_alias` and the rest of the language

`type_alias(name, TY_*)` doesn't touch any point in the parser besides `type_of_token`, which is
where **every** type position passes through: global declaration, local declaration, parameter,
`extern`, cast, and `p_type()` itself. That's why the alias works in all of them at once:

```c
type_alias("bool", TY_U8);      // bool x = 1;  i64 f(bool b)  (bool) v
type_alias("str",  TY_UPTR);
type_alias("Todo", TY_UPTR);    // and this is how a class becomes a type
```

The name becomes a reserved word from the moment it's registered, just like a `#rule`'s dispatch
literal — for the whole program, see "Registration reserves the word for the whole program"
above.

### `#dylib "path"` — implemented (M12)

Through M11, every `extern` came from `libSystem`. `#dylib` says which library the `extern`s
declared **after** it, until the next `#dylib`, come from; `#dylib ""` returns to the default
(libSystem), which is how a module avoids contaminating whatever gets included after it.

```c
#include "sys.mc"

#dylib "/usr/lib/libsqlite3.dylib"
extern i64 sqlite3_libversion_number();
#dylib ""                         // back to the default: libSystem
extern i64 getpid();

i64 main() {
    putnum(sqlite3_libversion_number());
    puts("\n");
    if (getpid() > 0) return 0;
    return 1;
}
```

```
$ build/mc1 --exe prog.mc -o prog && ./prog
3051000
$ otool -L prog
prog:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/usr/lib/libsqlite3.dylib (compatibility version 1.0.0, current version 1356.0.0)
$ nm -m prog | grep undefined
                 (undefined) external _getpid (from libSystem)
                 (undefined) external _sqlite3_libversion_number (from libsqlite3)
                 (undefined) external _write (from libSystem)
$ dyld_info -fixups prog
prog [arm64]:
    -fixups:
        segment         section          address             type   target
        __DATA          __got            0x100004000           bind  libSystem/_write
        __DATA          __got            0x100004008           bind  libsqlite3/_sqlite3_libversion_number
        __DATA          __got            0x100004010           bind  libSystem/_getpid
```

The mechanism is small: `parse.mc` keeps the paths in a linear table (`MAXDYLIBS 8`) and a
dylib's ordinal is **index + 2**, because in Mach-O's two-level namespace 1 is always libSystem;
each `extern` is tagged with the ordinal in effect in a per-name table
(`extern_lib_find(name)`, default 1). `backend_exe.mc` emits one extra `LC_LOAD_DYLIB` per dylib,
in registration order, puts the ordinal in each undefined symbol's `n_desc`, and switches to
`BIND_SET_DYLIB_ORD_IMM` when the next symbol comes from a different library — the bind opcodes
in the example above come out `ord 1 / _write`, `ord 2 / _sqlite3_libversion_number`,
`ord 1 / _getpid`.

The path **is not validated**: on modern macOS most system dylibs don't exist on disk (they live
in the dyld shared cache), and whoever validates is `dyld`, at `execve`.

**`#dylib` only applies to `--exe`.** `MH_OBJECT` has no dylib load command: a `.o` compiled from
the example above links with `ld -lSystem` and `ld` refuses,
`symbol(s) not found for architecture arm64`. It's the same trade-off already documented in
`docs/bootstrap.md` § M11 — `--exe` is the complete path, `.o` + `ld` is the compatibility path.
And stage0, as always, knows nothing about any of this: `#dylib` in a source compiled by
`build/mc0` is `unknown directive`.

### The real-world example: `examples/api`

The `lib/` demo proves the mechanism with 64 lines. `examples/api` proves it can carry a real
program: a **to-do HTTP API with SQLite persistence**, written with `class`, `interface`, `bool`,
and `str` — four things the language doesn't have. The compiler that compiles it is a 20-line
file:

```c
// examples/api/mc-api.mc
#include "../../src/core.mc"
#include "oop.mc"

void user_init() {
    syntax("class", &oop_class);
    syntax("interface", &oop_interface);
    type_alias("bool", TY_U8);
    type_alias("str", TY_UPTR);
}
```

`examples/api/oop.mc` (482 lines) is the module that runs inside the compiler. It doesn't extend
the parser: it consumes tokens via the public API and returns ordinary declarations through
`top_add`.

```c
// examples/api/main.mc — how the program is written
interface Handler {
    i64 handle(self, Request req, Response res);
}

class Todo {
    i64  id;
    str  title;
    bool done;

    str json(self) { ... }
}

class TodoHandler : Handler {
    Db db;

    i64 handle(self, Request req, Response res) { ... }
}
```

```
// and what the compiler sees after oop.mc
#define HANDLER_HANDLE 0
i64 handler_handle(uptr self, uptr req, uptr res) {
    return callp(ld64(ld64(self) + 0), self, req, res);
}
#define TODO_ID 0
#define TODO_TITLE 8
#define TODO_DONE 16
#define TODO_SIZE 24
i64  todo_id(uptr self)          { return ld64(self + 0); }
void set_todo_done(uptr self, u8 v) { st8(self + 16, v); }
uptr todo_json(uptr self)        { ... }
uptr todo_new()                  { uptr p = rt_alloc(24); return p; }
u8   todohandler_vt[8];
void todohandler_vt_init()       { st64(todohandler_vt + 0, &todohandler_handle); }
uptr todohandler_new()           { ... st64(p, todohandler_vt); return p; }
```

`main.mc`'s seven `class`/`interface` declarations become 39 ordinary declarations; the offsets
come out verified by a program that prints them:

```
$ build/mc-api --exe defs.mc -o defs && ./defs
TODO_ID=0 TODO_TITLE=8 TODO_DONE=16 TODO_SIZE=24 HANDLER_HANDLE=0 TODOHANDLER_SIZE=8
```

The routing is the point of the exercise: the main loop only ever holds a `Handler`, never the
concrete class, and dispatch goes through the object's vtable (`callp`, M10). The binary comes out
through `--exe` (M11), signed, with `libsqlite3` coming in via `#dylib` (M12) — all three
milestones in the same program:

```
$ make -C examples/api test
...
  ok    POST /todos (buy bread)
        {"id":1,"title":"buy bread","done":false}
  ok    GET /todos (two)
        [{"id":1,"title":"buy bread","done":false},{"id":2,"title":"pay bill","done":false}]
  ok    DELETE /todos/1
        {"deleted":1}
  ok    SELECT * FROM todos
        2|pay bill|0
== ok: all routes responded as expected ==

$ otool -L examples/api/build/api
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/usr/lib/libsqlite3.dylib (compatibility version 1.0.0, current version 1356.0.0)

$ build/mc1 examples/api/main.mc -o /tmp/x.o
examples/api/main.mc:27: type expected in parameter
```

That last line is the usual one: the default compiler doesn't know `str`. The surface belongs to
the directory that teaches it. `make check` runs all of this in the `check-examples` target; the
step-by-step guide is in `examples/api/README.md`.

---

## M21 — the rest of the parser surface

M12 gave a module the top-level and the statement positions. M21 gives it the two that were
missing — the **expression** and the **infix operator** — plus the one thing no position hands
you: the ability to **record** a region of source and **replay** it later, with substitutions.
These are mechanisms, never features: nothing here knows what a class, a generic, a namespace or a
memory policy is.

Every table below starts **empty** and every new field is zero, so an untaught compiler produces
byte-identical objects and `--dump-ast` output — `scripts/check-surface.sh` checks exactly that
against `build/mc0`, the frozen C seed, which has none of this. All of it is `.mc`-only, for the
usual reason: `stage0` is the seed and stays frozen.

### `syntax_expr(word, &f)` — a new expression

`i64 f()`, dispatched as the **first** thing in `parse_primary`, with the parser stopped on the
word; the handler consumes it. This is the position `#prefix` cannot serve: its template parses
exactly one operand with `parse_unary` into a fixed tree, so it reads neither a type nor an
argument list. The demo's two:

```c
// bits u32  ->  32.  A TYPE in expression position.
i64 sd_bits() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `bits` word
    i64 ty = p_type();                           // core type or type_alias
    return sd_int(type_width(ty) * 8, line, fl);
}

// pipe(x, f, g)  ->  g(f(x)).  A variable-length list in expression position.
i64 sd_pipe() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();
    p_expect(K_LPAR, "expected ( after pipe");
    i64 v = parse_expr(0);
    loop {
        if (!p_accept(K_COMMA)) break;
        v = sd_call(p_ident(), v, line, fl);
    }
    p_expect(K_RPAR, "expected ) after pipe");
    return v;
}
```

Two guards, both with the word's name and position, both `err_at2`:

```
$ ./my-mc tests/err/064-expr-noadvance.mc -o x.o
tests/err/064-expr-noadvance.mc:7: syntax_expr handler consumed no tokens: nop
$ ./my-mc tests/err/065-expr-nonode.mc -o x.o
tests/err/065-expr-nonode.mc:6: syntax_expr handler produced no expression: nil
```

The second has no `syntax_stmt` equivalent on purpose: a statement that returns 0 gets an empty
`N_BLOCK`, but an expression position has nothing to put there.

### `syntax_infix(word, prec, &f)` — a new operator

`i64 f(i64 left)`, called from `parse_expr`'s Pratt loop with the left side **already parsed** and
the operator **already consumed**. There is no new table: the `#infix` entry gained one column
(`INF_FN`), which is the whole point — a taught operator and a `#infix` one sit in a single
comparable precedence order, and `--dump-rules` prints them side by side.

What that buys is the right-hand side. The handler owns it: a name, a type, an argument list, or
an `=` it decides to read itself. Member assignment works precisely because `=` is deliberately
**not** in the infix table — the Pratt loop has already stopped, so the handler peeks `K_ASSIGN`
and emits a store, and core `parse_stmt` then sees a plain expression statement:

```c
// p ~> len        ->  ld64(p + 0)
// p ~> len = 3    ->  st64(p + 0, 3)
// p ~> at(i)      ->  ld64(p + 16 + i * 8)
i64 sd_arrow(i64 left) {
    uptr f = p_ident();                          // the field name, on the RIGHT
    ...
    if (p_accept(K_ASSIGN)) { ... }              // the handler reads the `=` itself
}
```

None of that is reachable from a template: `#infix "~>" 12 left ld64($1 + $2)` needs one
program-wide `#define` per field at a fixed width, dies on `p ~> x = 5;` with
`left side of assignment must be a name` and on `p ~> m()` with `wrong number of arguments`.

**Teaching the same operator twice is an error** (decision 7.3), at `user_init` time, before the
first token of any source is read — the same stance as a duplicate `#define` or two `#rule`s on
one dispatch literal:

```
$ ./my-mc x.mc -o x.o
mc: operator already taught: .+
```

**A `#infix` on a taught token drops the handler.** `infix_set` rewrites the whole entry,
`INF_FN` included, so the template wins and the operator goes back to being ordinary. That is not
an error, it is the documented order of precedence between the two surfaces, and
`tests/err/066-infix-drops-handler.mc` is the case.

### `p_skip_balanced(open, close, &len)` — record without parsing

Enter with the parser on the opening token; it counts depth over **real tokens** and returns the
source bytes of the whole span, delimiters included, leaving the parser just past the closing one.
Counting with the lexer instead of scanning bytes is what makes a `}` inside a string or a comment
harmless. An unterminated region is reported at the **opening** token — the position that says
which region never closed. The span is a slice of **one** buffer, so a region whose file ran out
in the middle (the closing token was found back in the includer) has no byte range at all and is
refused with `region crosses a file boundary`. What remains lives in the arena for the whole
compilation, so a module may keep it and replay it as often as it likes.

### `p_push_source(name, text, len)` — a second source

Exactly `#include`'s semantics: the lexer pops on its own at the end of the buffer, and `name` is
what `err_at` prints for everything inside. The buffer is whatever the module built — the recorded
span, or a header concatenated with it.

**The lookahead contract.** A push does **not** touch the pending lookahead token, so the
`p_next()` after the push discards it and reads the first token of the pushed source. A handler
must therefore sit on the **last** token of its own construct when it pushes — exactly what
`do_directive` does for `#include` (`lex_include(path, line); next();` with the current token still
on the string). Two independent prototypes of this got it wrong first, which is why it is written
down as a rule.

To get the generated **declarations** into the unit, a handler drives the parser itself; this works
from inside a function body too, because `top_add` appends to the unit list independently of where
the parser is:

```c
i64 d0 = p_depth();
p_push_source(name, buf_p(b), buf_len(b));
p_next();                                        // the contract: discards the lookahead
loop {
    if (p_depth() == d0) break;                  // the pushed source is exhausted
    top_add(parse_top());
}
```

### `p_subst_reset()` / `p_subst_name(from, to)` / `p_subst_int(from, v)` — hygiene

Entries accumulate into a pending list; the next `p_push_source` binds them to the frame it pushes
and the frame's pop discards them (`MAXSUBST` 16 per frame, nested frames independent). They are
applied in `lex_next`'s identifier branch **only**, by exact lexeme, linearly, in registration
order. Two properties follow from doing it in the lexer, both correctness and neither achievable by
rewriting a tree:

- substitution can never reach inside a string, a comment, or part of an identifier — `"T is T"`
  keeps its `T`s and `T_tag` stays `T_tag`, because both are one token;
- `p_subst_int` yields a **`T_INT` token**, so a substituted array bound folds in `parse_dim` like
  any other constant. Tree substitution cannot: `u8 buf[$1]` is `array size must be a positive
  constant`.

`p_subst_name` resolves `to` through `word_id`, so a type alias or a taught word arrives with the
right token id rather than as a bare `T_IDENT`.

### `p_resplit_punct(n)` — undo a longest match

The current punctuation token, of length `L > n`, becomes the punctuation formed by its first `n`
bytes, and the cursor rewinds to just after them. `>>` read as `>` with another `>` still to come
is the case; longest match is the one lexing decision a parser cannot undo afterwards, and this is
the narrow, sound piece of it — no pushback, no backtracking, no new state. The core learns "a
punctuation token may be re-split", not "generics exist".

### Error attribution costs zero core lines

`err_at` prints `lex_file()`, which for a pushed frame is the string the module passed. So the
module composes the provenance and gets it in front of every error inside the frame, and nested
instantiations compose because the module builds the name from the name it is already inside:

```
$ ./my-mc tests/err/063-tmpl-attrib.mc -o x.o
slot__i64__0 instantiated from tests/err/063-tmpl-attrib.mc:15:2: array size must be a positive constant
```

Nodes built inside the frame keep that string in `nd_file`, so a **codegen** error still names the
instantiation long after the frame popped. The gap: the line is relative to the generated text, so
a module that wants the template's own line copies the span verbatim (line-for-line aligned) or
emits a line map of its own.

### The demo, end to end

`lib/user_syntax_demo.mc` records a body and replays it once per argument tuple, and nothing about
that is in the core:

```c
tmpl slot<T, N> {
    T cells[N];                      // p_subst_int reaches parse_dim
    i64 T_tag = N;                   // one identifier: substitution is by whole lexeme
    uptr kind = "T is T";            // a string: the lexer never offers it
    st8(cells, 0);
    return T_tag + bits T / 8 + ld8(cells) + ld8(kind) - 'T';
}

make slot<i64, 3>;                   // -> i64 slot__i64__3()
make slot<u8, 2>;                    // -> i64 slot__u8__2()
make slot<i64, sum<1, 2>>;           // `>>` split by p_resplit_punct; memoized, emits nothing
```

Mangling, memoization, what an "argument" is and what `sum<a, b>` means are all the module's:
the core hands out a span, a second source, a substitution and a re-split, and nothing else.
`scripts/check-surface.sh` runs one case per hook plus the four `tests/err/` cases, the duplicate
registration, the demo test compiled twice byte for byte, and the inertness check.

**A module side table keyed by node index must never live in `nd_c`/`nd_d`.** `dump_node` walks
those as node indices, and `node_copy_subst` does not carry them; keep such a table in the module.

---

## M31 — the three things a taught *runtime* was missing

M21 finished the grammar positions. What M31's design panel found missing was not a position: three
independent teams built `spawn`/`intent`/`await` compilers against an unmodified `build/mc1`
(`docs/specs/M31.md`), and the core hosted the whole feature — but two of them got there only by
reaching into a parser internal, one reproduced the same deadlock twice, and all three rested on
register conventions that were true and unwritten. The three gaps are generic, small, and have
nothing to do with threads.

### `decl_find` and the three readers — ask the core about a declaration it already parsed

```c
i64 decl_find(uptr name);            // index of the N_FUNC/N_PROTO/N_EXTERN, -1 if none
i64 decl_ret(i64 d);                 // declared return type (TY_*)
i64 decl_nparams(i64 d);             // arity
i64 decl_param_type(i64 d, i64 i);   // the i-th parameter's type
```

A module that lowers a call needs the **callee's** signature: the declared return type decides what
the result may be bound to (`await r = f()` on a `void f()` has nothing to bind, and a naive version
dies with the core's `value of type void` far from the cause), and the parameter types decide what
has to be marshalled. That answer sits in the unit the parser is building, and until M31 the only
route to it was to walk `unit_head` — declared in `src/parse.mc` and *not* inside the public API
block. These five (`decl_valid` is the fifth: 1 for one of the three kinds) are the sanctioned way.

The walk is linear, in declaration order, and the first declaration of a name answers — a prototype
ahead of its definition carries the same signature. **Only what has been parsed so far is visible**,
which is the honest limit of asking during the parse: a module that needs a callee declared further
down asks again from a `pass()`, when the whole unit exists. Beyond concurrency: FFI glue for an
`extern`, doc extraction, an LSP hover — all of them want the signature the core already read.

`lib/user_syntax_demo.mc` teaches `widen x = f(a);`, where the local's type is `f`'s declared return
type and every argument is cast to the declared parameter type, neither written at the use site:

```
$ ./my-mc --dump-ast prog.mc
    VAR type=u8 name=a          <- u8 because `low` returns u8
      CALL type=i64 name=low
        CAST type=i64
          INT val=300 type=i64
    VAR type=i64 name=b
      CALL type=i64 name=keep
        CAST type=u8            <- u8 because `keep`'s parameter is u8
          INT val=300 type=i64
```

### `on_jump(&f)` — a hook on the exit edges of a scope

```c
i64 f(i64 n, i64 kind, i64 depth)
```

Called where the core creates an `N_RETURN` / `N_BREAK` / `N_CONTINUE`, **before** any `on_stmt`
hook and before another module can wrap it; `kind` is the node kind, `depth` how many blocks are
open in the current function (`p_blockdepth()` reads the same counter, and `parse_function` rebases
it per function). Handlers run in registration order and may return a replacement, or 0 to drop the
jump.

Why `on_stmt` is not a substitute: two teams independently built the same `lock (m) { ... }` by
appending the unlock after the body, and both reproduced the same defect — a `return` inside the
body jumps over the unlock and the next call hangs forever. And the host module already rewrites
`N_RETURN` into a block for its own reference counting before a later-registered `on_stmt` hook sees
it, so a second module can neither recognise the jump nor place code on that edge. Beyond
concurrency: `defer` / scope guards, which Go, Swift, Zig and D all put at language level precisely
because they must cover every exit edge, and any coverage or tracing module that needs a probe on
early returns rather than at the closing brace.

The demo's `guard EXPR { ... }` runs one statement on every edge out of the block — the fall-through
and each jump inside it:

```c
i64 h(i64 x) { guard bump() { if (x) { return 1; } } return 2; }
// becomes
i64 h(i64 x) { { if (x) { { bump(); return 1; } } bump(); } return 2; }
```

`scripts/check-surface.sh` proves the ordering with a number: `retcount`, the module's count of
statements that still *looked* like an `N_RETURN` when `on_stmt` ran, does not move for a guarded
jump, because `on_jump` had already replaced it with an `N_BLOCK`.

### A written and tested ABI contract

No new mechanism — documentation plus tests. Four invariants carry every taught runtime and
violating one fails at run time with no diagnostic: parameters arrive in `x0..x7` and the prologue
does not clobber them; the epilogue leaves `x0` alone; a zero-parameter, zero-local function has
`frame == 0` and an epilogue of exactly `ldp x29, x30, [sp], #16` + `ret`; and generated code never
writes `x18..x28`. The last two were true and unwritten, so an allocator that spilled depths into
`x19..x28`, or a leaf-function optimisation that dropped the `stp`, would have silently corrupted
every taught runtime.

They are now [objects.md § 4](reference/objects.md), and `make check-surface` asserts each of them
against `--dump-asm`: six functions compared instruction by instruction, `lib/sys_svc.mc`'s `write`
(the real user of the `#opcode` fixed-register rule) compared the same way, and over the whole of
`src/mc.mc` — 837 functions — every prologue, every `ret` preceded by that exact `ldp`, and zero
mentions of `x18..x28` in 58 914 lines.

---

## M14 — the same three things said from outside the source (`mc.toml`)

Tier 3 is written *in* the source: `syntax`, `type_alias`, `#dylib`. M14 adds a place to say some
of it from **outside** it, as data:

- **which modules make up the compiler** — `[compiler] core/modules/out`, instead of writing a
  `mc-api.mc` by hand and remembering to compile it first;
- **which library an `extern` comes from** — `[libs]` + `[externs] "sqlite3_*" = "sqlite3"`, the
  same table `#dylib` feeds. `#dylib` in the source still wins for its own `extern`s: the pattern
  table is only consulted after the exact one;
- **where `#include "x"` may look** — `[include].paths`, tried after the includer's own directory.

```
$ build/mc1 build examples/api
compiler build/mc-api.mc -> build/mc-api
compile main.mc -> build/api
```

The first line built the compiler that knows `class`/`interface`; the second used it. Nothing in
`src/` changed, and neither `make` nor `ld` ran. The whole format, the driver and the limits are in
**`docs/build.md`**.
