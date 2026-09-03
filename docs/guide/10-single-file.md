# 10 — One file, one program

Everything you can write without a project file. The exhaustive rules are
[../reference/language.md](../reference/language.md); this page is the working tour.

## The shape of a program

A source file is a flat list of top-level declarations — globals, functions, `extern`s,
prototypes, directives — and the entry point is `i64 main(...)`.

```mc
// expect-exit: 42
#include <sys>

#define ANSWER 42

i64 twice(i64 x) { return x + x; }

i64 main() {
    return twice(ANSWER / 2);
}
```

Declarations are read in two passes, so a function may be called before it is defined and mutual
recursion needs no forward declaration.

## Types, and the one pointer

`u8 u16 u32 u64 i64 uptr void`. That is the whole list.

`i64` is the working type. `u8`..`u64` exist because file formats have fields of those widths.
`uptr` is the **only** pointer, and it is opaque: no pointee type, no `*`, no `->`, and `p + 1`
is one byte further. Memory is read and written by explicit width:

```mc
// expect-exit: 42
i64 main() {
    u8 buf[8];
    st8(buf, 40);
    st8(buf + 1, 2);
    return ld8(buf) + ld8(buf + 1);
}
```

`ld8 ld16 ld32 ld64` read and zero-extend; `st8 st16 st32 st64` write. An array name decays to
`uptr`; `&x` gives the address of a local, a global or a function.

There is no `bool`: a comparison produces `i64` `0` or `1`. There is no `float`. There is no
`struct` — the answer here is `#define` offsets plus accessor functions, which is exactly how the
compiler's own data is laid out:

```mc
// expect-exit: 42
#define PT_X    0
#define PT_Y    8
#define PT_SIZE 16

u8 arena[1024];
i64 hp = 0;

uptr alloc(i64 n) {
    uptr p = arena + hp;
    hp = hp + ((n + 7) & ~7);
    return p;
}

i64  pt_x(uptr p)          { return ld64(p + PT_X); }
i64  pt_y(uptr p)          { return ld64(p + PT_Y); }
void set_pt_x(uptr p, i64 v) { st64(p + PT_X, v); }
void set_pt_y(uptr p, i64 v) { st64(p + PT_Y, v); }

i64 main() {
    uptr p = alloc(PT_SIZE);
    set_pt_x(p, 40);
    set_pt_y(p, 2);
    return pt_x(p) + pt_y(p);
}
```

That is not a workaround. It is the discipline that lets the compiler's own source transliterate
1:1 between C and `.mc`, and it means a future `struct` swaps twenty accessors rather than three
thousand call sites.

## Control flow

`if`/`else` and `loop { }`. `break;` leaves one loop, `break N;` leaves N — no labels needed
because a count says everything a label would. `continue;` restarts the innermost loop.

```mc
// expect-exit: 21
i64 main() {
    i64 i = 0;
    i64 s = 0;
    loop {
        i = i + 1;
        if (i > 6) break;
        s = s + i;
    }
    return s;
}
```

`while` and `for` come from `<prelude>`, six `#rule` macros written in the language
([30-teaching.md](30-teaching.md)). Two things to know when you use them: the body is always a
block (`while (c) x++;` does not match the pattern), and `for`'s step is an assignment
(`i = i + 1`, not `i++`) because in the core `=` is a statement rather than an operator.

## Globals, arrays and strings

```mc
// expect-exit: 42
uptr names[] = {"zero", "one", "two"};   // pointers in __data, with relocations
u32  widths[4] = {1, 2, 3};              // the fourth element is zero-filled
i64  total = 40;                          // __DATA,__data
u8   scratch[4096];                       // __DATA,__bss, zeroed by the kernel

i64 main() {
    st8(scratch, 2);
    if (ld32(widths + 12) != 0) return 1;
    if (ld8(ld64(names + 8)) != 'o') return 2;
    return total + ld8(scratch);
}
```

A string literal is a `uptr` into `__TEXT,__cstring`, NUL-terminated and deduplicated by content.
A `\0` **inside** a string is refused — the linker merges cstring literals at the first NUL, so
`"a\0b"` and `"a"` would end up at one address.

## Memory: an array and a bump pointer

There is no `malloc`. A program that needs a heap declares a global array and moves a pointer
through it, exactly as `alloc` does above. `__bss` comes zeroed from the kernel, so no
initialisation is needed. Freeing is your business: the compiler's own arena never frees, and
`examples/lang` builds reference counting with free lists on top of the same idea.

## `extern` and the two output paths

`extern` declares an undefined symbol. The compiler does **not** check that it exists.

```mc
// expect-exit: 0
// expect-stdout: hi
extern i64 write(i64 fd, uptr buf, i64 n);

i64 main() {
    write(1, "hi\n", 3);
    return 0;
}
```

Who catches a typo depends on the path you take:

| path | when a missing symbol is caught |
|---|---|
| `mc prog.mc -o prog.o` + `ld` | at **link** time: `Undefined symbols for architecture arm64` |
| `mc --exe prog.mc -o prog` | at **load** time: `dyld: Symbol not found`, exit 134 |

`--exe` writes the stub and the bind opcode without consulting libSystem. Validating the name
would mean reading the SDK's `.tbd` files, and that dependency was deliberately refused — there
is no built-in list of known symbols. If you want the error at build time, use the `.o` path.

`#dylib "path"` says which library the `extern`s after it come from; `mc.toml`'s `[libs]` and
`[externs]` say the same thing from outside the source
([20-project-toml.md](20-project-toml.md)).

## Function pointers

There is no function type. `&f` is a `uptr` like any other, and the indirect call is an
intrinsic: `callp(p, a1, …, a7)`.

```mc
// expect-exit: 42
i64 add2(i64 a) { return a + 2; }
i64 mul2(i64 a) { return a * 2; }
uptr tbl[2];

i64 main() {
    st64(tbl, &add2);
    st64(tbl + 8, &mul2);
    return callp(ld64(tbl), 40) + callp(ld64(tbl + 8), 0);
}
```

This is the whole mechanism behind passes, backends and vtables: `examples/api` dispatches its
HTTP handlers through exactly this.

## Including files

```c
#include "lib/util.mc"    // relative to THIS file's directory, once only
#include <sys>            // from the bundle inside the binary
```

Relative includes are once-only and path-normalised, so `inc/c.mc` and `inc/a/../c.mc` count as
one inclusion. Angle-bracket includes come from the bundle and have no filesystem fallback — the
catalogue is [../reference/bundle.md](../reference/bundle.md). A project can add extra search
roots with `[include].paths`.

`#define NAME expr` is a **folded constant**, not a textual macro: the expression is evaluated
once, at the definition, and the name is that value afterwards. Redefining it is an error, and so
is declaring a variable with a name a `#define` already owns.

## Choosing a system layer

Exactly one of these, and never `<io>` on its own:

| include | what it is |
|---|---|
| `<sys>` | libSystem `extern`s — the normal choice |
| `<sys_svc>` | the same five calls through `svc #0x80`, taught with `#opcode`; **no libc at all** |
| `<sys_linux>` | the Linux syscall layer plus a `_start`, for `-nostdlib` builds |

```mc
// expect-exit: 0
// expect-stdout: hi
#include <sys_svc>

i64 main() {
    write(1, "hi\n", 3);
    return 0;
}
```

That program contains no `extern` at all: `write` is three instructions the source itself taught
the compiler to emit ([40-backends.md](40-backends.md)).

## When something goes wrong

Every diagnostic is `file:line: message`, and every one of them is catalogued with a cause and a
fix in [../reference/diagnostics.md](../reference/diagnostics.md). Three you will meet early:

- `expression expected` — usually a missing `#token`: without it, a compound operator is lexed as
  two tokens and the parser stops far from the mistake.
- `unknown name` — an identifier that is no local, global, function or `extern`.
- `frame too large` — locals plus spills exceed 4095 bytes, the limit of `sub sp, sp, #imm`. Move
  the big array to a global.

## Next

One file stops being enough when you have a linker to call, libraries to name, or a compiler to
teach first. That is [20-project-toml.md](20-project-toml.md).
