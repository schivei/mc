# `#include <name>`, the library inside the binary

`mc` carries its standard library **and its own source** inside the executable, compressed, and
serves them through the angle-bracket form of `#include`. That is what makes one downloaded
binary the whole toolchain: no checkout, no include path, no install step.

```mc
// expect-exit: 0
// expect-stdout: 42
#include <sys>
#include <prelude>

i64 main() {
    i64 n = 0;
    while (n < 42) { n = n + 1; }
    putnum(n);
    write(1, "\n", 1);
    return 0;
}
```

`<name>` is served by the bundle **or it is an error** — there is no filesystem fallback, on
purpose: `<name>` means "the copy that shipped with this binary", and the answer must not depend
on the working directory.

```
$ mc prog.mc -o prog.o
prog.mc:1: unknown bundled include: no/such/module
```

`#include "path"` is unchanged: the includer's own directory first, then each `[include].paths`
root in order.

---

## The catalogue

The manifest is `tools/bundle.list`, one `NAME<TAB>PATH` per line, sorted by name: 42 entries,
plus `mc/bundle_data`, which is regenerated on demand (see below). Those are the names `<...>`
accepts.

### The system layer — pick exactly one

| name | file | what it gives you |
|---|---|---|
| `<sys>` | `lib/sys.mc` | `open creat read write close exit` as libSystem `extern`s, plus `mmap`/`munmap`, `posix_spawnp`/`waitpid`/`_NSGetEnviron`, plus `<io>` |
| `<sys_svc>` | `lib/sys_svc.mc` | the same five calls through `#opcode svc #0x80`, with **no libSystem at all**, plus `<io>` |
| `<sys_linux>` | `lib/sys_linux.mc` | the Linux syscall layer (`svc #0`, number in `x8`) and a `_start`, for `-nostdlib` |
| `<sys_windows>` | `lib/sys_windows.mc` | the Windows layer: the same five calls over seven kernel32 `extern`s, plus the entry point `mc_start`, for `/nodefaultlib`. It is the one layer that does **not** pull in `<io>` — add `#include <io>` after it (see [../build.md](../build.md) § Windows targets) |
| `<io>` | `lib/io.mc` | `strlen`, `puts`, `putnum` — written in the language, on top of whatever `write` the includer declared. **Never include it alone** |

`O_RDONLY`/`O_WRONLY`/`O_CREAT`/`O_TRUNC` live in each system layer, not in `<io>`, because they
are per-system values (`O_CREAT` is `0x200` on macOS, `0x40` on Linux and `0x100` in the
Windows layer, where the flags are not passed to the system at all).

### The language layer

| name | file | what it gives you |
|---|---|---|
| `<prelude>` | `lib/prelude.mc` | `while`, `for`, `+=`, `-=`, `++`, `--` — six `#rule`s and four `#token`s |
| `<lz>` | `src/lz.mc` | `lz_deflate` / `lz_inflate` / `lz_bound`: the LZ77 the bundle itself uses, with no dependencies at all (not even the arena), so `#embed … lz` is usable from any program |

### The compiler itself

`<mc/core>` is the whole compiler minus exactly one function, `void user_init()`. Including it
and supplying that function *is* a taught compiler ([hooks.md](hooks.md)).

| name | file |
|---|---|
| `<mc/core>` | `src/core.mc` — the include list that pulls in everything below |
| `<mc/host>` | **not a file**: the host layer of the compiler that is *running*. See below |
| `<mc/host_macos>` | `src/host_macos.mc` |
| `<mc/host_linux>` | `src/host_linux.mc` — the operating-system half, shared by both architectures |
| `<mc/host_linux_aarch64>` | `src/host_linux_aarch64.mc` |
| `<mc/host_linux_x86_64>` | `src/host_linux_x86_64.mc` |
| `<mc/arena>` | `src/arena.mc` |
| `<mc/ast>` | `src/ast.mc` |
| `<mc/lex>` | `src/lex.mc` |
| `<mc/parse>` | `src/parse.mc` |
| `<mc/hooks>` | `src/hooks.mc` |
| `<mc/gen_resolve>` | `src/gen_resolve.mc` |
| `<mc/gen_walk>` | `src/gen_walk.mc` |
| `<mc/machine_arm64>` | `src/machine_arm64.mc` |
| `<mc/machine_x86_64>` | `src/machine_x86_64.mc` |
| `<mc/macho>` | `src/macho.mc` |
| `<mc/backend_exe>` | `src/backend_exe.mc` |
| `<mc/backend_coff>` | `src/backend_coff.mc` |
| `<mc/backend_elf>` | `src/backend_elf.mc` |
| `<mc/sha256>` | `src/sha256.mc` |
| `<mc/toml>` | `src/toml.mc` |
| `<mc/driver>` | `src/driver.mc` |
| `<mc/limits>` | `src/limits.mc` |
| `<mc/bundle>` | `src/bundle.mc` |
| `<mc/main>` | `src/main.mc` |
| `<mc/bundle_data>` | `src/bundle_data.mc` — see below |

#### `<mc/host>`, the one name that is not an entry

`<mc/core>` is host-neutral: it says nothing about `posix_spawnp`, the environment, the `O_*`
values or which `(os, arch)` pair the binary is. That comes from a host file, and a compiler needs
exactly one of them, included **before** the core.

`<mc/host>` is how a source asks for "the one that matches whichever `mc` is compiling me". It is
resolved in `src/main.mc` (`host_bundle_open`) to `host_include()`, which each host file answers
for itself — `mc/host_macos`, `mc/host_linux_aarch64` or `mc/host_linux_x86_64` — and the entry it
lands on is what the once-only include list records, so writing `<mc/host>` and
`<mc/host_macos>` in the same program includes the file once, not twice.

```mc
#include <mc/host>
#include <mc/core>

void user_init() { }
```

That is a complete compiler, and it is exactly what `mc build` generates for a `[compiler]`
section ([../build.md](../build.md)). See [../guide/90-linux-host.md](../guide/90-linux-host.md)
for what the host layer answers.

### The demonstrations

Everything `make check-surface` wires up is bundled too, so the demos can be reproduced from a
downloaded binary with no checkout:

| name | file |
|---|---|
| `<backend_arm64>` | `lib/backend_arm64.mc` — the `arm64-surface` backend |
| `<pass_demo>` | `lib/pass_demo.mc` — the `x * 1` → `x` pass |
| `<user_default>` | `lib/user_default.mc` — an empty `user_init()` |
| `<user_demo>` | `lib/user_demo.mc` — registers the backend and the pass |
| `<user_syntax_demo>` | `lib/user_syntax_demo.mc` — the nine Tier 3 registrations |
| `<mc_syntax_demo>` | `lib/mc_syntax_demo.mc` — the taught compiler that wires them in |
| `<syntax_demo_test>` | `lib/syntax_demo_test.mc` — the program only that compiler accepts |
| `<user_dupop>` | `lib/user_dupop.mc` — the duplicate `syntax_infix` refusal |
| `<user_tokadd>` | `lib/user_tokadd.mc` — the `tok_add`-before-`tok_init` guard |
| `<embed_demo>` | `tests/mc/bundle/embed_demo.mc` — `#embed` inside a bundled file |
| `<embed_demo.txt>` | `tests/mc/bundle/embed_demo.txt` — its payload |

---

## Relative includes inside a bundled file

The bundle is **flat**: `mc/lex` is one name, not a directory and a file. But `src/core.mc` still
says `#include "arena.mc"` and `src/driver.mc` still says `#include "../lib/prelude.mc"`, and
both must keep working when the including file is itself bundled. So the lexer joins and
normalises the name the usual way, drops a trailing `.mc`, and looks the result up; if that
misses, it retries with the **last path component**.

| written in | resolves to | found as |
|---|---|---|
| `mc/core` → `"arena.mc"` | `mc/arena` | exact |
| `sys` → `"io.mc"` | `io` | exact |
| `mc/driver` → `"../lib/prelude.mc"` | `lib/prelude` → `prelude` | last component |
| `mc/core` → `"lz.mc"` | `mc/lz` → `lz` | last component |

`tools/bundle.mc` refuses a manifest in which two entries share a last component, so that
fallback can never be ambiguous.

A bundled file is pushed onto the same `#include` stack a real one uses, with the bundled name in
place of a path — which is what a diagnostic then shows:

```
syntax_demo_test:10: type expected at top level
```

## `mc/bundle_data`, the file the bundle cannot contain

`src/core.mc` includes `bundle_data.mc`, and `src/bundle_data.mc` **is** the bundle. It cannot be
inside itself: its own bytes would change the bytes it contains. So it is the one name that is
regenerated on demand — `bundle_find("mc/bundle_data")` answers with index `BUNDLE_COUNT`, and
the file is written out again from the blob and index already in memory, by the very same
`bundle_emit` that `tools/bundle.mc` uses. One definition of the format, so the two cannot drift.

Since M21.5 `bundle_emit` has **two modes**, and the difference is arena, not format:

| mode | who gets it | how the blob is declared |
|---|---|---|
| 0 | `tools/bundle.mc`, writing `src/bundle_data.mc` to disk | `u64 bundle_blob[] = { … }` |
| 1 | the binary, answering `<mc/bundle_data>` | `#embed bundle_blob "bundle.bin"` |

An array initializer costs **one AST node per element**, so spelling the 180 KB blob out cost
~22 500 nodes — 2.3 MB of arena — in every taught compiler that includes `<mc/core>`. As
`#embed` it costs exactly one node (`N_BLOB`). `mc/bundle.bin` is therefore the **second** name
that is not in the blob (index `BUNDLE_BIN = BUNDLE_COUNT + 1`): it *is* `bundle_blob`, served
straight out of the compiler's own data with no inflate and no copy, rounded up to a multiple of
8 so both forms declare a global of the same size.

The disk copy keeps the `u64` form because the frozen `stage0/lex.c` has no `embed` in its
`dir_names[]` and `build/mc0 src/mc.mc` is the seed step of `make mc1`. Both forms produce the
same object, which is what makes the split safe — and what `check-standalone` measures.

`scripts/check-standalone.sh` proves the consequence in the strongest form available: a compiler
built from `#include <mc/core>` + `#include <user_default>`, in an empty directory, compiles
`src/mc.mc` into an object **byte for byte identical** to `build/mc2.o`.

---

## The format, and regenerating it

`src/bundle_data.mc` is **generated source, checked in**. It holds one blob — the NUL-terminated
names first, in manifest order, then each LZ77 stream — and one flat index with four values per
entry (name offset, stream offset, compressed size, real size). Names live in the blob rather
than as string literals because every literal counts against the C seed's budget, and the index
is one array rather than four for the same reason.

```
make bundle          # regenerate src/bundle_data.mc from tools/bundle.list
make check-bundle    # prove the checked-in copy is exactly what comes out
```

`make bundle` is the only way that file is ever written. Run it whenever a `lib/*.mc` or a core
module changes, **before** `make bootstrap` — `make check` runs `check-bundle` first precisely so
that a stale bundle fails with a message naming `make bundle`, instead of failing later as a
mysterious fixed-point difference.

The bundle is inside the fixed point: `mc1` and `mc2` both carry it, and the objects they produce
must still be identical. See [../guide/70-bootstrap.md](../guide/70-bootstrap.md).

## `#embed` and the bundle

`#embed NAME "path" [lz]` ([directives.md](directives.md)) reads its payload the same way its
includer was read: from disk for a real file, and from the bundle when the directive was written
inside a bundled `<name>` include. `<embed_demo>` and `<embed_demo.txt>` are in the manifest
exactly so that this path is exercised from a binary with no checkout.
