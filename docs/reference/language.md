# The core language

The core is what `stage0/*.c` and `src/*.mc` implement between them: the language `mc` compiles
before any teaching happens. Everything else in this reference — `#rule`, `syntax`, `pass`,
`backend` — builds on top of it and is described in [directives.md](directives.md) and
[hooks.md](hooks.md).

The organising rule is that the core only has to be big enough to compile **one** program,
`src/mc.mc`. Every "why is there no X?" below has that answer.

---

## 1. Lexical structure

### Tokens

The lexer produces `(id, value, lexeme, file, line)`. Seven ids are token *classes*:

| id | class | when |
|---|---|---|
| 0 | `T_EOF` | end of the last source |
| 1 | `T_IDENT` | identifier: `[A-Za-z_][A-Za-z_0-9]*` |
| 2 | `T_INT` | integer literal, value folded |
| 3 | `T_CHAR` | char literal, value folded |
| 4 | `T_STR` | string literal |
| 5 | `T_DIR` | `#name` at the start of a directive |
| 6 | `T_HOLE` | `$name` inside a `#rule` template |

Everything else is a **lexeme in the token table**, numbered from 256 in registration order. The
core registers 45 of them at start-up (`tok_init`): the seven type words, `if else loop break
continue return extern`, the punctuation, and the operators. `#token`, `#rule`'s dispatch
literal, and every Tier 3 registration append to the same table — which is why `--dump-tokens`
shows ids above 300 in a taught program, and why the ids `256..269` (`u8` through `extern`) must
never move: registering a token before `tok_init` would shift them and break the core.

Punctuation is matched by **longest prefix**, scanning the table linearly. `>>=` would win over
`>>` if it existed; `p_resplit_punct` is the one way to undo such a match
([hooks.md](hooks.md)).

### Comments

`// to end of line` and `/* ... */`. Block comments do not nest; an unclosed one is
`unterminated comment`.

### Literals

- **Integer** — decimal or `0x` hexadecimal. Stored as `i64`; `0xFFFFFFFFFFFFFFFF` is fine.
- **Char** — `'a'`, with escapes `\n \t \r \0 \\ \' \"`. It folds straight into an integer node;
  there is no separate char type.
- **String** — `"..."`, decoded into the arena, emitted into `__TEXT,__cstring` with a trailing
  NUL, and deduplicated by content (first occurrence wins the `l_strN` symbol). A `\0` **inside a
  string is an error** (`\0 not allowed in string`): `__cstring` is `S_CSTRING_LITERALS` and the
  linker merges literals at the first NUL, so `"a\0b"` and `"a"` would end up at one address.
  A string expression has type `uptr`.

---

## 2. Types

Seven words in the core, and an eighth the core itself **registers**: `i32` (M45). A ninth is
`type_alias` (a second name for an existing one) or, since M24, `type_new` — a **primitive the
core has never heard of**, registered by a module.

| type | width | signedness of `/ % >>` | notes |
|---|---|---|---|
| `u8` | 1 | unsigned | bytes |
| `u16` | 2 | unsigned | Mach-O 16-bit fields |
| `u32` | 4 | unsigned | Mach-O 32-bit fields, instruction words |
| `u64` | 8 | unsigned | wide unsigned values |
| `i64` | 8 | **signed** | the working integer type |
| `uptr` | 8 | unsigned | the only pointer: opaque, no pointee, byte arithmetic |
| `void` | — | — | return type only |
| `i32` | 4 | **signed** | M45; C's `int`, and the type an `extern` returning `int` declares |

There is no `i8/i16`, no float, no `bool` — but each of those is now **one line** away, see
"Types a module registers" below. A comparison yields `i64` `0` or `1`, and comparisons are always
**signed** — the convention is that addresses stay below 2^63; it is documented, not enforced.

### `i32`: the eighth word, and it is registered, not a keyword

`i32` is not in the `TY_*` ladder and is not a token `tok_init` creates. The core calls
`type_new("i32", 4, 4, TK_SINT)` from `core_types_init()` before `user_init()`, so the word arrives
through exactly the mechanism M24 gave a module — the alias table, `word_add`, `type_of_token`'s
last arm — and `TY_MAX` is still 7. Two consequences a program can see: `i32` is **reserved
program-wide** (a variable called `i32` is `name reserved by a syntax/type_alias registration`),
and a recreated compiler whose machine cannot sign-fill removes the word with
`type_disable(ty_i32)`, after which every position that names it answers
`i32: removed by this compiler` (that is what `examples/avr` does).

The value of a type narrower than the word is **defined by extension from its width** — zero for
`u8`/`u16`/`u32`, sign for `i32`:

| | `u8` `u16` `u32` | `i32` |
|---|---|---|
| a load into an expression (a local, a global, a parameter re-read) | zero-extends: `ldrb`/`ldrh`/`ldr w`; `movzx`/`mov r32`; `lbu`/`lhu`/`lwu` | **sign-extends**: `ldrsw`; `movsxd`; `lw` |
| a store | truncates to the width | truncates — **the same instruction** as `u32` |
| arithmetic | 64-bit on the extended value; wraps at the next store or cast | the same |
| `/ % >>` | unsigned | **signed** (`sdiv`/`idiv`, `asr`) |
| comparisons | signed on the 64-bit value | signed on the 64-bit value, and now correct |
| `(T) x` | zero-fill: `and #mask` / `mov wd, wn` | **sign-fill**: `sxtw` / `movsxd` / `sext.w` |
| a constant cast, at compile time | masks | sign-extends from bit 31 |
| a literal | there is none; `i32 x = -1` stores `0xffffffff` and reads back `-1` | |
| the signed read of raw memory | `ld32(p)` stays `u32`, zero-extending | spelled `(i32) ld32(p)` |

`u32` and `i32` are the same four **stored** bytes; what differs is bits 63..32 of the value once
it is read. `(i32) 0xffffffff` is `-1` and `(u32)` of an `i32` `-1` is `4294967295`.

**The one observable difference from C**, stated once: `INT_MIN / -1`. With
`i32 a = -2147483648; i32 b = -1;`, `a / b` is a 64-bit `sdiv` on sign-extended operands and the
answer is `2147483648` on every machine — no `#DE` trap on x86-64, where a 32-bit `idiv` would
raise one — and `INT_MIN` again only after a store back into an `i32`. That is the price of
"64-bit on the extended value", the model `u32` has had since M0
(`u32 a = 0xffffffff; i64 x = a + 1` is `4294967296`), and it is what keeps `fold()` and the
runtime in agreement.

`uptr` has no pointee type, so `p + 1` is one **byte** further, never one element. There is no
`*p` and no `p->f`: memory is read and written by explicit width (§ 5).

A cast is C-shaped, `(u32) x`, and unambiguous because a type keyword always follows the `(`. It
narrows through a mask (`u8`/`u16`/`u32`) and is otherwise a no-op. `(void) x` is
`cast to void`.

### Types a module registers (M24)

`type_new(name, width, align, kind)` ([hooks.md](hooks.md) § 3) appends ids past the ladder. The
core appends the **eighth**, `i32`, from `core_types_init()` before `user_init()`; a module's first
is the **ninth**. The rule that keeps the core honest is a number: **an id below `TY_MAX` (7) is a
core type and behaves exactly as it always has; an id at or above it was registered, and every core
decision about it is delegated** — to the registry's columns, and to nothing that tests the id
itself. The core consumes three of the four columns and one reading of the fourth —

- `width` sizes a global, an array element and a **frame slot** (`slot_new(type_width(ty))`), so a
  16-byte type gets 16 bytes of frame where an `i64` gets 8;
- `align` is the alignment `glob_place` places it at;
- `name` is what `--dump-ast` prints (`type=f64`, not `?`);
- `kind` — `TK_INT`, `TK_FLOAT`, `TK_WIDE`, `TK_OPAQUE`, `TK_SINT` — is what the **machine**
  dispatches on when it does not know the exact id. Since M45 the core reads it too, in exactly
  three places: `type_signed` (signed `/ % >>`), `fold_taught` (what folds) and `walk_narrow`
  (what is extended after a call and before a `return`).

Everything else about such a type belongs to the module that registered it: its literals
(`syntax_lit`), its arithmetic and its ABI (a derived machine table, [machine.md](machine.md)) and
its named hardware instructions (`intrinsic`). The core **does not fold** `+`, `-`, `~`, `!` or a
cast over a literal of a `TK_FLOAT`, `TK_WIDE` or `TK_OPAQUE` type — it has no arithmetic for a
representation it did not define, so the node reaches the module's machine untouched. It does fold
a `TK_INT` or `TK_SINT` one, because for those two kinds the runtime **is** the core's own integer
operators.

That is also what makes a signed narrow integer one line of a module: `type_new("i16", 2, 2,
TK_SINT)` gets `ldrsh`, `sxth`, signed division, signed comparison and a narrowed call result from
the core and from a machine that honours the kind, with no further line anywhere
(`lib/user_syntax_demo.mc` does exactly this, and `scripts/check-surface.sh` asserts it).

`type_new` reserves the word for the whole program, exactly as `type_alias` does: a compiler that
loads `<float>` has no identifier called `f32`. That is why `<float>` is not in
`lib/user_default.mc` — nobody gets it by accident.

The name is valid in all seven type positions at once (global, local, parameter, `extern`, cast,
array element, `p_type()`), because they all end in the same lookup.

---

## 3. Expressions

### Precedence

Higher binds tighter. This is the Pratt table `--dump-rules` prints; `#infix` and
`syntax_infix` add rows to the same table, so a taught operator sits in one comparable order with
the core's.

| prec | operators | associativity | notes |
|---|---|---|---|
| — | `f(a, …)`, `(e)`, literal, name | — | primary |
| — | `- ~ ! &` | prefix | unary minus, bitwise not, logical not, address-of |
| 10 | `* / %` | left | signedness follows the **left** operand's type |
| 9 | `+ -` | left | |
| 8 | `<< >>` | left | `>>` is `asr` when the left operand is `i64`, `lsr` otherwise |
| 7 | `< <= > >=` | left | result 0/1 |
| 6 | `== !=` | left | result 0/1 |
| 5 | `&` | left | bitwise |
| 4 | `^` | left | bitwise |
| 3 | `\|` | left | bitwise |
| 2 | `&&` | left | **short-circuit** |
| 1 | `\|\|` | left | **short-circuit** |

`&&` and `||` short-circuit, which is not an optimisation but a requirement: the compiler's own
source is full of `p != 0 && ld8(p) == 'x'`.

Assignment is **not** in this table. `x = e` is a *statement*, not an operator, so there is no
`a = b = c` and no `if (x = 1)`. That is also why a `syntax_infix` handler can read an `=` of its
own after the operator it owns.

```mc
// expect-exit: 42
i64 main() {
    i64 a = 2 + 4 * 10;                 // 42
    if (a != 42) return 1;
    if ((7 * 6 & 255) != 42) return 2;
    if ((1 << 5) + 10 != 42) return 3;
    u64 big = 0xFFFFFFFFFFFFFFFF;
    if (big / 2 != 0x7FFFFFFFFFFFFFFF) return 4;   // udiv: left operand is u64
    i64 neg = 0 - 8;
    if (neg / 2 != 0 - 4) return 5;                // sdiv: left operand is i64
    i64 z = 0;
    if (z && 1 / z) return 6;                      // short-circuit: no division happens
    return a;
}
```

### Constant folding

`fold()` runs over the whole unit before codegen, and folds constant against constant with the
same signedness rule as the runtime. A `#define` is folded at *definition* time and is therefore
a constant, never a textual macro. Folding `x / 0` where both sides are constants is
`division by zero` at compile time.

Folding stops at a **kind the core's integer operators do not fit** (§ 2): `fold_unary`,
`fold_binary` and `fold_cast` each return early when an operand — or, for a cast, the destination
— is `TK_FLOAT`, `TK_WIDE` or `TK_OPAQUE`. Without that, a float literal carried as its IEEE bit
pattern would make `1.5 + 2.5` an integer add of two bit patterns and produce an infinity at
compile time with no diagnostic. `--dump-ast` shows the tree *before* `fold()` runs, so the
observable difference is in `--dump-asm`: a taught `-1.5` leaves a `fneg` behind where a core `-1`
leaves one `movz`.

A `TK_INT` or `TK_SINT` type folds, core or registered, and `fold_cast` masks to the type's width
and then fills the bytes above it by the kind — which is exactly what `MTASK_CAST` does at run
time. So `#define M (i32) 0x80000000` is the constant `-2147483648` and not an instruction.

### Division by zero at run time is the target's answer, not the language's

A divisor that is only zero at run time, and `INT64_MIN / -1`, reach the hardware unguarded:
AArch64's `sdiv`/`udiv` never trap and give `0`, `x` and `INT64_MIN`; x86-64's `idiv`/`div` raise
`SIGFPE` and the process dies; wasm will trap (`docs/specs/M33.md` § 8). The same source therefore
behaves differently on the two shipped targets, deliberately — see
[../core-language.md](../core-language.md) § "Division by zero, and `INT64_MIN / -1`".

---

## 4. Statements

```
stmt := "if" "(" expr ")" stmt [ "else" stmt ]
      | "loop" block
      | "break" [ INT ] ";"
      | "continue" ";"
      | "return" [ expr ] ";"
      | type IDENT [ "[" INT "]" ] [ "=" expr ] ";"
      | IDENT "=" expr ";"
      | expr ";"
      | block
block := "{" stmt* "}"
```

- `loop { }` is the **only** loop. `while` and `for` come from the prelude as `#rule`s (§ 8).
- `break N;` leaves N enclosing loops; `break;` is `break 1;`. `N` beyond the current depth is
  `break out of range`, and `break 0;` is `break expects a positive level`. No labels are needed
  because a level count says everything a label would.
- `continue;` restarts the innermost `loop`. Inside a prelude `for`, that means the step is
  skipped — the step lives at the end of the generated body (§ 8).
- The assignment statement's left side must be a plain name (`left side of assignment must be a
  name`); assigning to an array name is `assignment to array`.

```mc
// expect-exit: 21
i64 main() {
    i64 i = 0;
    i64 s = 0;
    loop {
        loop {
            i = i + 1;
            if (i > 6) break 2;         // leaves BOTH loops at once
            s = s + i;
        }
    }
    return s;                            // 1+2+3+4+5+6 = 21
}
```

---

## 5. Memory

There is no dereference syntax. Eight intrinsics do all of it:

| intrinsic | reads/writes | result |
|---|---|---|
| `ld8(p)` `ld16(p)` `ld32(p)` `ld64(p)` | 1/2/4/8 bytes at `p` | zero-extended `i64` |
| `st8(p, v)` `st16(p, v)` `st32(p, v)` `st64(p, v)` | 1/2/4/8 bytes at `p` | `void` |

`&x` gives the `uptr` of a local, a global, **or a function** (§ 7). An array name decays to
`uptr` on its own. `callp(p, a1, …, a7)` calls the address `p` (§ 7).

Wrong arity on any of these is `wrong arity in intrinsic`.

```mc
// expect-exit: 0
// expect-stdout: 46368
#include <sys>

i64 fib(i64 n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

i64 main() {
    u8 buf[24];
    st8(buf, 'x');
    if (ld8(buf) != 'x') return 1;
    putnum(fib(24));
    write(1, "\n", 1);
    return 0;
}
```

---

## 6. Declarations

### Locals

`type x = e;` and `type x[N];`. A local lives on the frame at `[sp, #k]`. `void` is refused
(`local of type void`).

- A local array's `N * width` must be ≤ 4095 (`local array too large`).
- The whole frame — locals, arrays and the spill area, rounded up to 16 — must be ≤ 4095, because
  `sub sp, sp, #imm` only carries 12 bits (`frame too large`).

### Globals

`type x = <constant>;` goes to `__DATA,__data`; `type x[N];` with no initializer is a
reservation in `__DATA,__bss`; `type x[N] = { … }` or `type x[] = { … }` is an initialised array
in `__data`, aligned to 16.

- Elements are folded constants written at the type's width. Fewer elements than `N` zero-fills
  the rest; more is `initializer with too many elements`.
- For a `uptr` array, a string element writes eight zero bytes plus an `UNSIGNED` relocation
  against that string's `l_strN` symbol — that is how a table of pointers to literals is built.
- A non-constant initializer is `global initializer must be constant`.

```mc
// expect-exit: 42
uptr names[] = {"zero", "one", "two"};   // three relocated pointers in __data
u32  t[4]    = {1, 2, 3};                // the fourth element comes out zeroed
i64  sums[2] = {20 + 22, 7 * 6};         // folded in the element
u8   scratch[64];                        // __bss

i64 main() {
    if (ld8(ld64(names + 8)) != 'o') return 1;
    if (ld32(t + 12) != 0) return 2;
    st64(scratch, 1);
    if (ld64(scratch) != 1) return 3;
    return ld64(sums);
}
```

### Functions

`type name(type a, …) { }`, at most **12** parameters (`at most 12 parameters`): the first eight
travel in registers and the rest on the stack ([objects.md](objects.md) § 4). There are no varargs. A parameter of type `void` is refused. The unit is
read in two top-level passes, so a function may be called before it is defined and mutual
recursion needs no forward declaration.

A **prototype** is `type name(params);` with no body and no `extern`. The later definition must
match the return type and the arity (`declaration does not match prototype`); a prototype nobody
defines is `prototype with no definition`.

### A call returns what it declares (M45)

The result of a call has the type the **callee's declaration** gives it, and when that type is
narrower than the word the compiler extends it — by the sign for `i32` (and for any `TK_SINT` a
module registered), by zero for `u8`/`u16`/`u32`. This is not an optimisation detail: AAPCS64, the
SysV x86-64 ABI and both Windows ABIs all leave the bits **above** a 32/16/8-bit result
unspecified, so a caller that reads all 64 of them is reading whatever the callee happened to
leave. Declaring `extern i32 open(...)` is therefore how a C `int` is spelled, and
`i64 fd = open(...); if (fd < 0)` then works.

The symmetric half holds too: an `mc` function declared `u8` or `i32` extends its own result
before `return`, so a C caller of it gets what its ABI entitles it to. A function with no explicit
`return` is untouched — that is what keeps the `#opcode` syscall wrappers, which rely on "the
epilogue leaves `x0` alone", working.

`callp` is the exception, by decision: a pointer call has no declaration, its result stays `i64`,
and a caller that knows better writes `(i32) callp(...)`.

```mc
// expect-exit: 42
u8  low(i64 x)  { return x; }        // 300 -> 44, on both sides of the call
i32 neg()       { return 0 - 1; }

i64 main() {
    if (low(300) != 44) return 1;
    if (neg() >= 0) return 2;        // -1, not 4294967295
    return 42;
}
```

### `extern`

`extern type name(type a, …);` declares an undefined symbol `_name`. The compiler does **not**
check that the symbol exists. Who catches a typo depends on the output path:

- `.o` + `ld` — the link fails with `Undefined symbols for architecture arm64`.
- `--exe` — the binary is produced and signed, and `dyld` kills it at load time with
  `Symbol not found`, exit 134.

That difference is deliberate: `--exe` would have to read the SDK's `.tbd` files to do better,
and there is no built-in list of known symbols. Use the `.o` path when you want the error at
build time. `#dylib` ([directives.md](directives.md)) says which library an `extern` comes from.

**Declare the width C declares.** A C function returning `int` is `extern i32 f(...)`, not
`extern i64 f(...)`: the extra bits are unspecified and § 6 above says what the compiler does with
the truthful declaration. `<sys>` (`lib/sys.mc`) is the one place in this repository that keeps
`i64` for a set of `int`-returning functions, and it does so on a measurement rather than a
preference — libSystem's syscall wrappers hand back a full 64-bit `-1`
([M45](../specs/M45.md) § Implementation notes) — and because the frozen seed compiles that file
and cannot spell `i32` at all. A program wanting the truthful declaration writes its own
`extern i32 open(uptr, i64, i64);` and does not include `<sys>`, since two disagreeing
declarations of one name are `declaration does not match prototype`.

**`c_int(v)` — the same answer without the declaration.** The compiler's own arena
(`src/arena.mc`, part `<mc/core_min>`) exports one function for the case where the truthful
declaration is not available:

```
i64 c_int(i64 v);      // the low 32 bits of v, sign-extended from bit 31
```

It is the value of a C `int` result read as a signed 32-bit quantity: `c_int(0xffffffff)` is `-1`,
`c_int(0x7fffffff)` is `2147483647`, and `c_int(0x00000000ffffffff)` and
`c_int(0xffffffffffffffff)` are both `-1` — which is the point. Bits 63..32 of a 32-bit return are
unspecified on every ABI `mc` targets, so `c_int` is correct whether the callee sign-extended, zero-
extended or left rubbish there, and it is pure arithmetic, so it needs no support from the machine.

`src/` uses it instead of narrow declarations, and that is a constraint rather than a preference:
`src/*.mc` and `lib/sys.mc` are compiled by the frozen C seed, which cannot spell `i32` at all, and
declaring those results `u32` would make this compiler emit an extension the seed cannot emit —
`scripts/check-asm.sh` compares the two over exactly those files. The call sites are
`c_int(open(...))`, `c_int(creat(...))` and `c_int(waitpid(...))`. `<sys>` (`lib/sys.mc`) keeps
`i64` for the same reason and does not need `c_int`, on the measurement recorded above.

A program that can be compiled by `mc` itself — anything outside the seed set — has no reason to
use `c_int`: it writes `extern i32 f(...)` and the compiler does the extension at the call.

---

## 7. Function pointers

The core has no function type. `&name` on a function or an `extern` is a `uptr` like any other
(`adrp`/`add`, relocations `PAGE21` + `PAGEOFF12`), and the indirect call is an intrinsic:

`callp(p, a1, …, a11)` puts `p` in `x16` and the arguments where a direct call would put them —
`x0..x7`, then the stack — and issues `blr x16`. Live depth registers are saved exactly as for a
`bl`. The result is `x0`, typed `i64` — a pointer call has no declaration, so it is the one call
M45's narrowing does not touch; converting it is the caller's job, `(i32) callp(...)`. Arity is 1 to 12 counting
the pointer (`callp expects 1 to 12 arguments`).

```mc
// expect-exit: 42
i64 add2(i64 a) { return a + 2; }
uptr tbl[1];

i64 main() {
    st64(tbl, &add2);
    return callp(ld64(tbl), 40);
}
```

Known limit on the `.o` + `ld` path only: `&name` for an `extern` that lives in a dylib produces
a correct object, but `ld` refuses it — an imported symbol only has an address through `__got`
and the core does not emit `GOT_LOAD_PAGE21`. Through `--exe` it always works, because `mc`
resolves the relocation itself and points it at the symbol's stub.

---

## 8. The prelude

`while`, `for`, `+=`, `-=`, `++` and `--` are **not** core syntax. They are four `#token`s and
six `#rule`s in `lib/prelude.mc`, bundled as `<prelude>`, and they arrive only through an
explicit include.

| written | becomes |
|---|---|
| `while (c) { B }` | `loop { if (!c) break; { B } }` |
| `for (INIT COND ; x = STEP) { B }` | `{ INIT loop { if (!COND) break; { B } x = STEP; } }` |
| `x += e;` · `x -= e;` | `x = x + e;` · `x = x - e;` |
| `x++;` · `x--;` | `x = x + 1;` · `x = x - 1;` |

Consequences worth knowing:

- **The body is always a block.** `while (c) x++;` without braces does not match the pattern.
- **`for`'s step is `ident $x = expr $step`**, because assignment is a statement in the core, so
  it is written `i = i + 1` and not `i++`.
- **`for (; c; s)` does not exist**: the pattern requires a `stmt $init` and the core has no
  empty statement. Use `while`.
- **`while` and `for` become reserved words** from the include on: a rule's dispatch literal is
  registered in the lexer, so `i64 while = 1;` stops being a valid declaration.

```mc
// expect-exit: 0
// expect-stdout: 45
#include <sys>
#include <prelude>

i64 main() {
    i64 s = 0;
    for (i64 i = 0; i < 10; i = i + 1) {
        s += i;
    }
    putnum(s);
    write(1, "\n", 1);
    return 0;
}
```

---

## 9. Program shape and entry point

A unit is a sequence of top-level declarations: globals, prototypes, `extern`s, functions and
directives. The entry point is `i64 main(...)`; `--exe` refuses a unit without one
(`no _main: cannot generate an executable`). `main` receives `argc` in the first parameter and
`argv` — a `uptr` to an array of `uptr` — in the second, so `argv[i]` is `ld64(argv + i * 8)`.

```mc
// expect-exit: 2
i64 main(i64 argc, uptr argv) {
    if (ld8(ld64(argv)) == 0) return 1;   // argv[0] is a non-empty string
    return argc + 1;                       // run with no arguments: 1 + 1
}
```

There is no runtime and no `libc` unless you include one: `<sys>` declares libSystem's
`open/creat/read/write/close/exit` and adds `strlen`/`puts`/`putnum` written in the language;
`<sys_svc>` is the same interface through `svc #0x80` with no libSystem at all; `<sys_linux>` is
the Linux syscall layer plus a `_start`. See [bundle.md](bundle.md).

Memory is a global array plus a bump pointer — that is what `src/arena.mc` is. There is no
`malloc` and no `free` in the language.

---

## 10. Limits

Everything here is a real diagnostic; the full catalogue is [diagnostics.md](diagnostics.md).

| limit | value | error |
|---|---|---|
| parameters per function | 12 (8 in registers) | `at most 12 parameters` |
| `callp` arity | 12 including the pointer | `callp expects 1 to 12 arguments` |
| expression depth | 64 | `expression too deep` |
| frame size | 4095 bytes | `frame too large` |
| local array | 4095 bytes | `local array too large` |
| global array | 2^30 bytes | `global array too large` |
| `#rule` re-expansion | 64 levels | `too many nested rules` |
| `#embed` file | 16 MiB | `#embed file is empty or over 16 MiB` |
| branch distance inside a function | ±1 MiB (the 19-bit range, checked uniformly) | `branch too far` |
| `bl` distance | ±128 MiB | `bl too far` (in `--exe`) |
| substitutions per pushed source | 16 | `too many substitutions` |

Every other table in the self-hosted compiler — nodes, symbols, strings, functions, the token
table — **has no ceiling**: it is an arena block that doubles on demand, pre-sized from an
estimate. `mc limits` reports the sizing; see [cli.md](cli.md) and [toml.md](toml.md).

The C seed still has fixed `MAX*` constants, because it only ever has to compile `src/mc.mc`.
`make check-limits` is the guard that warns before one of them fills up.

---

## 11. What the core deliberately does not have

`struct`, `while`/`for`, `switch`, `goto`, labels, `float`, `bool`, `i8/i16/i32`, typed pointers,
varargs, `+=` and `++`, multiple assignment, the ternary operator, operator overloading, modules,
namespaces, generics, classes, and a standard library.

Most of them are reachable **through the surface** instead: `while`/`for`/`+=`/`++` from the
prelude, `bool` from `type_alias`, `f32`/`f64` from `<float>` — a library, not a keyword, with its
literals, its four ABIs and its instructions in `lib/` and nothing in `src/` — over
M24's `type_new`/`syntax_lit`/`intrinsic` and a derived machine ([hooks.md](hooks.md) § 3,
[../guide/96-a-new-primitive.md](../guide/96-a-new-primitive.md)), classes and generics from
`syntax`/`syntax_expr` (`examples/lang` teaches all of the last row). What is genuinely absent is `struct` — it would
need a `type $t` hole in `#rule` and a layout model, which is more than `#rule` delivers; the
answer in this codebase is `#define` offsets plus accessor functions, which is also what makes
the compiler's own data flat and portable.
