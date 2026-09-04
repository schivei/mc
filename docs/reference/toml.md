# `mc.toml`, every key

`mc build [DIR]` reads `DIR/mc.toml` (or `--config FILE`). **Every path in the file is relative
to the directory of the config**, never to the working directory, so `mc build examples/api` from
the repository root does exactly what `mc build` does from inside `examples/api`.

The parser is `src/toml.mc`; the driver that reads these keys is `src/driver.mc`.

---

## The whole file

```toml
[project]
name  = "api"              # only used to default [compiler].out
entry = "main.mc"          # required
out   = "build/api"        # required
kind  = "exe"              # exe (default) | obj

[target]
os   = "macos"             # macos (default) | linux
arch = "aarch64"           # aarch64 only

[compiler]                 # optional: build a taught compiler first
core    = "../../src/core.mc"
modules = ["mc-api.mc"]
out     = "build/mc-api"

[linker]                   # optional on macOS; REQUIRED when os = "linux"
cmd  = "ld"
args = ["-arch", "arm64", "-syslibroot", "{sdk}", "-lSystem",
        "-o", "{out}", "{obj}", "{libs}"]

[sysroot]
path = "build/sysroot/linux-aarch64"

[libs]
sqlite3 = "/usr/lib/libsqlite3.dylib"

[externs]
"sqlite3_*" = "sqlite3"

[include]
paths = ["lib"]

[limits]
tolerance = 0.25
```

---

## `[project]`

| key | type | default | meaning |
|---|---|---|---|
| `project.name` | string | — | only used to default `[compiler].out` to `build/mc-<name>` |
| `project.entry` | string | **required** | the source handed to the compiler |
| `project.out` | string | **required** | the artifact. Parent directories are created; the file is `unlink`ed before being written, because overwriting a signed executable on the same inode makes the kernel `SIGKILL` its next run |
| `project.kind` | string | `"exe"` | `exe` or `obj`. `obj` stops at the object file |

A missing `entry` or `out` is `<file>: missing key: project.entry`. A `kind` that is neither is
`must be exe or obj`, reported at the offending value's line and column.

## `[target]`

| key | type | default | accepted |
|---|---|---|---|
| `target.os` | string | the host's | a pair the compiler or one of its modules registered |
| `target.arch` | string | the host's | likewise |

The accepted set is the `(os, arch)` pairs the `target()` registry holds
([hooks.md](hooks.md)) — `macos/aarch64`, `linux/aarch64`, `linux/x86_64`,
`windows/aarch64` and `windows/x86_64` out of the box — **and a pair a module registered counts**.
The registry is consulted after `user_init()` has run (M39.5), so a taught compiler that calls
`target("none", "riscv64", "rv-image", "rv-image")` can be driven by `mc build` through its own
`mc.toml`; `examples/kernel` is the worked example. The consequence to know is that the entry
source is opened and lexed before an unknown pair is reported, so the diagnostic comes after the
`compile x -> y` step line. Anything the registry does not hold is refused at the value's
position, with a message built from the registry:

```
$ mc build tests/proj --config /tmp/haiku.toml
/tmp/haiku.toml:6:6: only macos, linux and windows (see docs/build.md): target.os
$ mc build tests/proj --config /tmp/riscv.toml
/tmp/riscv.toml:7:8: only aarch64 and x86_64 (see docs/build.md): target.arch
```

`os = "linux"` changes exactly two things: the object comes out as an ELF64 `ET_REL` (the
`elf-obj` / `elf-obj-x86_64` backends) instead of a Mach-O, and `[linker]` becomes **required** —
there is no direct-executable backend for Linux (`linux requires [linker]: there is no direct
executable`). `arch` then decides the instruction set inside that object.

`os = "windows"` says the same two things in COFF: the object is an
`IMAGE_FILE_MACHINE_ARM64` `.obj` (`coff-obj-arm64`) and `[linker]` is required
(`windows requires [linker]: there is no direct executable`).
See [../guide/50-cross-compile.md](../guide/50-cross-compile.md).

A registered pair may be missing the *other* half instead: `target(os, arch, 0, exe)` is a target
with no separable object step, which is what a board writing a flat image registers. Then
`kind = "obj"` — and `kind = "exe"` with a `[linker]`, which goes through the object first — is
`<os>/<arch> has no object backend: use kind = "exe"`, at the same position and with the same
exit 1. `kind = "exe"` and no `[linker]` is the shape such a target is for.

## `[compiler]` — build the compiler that will compile the entry

| key | type | default | meaning |
|---|---|---|---|
| `compiler.modules` | array of strings | — | files `#include`d in order, after the core. Its presence is what turns on this whole step |
| `compiler.out` | string | `build/mc-<project.name>` | where the taught compiler is written. Must be **relative** and contain no `..` |
| `compiler.core` | string | `<mc/core>` from the bundle | pin a checkout of `src/core.mc` instead of the copy inside the binary |

`mc build` writes `<compiler.out>.mc` — a generated file, next to the compiler — containing the
core include plus one include per module:

```c
// generated by `mc build` from examples/api/mc.toml
#include <mc/core>
#include "../mc-api.mc"
```

compiles it with the built-in `macho-exe` backend, and then **spawns** the binary that came out
as `<out> build DIR --config FILE --entry-only`. The spawn is not decoration: the compiler's
tables are process globals built once, so two compilations never fit in one run. `--entry-only`
re-reads the same TOML, which is why `[include]`, `[libs]` and `[externs]` apply to the entry
either way.

The generated file lives inside `build/`, so each `#include` gets one `../` per directory level
between the config and `[compiler].out` — counted on the **normalised** path, so `./build/x`,
`build/./x` and `build//x` all count as one level. The `..` and leading-`/` checks run on the
string as written, because normalising first would swallow a `..`.

Errors: `missing key: compiler.modules`, `must be a relative path: compiler.out`,
`must not contain ..: compiler.out`, `missing key: compiler.out` (when there is no
`project.name` to default from).

## `[linker]` — hand off to an external linker

| key | type | meaning |
|---|---|---|
| `linker.cmd` | string | the program to run. Its presence is what turns on the link step |
| `linker.args` | array of strings | the argument list, with placeholders |

Without `[linker]`, `kind = "exe"` uses the built-in `macho-exe` backend: no `ld`, ad-hoc
signature, dylibs bound by ordinal. With it, `mc` writes `<out>.o` and spawns the tool, which
inherits stdin/stdout/stderr so its diagnostics reach you unchanged; a non-zero exit stops the
build with exit 1.

| placeholder | expands to |
|---|---|
| `{out}` | `[project].out`, resolved against the config's directory |
| `{obj}` | the object just written, `<out>.o` |
| `{sdk}` | the output of `xcrun --show-sdk-path`, run **lazily** — only if some argument mentions it, at most once per build |
| `{sysroot}` | the sysroot for `[target]`, found by the resolution chain of [sysroot.md](sysroot.md): `[sysroot].path` (checked), then the running system, then the cache |
| `{stubs}` | the directory of the import stubs `mc` writes from the program's own `extern`s — `<dirname of [project].out>/stubs`. Written **lazily**, like `{sdk}`: only if some argument mentions it, and at most once per build ([sysroot.md](sysroot.md) § 9) |
| `{libs}` | one argument per `[libs]` entry, in key order |

`{out}`, `{obj}`, `{sdk}`, `{sysroot}` and `{stubs}` are substituted **inside** an argument, so
`-L{sdk}/usr/lib` and `{sysroot}/crt1.o` both work. `{libs}` is the one that must be a whole
argument, since it expands to several; each expanded value then goes through the same
substitution, so a library may be written `"{sdk}/usr/lib/libsqlite3.tbd"`.

Errors: `too many arguments in [linker].args` (the argv cap is 64),
`mc: cannot run: <cmd>`, `xcrun --show-sdk-path failed`.

## `[sysroot]`

| key | type | meaning |
|---|---|---|
| `sysroot.path` | string | the sysroot itself, resolved against the config's directory. Step 1 of the chain, and the one that wins |
| `sysroot.cache` | string | the ROOT of a cache of sysroots, resolved the same way: the one for this target is `<cache>/<os>-<arch>`. Step 3 |

Neither key is required. `{sysroot}` is resolved by the chain of
[sysroot.md](sysroot.md) — `[sysroot].path`, then the running system when the host *is* the
target, then `--sysroot-dir` / `[sysroot].cache` / `~/.mc/sysroots/<os>-<arch>` — and the chain
runs at most once per build, and only when some `[linker].args` argument actually mentions the
placeholder.

`sysroot.path` is now **checked**: a directory that is there but does not hold the target's
marker files (`crt1.o` and `libc.a` for Linux, `kernel32.lib` for Windows,
`usr/lib/libSystem.tbd` for macOS) stops the build with the `no sysroot` message and exit **2**,
instead of being handed to the linker to fail on. An explicit path that is wrong is a mistake to
report, not a reason to go looking somewhere else, so the probes and the cache are not tried
after it.

## `[libs]` and `[externs]` — `#dylib` said from outside the source

```toml
[libs]
sqlite3 = "/usr/lib/libsqlite3.dylib"

[externs]
"sqlite3_*" = "sqlite3"
```

- `libs` feeds the very same table `#dylib` does. Ordinals are handed out in the order the keys
  appear, starting at 2, because ordinal 1 is always libSystem.
- `externs` maps a symbol name, or a prefix ending in `*`, to a `[libs]` key. The pattern table is
  consulted **after** the exact table, so a `#dylib` in the source always wins for its own
  `extern`s. An `extern` no pattern claims stays on libSystem.
- A key containing `*` has to be quoted — bare TOML keys are `A-Za-z0-9_-`.
- On a `[linker]` build the ordinals do not matter (the linker resolves symbols); `[libs]` is
  then just the list `{libs}` expands to.

Errors: `library not declared in [libs]` — an `[externs]` value naming a key `[libs]` does not
have.

## `[include]`

| key | type | meaning |
|---|---|---|
| `include.paths` | array of strings | extra roots for `#include "x"`, tried **after** the includer's own directory, in the order written |

A project never shadows a relative include that already resolved; the roots only catch what would
otherwise fail. With no root registered the lexer behaves exactly as it did before this key
existed — not even an extra `open` happens.

## `[limits]`

| key | type | default | range |
|---|---|---|---|
| `limits.tolerance` | float | `0.25` | 0.0 to 1.0 |

How much slack `mc build` reserves on top of its own estimate of what the build needs. `mc limits`
reports how good the guess was, and `mc build --fix-limits` is what raises this number. Out of
range is refused at the value's position: `tolerance must be between 0 and 1`.

There is no float type in the language, so there is none here either: the parser reads the
decimal text into an `i64` of **basis points**. `0.25` is `2500`, `1.0` is `10000`, `0.0001` is
`1`, and a fifth fraction digit is `float with more than 4 fraction digits`.

---

## The TOML subset

`src/toml.mc` accepts exactly this:

```toml
# comment, to the end of the line
[table]                          # sets the prefix for the keys that follow
[[array.of.tables]]              # same, with an occurrence index in the prefix
key = "value"                    # bare key, quoted key, or dotted: a.b.c
"quoted key" = 1                 # a key containing * has to be quoted
n     = -42                      # decimal integer; + - and _ separators allowed
t     = 0.25                     # decimal float, kept as basis points (2500)
flag  = true                     # true | false
list  = ["a", "b"]               # array of strings or of integers, multi-line,
                                 # trailing comma allowed, no nesting
```

String escapes are `\" \\ \n \t \r`; anything else is `unknown escape`. Every error carries
**line and column**:

```
$ build/tomldump tests/toml/bad-string.toml
tests/toml/bad-string.toml:2:8: unterminated string
$ build/tomldump tests/toml/bad-equals.toml
tests/toml/bad-equals.toml:2:6: expected = after the key
$ build/tomldump tests/toml/bad-header.toml
tests/toml/bad-header.toml:1:9: expected ] in the table header
```

**A quoted key may not contain a `.`** (`quoted key must not contain .`). The result table is
flat and its paths are segments joined with `.`, so `"b.c"` under `[a]` and `c` under `[a.b]`
would both land on `a.b.c`; rather than pick a winner, the parser refuses the ambiguous one. `*`
is unaffected, which is why `[externs] "sqlite3_*"` keeps working.

### The result is a flat table, not a tree

Deliberately — it is the same shape as every other table in this compiler (`docs/determinism.md`
rule 1: nothing hashed, nothing iterated but an array in insertion order). An entry is
`(path, value, type, index)` and entries stay in source order. Array elements share a path and
carry an index; `[[x]]` puts the occurrence number in the path (`server.0.host`). Values are
always stored as text.

```
$ build/tomldump tests/toml/full.toml
str  project.name = "api"
str  project.entry = "main.mc"
...
str  compiler.modules[0] = "mc-api.mc"
str  libs.sqlite3 = "/usr/lib/libsqlite3.dylib"
str  externs.sqlite3_* = "sqlite3"
str  include.paths[0] = "lib"
```

That flat walk is what makes `[libs]` and `[externs]` work: the driver needs the **keys** of a
table, not just a value, and walking in order is also what fixes the dylib ordinals.

`src/tomldump.mc` is a small driver that prints the table; `scripts/check-toml.sh` compares its
output against `tests/toml/*.expect`, well-formed and malformed files alike.
