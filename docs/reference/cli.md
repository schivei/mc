# Every command, flag and dump

`mc` has one binary and three entry points: the single-file compiler, `mc build` and `mc limits`.
Everything below is read off `src/main.mc` (the single-file CLI) and `src/driver.mc` (the two
subcommands). Running `mc` with no argument prints exactly this and exits 1:

```
usage: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] [--backend=NAME|--exe] [--machine=NAME] [--include=DIR] source.mc [-o out]
       mc --host
usage: mc build [DIR] [--config FILE] [--compiler-only] [--limits|--fix-limits]
       mc limits [DIR|FILE.mc]
```

---

## 1. The single-file compiler

```
mc [MODE] [--backend=NAME | --exe] SOURCE [-o OUT]
```

Arguments are read left to right. The first non-flag argument is the source; a second one is
`mc: duplicate entry: <arg>`. An unknown flag starting with `-` that is not `--backend=…` is
`mc: unknown option: <arg>`.

| flag | meaning |
|---|---|
| `-o OUT` | output path. Default `out.o`. `-o` with nothing after it is `mc: -o requires an argument`. |
| `--exe` | alias for `--backend=macho-exe`: write a signed Mach-O executable directly, no `ld`. |
| `--backend=NAME` | pick a registered backend. Built in: `macho`, `macho-exe`, `elf-obj`, `elf-obj-x86_64`, `coff-obj-arm64`, `coff-obj-x86_64`. The default is the HOST's object backend — `macho` on macOS, `elf-obj`/`elf-obj-x86_64` on Linux (M37). A taught compiler adds its own with `backend("name", &f)`. An unknown name lists what exists and exits 1. |
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
registered: macho macho-exe elf-obj
```

### Modes: the five dumps

A dump writes deterministic text to **stdout** and produces no object. Only one mode is in
effect — the last one on the command line wins. All five exist in the C seed too, which is what
`make check-lex`, `check-ast` and `check-asm` compare across the two compilers.

| flag | prints | stops after |
|---|---|---|
| `--dump-tokens` | `line id lexeme`, one token per line | the lexer |
| `--dump-ast` | the tree, two spaces per level, **after** `#rule` expansion and after every registered `pass()` | the parse |
| `--dump-rules` | the `#rule` table, then every infix and prefix operator with precedence and associativity | the parse |
| `--dump-asm` | one function per label, one instruction per line, `gen_lower` only (nothing is encoded) | lowering |
| `--dump-syms` | one line per section, then one line per symbol | encoding |

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

---

## 2. `mc build` — the project driver

```
mc build [DIR] [--config FILE] [--entry-only] [--compiler-only] [--limits | --fix-limits]
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

### Exit codes

| code | meaning |
|---|---|
| `0` | success — and, under `--limits`, verdict `ok` |
| `1` | any diagnostic: a compile error, a TOML error, a spawned tool that failed |
| `3` | verdict `tight` or `grew` (`--limits` / `mc limits` only) |

`--fix-limits` exits 0 when it managed to write a tolerance that fits, and 3 when even `1.0`
would not have been enough (the file is left alone in that case).

---

## 4. What is not a flag

- **`{sdk}` in `[linker].args`** makes the driver run `xcrun --show-sdk-path`, once per build and
  only if some argument mentions the placeholder. That is the only external command `mc` runs on
  its own; the others are the linker and the taught compiler, both named in `mc.toml`.
- **There is no `--target=`**: the target is `[target]` in `mc.toml`. Cross-compiling is
  [../guide/50-cross-compile.md](../guide/50-cross-compile.md).
- **There is no `--help`**: any bad invocation prints the usage above.
- **The C seed (`build/mc0`) has fewer flags.** It accepts the five dumps, `-o` and
  `--backend=macho`, and nothing else: `--exe`, `--backend=` with any other name, `mc build` and
  `mc limits` exist only in the self-hosted compiler. See
  [../guide/70-bootstrap.md](../guide/70-bootstrap.md).
