# How `mc` compiles itself

`mc` is written in `mc`. That sentence is only interesting if it can be checked, so this page
describes the chain that checks it, and the rules a contributor has to follow to keep it
checkable.

## The chain

```
build/mc0 src/mc.mc -o build/mc1.o     # mc0 = clang compiling stage0/*.c
scripts/link.sh build/mc1 build/mc1.o

build/mc1 src/mc.mc -o build/mc2.o     # mc1 = the .mc compiler, compiled by mc0
scripts/link.sh build/mc2 build/mc2.o

build/mc2 src/mc.mc -o build/mc3.o     # mc2 = the .mc compiler, compiled by mc1

cmp build/mc2.o build/mc3.o            # the fixed-point criterion
```

`make bootstrap` runs the whole thing, prints a time and a size per stage, checks the SHA-256 of
`mc2.o` against a checked-in golden, then re-runs the test suite with `mc2` and compares every
object `mc1` and `mc2` produce.

```
$ make bootstrap
=== M7 -- fixed point: mc0 -> mc1 -> mc2 -> mc3 ===
-- stage 1: build/mc0 src/mc.mc -> build/mc1.o --
  mc0 compiles mc.mc: 0.051s
  size build/mc1.o: 523120 bytes
-- stage 2: build/mc1 src/mc.mc -> build/mc2.o --
  mc1 compiles mc.mc: 0.282s
  size build/mc2.o: 523120 bytes
-- stage 3: build/mc2 src/mc.mc -> build/mc3.o --
  mc2 compiles mc.mc: 0.500s
  size build/mc3.o: 523120 bytes
-- fixed-point criterion: cmp build/mc2.o build/mc3.o --
  ok: build/mc2.o == build/mc3.o
-- golden SHA-256 of build/mc2.o --
  ok: 94db4b12b772d418ae44399b4ecd984d790c92c2bfb12798a568a70112f11918 matches tests/golden/mc2.sha256
=== total bootstrap time: 1.011s ===
```

## Why the criterion is `mc2.o == mc3.o`

`mc1.o` comes from `mc0` (clang's build of the C seed) compiling `src/mc.mc`. `mc2.o` comes from
`mc1` — the `.mc` compiler itself, now running — compiling the same source. Those are **two
different compilers**. They happen to agree byte for byte in this repository, which is pleasant
but proves nothing.

What proves the fixed point is `mc2.o == mc3.o`: `mc2` and `mc3` are produced by the *same*
compiler compiling the *same* source, one generation apart. If they are identical, the compiler
reproduces itself without drift — running one more generation would change nothing. That is the
whole point of having cut `clang` out of the chain.

## `clang` runs exactly once

```
$ grep -rn clang scripts/ Makefile
Makefile:1:CC      = clang
scripts/link.sh:3:# ld is not gcc/cc/clang: it stays allowed after the cord is cut (M8).
scripts/bootstrap.sh:9:#     ... different — clang vs mc1)
```

`CC = clang` is referenced only by the `build/mc0` rule (and by `build/mc0-san`, the sanitizer
build, which is never part of the bootstrap chain). The other two hits are comments. No script
invokes `clang`, `cc` or `gcc`.

The seed is capped at **3000 lines** of C23, checked in CI:

```
$ make budget
stage0: 2846 / 3000 lines
```

It uses five libc functions — `open`, `read`, `write`, `close`, `_exit` — and nothing else: no
stdio, no malloc, no qsort.

## Cutting `ld` too

`ld` is not a C compiler, so it stayed allowed. Since `--exe` exists it is also unnecessary:

```
$ mc --exe src/mc.mc -o build/mc-exe          # the last step that came through ld
$ build/mc-exe src/mc.mc -o tmp/x.o
$ cmp tmp/x.o build/mc2.o && echo identical
identical
$ build/mc-exe --exe src/mc.mc -o build/fix/mc-exe
$ cmp build/mc-exe build/fix/mc-exe            # no output: the executable's own fixed point
```

**The signature's identifier is the output file's basename.** So the executable's fixed point
only holds for the same basename — `-o build/mc-exe2` changes the identifier's length, which
changes the `CS_CodeDirectory` size, the `LC_CODE_SIGNATURE` datasize, `__LINKEDIT`'s filesize,
the `LC_UUID` (a hash of the content) and the page hashes. Exactly five fields, and `cmp -l`
confirms nothing else moves. Using the basename is the same convention Apple's `codesign`
follows.

## Cutting the checkout

The standard library and the compiler's own source travel **inside** the binary, compressed
([../reference/bundle.md](../reference/bundle.md)). `scripts/check-standalone.sh` copies `mc`
alone into an empty directory and proves the strongest statement available: a compiler built from

```c
#include <mc/core>
#include <user_default>
```

compiles `src/mc.mc` into an object **byte for byte identical** to `build/mc2.o`. The bundled
core is not a copy of the core; it is the core.

## The rules that keep it reproducible

These are the eight rules of `docs/determinism.md`, which every contribution has to respect.

1. **Never hash a pointer, and never iterate a hash table to produce output.** Where a lookup
   needs to be fast, keep a parallel array in insertion order and walk that.
2. **The symbol table is a stable partition, never a sort.** Locals, then defined externals, then
   undefined — which is what `LC_DYSYMTAB` requires, and what ELF's `sh_info` requires too. A
   `qsort` would make the output depend on something other than creation order.
3. **The C seed's I/O has the same shape as the `.mc` version** — `open`, `read` in a loop,
   `close` — so that a short read cannot behave differently on the two sides.
4. **No `__FILE__`, no date, no absolute path, no `N_OSO`, no `ar`.** `LC_BUILD_VERSION` is
   hardcoded. Nothing about the machine that ran the compiler may reach the output.
5. **Zero every padding and alignment byte explicitly.** Never write a struct; write every field
   byte by byte in little-endian.
6. **The reference build is fixed**: `-O1` for the seed, with a separate sanitizer build
   (`-O0 -fwrapv -fno-strict-aliasing -fsanitize=undefined,address`) in CI.
7. **The five dumps produce deterministic text**, and have since the first milestone. They are
   the diagnostic tool for everything below.
8. **Compare objects, not linked executables**, and keep a versioned golden SHA-256 of `mc2.o`.

And one more, added when the tables became growable:

9. **Capacity never reaches the output.** A block that doubled holds exactly the same elements in
   exactly the same order as one that did not. Nothing reads a capacity: `nnodes`, `nsymbols`,
   `nstrs` are the counters codegen and the writers consult, and `nodecap` and friends exist only
   for `grow()`. The violation to watch for is a loop bounded by the capacity instead of the
   count — that would put reserved-but-unused slots into the output and make the bytes depend on
   `[limits].tolerance`.

## When the fixed point breaks

You changed something in `src/` and `cmp build/mc2.o build/mc3.o` now differs. The procedure:

1. Confirm the divergence with `cmp`.
2. Run the dump diff — the dumps are deterministic text, so the first differing line already
   names the instruction or symbol at fault:

   ```sh
   diff <(build/mc1 --dump-asm src/mc.mc) <(build/mc2 --dump-asm src/mc.mc)
   ```

3. Bisect by function: compile a subset of `src/mc.mc` and repeat the diff until one function
   remains.
4. Check that function against the rules above. The usual causes, in order of frequency: table
   ordering (rules 1 and 2), unzeroed padding (rule 5), a short file read (rule 3).
5. Fix, rebuild the three stages, and repeat until `cmp` is silent.

## Changing the golden

`tests/golden/mc2.sha256` is the checked-in hash of `build/mc2.o`. Rewrite it **only** when both
of these are true, and say so in the commit message:

```sh
diff <(build/mc1 --dump-asm src/mc.mc) <(build/mc2 --dump-asm src/mc.mc)   # must be empty
cmp build/mc2.o build/mc3.o                                                # must be silent
```

An empty dump diff means the two generations agree on every instruction; a silent `cmp` means the
fixed point holds. A golden rewritten without both is a change nobody reviewed.

## Regenerate the bundle before you bootstrap

`src/bundle_data.mc` is generated source, checked in. If you touched a `lib/*.mc` or a core
module:

```sh
make bundle          # regenerate it from tools/bundle.list
```

`make check` runs `check-bundle` **first**, on purpose: a stale bundle then fails with a message
naming `make bundle`, instead of failing three targets later as a mysterious fixed-point
difference.

## What `make check` proves, target by target

| target | what it establishes |
|---|---|
| `budget` | the C seed is still under 3000 lines |
| `test` | the suite passes with the seed |
| `check-lex`, `check-ast`, `check-asm` | the two compilers agree, token for token, node for node and instruction for instruction, over `tests/`, `lib/` and `src/` |
| `check-bundle` | the checked-in bundle is reproducible and up to date |
| `check-obj` | the two compilers produce identical objects |
| `bootstrap` | the fixed point, plus the golden |
| `check-surface` | a backend written from outside produces identical bytes, every Tier 3 hook works, and the mechanism is inert when nothing is registered |
| `test-exe` | the whole suite through `--exe`, with `codesign --verify` on each binary |
| `check-mc` | `#embed` and `#include <name>`, which exist only in the self-hosted compiler — and which the seed must refuse |
| `check-standalone` | `mc` alone in an empty directory is the whole toolchain |
| `check-toml`, `check-build` | the TOML subset and `mc build` end to end |
| `check-limits` | the seed's fixed tables still have headroom |
| `test-linux` | the suite cross-compiled, linked with `ld.lld` and run in Docker |
| `check-examples`, `check-lang` | the two worked examples |
| `check-docs` | every public symbol is documented and every sample in `docs/` compiles |
| `site`, `check-site` | `mcsite` renders `docs/` into `site/public`, and every internal link, HTML structure and contrast pair holds |

The two cross-checks in the middle are the ones worth internalising: `check-asm` and `check-obj`
compare a compiler written in C against a compiler written in `mc`, over the same corpus. As long
as they agree, the transliteration is honest — and every new feature that lands only in `src/`
has to explain why the two are allowed to differ.
