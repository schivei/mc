# Every command, flag and dump

`mc` has one binary and four entry points: the single-file compiler, `mc build`, `mc limits` and
`mc sysroot`. Everything below is read off `src/cli.mc` (the single-file CLI), `src/driver.mc`
(the first two subcommands) and `src/sysroot.mc` (the third). Running `mc` with no argument
prints exactly this and exits 1:

```
usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules|--dump-machine] [--backend=NAME|--exe] [--machine=NAME] [--include=DIR] source.mc [-o out]
       mc --host
usage: mc build [DIR] [--config FILE] [--compiler-only] [--limits|--fix-limits] [--sysroot-dir DIR]
       mc limits [DIR|FILE.mc]
       mc sysroot list|path <target>|fetch <target> [--yes] [--sysroot-dir DIR]
       mc sysroot stub [DIR] [--config FILE]
```

---

## 1. The single-file compiler

```
mc [MODE] [--backend=NAME | --exe] [--libc=gnu|musl] [--link=dynamic|static]
   [--interp=PATH] SOURCE [-o OUT]
```

Arguments are read left to right. The first non-flag argument is the source; a second one is
`mc: duplicate entry: <arg>`. An unknown flag starting with `-` that is not `--backend=…` is
`mc: unknown option: <arg>`.

| flag | meaning |
|---|---|
| `-o OUT` | output path. Default `out.o`. `-o` with nothing after it is `mc: -o requires an argument`. |
| `--exe` | write a direct executable for the HOST, no linker. The backend is the exe slot of the host's `target()` registration, resolved after `user_init()` (post-M41 review) — `macho-exe` on macOS, a signed Mach-O binary, and `elf-exe` / `elf-exe-x86_64` on Linux, a dynamic ELF64 `ET_EXEC` (M42) whose `PT_INTERP` names **musl's** loader unless `--libc=gnu` says otherwise. A host registered with 0 in that slot has no direct executable at all, and the flag is refused with `<os> requires a linker: there is no direct executable` instead of writing a binary for another operating system; that is the case on Windows, where the road is an object plus `[linker]`. `--exe` and `--backend=` write the same decision, so the last one on the command line wins. |
| `--libc=gnu\|musl` | which C library **family** a dynamic Linux executable is linked against — the command-line form of [`[target].libc`](toml.md#target-libc-and-target-link-the-two-axes-of-a-linux-target), and the same two words. It picks the `PT_INTERP` path and the `DT_NEEDED` soname together (`gnu`: `/lib/ld-linux-aarch64.so.1` or `/lib64/ld-linux-x86-64.so.2` + `libc.so.6`; `musl`, the default: `/lib/ld-musl-<arch>.so.1` + `libc.so`). Anything else is `mc: --libc must be gnu or musl: <value>`. |
| `--link=dynamic\|static` | the command-line form of [`[target].link`](toml.md#target-libc-and-target-link-the-two-axes-of-a-linux-target). `static` is an **assertion**: the writer already takes the static path for a program that imports nothing, and the flag makes that a requirement — with an import in the set it refuses with `mc: static link with imports needs [linker]: see docs/build.md -- static linking (M46)` instead of writing a dynamic binary. Anything else is `mc: --link must be dynamic or static: <value>`. |
| `--interp=PATH` | the loader path alone, overriding the family's — the command-line form of `[target].interp`, for a system whose loader is at neither standard place. The soname still comes from `--libc=`. |
| `--backend=NAME` | pick a registered backend. Built in: `macho`, `macho-exe`, `elf-obj`, `elf-obj-x86_64`, `elf-exe`, `elf-exe-x86_64`, `coff-obj-arm64`, `coff-obj-x86_64`. The default is the HOST's object backend — the object slot of the host's `target()` registration, `macho` on macOS and `elf-obj`/`elf-obj-x86_64` on Linux (M37) — resolved after `user_init()` like `--exe`'s (post-M41 review), so a module that re-registers the host pair is honoured here too. A host registered with 0 in that slot has no object step at all, and the default is refused with `<os>/<arch> has no object backend: use --exe`. A taught compiler adds its own with `backend("name", &f)`. An unknown name lists what exists and exits 1. |
| `--include=DIR` | add one `#include "…"` search root, exactly like a `[include].paths` entry does for `mc build`. Repeatable; roots are tried in the order given, after the includer's own directory. It is what lets one source tree carry two platform layers in different directories and pick one without a `mc.toml` (`examples/conc/lib/macos`, `lib/linux`). |
| `--host` | print what this binary is and exit 0 — three lines, no source needed. |
| `--machine=NAME` | pick the machine the `--dump-*` modes lower with: `arm64` (the host's, default), `x86_64` (System V) or `x86_64-win` (Win64 — the same instruction set, the Windows calling convention). A compile does **not** need it — an object backend names its own machine, because the file records the architecture — so this flag exists for looking at what a machine selects (`--dump-asm --machine=x86_64-win`). An unknown name is `mc: unknown machine: NAME`. |

```
$ mc --host
os macos
arch aarch64
sys sys
```

`os` and `arch` are the `[target]` pair an `mc.toml` with no `[target]` gets, and the pair that
picks the default backend (`macho` on macOS, `elf-obj` / `elf-obj-x86_64` on Linux); `sys` is the
bundled system layer a program on this host includes for its I/O (`<sys>` or `<sys_linux>`). The
same binary built for a Linux host answers `linux`, its architecture, and `sys_linux` — see [../guide/90-linux-host.md](../guide/90-linux-host.md).

Backends are documented in [objects.md](objects.md) and in [../guide/40-backends.md](../guide/40-backends.md).

```
$ mc --backend=xyz prog.mc -o x.o
unknown backend: xyz
registered: macho macho-exe elf-obj elf-obj-x86_64 elf-exe elf-exe-x86_64 coff-obj-arm64 coff-obj-x86_64
```

`--backend=elf-exe` and `--backend=elf-exe-x86_64` are what `--exe` resolves to on Linux, and
naming one of them from macOS is how a Linux executable is cross-built with no `mc.toml` at all:

```
$ mc --backend=elf-exe hello.mc -o hello
$ llvm-readelf -h hello | grep Type
  Type:                              EXEC (Executable file)
```

The three flags above say the rest, so a source never has to become a project to name its libc:

```
$ mc --backend=elf-exe --libc=gnu hello.mc -o hello
$ llvm-readelf -l -d hello | grep -E 'interpreter|NEEDED'
      [Requesting program interpreter: /lib/ld-linux-aarch64.so.1]
 0x0000000000000001 (NEEDED)   Shared library: [libc.so.6]
```

The compiler **never probes the host** for its libc — one source, one answer on every machine
([../determinism.md](../determinism.md)) — so the default is the constant `musl` and `--libc=gnu`
is how a glibc host says so. The last one on the command line wins, like every other flag here.

All three describe a Linux dynamic **executable**, and only the executable writer reads them:
`PT_INTERP` and `DT_NEEDED` are program-header fields, and an object file has neither. So they are
refused, never read and ignored, on a run that would not write one (post-M42 review):

| the command line | the refusal |
|---|---|
| `mc prog.mc -o prog.o --libc=gnu`, `mc --backend=elf-obj --libc=gnu …` — an object | `mc: --libc applies to an executable: use --exe` |
| `mc --dump-asm --libc=gnu …` — any of the six dumps, with or without `--exe` | `mc: --libc applies to an executable: a --dump-* mode writes none` |
| `mc --exe --libc=gnu …` on a host that is not Linux | `mc: --libc applies to a linux target` |

What makes a writer an executable writer is that some `target()` registration names it in its
**exe slot** — the same table `--exe` resolves through — so a target a module registered from
`user_init()` answers for its own writer, and no backend name is special-cased. The three
questions are asked after `user_init()` and before every dump, which is why an unreadable entry
file reports `cannot open` first ([diagnostics.md](diagnostics.md) § 10).

### Modes: the six dumps

A dump writes deterministic text to **stdout** and produces no object. Only one mode is in
effect — the last one on the command line wins. Five of the six exist in the C seed too, which is
what `make check-lex`, `check-ast` and `check-asm` compare across the two compilers;
`--dump-machine` is the self-hosted compiler's own, because the seed has no machine table.

| flag | prints | stops after |
|---|---|---|
| `--dump-tokens` | `line id lexeme`, one token per line | the lexer |
| `--dump-ast` | the tree, two spaces per level, **after** `#rule` expansion and after every registered `pass()` | the parse |
| `--dump-rules` | the `#rule` table, then every infix and prefix operator with precedence and associativity | the parse |
| `--dump-asm` | one function per label, one instruction per line, `gen_lower` only (nothing is encoded) | lowering |
| `--dump-syms` | one line per section, then one line per symbol | encoding |
| `--dump-machine` | every registered machine, one line per task, with the **origin** of the slot | `user_init()` |

```
$ mc --dump-tokens prog.mc
1 260 i64
1 1 main
1 270 (
1 271 )
1 272 {
1 268 return
1 2 42
1 277 ;
1 273 }
2 0 EOF
```

The number after the line is the token id: `0..6` are the classes (`T_EOF`, `T_IDENT`, `T_INT`,
`T_CHAR`, `T_STR`, `T_DIR`, `T_HOLE`) and `256` upward are lexemes in the mutable token table, in
registration order — `#token` and every Tier 3 registration append there. See
[language.md](language.md) § Tokens.

```
$ mc --dump-ast prog.mc
FUNC type=i64 name=main
  BLOCK
    RETURN
      INT val=42 type=i64
```

```
$ mc --dump-asm prog.mc
_main:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  movz x9, #42
  mov x0, x9
  b L1
L1:
  ldp x29, x30, [sp], #16
  ret
```

```
$ mc --dump-syms prog.mc
section __TEXT,__text flags=0x80000400 align=2 size=28 nreloc=0
sym 0 extern sect=1 value=0 _main
```

`--dump-rules` on a source that includes `<prelude>`:

```
$ mc --dump-rules prog.mc
rule 0: stmt: while ( expr $1 ) block $2 => 7 nodes
rule 1: stmt: for ( stmt $1 expr $2 ; ident $0 = expr $3 ) block $4 => 11 nodes
rule 2: stmt: ident $0 += expr $1 ; => 4 nodes
rule 3: stmt: ident $0 -= expr $1 ; => 4 nodes
rule 4: stmt: ident $0 ++ ; => 4 nodes
rule 5: stmt: ident $0 -- ; => 4 nodes
infix || prec 1 left
infix && prec 2 left
...
prefix -
prefix ~
prefix !
prefix &
```

The `$N` in a rule line is the hole's index in the template, and `=> N nodes` is the size of the
parsed template. `--dump-rules` is the one dump whose `.mc` version says more than the C seed's:
only the self-hosted compiler has the handler column that `syntax_infix` fills in.

`--dump-machine` (M24) is the audit of the other seam. It stops right after `user_init()` — a
machine table is not a function of the source — and reports, per registered machine, which
implementation is behind each task:

```
$ mc-badmach --dump-machine prog.mc
machine arm64 (current)
  prologue          bundled arm64
  const             bundled arm64
  bin               taught
  ...
machine x86_64
  ...
```

`bundled <name>` means the slot's pointer is the one that bundled machine had for that task before
`user_init()` ran, and `taught` means a module replaced it. `(current)` marks the machine the
walker would drive. It is the cheapest test that an override took effect, and it is what makes a
derived machine reviewable — which slots a module actually replaced, and on top of what. There is
no runtime symbol table, so the answer is read from a snapshot of the registry rather than from a
symbol name; the source file is required only because `user_init()` runs after `lex_init`.

---

## 2. `mc build` — the project driver

```
mc build [DIR] [--config FILE] [--entry-only] [--compiler-only] [--limits | --fix-limits] [--sysroot-dir DIR]
```

`DIR` defaults to `.`, the config to `DIR/mc.toml`. Every path inside the file is relative to the
**directory of the config**, so `mc build examples/api` from the repository root does the same
thing as `mc build` from inside `examples/api`. Every key is in [toml.md](toml.md).

| flag | meaning |
|---|---|
| `--config FILE` | use FILE instead of `DIR/mc.toml`. Missing argument: `mc: --config requires an argument`. |
| `--entry-only` | skip the `[compiler]` step and compile `[project].entry` with the running binary. This is the flag `mc build` passes to the taught compiler it just built — you rarely type it. |
| `--compiler-only` | build the taught compiler from `[compiler].modules`, print its path on stdout and stop — no spawn, no entry. This is the flag a `test.sh` wants when it drives the taught compiler over its own suite, and the one an editor server needs. Without a `[compiler].modules` it is an error (`missing key: compiler.modules`), not a silent full build; together with `--entry-only` it is `mc: --entry-only and --compiler-only are exclusive`. |
| `--limits` | after the build, print the table report and return a verdict (see below). |
| `--fix-limits` | the same report, and rewrite **only** the `[limits]` section of `mc.toml` with the smallest tolerance that would have avoided `grew` and `tight`. |
| `--sysroot-dir DIR` | DIR **is** the sysroot for `[target]`, ahead of `[sysroot].cache` and of `~/.mc/sysroots` in the resolution chain — but behind `[sysroot].path`, which still wins. CI passes it so that no job depends on `HOME`. Missing argument: `mc: --sysroot-dir requires an argument`. See [sysroot.md](sysroot.md). |

A second bare argument is `mc: duplicate directory: <arg>`; any other `-flag` reprints the usage
and exits 1.

```
$ mc build examples/api
compiler build/mc-api.mc -> build/mc-api
compile main.mc -> build/api
```

One line per step, always `what from -> to`. The steps are `compiler` (a `[compiler]` section
was present), `compile` and `link` (a `[linker]` section was present).

## 3. `mc limits` — the table report

```
mc limits [DIR | FILE.mc] [--config FILE]
```

With a path ending in `.mc` it runs the whole pipeline over that one file, up to
`gen_encode_all()`, and writes no object. With anything else it is `mc build DIR --limits`.

```
$ mc limits src/mc.mc
limits src/mc.mc
table         estimate   reserved       used  grow  verdict
tokens               0        512         51     0  ok
includes            22         64         22     0  ok
...
heap          24139550   33554432   23489728     0  ok
tolerance 0.25, verdict ok (heap in bytes, every other table in elements)
```

Columns: the static estimate, what was reserved (`estimate * (1 + tolerance)`, floored at a cold
start seed), the high-water usage, how many times the block had to double, and the row verdict.
Row verdicts are `ok`, `tight` (used over 90 % of reserved) and `grew` (the block doubled at
least once); the report's verdict is the worst row.

## 3b. `mc sysroot` — where a cross link finds its files

```
mc sysroot list
mc sysroot path <os>-<arch>
mc sysroot fetch <os>-<arch> [--yes] [--sysroot-dir DIR]
mc sysroot stub [DIR] [--config FILE]
```

| subcommand | what it does |
|---|---|
| `list` | one line per registered target and the source `fetch` would use. Walks the target registry and the pinned table and touches no file, so the output is the same on every host (`tests/golden/sysroot-list.txt`) |
| `path <target>` | run the resolution chain for that target and print the directory on stdout; the `no sysroot` message and exit 2 when nothing answered |
| `fetch <target>` | print the plan (url, size, sha256, destination). With `--yes`, download it, verify the sha256 with `mc`'s own SHA-256, extract it and write `manifest.toml` |
| `stub [DIR]` | read `DIR/mc.toml` (or `--config FILE`), parse `[project].entry`, and write one import stub per library it uses — a `.tbd` on macOS, a `.def` plus the `.lib` `llvm-dlltool` builds from it on Windows. No object and no link; `[linker]` is not required |

| flag | meaning |
|---|---|
| `--yes` | actually download. Without it `fetch` prints the plan, says `nothing was downloaded: re-run with --yes` and exits 0. There is no prompt: `mc` has no `isatty` |
| `--sysroot-dir DIR` | DIR is the destination (`fetch`) or the candidate (`path`), instead of `~/.mc/sysroots/<os>-<arch>` |

`mc sysroot stub` is the same thing `{stubs}` in `[linker].args` does on its own during a build,
without the build. `fetch` is the **only** thing in `mc` that reaches the network, and it does it by spawning
`curl`/`wget`/`curl.exe` — there is no HTTP and no TLS in this language. `mc build` never
downloads. Everything about the chain, the cache and the pinned rows is in
[sysroot.md](sysroot.md).

### Exit codes

| code | meaning |
|---|---|
| `0` | success — and, under `--limits`, verdict `ok` |
| `1` | any diagnostic: a compile error, a TOML error, a spawned tool that failed |
| `2` | the environment is not ready: no sysroot for the target ([sysroot.md](sysroot.md) § 5) |
| `3` | verdict `tight` or `grew` (`--limits` / `mc limits` only) |

`--fix-limits` exits 0 when it managed to write a tolerance that fits, and 3 when even `1.0`
would not have been enough (the file is left alone in that case).

Code **2** is one message and nothing else — the `no sysroot for <os>-<arch>` block of
[sysroot.md](sysroot.md) § 5. It is a separate code so that a script can tell "your machine is
missing files" from "your program does not compile" without reading the text.

---

## 4. What is not a flag

- **`{sdk}` in `[linker].args`** makes the driver run `xcrun --show-sdk-path`, once per build and
  only if some argument mentions the placeholder. That is the only external command `mc` runs on
  its own; the others are the linker and the taught compiler, both named in `mc.toml`.
- **The subcommands are registrations, not `if`s (M41).** `build`, `limits` and `sysroot` come
  from a `subcommand()` table that `<mc/core_build>` fills, and the usage text `mc` prints with no
  arguments is the two fixed lines plus one entry per registered subcommand. A compiler assembled
  without that part prints two lines and accepts no subcommand — which is the honest answer, since
  it has none. Same text, byte for byte, for `mc` itself.
- **The default backend has a second source (M41).** With no `--backend=` and no `--exe`, `mc`
  asks the target registry for the host's pair, as before; a compiler with no target registry at
  all uses whatever `backend_default("name")` recorded, and with neither says
  `no backend: use --backend=NAME`. See `docs/guide/98-recreating-the-compiler.md`.
- **`--exe` is the host's, not Mach-O's (post-M41 review).** It used to be written in `src/cli.mc` as the
  literal name `macho-exe`, so a Linux- or Windows-hosted `mc --exe` wrote a Mach-O binary its own
  kernel refuses with `ENOEXEC` — the same class of bug M37 fixed for the object backend. It reads
  the exe slot of `target(host_os(), host_arch(), …)` now, and refuses when that slot is 0. The
  resolution happens after `user_init()` and after the `--dump-*` modes have returned, so a target
  a module registered counts and `--exe --dump-asm` still dumps.
- **Both slots are resolved in the same place (post-M41 review).** The DEFAULT object backend used
  to be looked up while the flags were being read, which is before `user_init()`: a module that
  re-registered the host pair was honoured by `mc build` (the driver resolves inside `drv_parse`,
  after `user_init()` — M39.5) and silently ignored by `mc x.mc -o x.o`. It now sits beside
  `--exe`'s, after `user_init()` and after the dumps have returned, and a 0 in the object slot —
  a registration, not an omission: it is what a board whose flat image is the whole artefact writes
  — is refused with `<os>/<arch> has no object backend: use --exe` instead of being handed to
  `backend_find()`, which takes a name. The two refusals are the driver's own messages
  (`drv_backend_for`, `src/driver.mc`) with what a TOML file would do replaced by what a command
  line can: `[linker]` becomes "a linker" and `kind = "exe"` becomes `--exe`. Because the
  resolution happens after the `--dump-*` early returns, `mc --dump-ast x.mc` now works on a
  compiler whose host answers for no backend at all — nothing in a dump needs one.
- **There is no `--target=`**: the target is `[target]` in `mc.toml`. Cross-compiling is
  [../guide/50-cross-compile.md](../guide/50-cross-compile.md).
- **There is no `--help`**: any bad invocation prints the usage above.
- **The C seed (`build/mc0`) has fewer flags.** It accepts the five dumps, `-o` and
  `--backend=macho`, and nothing else: `--exe`, `--backend=` with any other name, `mc build` and
  `mc limits` exist only in the self-hosted compiler. See
  [../guide/70-bootstrap.md](../guide/70-bootstrap.md).
