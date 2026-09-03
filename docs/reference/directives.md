# The ten `#` directives

A directive is a `#name` at the start of a line-ish position, processed **at compile time, in
source order**, mutating the compiler's own tables as the parse goes. There are exactly ten, and
the list is `dir_index()` in `src/lex.mc`:

`#include` · `#define` · `#token` · `#infix` · `#prefix` · `#rule` · `#section` · `#opcode` ·
`#dylib` · `#embed`

Anything else is `unknown directive`. Two of them — `#include <name>` and `#embed` — exist only
in the self-hosted compiler; the frozen C seed answers `#include expects a string` and
`unknown directive` respectively.

The first six shape the *language*; the last four shape the *output*. Together they are what
`docs/surface.md` calls Tier 1: teaching by directive, with no code running inside the compiler.
Tier 2 and Tier 3 — passes, backends and syntax handlers — are functions instead, and live in
[hooks.md](hooks.md).

---

## `#include "path"` and `#include <name>`

Textual inclusion, **once only**. `path` resolves against the directory of the file that wrote
the directive, then against each `[include].paths` root in order ([toml.md](toml.md)). Paths are
normalised lexically (`.` and `..`) before the once-only check, so `inc/c.mc` and
`inc/a/../c.mc` count as one inclusion.

`<name>` is served from the **bundle carried inside the binary** — there is no filesystem
fallback, and an unknown name is `unknown bundled include: <name>`. The catalogue is
[bundle.md](bundle.md).

```mc
// expect-exit: 0
// expect-stdout: 42
#include <sys>                     // the bundle: lib/sys.mc + lib/io.mc

i64 main() {
    putnum(42);
    write(1, "\n", 1);
    return 0;
}
```

Errors: `#include expects a string`, `unterminated #include <name>`, `unknown bundled include`,
`mc: cannot open: <path>`, `path with too many segments`.

---

## `#define NAME expr`

A **folded constant**, not a textual macro: `expr` is parsed and folded at definition time and
the name becomes that value from there on. A repeat is `duplicate #define`, and declaring a
local, parameter, global or function with a name a `#define` already owns is
`name already defined by #define` — in either order.

```mc
// expect-exit: 42
#define ROWS 6
#define COLS 7
#define CELLS (ROWS * COLS)        // folded here, not expanded at each use

i64 main() { return CELLS; }
```

Errors: `#define expects a name`, `#define expects a constant expression`, `duplicate #define`.

---

## `#token "lexeme"`

Registers a new lexeme in the lexer's table, with the next free id. Punctuation is matched by
longest prefix, so `#token "<+>"` makes `<+>` a single token instead of `<`, `+`, `>`. This is
the prerequisite for `#infix`, `#prefix` and any `#rule` whose pattern mentions a compound
operator: without it the lexer never produces the token and the error surfaces far from the
cause (`expression expected`).

Errors: `#token expects a string`, `empty lexeme`.

---

## `#infix "op" PREC left|right TEMPLATE`  ·  `#prefix "op" TEMPLATE`

Extend the Pratt table. `$1` and `$2` are the operands; the template is parsed **immediately** by
the parser that already exists and becomes a tree with holes, so expansion is a tree copy and
there are no precedence surprises. `PREC` is 1..100; the core's own operators occupy 1..10
(see [language.md](language.md)).

```mc
// expect-exit: 42
#token "<+>"
#token "~~"
#infix  "<+>" 9 left ($1 + $2) * 2
#prefix "~~"  0 - $1

i64 main() {
    i64 v = 10 <+> 11;             // (10 + 11) * 2 = 42
    if (~~5 != 0 - 5) return 1;
    return v;
}
```

`#infix` on a token a `syntax_infix` handler already owns clears the handler: the template wins.
A second `syntax_infix` on the same token is refused instead — see [hooks.md](hooks.md).

Errors: `#infix expects the precedence`, `#infix expects left or right`,
`precedence out of 1..100`.

---

## `#rule stmt: PATTERN => TEMPLATE`

A statement-level macro with a flat pattern and a parsed template. Only the category `stmt`
exists; `#rule expr:` is reserved (`#rule expr: reserved, not yet supported`) and anything else
is `#rule only knows category stmt`.

**Pattern items** are either a literal token or `nt $name` with `nt` ∈ `expr | stmt | block |
ident`. `type $t` is out of scope (`nt \`type\` is out of scope for M9`).

**Dispatch** is by the token that opens the statement: the table is linear and indexed by it, so
there is no backtracking, and the last rule registered for a token wins. Once a rule is chosen
every item must match.

- The first item must be a **literal token** (`the #rule pattern must open with a literal
  token`), with one exception: a leading `ident $x`, which serves compound forms like
  `ident $x += expr $e ;`. Dispatch then happens on the literal that follows, and the name on the
  left has already been read by the normal statement path.
- A literal that is an identifier is registered in the lexer, so it becomes a **reserved word**
  for the rest of the unit — including over names declared earlier. Choose opening words you do
  not intend to use as identifiers.
- A core keyword as the dispatch literal is refused: `cannot redefine core keyword`.

**Holes come in two kinds.** `expr`/`stmt`/`block` become nodes and travel by tree copy;
`ident $x` and the gensym `$$t` become *names*, which is what lets a hole stand where the AST
holds a name — the left side of an assignment, or a local declaration.

**Hygiene is gensym only.** `$$name` in the template becomes a fresh local per expansion, named
`$g1`, `$g2`, … from a global counter. The `$` is load-bearing: the lexer never forms an
identifier containing `$`, so a user name can never collide with a gensym.

```mc
// expect-exit: 42
#token "+="
#rule stmt: ident $x += expr $e ;   => $x = $x + $e;
#rule stmt: swap ( ident $a , ident $b ) ;
    => { i64 $$t = $a; $a = $b; $b = $$t; }

i64 main() {
    i64 a = 2;
    i64 b = 40;
    swap(a, b);                    // a = 40, b = 2
    a += b;                        // 42
    return a;
}
```

A rule may use rules defined before it: the template is parsed by a parser that already knows
them, so expansion happens once, at definition time, and infinite recursion is impossible by
construction. Nesting at definition time is capped at 64 levels (`too many nested rules`).

`--dump-rules` prints the table ([cli.md](cli.md)). The prelude — `while`, `for`, `+=`, `-=`,
`++`, `--` — is nothing but six of these rules plus four `#token`s
([language.md](language.md) § 8).

Errors: `#rule expects category stmt`, `expected : after the #rule category`,
`empty #rule pattern`, `expected $name in the pattern`, `duplicate hole in #rule`,
`too many holes in #rule`, `too many name holes in #rule`, `too many items in the #rule pattern`,
`#rule without =>`, `hole $name has no rule binding it`, `hole out of range in template`,
`$$name only works in a #rule template`, `the rule expected`, `the rule expected a name`,
`the rule expected a name on the left`.

---

## `#section SEG SECT [FLAGS] [ALIGN]`

Placement: everything emitted after it — functions and globals alike — goes into that section,
until the next `#section`. With **no arguments** it returns to the defaults (`__TEXT,__text` for
code, `__DATA,__data` / `__DATA,__bss` for globals).

`FLAGS` is the Mach-O section flags word (`0x80000400` = pure instructions, `1` = `S_ZEROFILL`,
`0` = regular data); `ALIGN` is a log2 and defaults to 3. Both must be constants.

```mc
// expect-exit: 42
#section __DATA __tbl 0 3
u64 tbl[4] = {40, 1, 1, 0};        // real bytes, in __DATA,__tbl

#section __DATA __zt 1 4           // S_ZEROFILL: counted, but no file space
u64 zt[2];

#section __TEXT __hot 0x80000400 2
i64 hot(i64 x) { return x + 2; }   // this function lands in __TEXT,__hot

#section                           // back to the defaults
i64 main() {
    st64(zt, ld64(tbl));
    return hot(ld64(zt));
}
```

Errors: `#section expects the section name`, `#section expects constant flags`,
`#section expects constant alignment`, `section flags out of 32 bits`, `alignment out of 0..15`,
`function in a zerofill section`, `global with initializer in a zerofill section`.

---

## `#opcode name(params) EXPRESSION`

Teaches one instruction. The expression is a 32-bit word template over the parameters; calling
`name(...)` with **constant** arguments folds the word and emits it straight into the current
function's instruction stream (it shows up as `.word` in `--dump-asm`). It is not a function and
has no symbol.

This is how `<sys_svc>` implements the five system calls with no libSystem at all: the prologue
writes the parameters to the frame without touching `x0..x7`, and the epilogue does not touch
`x0`, so a function whose whole body is `#opcode` calls sees its arguments in the ABI registers
and returns whatever the kernel left in `x0`.

```mc
// expect-exit: 0
// expect-stdout: hi
#opcode mov16(rd, imm) 0xD2800000 | (imm << 5) | rd
#opcode svc(imm)       0xD4000001 | (imm << 5)

#define SYS_WRITE 4
#define SYS_EXIT  1

i64 sys_write(i64 fd, uptr buf, i64 n) {
    mov16(16, SYS_WRITE);          // x16 = the syscall number
    svc(0x80);                     // x0..x2 already carry fd, buf, n
}

i64 main() {
    sys_write(1, "hi\n", 3);
    return 0;
}
```

Errors: `#opcode expects a name`, `expected ( in #opcode`, `parameter name expected in #opcode`,
`at most 8 parameters in #opcode`, `expected ) in #opcode`, `duplicate #opcode`,
`#opcode argument not constant`, `wrong number of arguments in #opcode`,
`operator without constant folding`, `emitted word does not fit in 32 bits`.

### `emit()` and `reloc()` — what `#opcode` does not cover

`emit(CONST)` writes one raw 32-bit word. `reloc(TYPE, "symbol")` attaches a relocation to the
**next** word emitted in the function; `TYPE` is one of `BRANCH26`, `PAGE21`, `PAGEOFF12`,
`UNSIGNED`, predefined constants. An unknown symbol becomes an undefined external.

`UNSIGNED` is accepted as a constant but refused in this position — it is an 8-byte relocation
over a 4-byte word, so it would overrun the next instruction. Write an 8-byte address as a global
array initializer instead, which puts the `UNSIGNED` where it belongs.

```mc
// expect-exit: 42
i64 helper() { return 42; }

i64 call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);              // a raw bl; the offset comes from the relocation
}

i64 main() { return call_helper(); }
```

Errors: `emit expects an argument`, `emit expects a constant`, `reloc expects two arguments`,
`relocation type must be constant`, `reloc expects the symbol in quotes`,
`unknown relocation type`, `two relocations for the same word`,
`reloc without an immediately following emit`,
`reloc UNSIGNED requires 8 bytes: use a global array initializer`.

---

## `#dylib "path"`

Says which dynamic library the `extern`s written **after** it come from. The path table is
consulted by the `macho-exe` backend, which emits one `LC_LOAD_DYLIB` per entry and binds each
imported symbol by ordinal (1 is always libSystem, the rest are handed out in the order the
directives appear). `#dylib ""` returns to the default.

```c
#include <sys>

#dylib "/usr/lib/libsqlite3.dylib"
extern i64 sqlite3_libversion_number();

#dylib ""                          // back to libSystem
```

`#dylib` only has an effect on the `--exe` path: the `.o` + `ld` path leaves symbol resolution to
`ld`, which will refuse a `_sqlite3_*` it was not told about. `[libs]` + `[externs]` in `mc.toml`
say the same thing from outside the source, and `#dylib` wins for its own externs
([toml.md](toml.md)).

Errors: `#dylib expects a string`, `too many dylibs for the bind opcode`.

---

## `#embed NAME "path" [lz]`

The bytes of a file as a global `u8` array, plus two `#define`s:

| declares | is |
|---|---|
| `u8 NAME[]` | the bytes, in `__DATA,__data` |
| `NAME_size` | the length of what is stored (compressed, when `lz` is given) |
| `NAME_raw` | the original length of the file |

The path resolves like `#include "path"`, from the file that wrote the directive; inside a
bundled `<name>` include the payload comes from the bundle too. With `lz` the bytes are
compressed with `src/lz.mc`'s LZ77, and `<lz>`'s `lz_inflate` is what reads them back.

```c
#include <sys>
#include <lz>

#embed plain  "data.txt"
#embed packed "data.txt" lz

u8 out[4096];

i64 main() {
    write(1, plain, plain_size);              // plain_size == plain_raw
    lz_inflate(packed, packed_size, out);     // packed_raw bytes come back
    write(1, out, packed_raw);
    return 0;
}
```

Every byte costs one AST node, so a large embed is bounded by the arena long before the declared
16 MiB ceiling. Working examples: `tests/mc/070-embed.mc` and `tests/mc/071-embed-lz.mc`.

Errors: `#embed expects NAME "path" [lz]`, `#embed file is empty or over 16 MiB`.
