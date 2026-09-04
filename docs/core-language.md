# core-language.md — the `.mc` core language

Reference for the core language specified in `docs/plan.md` and detailed in
`docs/specs/M1.md`...`M12.md`. State of the code at this milestone (**M11 closed**):
lexer, Pratt parser, AST, ARM64 codegen, and Mach-O writer complete for everything below —
`make test` runs 32/32 tests (`tests/001-return42.mc` ... `tests/061-pass.mc`), and every
example in this document was actually compiled and run with `build/mc0` to confirm the text.
`#rule`/prelude with `while`/`for` (**M9**), programmatic `pass()`/`backend()` (**M10**), and a
direct `MH_EXECUTE` executable (**M11**) are all implemented — see `docs/surface.md` for the
teaching-surface mechanisms themselves.

## Types

7 words, registered in the core table when the lexer initializes.

| Type | Size | Use |
|---|---|---|
| `u8` | 1 byte | bytes, small Mach-O fields |
| `u16` | 2 bytes | `n_desc` and the like |
| `u32` | 4 bytes | `n_strx` and the like, instruction word |
| `u64` | 8 bytes | wide unsigned values |
| `i64` | 8 bytes | working integer type — most expressions |
| `uptr` | 8 bytes | the only pointer type: opaque, no pointee type, byte arithmetic |
| `void` | — | no-value return |

No `i8/i16/i32`, no `float`, no `bool` — comparisons produce `i64` 0/1. Comparisons are always
signed (addresses stay below 2^63, by documented convention, not checked at runtime).

## Literals

- Decimal and hex integer (`0x...`).
- Char `'a'`, escapes `\n \t \r \0 \\ \' \"` — folds directly into `N_INT` (there's no separate
  AST kind for char). `\0` is valid inside a char literal.
- String `"..."` — bytes decoded into the arena, emitted in `__TEXT,__cstring` with a trailing
  NUL, deduped by content (linear search, first occurrence wins the `l_strN` symbol).
  `\0` inside a string literal is an **error**: `__cstring` is `S_CSTRING_LITERALS` and `ld`
  merges literals at the first NUL, which would make `"a\0b"` and `"a"` end up at the same
  address. Tested:
  ```
  $ build/mc0 t.mc      # write(1, "a\0b", 3);
  t.mc:2: \0 not allowed in string
  ```

## Operators and precedence

The core's Pratt table, higher precedence binds tighter.

| Prec | Operators | Note |
|---|---|---|
| 11 | `f(a, b)` (call) | args in `x0..x7` |
| 10 | `* / %` | see "Signed vs. unsigned division and modulo" below |
| 9 | `+ -` | |
| 8 | `<< >>` | `>>` is arithmetic (`asr`) only if the left operand is `i64`; logical (`lsr`) otherwise |
| 7 | `< <= > >=` | result 0/1 via `cset` |
| 6 | `== !=` | same |
| 5 | `&` | bitwise |
| 4 | `^` | bitwise |
| 3 | `\|` | bitwise |
| 2 | `&&` | mandatory short-circuit |
| 1 | `\|\|` | mandatory short-circuit |

Prefix unaries `- ~ !`. `&x` (address of a local, global, **or function** — see below) — prefix,
same precedence as the unaries.
C-style cast `(u32) x` (unambiguous: a type keyword always follows `(`) — `and`/`mov wd,wn` to
mask u8/u16/u32. Assignment `x = e` (`=` only, no native `+=`).

### Signed vs. unsigned division and modulo

`/` and `%` use `sdiv`/`msub` (signed) only when the **left** operand's type is `i64`; for
`u8/u16/u32/u64/uptr` on the left they use `udiv`/`msub` unsigned — the same decision rule as
`>>`. `fold()` (constant folding) mirrors the same criterion. Tested (`tests/041-udiv.mc`):

```c
u64 big = 0xFFFFFFFFFFFFFFFF;
if (big / 2 != 0x7FFFFFFFFFFFFFFF) return 1;                       // udiv, at runtime
if ((u64) 0xFFFFFFFFFFFFFFFF / 2 != 0x7FFFFFFFFFFFFFFF) return 2;  // udiv, folded at compile time
i64 neg = 0 - 8;
if (neg / 2 != 0 - 4) return 5;                                    // i64 stays signed (sdiv)
```

### Division by zero, and `INT64_MIN / -1`

Neither case has an answer in the language: the machine emits its target's divide instruction and
the instruction set decides. Constants never get that far — `fold()` refuses `x / 0` and `x % 0`
with `division by zero` at compile time — so only a divisor that is zero at *run time* reaches the
hardware, and there the two shipped machines disagree:

| at run time | AArch64 (`sdiv`/`udiv`) | x86-64 (`idiv`/`div`) |
|---|---|---|
| `7 / 0` | `0` | `SIGFPE`, the process is killed |
| `7 % 0` | `7` | `SIGFPE`, the process is killed |
| `INT64_MIN / -1` | `INT64_MIN` | `SIGFPE`, the process is killed |

Measured, one source per row (`INT64_MIN` is written `0 - 9223372036854775807 - 1`): built with
`mc --exe` on macOS/arm64, and through `[target] os = "linux"` on linux/arm64, the three exit 0, 7
and 0; cross-compiled with `arch = "x86_64"` and run under `docker run --platform linux/amd64`, all
three print `Arithmetic exception` and exit 136 — the shell's way of saying `SIGFPE` (128 + 8).

AArch64's three answers are what its ISA does, not a semantic mc chose, so no guard is emitted on
a target whose divide traps: every division on x86-64 would pay for a check the language never
promised. `docs/specs/M33.md` § 8 decides the same for wasm, whose `div_s`/`div_u`/`rem_s`/`rem_u`
also trap. Test the divisor yourself when it can be zero.

## Memory intrinsics

`ld8 ld16 ld32 ld64` (read, zero-extend) and `st8 st16 st32 st64(p, v)` (write). There's no `*p`
or `p->f`: access is always by explicit width. An array name decays to `uptr` automatically.

## `&function` and `callp` — function pointer (M10)

The core has no function type: a function pointer is a `uptr` like any other, and an indirect
call is an intrinsic. These are the two pieces Tier 2 (`pass()`/`backend()`) needs.

**`&name` where `name` is a function or an `extern`** gives the address of symbol `_name`:
`adrp`/`add` with the `PAGE21` + `PAGEOFF12` relocations, the same as `&global`. If the name came
from an `extern`, the symbol comes out **undefined external** in the `.o`. `&local`, `&global`,
and `&function` are the same syntax: codegen looks for a local, then a global, then the
signature table, and only then errors `unknown name`.

**`callp(p, a1, ..., a11)`** calls address `p`: the arguments go where a direct call would put
them — `x0..x7`, then the stack — the pointer goes into `x16` (IP0 — caller-saved and outside
`x0..x7`, so no argument steps on it), and the call is `blr x16`. Saving live depths is the same as
for a normal `bl`. The result is `x0` and its type is `i64` — if the called function returns
something else, converting it is up to the caller. Arity 1 to 12 (the pointer counts): eleven
arguments is the max.

```c
i64 add2(i64 a) { return a + 2; }
uptr tbl[2];

i64 main() {
    st64(tbl, &add2);                 // store add2's address in the table
    return callp(ld64(tbl), 40);      // add2(40) = 42
}
```

Tested in `tests/060-callp.mc` (a `uptr` table with `&add2`/`&mul2`, a 7-argument call, exit 42).
**Known limit, only along the `.o` + `ld` path:** `&name` for an `extern` living in a dylib
(`&write` from libSystem) produces a correct `.o`, but `ld` refuses the link — an imported symbol
only has an address via `__got`, and the core doesn't emit a `GOT_LOAD_PAGE21` relocation:

```
$ build/mc1 amp.mc -o amp.o && scripts/link.sh amp amp.o     # uptr w = &write;
ld: fixup error (kind=arm64_adrp_lo12) at '_main'+0xC from amp.o, target '_write' does not have address
```

With an `extern` resolved by another `.o` in the same link, `&name` works. And **via `--exe`
(M11) it always works**: whoever resolves the relocation there is `mc` itself, which points the
`adrp`/`add` at the symbol's stub in `__TEXT,__stubs` — a callable address.

```
$ build/mc1 --exe amp.mc -o amp && ./amp                     # callp(&write, 1, "via &write\n", 11)
via &write
```

## Arrays

- Local array (`u8 buf[24];` inside a function) — space in the frame.
- Global array (`u8 heap[HEAP_SIZE];` at top level) — a reservation in `__bss` with no
  initializer, or `__data` with one.
- **Global array initializer**: `type v[N] = { e1, e2, ... };` or `type v[] = { ... }` (N
  inferred from the list). Elements are folded constants, written at the type's width; `N`
  larger than the count fills the rest with zero, a count larger than `N` is an error. Goes to
  `__data` (aligned to 16). For `uptr`, a string-literal element writes 8 zero bytes plus an
  `R_UNSIGNED` relocation pointing at that string's `l_strN` symbol (see
  `docs/macho-notes.md`). Tested (`tests/040-arrinit.mc`):
  ```c
  uptr names[] = {"zero", "one", "two"};   // N inferred: 3 pointers in __data
  u32  t[4] = {1, 2, 3};                   // N > count: the 4th element comes out zeroed
  i64  sum[2] = {20 + 22, 7 * 6};          // constant folding in the element
  // ld64(names + 8) -> pointer to "one"; ld32(t+12) == 0; ld64(sum) == 42
  ```

## Frame and local-array limits

Local array: `nelem * width` may not exceed 4095 bytes (checked in the parser and again in
codegen) — error `local array too large`. The whole function frame (all locals + spill area,
rounded to 16) also may not exceed 4095 bytes (`sub sp, sp, #imm` only fits in 12 bits) — error
`frame too large`. Tested:
```
u8 big[4080];   // ok, frame fits
u8 big[4096];   // local array too large (nelem*width > 4095)
u8 big[4090];   // frame too large (rounding to 16 overflows the sub-immediate)
```

## Control flow

- `if (c) stmt [else stmt]`.
- `loop { }`. There's no `while`/`for` in the core; they come from the prelude via `#rule` (**M9,
  implemented** — `lib/prelude.mc`, § Prelude below).
- `break;` / `break N;` (exits N levels, no labels needed; N greater than the current loop depth
  is an error).
- `continue;`.
- `return [e];`.

## Functions

`type name(type a, ...) { }` — max 12 parameters (the first eight in registers, 9..12 on the
stack — `docs/reference/objects.md` § 4; exceeding it is
an error; no varargs). Two top-level passes allow calling a function before it's defined, and
mutual recursion with no forward declaration.

### Prototype

`type name(params);` at top level (no body, no `extern`) registers the signature before the
definition; the later definition must match return type and arity; a prototype with no
definition and no `extern` by the end of the unit is an error. Tested (`tests/042-proto.mc`):
```c
i64  sum(i64 a, i64 b);          // used before it's defined
i64  double(i64 x);              // defined after whoever calls it
i64 main() { show(sum(double(20), 2)); return 0; }  // stdout "42\n", exit 0
i64 sum(i64 a, i64 b) { return a + b; }
i64 double(i64 x) { return x + x; }
```

## `extern`

`extern type name(type a, ...);` declares an undefined symbol (`_name` with no body — this is
how `write`/`open` from libSystem come in, see `lib/sys.mc`).

The compiler **does not check whether the symbol exists**: it only registers the undefined
reference. Who discovers the error, and when, depends on the output path — and that difference is
deliberate (`docs/bootstrap.md` § M11). For

```
// missing.mc
extern i64 does_not_exist(i64 x);

i64 main() {
    return does_not_exist(1);
}
```

the `.o` + `ld` path (default) refuses **at link time**:

```
$ build/mc1 missing.mc -o missing.o          # exit 0
$ scripts/link.sh missing missing.o
Undefined symbols for architecture arm64:
  "_does_not_exist", referenced from:
      _main in missing.o
ld: symbol(s) not found for architecture arm64                  # exit 1
```

and the `--exe` path generates the binary (signed, `codesign --verify` passes) and fails **at
load time**, in `dyld`:

```
$ build/mc1 --exe missing.mc -o missing-exe   # exit 0
$ ./missing-exe
dyld[80040]: Symbol not found: _does_not_exist
  Referenced from: <F1456454-2B44-5ECA-A150-2354A925A8A5> .../missing-exe
  Expected in:     <4FED5EE2-5D3E-35B1-A170-9859C4B683BB> /usr/lib/libSystem.B.dylib
                                                                # exit 134 (SIGABRT)
```

`--exe` writes the stub and the symbol's bind opcode without consulting `libSystem`; validating
the name would require reading the SDK's `.tbd` files, and M11 refuses that dependency (there is
no, and will be no, built-in list of known symbols). If you want the error at build time, use the
`.o` + `ld` path.

## `#include` and `#define`

- `#include <name>` (M15): textual inclusion of a file carried **inside the binary** —
  `<sys>`, `<prelude>`, `<lz>`, `<mc/core>`, … There is no filesystem fallback: an unknown name is
  `unknown bundled include: <name>`. See `docs/build.md` § M15 and `docs/surface.md` § Tier 1.
- `#embed NAME "path" [lz]` (M15): the file's bytes as `u8 NAME[]`, plus `NAME_size` and
  `NAME_raw`. Same path resolution as `#include "x"`, taken from the file that wrote the
  directive; inside a bundled `<name>` include the payload comes from the bundle as well.
  Since M21.5 the payload is ONE AST node (`N_BLOB`), not one per byte — the object is unchanged,
  the arena cost is not (`docs/surface.md` § `#embed`).
- `#include "file.mc"`: textual inclusion, once-only, relative to the directory of the including
  file. `path_join` normalizes `.` and `..` lexically (without touching the filesystem) before
  the once-only check, so two paths that reach the same file via different textual routes
  (`inc/c.mc` and `inc/a/../c.mc`) count as a single inclusion. Max depth 16. Tested
  (`tests/043-include-norm.mc`): `#include "inc/c.mc"` and `#include "./inc/a/b.mc"` (which in
  turn includes `../c.mc`) resolve to the same file — `common()` isn't declared twice.
- `#define NAME expr`: expr parsed and folded at definition time (via `fold()`), a constant — not
  a textual macro. Redefining it is an error. Use must come after the definition (source order).
- **`#define` vs. a name**: declaring a local, parameter, global, or function with a name already
  used by `#define` is an error, `name already defined by #define`, regardless of the order
  between the two. Tested:
  ```
  #define LIMIT 10
  i64 LIMIT = 5;      // t.mc:2: name already defined by #define
  i64 f(i64 N)         // same for a parameter, if N is already a #define
  ```

## Prelude (`lib/prelude.mc`) — `while`, `for`, `+=`, `-=`, `++`, `--`

None of this is core syntax: it's six `#rule stmt:` and four `#token` written in the language
itself, in a file that only comes in via explicit `#include` (§ `docs/surface.md` § `#rule`). The
core keeps compiling without it — `src/lex.mc`, `src/parse.mc`, and `src/gen_arm64.mc` don't
include it; `src/macho.mc` does, and it's the leaf module migrated at M9.

```c
#include "../lib/prelude.mc"

i64 sum(i64 n) {
    i64 s = 0;
    for (i64 i = 0; i < n; i = i + 1) {   // step is `ident $x = expr $step`
        s += i;
    }
    i64 k = n;
    while (k > 0) {                        // the body is always a block: { }
        k--;
    }
    return s;
}
```

What the prelude gives you, and what it **doesn't**:

| Written | Becomes |
|---|---|
| `while (c) { B }` | `loop { if (!c) break; { B } }` |
| `for (INIT COND ; x = STEP) { B }` | `{ INIT loop { if (!COND) break; { B } x = STEP; } }` |
| `x += e;` · `x -= e;` | `x = x + e;` · `x = x - e;` |
| `x++;` · `x--;` | `x = x + 1;` · `x = x - 1;` |

- **The body is always a block.** The pattern says `block $b`, so `while (c) x++;` with no braces
  is an error.
- **`for`'s step is `ident $x = expr $step`, not any arbitrary expression.** In the core,
  assignment is a *statement*, not an operator (`=` isn't in the Pratt table), so a bare `expr`
  in the step's place could only be a function call — useless for a counter. That's why the step
  is written `i = i + 1` (and not `i++`, which is a whole statement, with its own `;`).
- **`for (; c; i = i + 1)` doesn't exist**: the pattern requires a `stmt $init`, and the core has
  no empty statement. Where C would use a `for` with no initializer, `.mc` uses `while`.
- **`while` and `for` become reserved words** from the `#include` on: a rule's first literal item
  is registered as a lexeme (`tok_add`), so `i64 while = 1;` becomes an error
  (`variable name expected`) — see `tests/err/055-keyword.mc`.

### `continue` inside `for` skips the step

The step sits **at the end of the body** of the generated `loop`, and `continue` jumps back to
the top of that `loop` — so `continue` skips the step, exactly as it would in a hand-written
`loop{}`. This isn't a prelude bug: it's the direct consequence of the core having no step
clause, and `#rule` not inventing one. Whoever exits via `continue` needs to advance the counter
first:

```c
for (k = 0; k < 10; k = k + 1) {
    if (k % 2) { k = k + 1; continue; }   // without this line the loop doesn't advance
    t = t + k;
}
```

`tests/051-for.mc` covers both cases (the normal `for` and the `continue` that advances by hand).
`break` inside `while`/`for` is the core's `break` and exits the generated `loop`, as expected.

## Mandatory style in `mc.mc`

Never access raw layout (`ld64(n + 16)`) in the middle of the code: always
`#define NODE_LHS 16` + accessors `node_lhs(n)` / `set_node_lhs(n, v)`. When `struct` arrives via
the surface, you swap ~20 accessors, not thousands of call sites. Every `src/*.mc` has followed
this discipline since M6 (`docs/specs/M6-M7.md`); M9 did **not** bring `struct` — the spec
(`docs/specs/M9.md`) took it out of scope once M6 showed that `#define` + accessor solves it, and
a real `struct` would need the `type $t` hole and a layout model, more than `#rule` delivers.

## Example program

Actually compiled and run (`build/mc0 exemplo.mc -o out.o && scripts/link.sh out out.o &&
./out` prints `46368`, exit 0). `write` is declared directly via `extern` here instead of
`#include "sys.mc"` because `sys.mc` already brings in `putnum` from `lib/io.mc` — this example
defines its own to show a local array + `st8`/`ld8`; a real program would normally prefer to
include `sys.mc`/`sys_svc.mc` and use the `putnum` from there (see `docs/surface.md`).

```c
extern i64 write(i64 fd, uptr buf, i64 n);   // extern: just the signature, no #include

#define HEAP_SIZE 1048576         // constant folded at compile time

u8  heap[HEAP_SIZE];              // global array = reservation in __bss
i64 hp = 0;                       // global in __data

uptr alloc(i64 n) {
    uptr p = heap + hp;           // uptr is opaque: byte arithmetic
    hp = hp + ((n + 7) & ~7);
    return p;
}

i64 fib(i64 n) {                  // parameters, recursion
    if (n < 2) return n;          // if/else
    return fib(n - 1) + fib(n - 2);
}

void putnum(i64 v) {
    u8 buf[24];                   // local array = space in the frame
    i64 i = 24;
    loop {                        // loop/break
        i = i - 1;
        st8(buf + i, '0' + v % 10);   // memory access by explicit width
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);    // write comes from extern
}

i64 main(i64 argc, uptr argv) {
    uptr first = ld64(argv);      // argv[0] with no sigil: ld64 reads 8 bytes
    putnum(fib(24));              // prints 46368
    write(1, "\n", 1);            // string literal is worth a uptr into __cstring
    return 0;
}
```

## Transliteration pitfalls

Transliterating `stage0/*.c` function by function into `src/*.mc` (M6, `docs/specs/M6-M7.md`)
runs into C features the `.mc` core doesn't have. Each item below is a real case found in
`stage0`, with the workaround that ended up in `.mc`:

- **`struct`** — doesn't exist. Becomes `#define FIELD off` + accessors
  `field(p)`/`set_field(p, v)` (see "Mandatory style in mc.mc" above) — a rule since the first
  line of `arena.mc`.
- **`?:`** — doesn't exist. Becomes an explicit `if` assigning the same variable on both branches:
  `size_t cap = b->cap ? b->cap : 64;` (`stage0/arena.c`) became
  `i64 cap = buf_cap(b); if (cap == 0) cap = 64;` (`src/arena.mc`).
- **`for`** — doesn't exist, only `loop { }` + `break N`/`continue`. `for (init; cond; step) body`
  becomes `init; loop { if (!cond) break; body; step; }`, with the "step" hand-written at the end
  of the body.
- **`static`** (internal linkage + forward declaration) — `.mc` has no translation units:
  everything comes in via `#include` into a single file, so `static` has nothing to do and is
  dropped. The part that matters — declaring a signature before its definition, for mutual
  recursion (`parse_expr`/`parse_unary` in `stage0/parse.c`, `gen_stmt`/`gen_expr` in
  `stage0/gen_arm64.c`) — uses `.mc`'s native prototype (tested in `tests/042-proto.mc`, M5.5),
  not the C idiom.
- **unsigned comparison** — `.mc` only has signed comparison (see § Types above). C uses
  `size_t`/`u64` unsigned for offsets and capacity throughout; the workaround is the convention
  "addresses and sizes always stay below 2^63" (documented, not checked at runtime), which makes
  signed `<`/`<=`/etc. equivalent to C's unsigned ones for every value that actually shows up in
  `arena.mc`/`gen_arm64.mc`/`macho.mc`.
- **`++`/`--`** — don't exist **in the core**. Without the prelude, `i++` becomes `i = i + 1` and
  `i--` becomes `i = i - 1` — mechanical, but scattered across every transliterated loop. With
  `#include "../lib/prelude.mc"` (M9) `i++`/`i--`/`i += e`/`i -= e` exist as four `#rule`s, and
  that's what `src/macho.mc` uses today.
- **adjacent string literals** — C concatenates `"a" "b"` at compile time; `.mc` has no such rule.
  `out_str(2, "usage: mc0 ... " "source.mc [-o out.o]\n");` (`stage0/main.c`) became a single
  literal in `src/cli.mc`.
- **`&arr[i]` (address of an indexed element)** — `&` only accepts a direct name (`&name`), not an
  indexing expression — `.mc` has no `p[i]` or `p->f` (§ Operators above). `Node *p =
  &nodes[nnodes]; p->kind = k;` (`stage0/ast.c`, `node_new`) became passing the **index** along
  and letting the accessors compute `base + index*size`: `set_nd_kind(nnodes, kind);`
  (`src/ast.mc`) — "the address of the element" is never materialized, only the index.
- **`continue` inside a `loop{}` with no separate step clause** (equally true for the prelude's
  `for`, § above) — in C's `for`, `continue` runs the `step` and re-evaluates the condition;
  `loop{}` has no step clause, so a naive `continue` skips exactly the advance that would close
  the loop (`e = nodes[e].next`, `i++`), which can hang in an infinite loop. The workaround used:
  eliminate the `continue` by rewriting `if (cond) { ...; continue; }` followed by more code as
  `if (cond) { ... } else { ... }`, with the advance (`e = nd_next(e);`) unconditional at the end
  of the body. Real example: the `for` with `continue` in `stage0/gen_arm64.c` (globals with a
  string pointer) became the `if`/`else` with `e = nd_next(e)` at the end in
  `src/gen_arm64.mc`.
- **variadic `open` → `creat`** — libSystem's `open(path, flags, ...)` is variadic (`...` for
  `mode`), and in the arm64 Apple ABI variadic arguments travel on the stack — which `.mc`
  doesn't know how to set up (only `x0..x7`). The workaround is using `creat(path, mode)` to
  create a file (no variadic; `open` without `O_CREAT` still works for reading, with `mode`
  always 0) — see the comment in `stage0/arena.c` and `src/arena.mc`.
