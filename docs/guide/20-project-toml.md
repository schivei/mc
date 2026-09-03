# 20 — A project: `mc build` and `mc.toml`

One file at a time works until you have a linker to call, libraries to name, or a compiler to
teach before you can compile your program at all. `mc build` reads a TOML file and does the whole
thing.

```
mc build [DIR] [--config FILE]
```

`DIR` defaults to `.`, the config to `DIR/mc.toml`. **Every path in the file is relative to the
directory of the config**, so `mc build examples/api` from the repository root does exactly what
`mc build` does from inside `examples/api`.

Every key, with its type and default, is [../reference/toml.md](../reference/toml.md). This page
walks the sections in the order you are likely to need them.

## The smallest useful file

```toml
[project]
entry = "main.mc"
out   = "build/app"
```

```
$ mc build
compile main.mc -> build/app
```

That is it: `entry` compiled with the built-in `macho-exe` backend into a signed executable, with
parent directories created for you. `mc build` prints one line per step, always
`what from -> to`.

Two more keys shape the artifact:

```toml
[project]
name  = "app"          # only used to default [compiler].out
entry = "main.mc"
out   = "build/app.o"
kind  = "obj"          # exe (default) | obj
```

`kind = "obj"` stops at the object file. `out` is `unlink`ed before being written — overwriting a
signed executable on the same inode makes the kernel `SIGKILL` its next run, because the
signature is cached against the inode.

## `[target]` — what machine this is for

```toml
[target]
os   = "macos"         # macos (default) | linux
arch = "aarch64"       # aarch64 only
```

Anything else is refused at the exact position of the offending value:

```
$ mc build tests/proj --config /tmp/windows.toml
/tmp/windows.toml:6:6: only macos and linux (see docs/build.md): target.os
```

`os = "linux"` swaps the object writer for ELF64 and makes `[linker]` required — that is
[50-cross-compile.md](50-cross-compile.md).

## `[include]` — extra roots for `#include "x"`

```toml
[include]
paths = ["lib"]
```

Tried **after** the includer's own directory, in the order written. A project never shadows a
relative include that already resolved; the roots only catch what would otherwise fail. With no
root registered, the lexer behaves exactly as it did before this key existed — not even an extra
`open` happens.

## `[linker]` — handing off to an external linker

Without this section, `kind = "exe"` uses the built-in `macho-exe` backend: no `ld`, ad-hoc
signature, dylibs bound by ordinal. With it, `mc` writes `<out>.o` and spawns the tool.

```toml
[linker]
cmd  = "ld"
args = ["-arch", "arm64", "-platform_version", "macos", "13.0", "13.0",
        "-syslibroot", "{sdk}", "-lSystem",
        "-o", "{out}", "{obj}", "{libs}"]
```

```
$ mc build tests/proj --config tests/proj/link.toml
compile app.mc -> build/app-ld.o
link build/app-ld.o -> build/app-ld
```

| placeholder | expands to |
|---|---|
| `{out}` | `[project].out` |
| `{obj}` | the object just written |
| `{sdk}` | `xcrun --show-sdk-path`, run lazily — only if some argument mentions it, once per build |
| `{sysroot}` | `[sysroot].path` |
| `{libs}` | one argument per `[libs]` entry, in key order |

The first four substitute **inside** an argument, so `-L{sdk}/usr/lib` works. `{libs}` must be a
whole argument, because it expands to several; each expanded value then goes through the same
substitution, so a library may be written `"{sdk}/usr/lib/libsqlite3.tbd"`.

The tool inherits stdin/stdout/stderr, so its diagnostics reach you unchanged, and a non-zero
exit stops the build.

## `[libs]` and `[externs]` — naming dynamic libraries

`#dylib "path"` in a source says which library the `extern`s after it come from. These two
sections say the same thing without touching the source:

```toml
[libs]
sqlite3 = "/usr/lib/libsqlite3.dylib"

[externs]
"sqlite3_*" = "sqlite3"
```

- `[libs]` feeds the very same table `#dylib` does. Ordinals are handed out in key order starting
  at 2, because ordinal 1 is always libSystem.
- `[externs]` maps a symbol name, or a prefix ending in `*`, to a `[libs]` key. The pattern table
  is consulted **after** the exact table, so a `#dylib` in the source always wins for its own
  `extern`s. An `extern` no pattern claims stays on libSystem.
- A key containing `*` must be quoted; bare TOML keys are `A-Za-z0-9_-`.

That this really binds by ordinal, with no `#dylib` anywhere in the sources:

```
$ mc build tests/proj --config tests/proj/exe.toml
compile app.mc -> build/app-exe
$ otool -L tests/proj/build/app-exe
tests/proj/build/app-exe:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/usr/lib/libsqlite3.dylib (compatibility version 1.0.0, current version 1356.0.0)
$ tests/proj/build/app-exe
sqlite ok
```

On a `[linker]` build the ordinals do not matter — the linker resolves symbols — and `[libs]` is
just the list `{libs}` expands to.

## `[compiler]` — build the compiler that will compile your program

This is the section that makes `mc build` more than a Makefile in disguise.

A taught compiler in `mc` is a **file**, not an edit to the compiler's source: `<mc/core>` is the
whole compiler minus exactly one function, `void user_init()`, and a module supplies it
([30-teaching.md](30-teaching.md)). `[compiler]` says which files to glue together:

```toml
[compiler]
modules = ["mc-api.mc"]          # #include'd in order, after the core
out     = "build/mc-api"         # default: build/mc-<project.name>
# core  = "../../src/core.mc"    # optional: pin a checkout instead of the bundle
```

```
$ mc build examples/api
compiler build/mc-api.mc -> build/mc-api
compile main.mc -> build/api
```

Two lines, two steps. The first built a compiler that understands `class` and `interface`; the
second used it to compile the server. Neither `make` nor `ld` was involved.

What happens under those two lines:

1. `mc build` **writes** `<compiler.out>.mc` — a generated file next to the compiler:

   ```c
   // generated by `mc build` from examples/api/mc.toml
   #include <mc/core>
   #include "../mc-api.mc"
   ```

2. It compiles that with the built-in `macho-exe` backend.
3. It **spawns** the binary that came out, as
   `<out> build DIR --config FILE --entry-only`.

The spawn is not decoration. The compiler's tables — lexer, arena, AST, symbols — are process
globals built once, so two compilations never fit in one run. `--entry-only` says "you are the
second half": skip `[compiler]` and compile the entry, reading the same TOML — which is why
`[include]`, `[libs]` and `[externs]` apply to the entry either way.

`[compiler].out` must be a **relative** path with no `..`, because the generated file sits inside
it and includes the modules by relative path — one `../` per directory level, counted on the
normalised path. Both constraints are refused with a clear message.

Since the core comes from the bundle inside the binary, a project needs **no path into this
repository** to teach the compiler. `core = "..."` is still accepted and still wins, which is how
a project pins its own checkout.

## `[limits]` — how much the compiler reserves up front

```toml
[limits]
tolerance = 0.25       # default; a float in [0, 1]
```

`mc` has no fixed table sizes. Before the first table exists it estimates what the build will
need — from a byte-level pre-scan of the entry and everything it includes, and from
`build/.mc-usage.toml`, which every `mc build` writes with the previous run's high-water marks —
and reserves `estimate * (1 + tolerance)`. A table that guesses low still works: it doubles.

```
$ mc limits src/mc.mc
limits src/mc.mc
table         estimate   reserved       used  grow  verdict
tokens               0        512         51     0  ok
includes            22         64         22     0  ok
...
nodes            71546      89432      68105     0  ok
...
funcs              961       1201        836     0  ok
...
strings            602        752        571     0  ok
...
symbols           1883       2353       1666     0  ok
...
heap          24139550   33554432   23489728     0  ok
tolerance 0.25, verdict ok (heap in bytes, every other table in elements)
```

Row verdicts are `ok`, `tight` (over 90 % of what was reserved) and `grew` (the block had to
double); the report's verdict is the worst row, and the exit code is 0 for `ok` and 3 otherwise.
`mc build --limits` prints the same report after a build; `mc build --fix-limits` rewrites
**only** the `[limits]` section with the smallest tolerance that would have avoided both.

None of this can reach the output: a table that had to grow holds exactly the same elements, in
exactly the same order, as one that did not.

## The whole file

```toml
[project]
name  = "api"
entry = "main.mc"
out   = "build/api"
kind  = "exe"

[target]
os   = "macos"
arch = "aarch64"

[compiler]
modules = ["mc-api.mc"]
out     = "build/mc-api"

[libs]
sqlite3 = "/usr/lib/libsqlite3.dylib"

[externs]
"sqlite3_*" = "sqlite3"

[include]
paths = ["lib"]

[limits]
tolerance = 0.25
```

That is `examples/api/mc.toml` with its comments stripped — a taught compiler, a dynamic library
bound by ordinal, an include root and a tolerance, and no Makefile anywhere.

## The TOML subset

`[table]`, `[[array.of.tables]]`, bare/quoted/dotted keys, strings with `\" \\ \n \t \r`,
integers (with `+ - _`), booleans, decimal floats (kept as basis points), and single-level arrays
of strings or integers with an optional trailing comma. Every error carries **line and column**:

```
$ build/tomldump tests/toml/bad-equals.toml
tests/toml/bad-equals.toml:2:6: expected = after the key
```

The column is what distinguishes `entry = main.mc` — a bare word where a value goes — from a typo
in the key. The result is deliberately a flat `(path, value, index)` table in source order, not a
tree; that is what lets `[libs]` and `[externs]` be read by *key*, and it is what fixes the dylib
ordinals.

## Next

`[compiler]` is where the interesting part starts: [30-teaching.md](30-teaching.md).
