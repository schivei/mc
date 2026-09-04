# build.md — `mc build` and `mc.toml` (M14), the bundle and `#embed` (M15), Linux targets (M16), Windows targets (M19), limits (M23), a Linux host (M37)

Through M13 the only way to compile was one file at a time:

```
mc source.mc -o out.o          # object, then ld
mc --exe source.mc -o out      # signed executable, no ld
```

That is still exactly what `mc` does, unchanged. M14 adds one subcommand on top of it:

```
mc build [DIR] [--config FILE]
```

`DIR` defaults to `.`, the config to `DIR/mc.toml`. Everything the build needs — what to compile,
where to put it, which compiler to compile it *with*, which libraries the `extern`s come from —
is data in that file, not flags on a command line and not a Makefile.

```
$ build/mc1 build examples/api
compiler build/mc-api.mc -> build/mc-api
compile main.mc -> build/api
```

Two lines, two steps: the first built a **compiler that understands `class` and `interface`**, the
second used it to compile the server. Neither `make` nor `ld` was involved.

Everything lives in `src/toml.mc` (the parser) and `src/driver.mc` (the driver). `stage0/` was not
touched: the C seed only ever has to compile `src/mc.mc`.

---

## The file

Every path in the file is relative to **the directory of the config**, never to the working
directory — so `mc build examples/api` from the repository root does the same thing as `mc build`
from inside `examples/api`.

```toml
[project]
name  = "api"              # used only for the default [compiler].out
entry = "main.mc"          # the source to compile
out   = "build/api"        # the artifact; parent directories are created
kind  = "exe"              # exe (default) | obj

[target]
os   = "macos"             # macos (default) | linux; anything else is an error
arch = "aarch64"           # aarch64 (default); linux also takes x86_64

[compiler]                 # optional: build a taught compiler first, then use it
core    = "../../src/core.mc"
modules = ["mc-api.mc"]
out     = "build/mc-api"   # default: build/mc-<project.name>

[linker]                   # optional on macOS; REQUIRED when os = "linux"
cmd  = "ld"                # without it, kind = "exe" uses the built-in macho-exe
args = ["-arch", "arm64", "-syslibroot", "{sdk}", "-lSystem",
        "-o", "{out}", "{obj}", "{libs}"]

[sysroot]                  # M16: what {sysroot} expands to in [linker].args
path = "build/sysroot/linux-aarch64"

[libs]                     # named libraries, in the order the ordinals are handed out
sqlite3 = "/usr/lib/libsqlite3.dylib"

[externs]                  # symbol or prefix* -> library name
"sqlite3_*" = "sqlite3"

[include]
paths = ["lib"]            # extra roots for #include "x"
```

### `[project]`

| key | meaning |
|---|---|
| `name` | only used to default `[compiler].out` to `build/mc-<name>` |
| `entry` | the source handed to the compiler. **Required.** |
| `out` | the artifact. **Required.** Its parent directories are created, and it is `unlink`ed before being written — overwriting a signed executable on the same inode makes the kernel `SIGKILL` its next execution (cached signature). |
| `kind` | `exe` (default) or `obj`. `obj` stops at the `MH_OBJECT`. |

### `[target]`

`os` defaults to `macos`, takes `linux` since M16 and `windows` since M19; `arch` defaults to
`aarch64`, and since M17 `os = "linux"` also takes `x86_64`. What is accepted is exactly the
`(os, arch)` pairs the `target()` registry holds ([reference/hooks.md](reference/hooks.md)) —
`macos/aarch64`, `linux/aarch64`, `linux/x86_64`, `windows/aarch64` — and a module may register
more. Any other value is an error at the position of the offending value, and the message is
built from the registry:

```
$ build/mc1 build tests/proj --config /tmp/haiku.toml
/tmp/haiku.toml:6:6: only macos, linux and windows (see docs/build.md): target.os
$ build/mc1 build tests/proj --config /tmp/riscv.toml
/tmp/riscv.toml:7:8: only aarch64 and x86_64 (see docs/build.md): target.arch
```

`os = "linux"` changes two things and nothing else: the object comes out as an ELF64 `ET_REL`
(the `elf-obj` / `elf-obj-x86_64` backends, `src/backend_elf.mc`) instead of a Mach-O, and
`[linker]` becomes **required** — there is no direct-executable backend for Linux. `arch` then
picks which instruction set the object holds. See § Linux targets below.

`os = "windows"` says the same two things in COFF's spelling: the object is an
`IMAGE_FILE_MACHINE_ARM64` `.obj` (`coff-obj-arm64`, `src/backend_coff.mc`) and `[linker]` is
required. See § Windows targets.

### `[compiler]` — building the compiler that will compile `entry`

This is the section that makes `mc build` more than a Makefile in disguise. A taught compiler in
this project is a **file**, not an edit to `src/`: `src/core.mc` is the whole compiler minus
`void user_init()`, and a module supplies it (`docs/surface.md` § Tier 3). `[compiler]` says which
files to glue together:

```toml
[compiler]
modules = ["mc-api.mc"]          # #include'd in order, after the core
out     = "build/mc-api"
# core  = "../../src/core.mc"    # optional; without it the core comes from the bundle
```

`mc build` writes `<out>.mc` — for the example, `examples/api/build/mc-api.mc`:

```c
// generated by `mc build` from examples/api/mc.toml
#include <mc/core>
#include "../mc-api.mc"
```

Since M15 the core comes from the **bundle inside the binary** (`<mc/core>`, see below), so a
project needs no path into this repository to teach the compiler. `core = "..."` is still
accepted and still wins — that is how a project pins its own checkout of `src/core.mc` instead of
the copy the binary carries.

compiles it with the built-in `macho-exe` backend, and then **spawns the binary that came out**:

```
<out> build DIR --config FILE --entry-only
```

The spawn is not decoration. The compiler's tables — lexer, arena, AST, symbols — are globals
built once per process, so two compilations never fit in one run. `--entry-only` is the flag that
says "you are the second half": skip `[compiler]` and compile the entry, reading the same TOML —
which is why `[include]`, `[libs]` and `[externs]` apply to the entry in either shape.

**`--compiler-only` (M21.5) is the first half alone.** It builds the taught compiler, prints its
path on stdout and stops — no spawn, no entry:

```
$ build/mc1 build examples/lang --compiler-only
compiler build/mc-lang.mc -> build/mc-lang
examples/lang/build/mc-lang
```

That is the shape a `test.sh` wants: it drives the taught compiler over its own suite and has no
use for `[project].entry`. `examples/lang/test.sh` runs `--compiler-only` and then
`build/mc-lang build DIR --entry-only`, which is exactly the two halves a plain `mc build` runs.
It is also what an editor server needs, which is why the flag exists before M28.
`--entry-only` and `--compiler-only` together are an error; `--compiler-only` without
`[compiler].modules` is the same missing-key error a `[compiler]` build already gives.

`#include` is once-only, so a module that already pulls in the core (as `examples/api/mc-api.mc`
does, with `#include <mc/core>`) works whether or not `core` is also written here: the second
include of the same name is a no-op.

The generated file lives next to `[compiler].out`, inside `build/`, and the `#include` paths get a
`../` for each level between the config's directory and that one. That is why `[compiler].out`
has to be a **relative path with no `..` segments**; both are refused with a clear message.

The level count is taken from the **normalized** path, the same form the file is actually written
at, so redundant components do not inflate it: `out = "./build/mc-api"`, `"build/./mc-api"` and
`"build//mc-api"` all name one directory level and all get a single `../`, exactly like
`"build/mc-api"`. (Counting raw `/` bytes was the M14 bug: `"./build/mc-api"` produced `../../`
and every module include pointed one directory too high.) The `..` and leading-`/` checks still
scan the string **as written** — normalizing first would silently swallow a `..`.

### `[linker]` — handing off to an external linker

Without `[linker]`, `kind = "exe"` uses the built-in `macho-exe` backend: no `ld`, ad-hoc
signature, dylibs bound by ordinal (M11, `docs/bootstrap.md`). With `[linker]`, `mc` writes
`<out>.o` and spawns the tool:

```toml
[linker]
cmd  = "ld"
args = ["-arch", "arm64", "-platform_version", "macos", "13.0", "13.0",
        "-syslibroot", "{sdk}", "-lSystem", "-o", "{out}", "{obj}", "{libs}"]
```

| placeholder | expands to |
|---|---|
| `{out}` | `[project].out`, resolved against the config's directory |
| `{obj}` | the object `mc` just wrote, `<out>.o` |
| `{sdk}` | the output of `xcrun --show-sdk-path`, run **lazily**: only if some argument mentions it, and at most once per build |
| `{sysroot}` | `[sysroot].path`, resolved against the config's directory (M16). A missing `[sysroot].path` is an error only when some argument actually uses the placeholder |
| `{libs}` | one argument per `[libs]` entry, in the order the keys are written |

`{out}`, `{obj}`, `{sdk}` and `{sysroot}` are substituted **inside** an argument, so
`-L{sdk}/usr/lib` and `{sysroot}/crt1.o` both work.
`{libs}` is the one that has to be a whole argument, because it expands to several; each expanded
value goes through the same substitution, so a library can be written as
`"{sdk}/usr/lib/libsqlite3.tbd"` — which is what `tests/proj/link.toml` does, since on macOS
`/usr/lib/libsqlite3.dylib` only exists inside the dyld shared cache and `ld` cannot open it.

The tool inherits stdin/stdout/stderr, so its diagnostics reach the user unchanged, and a non-zero
exit stops the build with exit 1:

```
$ build/mc1 build tests/proj --config tests/proj/link.toml
compile app.mc -> build/app-ld.o
link build/app-ld.o -> build/app-ld
```

### `[libs]` and `[externs]` — `#dylib` said from outside the source

`#dylib "path"` (M12, `docs/surface.md`) annotates the `extern`s written after it. `[libs]` +
`[externs]` say the same thing without touching the source:

```toml
[libs]
sqlite3 = "/usr/lib/libsqlite3.dylib"

[externs]
"sqlite3_*" = "sqlite3"
```

- `[libs]` feeds the same table `#dylib` does (`dylib_add` in `src/parse.mc`); ordinals are handed
  out in the order the keys appear, starting at 2, because ordinal 1 is always libSystem.
- `[externs]` maps a symbol **or a prefix ending in `*`** to a library name. The pattern table is
  consulted **after** the exact table, so a `#dylib` in the source always wins for its own
  `extern`s. An `extern` no pattern claims stays on libSystem.
- A key with `*` in it has to be quoted — bare TOML keys are `A-Za-z0-9_-`. A key containing a
  `.` cannot be written at all, quoted or not: see the TOML section below.

The proof that this really binds by ordinal, with no `#dylib` anywhere in the sources
(`tests/proj/app.mc` + `tests/proj/inc/db.mc`):

```
$ build/mc1 build tests/proj --config tests/proj/exe.toml
compile app.mc -> build/app-exe
$ otool -L tests/proj/build/app-exe
tests/proj/build/app-exe:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/usr/lib/libsqlite3.dylib (compatibility version 1.0.0, current version 1356.0.0)
$ tests/proj/build/app-exe
sqlite ok
```

On a `[linker]` build the ordinals do not matter — it is the linker that resolves symbols — and
`[libs]` is just the list `{libs}` expands to.

### `[include].paths`

Extra roots for `#include "x"`, tried **after** the includer's own directory, in the order they are
written. A project never shadows a relative include that already resolved; the roots only catch
what would otherwise fail.

`tests/proj/app.mc` writes `#include "db.mc"` and the file is in `inc/`. Without the root:

```
$ build/mc1 build tests/proj --config tests/proj/build/noinc.toml
compile ../app.mc -> noinc-out
mc: cannot open: tests/proj/db.mc
```

With `paths = ["inc"]` it resolves. With no root registered the lexer's behaviour is byte for byte
what it was before M14 — not even an extra `open` happens.

---

## The TOML subset

`src/toml.mc` is deliberately small. It accepts:

```toml
# comment, to the end of the line
[table]                          # sets the prefix for the keys that follow
[[array.of.tables]]              # same, with an occurrence index in the prefix
key = "value"                    # bare key, quoted key, or dotted: a.b.c
"quoted key" = 1                 # a key with * has to be quoted
n     = -42                      # decimal integer, + - and _ separators allowed
t     = 0.25                     # M23: decimal float, kept as BASIS POINTS (2500)
flag  = true                     # true | false
list  = ["a", "b"]               # array of strings or of integers, multi-line,
                                 # trailing comma allowed, no nesting
```

Escapes inside a string: `\" \\ \n \t \r`. Everything else is an error with **line and column**:

A **quoted key may not contain a `.`**. The table is flat and its paths are segments joined with
`.`, so `"b.c"` under `[a]` and `c` under `[a.b]` would both land on `a.b.c` and one of the two
would be silently unreachable — two different keys, one lookup key. Rather than pick a winner,
the parser refuses the ambiguous one, pointing at the opening quote
(`tests/toml/bad-dotkey.toml:5:1: quoted key must not contain .`). `*` is unaffected: it collides
with nothing, which is why `[externs] "sqlite3_*"` keeps working.

```
$ build/tomldump tests/toml/bad-string.toml
tests/toml/bad-string.toml:2:8: unterminated string
$ build/tomldump tests/toml/bad-equals.toml
tests/toml/bad-equals.toml:2:6: expected = after the key
$ build/tomldump tests/toml/bad-header.toml
tests/toml/bad-header.toml:1:9: expected ] in the table header
$ build/tomldump tests/toml/bad-escape.toml
tests/toml/bad-escape.toml:2:11: unknown escape
$ build/tomldump tests/toml/bad-value.toml
tests/toml/bad-value.toml:2:9: value expected
$ build/tomldump tests/toml/bad-float.toml
tests/toml/bad-float.toml:3:21: float with more than 4 fraction digits
```

A float has no type of its own in the language, so it has none here either: `src/toml.mc` reads
the decimal text into an `i64` of **basis points** (hundredths of a percent), which is what
`[limits].tolerance` needs and all it needs — `0.25` is `2500`, `1.0` is `10000`, `0.0001` is `1`,
and a fifth fraction digit is an error. `tomldump` prints those entries as `bp`.

The column is what distinguishes `entry = main.mc` (a bare word where a value goes) from a typo in
the key.

### The result is a flat table, not a tree

Deliberately. It is the same shape as every other table in this compiler
(`docs/determinism.md`, rule 1: no hashing, nothing iterated but an array in insertion order). An
entry is `(path, value, type, index)` and the entries are kept **in source order**:

```
$ build/tomldump tests/toml/full.toml
str  project.name = "api"
str  project.entry = "main.mc"
...
str  compiler.modules[0] = "mc-api.mc"
...
str  libs.sqlite3 = "/usr/lib/libsqlite3.dylib"
str  externs.sqlite3_* = "sqlite3"
str  include.paths[0] = "lib"
```

Array elements share a path and carry an index; `[[x]]` puts the occurrence number in the path
(`server.0.host`, `server.1.host`). Values are always stored as text, integers included, so every
entry has the same shape.

The API is five functions:

```c
uptr toml_get(uptr path);                  // first value, or 0
uptr toml_get_array(uptr path, i64 i);     // i-th value with that path, or 0
i64  toml_count(uptr path);                // how many entries have that path
i64  toml_int(uptr path, i64 dflt);        // toml_get + atoi
i64  toml_entries();                       // and toml_path_at(i) / toml_val_at(i)
```

The last one is what makes `[libs]` and `[externs]` work: the driver needs the **keys** of a
table, so it walks the flat table in order. That walk is also what fixes the dylib ordinals.

`src/tomldump.mc` is the driver that prints the table, and `scripts/check-toml.sh` compares its
output against `tests/toml/*.expect` — well-formed files and malformed ones alike. The
pretty-printer lives in that driver and **not** in `src/toml.mc` on purpose: `toml.mc` is part of
`src/core.mc`, so every compiler binary carries it, and a dump nobody calls is a dozen string
literals charged against a budget the C seed still caps at 2048 (`MAXSTRS` in
`stage0/gen_arm64.c`; `make check-limits` is what watches how close `src/mc.mc` gets to it).

---

## Spawning tools

`mc build` runs three kinds of external process: the taught compiler, the linker, and `xcrun`.
All three go through `posix_spawnp` + `waitpid`, declared in `src/driver.mc` and — for programs
that want the same — in `lib/sys.mc`:

```c
extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern uptr _NSGetEnviron();
```

**M37: those declarations moved into the host layer.** `src/driver.mc` names no operating system
any more — it calls `host_environ()`, and the host file behind it is `src/host_macos.mc`
(`_NSGetEnviron`) or `src/host_linux.mc` (the `envp` `main` was called with, since musl has no
`_NSGetEnviron`). `posix_spawnp` and `waitpid` themselves are declared identically on both, because
musl has them under the same names; `lib/sys.mc` is unchanged and is still what a *program* uses.
See [guide/90-linux-host.md](guide/90-linux-host.md).

```c
u8 pid[8]; st64(pid, 0);
u8 av[3 * 8]; st64(av + 0, "ls"); st64(av + 8, "-l"); st64(av + 16, 0);
posix_spawnp(pid, "ls", 0, 0, av, ld64(_NSGetEnviron()));
u8 st[8]; st64(st, 0);
waitpid(ld64(pid), st, 0);                  // exit code = (ld32(st) >> 8) & 255
```

**There is deliberately no equivalent in `lib/sys_svc.mc`.** That file exists to prove the core
does not need libc for I/O — five `#opcode svc` wrappers around `open/read/write/close/exit`. But
`posix_spawn` is *not* a syscall: it is a libSystem routine that marshals file actions and
attributes into a struct and calls `__posix_spawn(2)` with a layout this language has no way to
describe. Reproducing it would mean hand-laying-out an undocumented kernel struct, which is a much
worse bargain than the five wrappers. A program that wants to spawn without libSystem has to
`fork`/`exec` by hand, which the core does not offer either.

`xcrun` only exists on macOS, so on any other host `{sdk}` is a config error rather than a spawn
that fails halfway through a build:

```
mc.toml:31:8: {sdk} needs xcrun: it exists only on macos [linker.args]
```

`xcrun`'s stdout is captured with a spawn file action
(`posix_spawn_file_actions_addopen` on fd 1) into `<out>.sdk`, which is read back and `unlink`ed —
no shell, no pipe, no `/tmp`.

---

## M15 — the bundle: `#include <name>`

A compiler that needs a checkout to compile anything is not distributable. M15 puts the standard
library and the compiler's own source **inside the binary**, compressed, and serves them through a
second form of `#include`:

```c
#include <sys>            // lib/sys.mc
#include <prelude>        // lib/prelude.mc: while / for / += / ++
#include <lz>             // src/lz.mc: lz_deflate / lz_inflate
#include <mc/core>        // src/core.mc: the whole compiler minus user_init
```

`<name>` is served by the bundle **or it is an error** — there is no filesystem fallback, on
purpose: `<name>` means "the copy that shipped with this binary", and the answer must not depend
on the working directory. An unknown name says so and lists nothing else:

```
$ mc prog.mc -o prog.o
prog.mc:1: unknown bundled include: no/such/module
```

`#include "x"` is unchanged: the includer's directory first, then each `[include].paths` root.

### What is in it

`tools/bundle.list` is the manifest, one `NAME<TAB>PATH` per line, sorted by name:

| names | files |
|---|---|
| `sys`, `sys_svc`, `sys_linux`, `io`, `prelude`, `lz`, `backend_arm64`, `pass_demo`, `user_default`, … | every `lib/*.mc`, plus `src/lz.mc` (a library, not only a compiler module) |
| `mc/core`, `mc/arena`, `mc/lex`, `mc/parse`, `mc/gen_resolve`, `mc/gen_walk`, `mc/machine_arm64`, `mc/backend_exe`, `mc/backend_elf`, … | every module `src/core.mc` includes |

Everything a taught compiler needs is there, which is what makes `<mc/core>` complete.

### Errors point at the bundled name

A bundled file is pushed onto the same `#include` stack as a real one, with the bundled name in
place of a path — so that is what a diagnostic shows:

```
syntax_demo_test:10: type expected at top level
```

### Relative includes inside a bundled file

`src/core.mc` still says `#include "arena.mc"`, and `src/driver.mc` still says
`#include "../lib/prelude.mc"`. The bundle is flat: there are no directories in it. So when the
including file is itself bundled, the lexer joins and normalizes the name the usual way, drops a
trailing `.mc`, and looks the result up in the bundle; if that misses, it tries the **last path
component**:

| written in | resolves to | found as |
|---|---|---|
| `mc/core` → `"arena.mc"` | `mc/arena` | exact |
| `sys` → `"io.mc"` | `io` | exact |
| `mc/driver` → `"../lib/prelude.mc"` | `lib/prelude` → `prelude` | last component |
| `mc/core` → `"lz.mc"` | `mc/lz` → `lz` | last component |

`tools/bundle.mc` refuses a manifest where two entries share a last component, so that fallback is
never ambiguous.

### `mc/bundle_data`, the file the bundle cannot contain

`src/core.mc` includes `bundle_data.mc`, and `src/bundle_data.mc` is the bundle. It cannot be
inside itself — its own bytes would change the bytes it contains. So it is the one name that is
**regenerated on demand**: `bundle_find("mc/bundle_data")` answers with index `BUNDLE_COUNT`, and
`bundle_read` writes the file out again from the blob and the index already in memory, with the
same `bundle_emit` that `tools/bundle.mc` uses. There is one definition of the format, so the two
cannot drift, and `<mc/core>` is complete.

`scripts/check-standalone.sh` proves it the strongest way available: a compiler built from
`#include <mc/core>` + `#include <user_default>` compiles `src/mc.mc` to an object **byte for
byte identical** to `build/mc2.o`.

#### The regenerated copy carries the blob as `#embed` (M21.5)

The two copies do not have the same *shape*. What the binary regenerates is:

```c
// generated by tools/bundle.mc from tools/bundle.list -- do not edit.
#embed bundle_blob "bundle.bin"
i64 bundle_idx[] = { 0,338,693,800, ... };
#define BUNDLE_COUNT 33
```

`mc/bundle.bin` is the **second** name the bundle cannot contain, index `BUNDLE_BIN`: it *is*
`bundle_blob`, served straight out of the running compiler's own data with no inflate and no copy,
the way `mc/bundle_data` is regenerated rather than stored. `path_join("mc/bundle_data",
"bundle.bin")` lands on it directly, so the `#embed` inside the regenerated module resolves
without the filesystem.

The point is arena. An initializer costs one AST node per element, so the ~180 KB blob spelled out
as `u64` cost ~22 500 nodes — 2.3 MB — in **every** taught compiler that includes `<mc/core>`.
As `#embed` it costs one (`docs/surface.md` § `#embed`). Measured with `mc limits` on
`#include <mc/core>` + one module:

| | nodes | heap used |
|---|---|---|
| before M21.5 | 80 312 | 21.7 MiB, and the reserve went past the 32 MiB static arena (64 MiB) |
| after M21.5 | 58 216 | 20.0 MiB inside it |

That is what let `examples/lang` delete its private copy of the core's module list and point
`[compiler]` at `<mc/core>` again.

**The file on disk keeps the `u64` form**, and that is not an oversight: `dir_names[]` in the
frozen `stage0/lex.c` has no `embed`, and `build/mc0 src/mc.mc` is the seed step of `make mc1`.
`bundle_emit` in `src/bundle.mc` writes either form — mode 0 for the file, mode 1 for the binary —
and both declare the same global with the same size (`bundle_bin_size()` rounds the blob up to a
multiple of 8, which is exactly how many bytes `u64 bundle_blob[]` declares), so the two produce
the **same object**. `check-standalone` is what proves that, and `check-bundle` guards the shape:
`<mc/bundle_data>` has to be one `BLOB` node plus the index array.

### The format

`src/bundle_data.mc` is generated source, checked in:

```c
u64 bundle_blob[] = {
0x5f646e656b636162,0x6f690034366d7261,...
};
i64 bundle_idx[] = {
0,2,0,0,
...
};
#define BUNDLE_COUNT 31
```

- `bundle_blob` holds the NUL-terminated names first, in manifest order, then each LZ stream.
- `bundle_idx` holds four values per entry: name offset, stream offset, compressed size, raw size.
- Both are read with `ld8`/`ld64`; the `u64` array is written little-endian by `glob_place`, so
  the bytes come back in the original order.

Two shapes here are deliberate and both are about the **frozen seed**:

- **`u64` elements, not `u8`.** The parser makes one AST node per initializer element, and
  `stage0` has a 32 MiB arena with 72-byte nodes. A 180 KB blob written as bytes needs ~180k
  nodes and exhausts it (measured: `mc: arena exhausted`); as `u64` it needs ~22.5k. Hexadecimal
  rather than decimal because an element with the high bit set is ≥ 2^63 and the codegen only
  emits signed division (see the note in `src/arena.mc`). Since M21.5 this form survives **only**
  for the file on disk; the copy the binary serves is `#embed` and costs one node (above).
- **One index array, names inside the blob.** `stage0/gen_arm64.c` has `MAXSTRS 512` and
  `src/mc.mc` was at 489 literals before M15. A `uptr bundle_name[] = {"sys", ...}` would have
  spent one literal per entry, and four array headers in the emitter would have spent four instead of two.

### Compression: `src/lz.mc`

LZ77 with a 64 KiB window and a greedy longest match, ~200 lines, no entropy coder:

```
0xxxxxxx            literal run of (xxxxxxx + 1) bytes, then those bytes
1xxxxxxx dd dd      match of (xxxxxxx + 3) bytes, `dd dd` back (little-endian)
```

`lz_deflate(src, n, dst) -> csize` and `lz_inflate(src, n, dst, rsize) -> written`. The file has
**no dependencies at all** — not even `arena.mc` — so `#include <lz>` alone is enough for a
program. A corrupt stream is not fatal there: inflate stops and returns what it produced, and the
caller decides (`src/bundle.mc` dies, a program can do something else).

Determinism, which is what makes `make bundle` reproducible: the match finder is a hash chain in
bss, reset at the start of every `lz_deflate`, walked newest-first with a fixed bound of 32
candidates, first longest match wins. Nothing depends on an address or on the arena's state.

A match of exactly 3 bytes is refused when a literal run is pending — it would cost 3 bytes for 3
bytes *plus* the control byte of the run it interrupts. That single rule is what makes
`lz_bound(n) = n + n/128 + 8` a true upper bound: every (literal run + match) pair then has
non-positive overhead.

On this repository: **360287 bytes of source → 161755 bytes of LZ (45%)**.

### Regenerating: `make bundle`

```
$ make bundle
build/mc1 --exe tools/bundle.mc -o build/bundle
build/bundle tools/bundle.list src/bundle_data.mc
  backend_arm64       8868 -> 4323
  io                  889 -> 711
  ...
bundle: 32 files, raw 360287 -> lz 161755, blob 162083 bytes, src/bundle_data.mc 389307 bytes
```

`tools/bundle.mc` is itself an `mc` program, and it writes the file with `bundle_emit` from
`src/bundle.mc` — the same function the compiler uses for `mc/bundle_data`.

**`src/bundle_data.mc` is generated source and must be regenerated whenever `lib/` or the core
changes.** `make check` runs `scripts/check-bundle.sh` *before* `make bootstrap` and fails loudly
if the checked-in copy is stale, because a stale bundle would make the fixed point prove something
about a compiler whose `<mc/core>` no longer matches `src/`. See `docs/bootstrap.md` § M15.

---

## M15 — `#embed`

```c
#embed NAME "path" [lz]
```

declares `u8 NAME[]` with the file's bytes — or with the LZ stream, when `lz` is written — plus
two constants:

| | |
|---|---|
| `NAME_size` | bytes in the array (the compressed size, with `lz`) |
| `NAME_raw`  | the file's original size (equal to `NAME_size` without `lz`) |

The path resolves exactly like `#include "x"`: relative to the directory of the file that **wrote
the directive**, then `[include].paths`. Inside a bundled `<name>` include there is no directory —
the includer is a bundle name, not a path — so the payload is looked up in the **bundle** by the
same rule a relative `#include` uses there (join, normalize, drop `.mc`, then the last-component
fallback); a name the bundle does not serve is `unknown bundled include: NAME`, not a confusing
`cannot open`. `tools/bundle.list` therefore has to carry the payload as its own entry, which is
what `tests/mc/bundle/embed_demo.mc` + `embed_demo.txt` demonstrate (`tests/mc/073-embed-bundle.mc`).

Note the base is the directive's own file and not whatever the lexer is reading: `#embed` looks one
token past the string for the optional `lz`, and when the directive is the **last** thing in an
included file that lookahead has already returned to the includer.

A program decompresses with `<lz>`:

```c
#include <sys>
#include <lz>

#embed plain  "data.txt"
#embed packed "data.txt" lz

u8 out[8192];

i64 main() {
    i64 n = lz_inflate(packed, packed_size, out, packed_raw);
    write(1, out, n);
    return 0;
}
```

Limit: 16 MiB, and an empty file is an error. In practice the arena runs out well before 16 MiB —
the bytes become a normal global array initializer, one AST node per element, which is exactly the
cost measured for the bundle above.

`#embed` and `#include <name>` do **not** exist in `stage0`: they are Phase 2 surface, and the C
seed is frozen. That is why their tests live in `tests/mc/` rather than in `tests/` — see
`scripts/check-mc.sh`.

---

## M16 / M17 — Linux targets (`os = "linux"`, `arch = "aarch64"` or `"x86_64"`)

`os = "linux"` in `[target]` makes `mc build` write an **ELF64 relocatable** instead of a Mach-O
and hand it to the linker named in `[linker]`. Nothing else in the file changes, and nothing in
`stage0/` changes: the ELF writer is `src/backend_elf.mc`, a backend registered like any other
(`--backend=elf-obj` and `--backend=elf-obj-x86_64` also work from the single-file CLI).

`arch = "x86_64"` (M17 step B) changes the instruction set and three fields of the file —
`e_machine`, the relocation numbers and their addend — and nothing else: the same `gen_lower`, the
same two-pass encoder, the same section table, the same symbol partition. What it swaps is the
**machine** behind the walker (`src/machine_x86_64.mc`, [reference/machine.md](reference/machine.md)).

The real config — this is exactly what `scripts/test-linux.sh` generates, with absolute paths:

```toml
[project]
entry = "hello.mc"
out   = "build/hello"

[target]
os   = "linux"
arch = "aarch64"

[sysroot]
path = "build/sysroot/linux-aarch64"   # what {sysroot} expands to

[linker]
cmd  = "ld.lld"
args = ["-o", "{out}",
        "{sysroot}/crt1.o", "{sysroot}/crti.o",
        "{obj}", "{libs}",
        "{sysroot}/libc.a", "{sysroot}/crtn.o"]
```

```
$ build/mc1 build . --config linux.toml
compile hello.mc -> build/hello.o
link build/hello.o -> build/hello
$ docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3 /w/build/hello
hello
```

`[linker]` is **required** for `os = "linux"`; there is no `macho-exe` equivalent that writes a
Linux executable directly, and asking for one says so:

```
$ build/mc1 build tests/proj --config /tmp/d.toml
/tmp/d.toml:6:6: linux requires [linker]: there is no direct executable: target.os
```

### The sysroot

`scripts/sysroot-linux.sh [--arch aarch64|x86_64]` fills `build/sysroot/linux-<arch>` by running
`apk add musl-dev` inside a throwaway Alpine container of the matching platform (`linux/arm64` or
`linux/amd64`, the second emulated on an Apple Silicon host) and copying out `crt1.o`, `crti.o`,
`crtn.o`, `libc.a` (and `libc.so`, for reference). It is a cache: with the four files already
there it does nothing, so `make test-linux` does not pull an image on every run.
`make sysroot-linux` and `make sysroot-linux-x86_64` run it; `scripts/test-linux.sh` runs it by
itself when any of the four files is missing (the same check the script itself makes, so a
half-populated sysroot is repaired instead of failing every test).

### What the ELF writer says

`gen_lower` and `gen_encode_all` are format-neutral — the same sections, symbols and relocations
that feed `macho_write` feed `elf_write`. The translation is:

| mc | ELF |
|---|---|
| `__TEXT,__text` | `.text`, `SHT_PROGBITS`, `AX`, align 4 |
| `__TEXT,__cstring` | `.rodata`, `SHT_PROGBITS`, `A`, align 1 |
| `__DATA,__data` | `.data`, `SHT_PROGBITS`, `WA`, align 16 |
| `__DATA,__bss` | `.bss`, `SHT_NOBITS`, `WA`, align 16 |
| `#section SEG SECT` | `.seg.sect` — leading underscores dropped, lowercased (`__TEXT,__hot` → `.text.hot`); `AX` when the Mach-O flags say pure-instructions, `SHT_NOBITS` when they say zerofill |
| symbol `_main` | `main` — the leading `_` the compiler adds is dropped |
| symbol `l_str0` | `.Lstr0` — the string labels become assembler temporaries |
| `R_BRANCH26` | `R_AARCH64_CALL26` (283) |
| `R_PAGE21` | `R_AARCH64_ADR_PREL_PG_HI21` (275) |
| `R_PAGEOFF12` on an `add` | `R_AARCH64_ADD_ABS_LO12_NC` (277) |
| `R_PAGEOFF12` on an ldr/str | `R_AARCH64_LDST{8,16,32,64}_ABS_LO12_NC` (278/284/285/286), by the access width in bits 31:30 |
| `R_UNSIGNED` (8 bytes) | `R_AARCH64_ABS64` (257) |

Section order in the file is null, the module's sections in creation order, one `.rela.X` per
section that has relocations, `.symtab`, `.strtab`, `.shstrtab` — so a module section's index is
its ELF section index minus one, which is what lets `st_shndx` be `sym_sect` unchanged. Symbols
come out in `macho.mc`'s stable partition (locals, defined globals, undefined), which is also
what ELF requires (`sh_info` = index of the first non-local). Relocation entries are sorted by
ascending offset, the ELF convention. On aarch64 every `r_addend` is 0 — the encoder leaves the
relocated immediate zeroed, so there is no implicit addend to carry over. The determinism rules
are the same ones `docs/determinism.md` states for Mach-O.

Verified field by field against `clang --target=aarch64-linux-musl -c` of equivalent C, with
`llvm-readobj --all` and `llvm-objdump -dr`; the one difference that is not the writer's is the
`R_PAGEOFF12` row: `mc` always materializes a global's address with `adrp` + `add`, so it asks for
`ADD_ABS_LO12_NC` where clang folds the offset into the load and asks for `LDST64_ABS_LO12_NC`.

### The x86-64 rows

`arch = "x86_64"` writes `EM_X86_64` (62) and three relocations instead of the five above:

| mc | ELF | where | addend |
|---|---|---|---|
| `call rel32` (`R_X86_PLT32`) | `R_X86_64_PLT32` (4) | instruction + 1 | −4 |
| `lea r, [rip + disp32]` (`R_X86_PC32`) | `R_X86_64_PC32` (2) | instruction + 3 | −4 |
| `R_UNSIGNED` (8 bytes, in data) | `R_X86_64_64` (1) | as written | 0 |

The addend is −4 because a `rel32` counts from the **end** of its own field, which is four bytes
past `r_offset`; that is exactly what `clang --target=x86_64-linux-musl -c` emits for the same
constructs, offsets and addends included. Every distinct instruction the machine produced while
compiling `src/mc.mc` for x86-64 — 948 of them — re-assembles byte-identically under
`llvm-mc -triple=x86_64-linux-musl`.

Sections, symbol names and the symbol partition are unchanged: `.text`/`.rodata`/`.data`/`.bss`,
`_main` → `main`, `l_str0` → `.Lstr0`. Functions are aligned to 4, so up to three zero bytes sit
between them; they are never executed, but a disassembler decodes them as `add %al, (%rax)`.

### No libc at all: `<sys_linux>`

`lib/sys_linux.mc` is `lib/sys_svc.mc`'s Linux sibling: `open`/`creat`/`read`/`write`/`close`/
`fchmod`/`exit` as raw `svc #0` with the call number in `x8` (openat 56, close 57, read 63,
write 64, fchmod 52, exit_group 94; `AT_FDCWD` is `-100`, written as `movn x0, #99`). It also
provides `_start`, which reads `argc`/`argv` off the entry stack, calls `main` and exits — so the
link needs no crt objects at all:

```toml
[linker]
cmd  = "ld.lld"
args = ["-nostdlib", "-e", "_start", "-o", "{out}", "{obj}"]
```

`tests/linux/070-nolibc.mc` is that case, inside `scripts/test-linux.sh`. It is AArch64-only —
the syscall words and `_start` are hand-encoded instructions — so it carries a `// skip-x86_64:`
header, and `--arch x86_64` lists it as skipped instead of running it.

The `O_RDONLY`/`O_WRONLY`/`O_CREAT`/`O_TRUNC` constants moved out of `lib/io.mc` and into each
system layer at M16, because they are per-system: `O_CREAT` is `0x200` on macOS and `0x40` on
Linux. `lib/io.mc` still holds only what is written in the language itself (`strlen`, `puts`,
`putnum`) and is still never included alone.

### Running the suite

`scripts/test-linux.sh [--arch aarch64|x86_64]` cross-compiles every `tests/*.mc` with the config
above, links each one with `ld.lld`, and runs it inside `docker run --rm --platform
linux/arm64|linux/amd64 -v <repo>:/w -w /w alpine:3`, comparing exit code and stdout with the same
`// expect-exit:` / `// expect-stdout:` headers the macOS suites use. The repository root is the
mount and the working directory because a test may open its own source by a relative path
(`tests/025-linecount.mc` does).

A test that cannot run on a target carries a third header and the script prints the list at the
end. `// skip-linux: REASON` is the whole operating system; `// skip-x86_64: REASON` is that
instruction set only.

```
32/32 tests passed on linux/aarch64
skipped (not portable to this target):
  032-svc — lib/sys_svc.mc has the Darwin syscall numbers in x16 and svc #0x80; the Linux equivalent is lib/sys_linux.mc
```

```
29/29 tests passed on linux/x86_64
skipped (not portable to this target):
  031-opcode — the #opcode templates are AArch64 words (movz/add); the x86-64 machine emits its own instruction set
  032-svc — lib/sys_svc.mc has the Darwin syscall numbers in x16 and svc #0x80; the Linux equivalent is lib/sys_linux.mc
  033-reloc — the raw word is an AArch64 `bl` and BRANCH26 is a Mach-O/AArch64 relocation; x86-64 calls are R_X86_64_PLT32
  070-nolibc — lib/sys_linux.mc encodes the syscalls and _start as AArch64 `svc #0` words; the x86-64 equivalent would be `syscall`
```

Everything else is portable as written on both, including `030-section` (custom `#section`s, which
`ld.lld` folds into `.text`/`.data` by name). The three that are not are exactly the three that
write instructions by hand — which is the point: `#opcode`, `emit()` and `reloc()` are an
instruction set, and everything above them is not.

One behaviour above them is still the hardware's: a division whose divisor is zero at run time, and
`INT64_MIN / -1`, answer `0`/`x`/`INT64_MIN` on AArch64 and raise `SIGFPE` on x86-64. No test in the
suite divides by zero, so the corpus does not see it; a program of yours can
([core-language.md](core-language.md) § "Division by zero, and `INT64_MIN / -1`").

`make test-linux` and `make test-linux-x86_64` are both inside `make check` and both guarded:
without `ld.lld` in `PATH`, or with Docker not running, they print `SKIPPED (...)` and the build
stays green. In CI each one has a job that links and *runs* the suite on a real machine of that
architecture (`docs/ci.md`), which is what `docs/plan.md` § Rule for every new target requires.

---

## M19 — Windows targets (`os = "windows"`, `arch = "aarch64"`)

`os = "windows"` makes `mc build` write a **COFF object** for Windows on ARM instead of a Mach-O
and hand it to the linker named in `[linker]`. Nothing else in the file changes, and nothing in
`stage0/` changes: the COFF writer is `src/backend_coff.mc`, a backend registered like any other
(`--backend=coff-obj-arm64` also works from the single-file CLI). The machine behind it is the
same `arm64` one macOS uses — this is a new *file format*, not a new instruction set.

```toml
[project]
entry = "hello.mc"
out   = "build/hello.exe"

[target]
os   = "windows"
arch = "aarch64"

[sysroot]
path = "build/sysroot/windows-aarch64"   # what {sysroot} expands to

[linker]
cmd  = "lld-link"
args = ["/machine:arm64", "/subsystem:console", "/entry:mc_start", "/nodefaultlib",
        "/out:{out}", "{obj}", "{sysroot}/kernel32.lib"]
```

```
$ build/mc1 build . --config windows.toml
compile hello.mc -> build/hello.exe.o
link build/hello.exe.o -> build/hello.exe
```

`[linker]` is **required**, for the same reason it is on Linux, and asking for a direct executable
says so:

```
$ build/mc1 build tests/proj --config /tmp/w.toml
/tmp/w.toml:6:8: windows requires [linker]: there is no direct executable: target.os
```

`/entry:mc_start /nodefaultlib` is not a stylistic choice: the entry point comes from
`lib/sys_windows.mc` and there is no C runtime in the link at all.

### The sysroot: an import library, not a download

A Windows program does not link against a copy of `kernel32.dll`. It links against an **import
library** — a small archive holding one thunk per exported name and no code from the DLL — and
that archive can be generated from a plain list of names. So `scripts/sysroot-windows.sh
[--arch aarch64] [DIR]` writes `kernel32.def` (the seven entry points `lib/sys_windows.mc`
declares) and builds `kernel32.lib` from it with `llvm-dlltool -m arm64`. No network, no Windows
SDK, no mingw. Like the musl one it is a cache: with `kernel32.lib` already there it does nothing.
`make sysroot-windows` runs it, and `scripts/test-windows.sh` runs it by itself.

A program that needs more than those seven names — a whole SDK, other DLLs — is what
`mc sysroot fetch windows-*` will be for; this is the toolchain the test suite needs.

### What the COFF writer says

`src/backend_coff.mc` is the third writer over one lowering. `gen_lower` and `gen_encode_all`
produce sections, symbols and relocations; the writer only spells them in COFF:

| the module says | the object says |
|---|---|
| `__TEXT,__text` | `.text`, `CNT_CODE \| MEM_EXECUTE \| MEM_READ` |
| `__TEXT,__cstring` | `.rdata`, `CNT_INITIALIZED_DATA \| MEM_READ` |
| `__DATA,__data` | `.data`, `CNT_INITIALIZED_DATA \| MEM_READ \| MEM_WRITE` |
| `__DATA,__bss` (zerofill) | `.bss`, `CNT_UNINITIALIZED_DATA`, `SizeOfRawData` = the size, `PointerToRawData` = 0 |
| `#section __TEXT __hot` | `.text.hot`, flags derived the same way the ELF writer derives them |
| section alignment | three bits of `Characteristics` (`IMAGE_SCN_ALIGN_<2^n>BYTES` is `(n + 1) << 20`), not a field |
| `_main` | `main` — Windows on ARM has **no** leading underscore, exactly like ELF |
| `l_str0` | `$str.0`, `IMAGE_SYM_CLASS_STATIC` |
| `R_BRANCH26` | `IMAGE_REL_ARM64_BRANCH26` (0x0003) |
| `R_PAGE21` | `IMAGE_REL_ARM64_PAGEBASE_REL21` (0x0004) |
| `R_PAGEOFF12` on an `add` | `IMAGE_REL_ARM64_PAGEOFFSET_12A` (0x0006) |
| `R_PAGEOFF12` on an `ldr`/`str` | `IMAGE_REL_ARM64_PAGEOFFSET_12L` (0x0007) — the linker reads the scale off the instruction |
| `R_UNSIGNED` | `IMAGE_REL_ARM64_ADDR64` (0x000E) |

`PAGEOFFSET_12L` is in the table but the suite never produces one: the arm64 machine always
materialises a global address with `adrp` + `add`, so every `R_PAGEOFF12` it emits lands on an
`add` and comes out `12A` — the same divergence from clang the ELF writer records. The `ldr`/`str`
form is reachable from hand-written code (`reloc(PAGEOFF12, …)` before an `#opcode` load), and the
classifier is the one `elf_pageoff12` and `exe_fix_pageoff12` already use.

Three things are worth naming because they are easy to get wrong:

* **A COFF section is numbered from 1 in table order**, which is exactly the module's `sym_sect`.
  Emitting the sections in creation order is what makes the renumbering a no-op.
* **The two long-name encodings are different.** A *section* name longer than eight bytes is `/`
  and the decimal offset into the string table, as text inside the eight bytes; a *symbol* name
  longer than eight bytes is four zero bytes followed by that offset as a 32-bit number. Using the
  section form for a symbol makes `llvm-readobj` print `/17` where a name should be.
* **There is no addend field.** COFF is Mach-O's shape here, not ELF's: the addend lives in the
  instruction, and the encoder already leaves it zeroed.

`TimeDateStamp` is `0`, never the clock — the same determinism rule as everywhere else
([determinism.md](determinism.md)). `NumberOfRelocations` is 16 bits, and a section with more than
65535 relocations is refused with a message rather than written wrong.

Every field above was checked against `clang --target=aarch64-windows-msvc -c` of equivalent C
with `llvm-readobj --file-headers --sections --symbols --relocs` and `llvm-objdump -dr`.

### No C runtime at all: `<sys_windows>`

`lib/sys_windows.mc` is `lib/sys_linux.mc`'s Windows sibling, with one difference of substance:
there is no syscall instruction. Windows has no stable system-call numbers, and the documented
boundary is `kernel32.dll` — so the layer is ordinary mc code over seven `extern`s
(`GetStdHandle`, `WriteFile`, `ReadFile`, `CreateFileA`, `CloseHandle`, `ExitProcess`,
`GetCommandLineA`), all non-variadic. `write(fd, …)` translates the descriptors 0, 1 and 2 through
`GetStdHandle`; `open`/`creat` hand back the `HANDLE` `CreateFileA` returned and the other
wrappers take it back unchanged, which is safe because a real handle is never 0, 1 or 2.

It also provides the entry point, `mc_start`: it splits `GetCommandLineA()` into `argc`/`argv`
(runs of spaces and tabs separate, a double quote toggles a region where they do not) and calls
`main` through a raw `bl`, the way `lib/sys_linux.mc`'s `_start` does — the two parameters are
already in `x0`/`x1` and the prologue does not touch them
([reference/objects.md](reference/objects.md) § 4).

**It deliberately does not include `io.mc`**, and that is the one place it differs from
`lib/sys_linux.mc`. On Linux the wrappers come out of `libc.a`, an archive the linker takes
members from; here they come out of an ordinary object linked *next to* the program, and an object
carries everything it holds. If this file also carried `strlen`/`puts`/`putnum`, every program
that already has them — anything that includes `lib/sys.mc`, which ends in `io.mc` — would fail
the link with a duplicate symbol. A program that includes the layer directly writes:

```mc-no-run
#include <sys_windows>
#include <io>
```

`tests/windows/070-kernel32.mc` is that case, the counterpart of `tests/linux/070-nolibc.mc`.

The `O_RDONLY`/`O_WRONLY`/`O_CREAT`/`O_TRUNC` constants live here too, for the same per-system
reason they live in each of the other layers.

### Running the suite

`mc` runs on macOS arm64 and a Windows binary runs on Windows, so the suite is split in two and
`scripts/test-windows.sh` has a mode for each half:

```
scripts/test-windows.sh [MC]                     cross-compile + validate (here)
scripts/test-windows.sh --build-only OUTDIR [MC] cross-compile only
scripts/test-windows.sh --run-only OUTDIR        link OUTDIR and run it (Windows)
```

`--build-only` writes one `<name>.obj` per test (`kind = "obj"`, so the driver stops at the
object), a `<name>.expect` with the header values, a `manifest`, a `skipped` list, and the two
files the other half cannot make for itself: `winrt.obj` — `lib/sys_windows.mc` compiled the same
way — and `kernel32.lib`. `--run-only` needs `lld-link` and nothing else: no `mc`, no compiler, no
SDK. The manifest records a link mode per object:

| mode | link |
|---|---|
| `kernel32` | `<name>.obj winrt.obj kernel32.lib` — the test's `extern` `write`/`open`/`read`/`close` resolve against the layer, exactly as they resolve against `libc.a` on Linux |
| `self` | `<name>.obj kernel32.lib` — the source already includes `<sys_windows>` and carries the layer and `mc_start` itself |

The default mode is what `make test-windows` runs on the development machine: cross-compile
everything, assert every object is an arm64 COFF with `TimeDateStamp` 0, and link three of them
with `lld-link`. Nothing is executed here — there is no Windows host — and the `windows-11-arm` CI
leg is the runtime oracle, which is what `docs/plan.md` § Rule for every new target requires.

```
32/32 objects cross-compiled for windows/aarch64 in build/tests-windows-aarch64
skipped (not portable to this target):
  032-svc — lib/sys_svc.mc enters the Darwin kernel directly; Windows has no stable system-call numbers at all, its boundary is kernel32 (lib/sys_windows.mc)
```

`// skip-windows: REASON` is the header, and `032-svc` is the only test that carries it. Everything
else is portable as written — `030-section` (custom sections), `031-opcode` and `033-reloc`
included: those two write AArch64 words by hand, and this target is AArch64.

`make test-windows` is inside `make check` and guarded like `test-linux`: without `lld-link` or
`llvm-dlltool` it prints `SKIPPED (...)` and the build stays green.

---

## M23 — limits: one estimate, one tolerance, no ceilings

Until M22 every table in the compiler was a static array with a `MAX*` ceiling, and a program that
outgrew one died with `too many X`. Since M23 there is no ceiling in `src/`: every table is an
arena block that **doubles on demand**, and the only thing left to decide is how big it should be
*before* the first append, so the doubling stays the exception.

```
mc limits [DIR|FILE.mc]        # build, then report; exit 0 / 3 / 1
mc build [DIR] --limits        # the same report at the end of a normal build
mc build [DIR] --fix-limits    # ... and, with your consent, raise the tolerance
```

```toml
[limits]
tolerance = 0.25               # a float in [0, 1]; 0.25 is the default
```

### How a table is sized

`grow()` in `src/arena.mc` is the whole mechanism — five lines at every append site:

```
    toktab = grow(T_TOKENS, toktab, ntok, &tokcap, TE_SIZE);
```

The first call allocates `estimate * (1 + tolerance)` elements; every call after that returns the
same block until it is full, and then doubles it and counts one **growth event**. Elements keep
their insertion order across a growth, so nothing the compiler emits can depend on when a table
grew — see `docs/determinism.md` § capacity.

The arena itself works the same way. It starts as the 32 MiB static `heap[]` in bss, and when that
runs out it maps one more chunk with `mmap` (`extern uptr mmap(...)` in `src/arena.mc`, and the
same prototype in `lib/sys.mc` so a program can do it too). Chunks are never moved and never
freed, which is what lets every table be a plain arena block. `arena exhausted` now only happens
if the kernel itself refuses.

**When it does, the message says where and how much (M21.5).** `xalloc` is called from everywhere
and carries no position of its own, so `parse.mc`'s `next()` leaves the current token's file and
line in two globals (`ax_file`, `ax_line`, `src/arena.mc`) — two stores per token — and the
diagnostic reads them:

```
mc: arena exhausted (12 MiB reserved, 23 MiB estimated, asked 9418352 bytes) while parsing src/arena.mc:5 -- raise [limits].tolerance or HEAP_SIZE
```

Four numbers, and each one points at a different fix: what was already reserved across every
chunk, what the plan had estimated (so a shortfall in the estimate is visible as such), the
request that did not fit, and the position the parser had reached. `cannot reserve the arena` —
the up-front `arena_reserve` failing instead of a later growth — prints the same line with its own
first word. With no position (the failure happened in the pre-scan, or during codegen) the
`while parsing` clause is simply absent.

The two knobs the last clause names are real: `[limits].tolerance` in `mc.toml` scales every
reserve including the arena's, and `HEAP_SIZE` in `src/arena.mc` is the static chunk a compiler
starts from.

### Where the estimate comes from

Two sources, and the bigger one wins.

**Static**, from a byte-level pre-scan of the entry file plus every include it can reach —
relative ones from disk, `<name>` ones from the bundle (inflated once and cached, so the lexer
pays nothing twice). The scan follows only a `#include` that **opens a line**: the ones inside
`//` comments and inside the string literals `src/driver.mc` writes are not directives, and
following them would pull whole modules into the estimate that the lexer never reads.

It counts four things — `bytes`, `"` (`quotes`), occurrences of `") {"` and occurrences of
`"#define"` — and turns them into this:

| table | estimate |
|---|---|
| `nodes` | `bytes / 11` |
| `ins` | `nodes * 9 / 10` |
| `strings` | `quotes / 3` |
| `funcs`, `lowered` | occurrences of `") {"` |
| `globals` | `funcs / 3` |
| `defines` | occurrences of `"#define"` |
| `symbols` | `funcs + globals + strings` (exact, by construction) |
| `includes` | files the pre-scan reached |
| `heap` | `sum(count * record size) * 5 / 3 + 7 * bytes` |
| everything else | its cold-start seed in `lim_seeds` (`src/arena.mc`) |

The token table is deliberately **not** byte-derived: it holds *distinct lexemes* — the core
keywords plus whatever `#token`, `#rule` and `syntax()` register — so 512 covers every source in
this repository and doubling covers a taught language.

The coefficients were calibrated against `src/mc.mc` (769 KB of reachable source, 22 files). What
`mc limits src/mc.mc` reports today:

| table | estimate | used | error |
|---|---|---|---|
| `nodes` | 71 546 | 68 105 | +5% |
| `ins` | 64 391 | 57 078 | +13% |
| `strings` | 602 | 571 | +5% |
| `funcs` | 961 | 836 | +15% |
| `globals` | 320 | 259 | +24% |
| `defines` | 514 | 493 | +4% |
| `symbols` | 1 883 | 1 666 | +13% |
| `includes` | 22 | 22 | exact |
| `heap` | 24 139 550 B | 23 489 728 B | +3% |

`examples/api` is the honest counter-example. Its taught compiler (`build/mc-api.mc`, which pulls
`<mc/core>` in) lands the same way — `nodes` 73 343 estimated against 70 360 used, verdict `ok` —
but its **entry** does not: `main.mc` is 33 KB of source in which seven `class`/`interface`
declarations expand into 39 ordinary ones, so the AST is bigger than the bytes suggest
(`nodes` 3 075 estimated, 3 932 used; `ins` 2 767 against 4 692). The first build grows; the
second does not, because of the second source below.

**Remembered**, from `build/.mc-usage.toml`, which `mc build` writes at the end of every build:

```toml
# written by `mc build`: high-water usage per table (M23).
# One section per compiled source. Safe to delete.
[usage."build/mc-api.mc"]
nodes = 63731
...
[usage."main.mc"]
nodes = 3932
...
```

One section per compiled source, keyed by the path the way `mc.toml` writes it — a project with a
`[compiler]` compiles **two** sources of very different sizes in two processes, and neither should
pre-size the other. The next build reads its own section and takes the larger of it and the static
estimate. Only capacities depend on this file; deleting it changes how much memory the build takes
and nothing else.

### The report

```
$ build/mc1 limits src/mc.mc
limits src/mc.mc
table         estimate   reserved       used  grow  verdict
tokens               0        512         51     0  ok
...
nodes            71546      89432      68105     0  ok
...
heap          24139550   33554432   23489728     0  ok
tolerance 0.25, verdict ok (heap in bytes, every other table in elements)
```

* **estimate** — what the two sources above agreed on.
* **reserved** — `estimate * (1 + tolerance)`, never below the table's cold-start seed. This is
  what was set aside *before* the first append; a table that grew ended up with more, and the
  `grow` column is what says so. For `heap` it is the bytes actually mapped, the static 32 MiB
  included.
* **used** — the high-water mark. Tables that restart per function (`locals`, `loops`) report the
  largest function, not the last one.
* **grow** — reallocations past that first reserve.
* **verdict** — `grew` (it had to grow), `tight` (no growth, but `used` is over 90% of `reserved`),
  `ok`.

The exit code is **0** for `ok`, **3** for `grew` or `tight`, and **1** if the build itself failed
— so a CI job can treat 3 as a warning and 1 as a break. `mc limits FILE.mc` runs the same
pipeline as a real compile up to `gen_encode_all()` and writes no object: the tables are the point.
A project with a `[compiler]` prints **two** reports, the compiler's first and the entry's second
(the child gets the same flag), and the worse of the two verdicts is what comes back.

### `--fix-limits`

`mc build --fix-limits` is the only thing that ever writes to `mc.toml`, and it writes exactly one
line: the smallest tolerance — a multiple of 0.05, in `[0, 1]` — that would have kept every table
off `grew` *and* off `tight` **with the static estimate alone**, because the static estimate is
what a clean checkout has. Every other byte of the file comes out as it went in; if there is no
`[limits]` section it is appended, and if there is one without a `tolerance` key the line is
inserted at its end.

```
$ build/mc1 build examples/api --fix-limits
...
fix-limits: tolerance 0.00 -> 0.10 in examples/api/mc.toml
...
fix-limits: tolerance 0.10 -> 0.95 in examples/api/mc.toml
$ diff before examples/api/mc.toml
46c46
< tolerance = 0.0
---
> tolerance = 0.95
```

When even `1.0` is not enough — a table whose static estimate is only its cold-start seed, for
instance — it says so and leaves the tolerance alone; the remembered usage is what covers that
case, and it was just written.

### Floats in `mc.toml`

The language has no floating point and does not need it here. `src/toml.mc` reads a decimal float
as **basis points**: an `i64` hundredth of a percent, so `0.25` is `2500`, `1.0` is `10000` and
`0.0001` is `1`. At most four fraction digits; a fifth is
`file:line:col: float with more than 4 fraction digits`. A value outside `[0, 1]` is refused at
the position where it was written:

```
$ build/mc1 limits examples/api
examples/api/mc.toml:46:13: tolerance must be between 0 and 1
```

### What this replaces

`MAX*` is gone from `src/`, with four exceptions that are not tables that scale with a program:
`MAXPARAMS` (8, the ABI), `MAXDEPTH` (64, the expression depth that produces `expression too
deep`), `MAXBIND`/`MAXRDEPTH`/`MAXITEMS`/`MAXNAMES`, which bound **one** `#rule` and size the
inline fields of a rule's record, and `MAXSUBST` (16, M21), which bounds **one** lexer frame's
substitutions and produces `too many substitutions`. The two tables M23 did not see, because they
came in with M16 and M21, follow the same rule as the rest: the ELF section table
(`src/backend_elf.mc`) is allocated at exactly `2 * nsections + 4` slots — the count is known
before the first append — and M21's four substitution arrays are parallel to the `#include` stack,
so `lex_push_mem` re-sizes them with it. `stage0/*.c` keeps every one of its ceilings: the C seed
is a seed and only ever has to compile `src/mc.mc`. `make check-limits` is what watches that gap —
`mc limits src/mc.mc` against the constants read straight out of `stage0/mc.h` and `stage0/*.c`,
failing at 90%:

```
$ scripts/check-limits.sh build/mc1
ok   tokens        51 / 2048     2%  (MAXTOK)
ok   defines      634 / 2048    30%  (MAXDEFS)
ok   funcs       1002 / 2048    48%  (MAXFUNCS)
ok   globals      320 / 512     62%  (MAXGLOBALS)
ok   strings      648 / 2048    31%  (MAXSTRS)
...
ok   heap        29Mi / 64Mi    46%  (HEAP_SIZE, max RSS of build/mc0)
17/17 seed limits under 90%
```

### The seventeenth row: the seed's arena

The last row is not a table, and it is the one that bit. At M17 every `MAX*` above was under 57%
and `build/mc0 src/mc.mc` started failing with `arena exhausted`: what had filled was
`HEAP_SIZE` in `stage0/arena.c`, which nothing watched.

The reason the arena fills faster than any element count suggests is that **the seed's growable
arrays double and never free**. `stage0/arena.c` is a bump allocator with no `free`, and
`nodes_grow` in `stage0/ast.c` allocates a new array of twice the capacity and copies — leaving
every earlier copy resident forever. With `sizeof(Node) == 72` and `src/mc.mc` at about 79 000
nodes, the live array is 9.4 MB and the dead ones another 9.4 MB: 18.9 MB of arena for a number
that `mc limits` prints as one line of `nodes`. The largest single contributor to that count is
`src/bundle_data.mc`, which carries the bundle as one `N_INT` node per `u64` (about 27 800 of
them) because the frozen seed has no `#embed` — see `scripts/check-bundle.sh`.

The seed cannot report its own high-water mark, and instrumenting it would be a change to the
frozen seed, so the row uses the **maximum resident set size** of one real `build/mc0 src/mc.mc`
run as the proxy (`/usr/bin/time -l`). The arena is a bss array, so only the pages the allocator
touched are resident; the measurement over-reports by the size of the binary itself, which is the
safe direction for a guard. On a system without `/usr/bin/time -l` the row skips instead of
failing.

When it does go over 90%, the fix is the one the project has made before (`517685f` lowered the
arena from 256 MiB to 32 MiB when self-compiling touched 14.5 MiB; `a5aa850` raised five `MAX*`
constants at M23): raise the constant. It is capacity, not behaviour — the arena size is not
observable in any output, so `check-obj`, `check-asm`, the fixed point and the golden are all
unaffected. M17 raised it to 64 MiB.

### What it buys

A generated program with 5 000 functions and 5 000 string literals — well past the seed's
`MAXFUNCS`/`MAXSTRS` of 2 048 — builds with **no change to any TOML**:

```
$ build/mc1 build tmp/big --limits  # first build
nodes            22858      28572      55133     1  grew
funcs             5004       6255       5015     0  ok
strings           3338       4172       5000     1  grew
ins              20572      25715      90118     2  grew
heap           8732233   33554432   28241744     0  ok
tolerance 0.25, verdict grew            # exit 3

$ build/mc1 build tmp/big --limits  # second build, remembered usage
nodes            55133      68916      55133     0  ok
funcs             5015       6268       5015     0  ok
strings           5000       6250       5000     0  ok
ins              90118     112647      90118     0  ok
heap          28241744   68878336   22706336     0  ok
tolerance 0.25, verdict ok              # exit 0
```

`build/big` runs and exits 42 either way. The second build is also the cheaper one: right-sized
tables allocate once instead of doubling, which is why its arena high-water drops from 28 MB to
22 MB.

---

## The Makefile still works

`examples/api/Makefile` does by hand exactly what `mc build` does from `mc.toml`, and both are
checked:

```
make -C examples/api mc-api      # build/mc-api, by hand
make -C examples/api api         # build/api, by hand
make -C examples/api test        # test-oop + tests/lib_test.sh + test.sh
```

`examples/api/test.sh` compiles with `mc build` since M14 — that is what puts the driver inside
`make check`, through `check-examples`.

---

## What `make check` proves

| target | what it runs |
|---|---|
| `check-toml` | `scripts/check-toml.sh`: `tomldump` over `tests/toml/*.toml`, compared with `*.expect`; the `bad-*` ones must exit 1 with the exact `file:line:col` |
| `check-build` | `scripts/check-build.sh`: `tests/proj` built three ways (`exe.toml`, `link.toml`, `obj.toml`), each artifact run or inspected, plus five diagnostics |
| `check-examples` | `examples/api/test.sh`, which now starts with `mc build examples/api` |
| `check-bundle` | `scripts/check-bundle.sh`: regenerates the bundle twice into temporary files, `cmp`s the two runs against each other and against the checked-in `src/bundle_data.mc`, checks that `<mc/bundle_data>` is the `#embed` form (one `BLOB` node plus the index), then runs `tools/lz_test.mc` (LZ round trip over random/degenerate buffers and over every bundled file) |
| `check-mc` | `scripts/check-mc.sh`: `tests/mc/*.mc` (`#embed`, `#include <name>`) through `.o` + `ld` and through `--exe`, plus the assertion that `build/mc0` rejects them |
| `check-standalone` | `scripts/check-standalone.sh`: `build/mc-exe` copied alone into a temporary directory, compiling `<sys>`/`<prelude>`, a taught compiler from `<mc/core>`, and the byte-for-byte comparison against `build/mc2.o` |
| `test-linux` | `scripts/test-linux.sh`: every `tests/*.mc` without `// skip-linux` cross-compiled with `elf-obj`, linked by `ld.lld` against musl and run in `docker --platform linux/arm64`, plus the no-libc case. Guarded: skipped with a message when Docker or `ld.lld` is missing |
| `test-linux-x86_64` | the same with `--arch x86_64`: the `elf-obj-x86_64` backend, an amd64 musl sysroot and `docker --platform linux/amd64`. Also skips the tests that carry `// skip-x86_64`. Guarded the same way |
| `test-windows` | `scripts/test-windows.sh`: every `tests/*.mc` without `// skip-windows` cross-compiled with `coff-obj-arm64`, every object's COFF header checked with `llvm-readobj` and three of them linked with `lld-link`. Nothing is executed — the `windows-11-arm` CI leg runs them. Guarded: skipped when `lld-link` or `llvm-dlltool` is missing |
| `check-limits` | `scripts/check-limits.sh`: `mc limits src/mc.mc` against the fixed `MAX*` constants still in `stage0/mc.h` and `stage0/*.c`, plus the seed's `HEAP_SIZE` against the max RSS of a real `build/mc0` run; fails when any of them is over 90% used |

```
$ scripts/check-toml.sh build/mc1
...
10/10 TOML files match
$ scripts/check-build.sh build/mc1
...
11/11 mc build checks passed
$ scripts/check-limits.sh build/mc1
...
17/17 seed limits under 90%
$ scripts/test-linux.sh build/mc1
...
32/32 tests passed on linux/aarch64
$ scripts/test-linux.sh --arch x86_64 build/mc1
...
29/29 tests passed on linux/x86_64
```

---

## Limits of M14, M15, M16 and M23

- **`[target]` defaults to the host.** With no `[target]` section at all, `os` and `arch` are what
  `mc --host` prints — `macos`/`aarch64` when a macOS binary reads the file, `linux`/`aarch64` or
  `linux`/`x86_64` when a Linux one does. Every config in this repository still pins the pair
  explicitly; a config that omits it is portable, and one that pins `macos` means it.
- **Two architectures, and for Linux only through an external linker.** `[target].arch` other than
  `aarch64` (macOS, Linux) or `x86_64` (Linux) is a clear error, and so is `[target].os` other than
  `macos`/`linux`; COFF and wasm are later milestones. A Linux `exe` without `[linker]` is refused —
  there is no ELF equivalent
  of `macho-exe`, so `ld.lld` (or any linker named in the config) does the layout.
- **The taught compiler is always built for the host, never for `[target]`.** It is a tool that
  has to run here, not part of the artifact. Which backend that is comes from the target registry,
  looked up with the *host's* pair: on macOS `macho-exe`, one step. On a host with no
  direct-executable backend — Linux — it is the host's object backend plus `[linker]`, the same
  section the entry uses, and a project that teaches the compiler there without one gets
  `a taught compiler on this host needs [linker]: there is no direct executable`.
- ~~**`mc` itself does not cross-compile yet**~~ — done in M37. `_NSGetEnviron` was the single
  blocker (libSystem's way of reaching `environ`, with no musl equivalent), and it now lives in
  the host layer: `src/mc_linux.mc` and `src/mc_linux_x86_64.mc` are the same core with
  `src/host_linux*.mc` instead of `src/host_macos.mc`. `build/mc1 build src --config
  src/mc.linux-aarch64.toml` cross-builds it, `scripts/bootstrap-linux.sh` bootstraps it on the
  Linux machine, and the object it writes for `src/mc.mc` is byte for byte the one macOS writes.
  See [guide/90-linux-host.md](guide/90-linux-host.md).
- **Static linking and the names in `lib/io.mc`.** A program that includes `<sys>` defines
  `strlen` and `puts` as ordinary global symbols. Against `libc.a` that is fine — an archive
  member is only pulled in for a symbol that is still undefined — but it does mean the program's
  own `strlen` is the one musl's pulled-in members will use.
- ~~**`#include <name>` from a bundle does not exist yet**~~ — done in M15, above:
  `[compiler].core` is now optional and the default core is `<mc/core>`.
- **`[compiler].out` must be a relative path with no `..`**, because the generated source lives
  next to it and reaches the modules by counting `../`.
- **`[[array of tables]]` is parsed and kept, but nothing reads it yet.** It is in the parser so
  the file format does not have to change when something does.
- **One entry per project.** `mc build` compiles one `entry` into one `out`; there is no
  dependency graph and no incremental build. Everything is recompiled every time — which for this
  compiler means a quarter of a second.
- **Duplicate keys are not rejected.** Real TOML makes a repeated key an error; here both entries
  stay in the table, in order, and `toml_get` answers with the first. The cost of catching it is a
  scan and an error message the driver never needs.
- **A key that is not read is not reported.** A typo in a section or key name is silently ignored,
  the same way an unknown `#define` in a source file is only noticed where it is used.
- **The bundle is a snapshot, not a package manager.** There is no version, no namespace beyond
  the `mc/` prefix, and no way to add to it without regenerating `src/bundle_data.mc` and
  rebuilding. A project that wants its own library still uses `#include "x"` and
  `[include].paths`.
- **`<name>` never falls back to disk.** That is deliberate (the answer must not depend on the
  working directory), but it also means a bundled file cannot be shadowed by a local copy for a
  quick experiment; edit `src/`/`lib/` and run `make bundle` instead.
- **`#embed` costs one AST node per byte.** The declared ceiling is 16 MiB; the practical one is
  the arena.
- **The estimate is a byte scan, not a parse.** It counts `"` without knowing about comments or
  escapes and `") {"` without knowing about function pointers, and it cannot see what a `syntax()`
  handler or a `#rule` will expand into. That is what the tolerance and the remembered usage are
  for; being wrong costs memory and one reallocation, never a failed build.
- **`--fix-limits` reasons about the static estimate only.** It answers "what tolerance would a
  clean checkout have needed", which is why it can land on a number as large as 0.95 for a project
  whose expansion the pre-scan cannot see.
- **The remembered usage is not a lock file.** `build/.mc-usage.toml` is written on every
  `mc build`, is safe to delete, and never affects a single byte of the output — only how much
  memory the build takes.
- **Deleting a source does not shrink its section.** Sections in `build/.mc-usage.toml` are keyed
  by source path and copied through untouched; one for a file that no longer exists just sits
  there until the file is deleted.
