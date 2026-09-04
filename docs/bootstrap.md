# bootstrap.md — M8: cutting the cord (M11: cutting `ld`; M15: cutting the checkout)

This document describes `scripts/bootstrap.sh` (M7, fixed point), the state of M8 (the compiler
stops depending on `clang` for anything beyond the first stage), and the `ld`-free chain that M11
added. Read `docs/plan.md` § Milestones, `docs/specs/M6-M7.md` § M7, and `docs/specs/M11.md`
before this text — this only documents what is already done.

## The chain

```
build/mc0 src/mc.mc -o build/mc1.o   # mc0 = clang compiling stage0/*.c
scripts/link.sh build/mc1 build/mc1.o

build/mc1 src/mc.mc -o build/mc2.o   # mc1 = the .mc compiled by mc0
scripts/link.sh build/mc2 build/mc2.o

build/mc2 src/mc.mc -o build/mc3.o   # mc2 = the .mc compiled by mc1

cmp build/mc2.o build/mc3.o          # the fixed-point criterion
```

`scripts/bootstrap.sh` runs this whole chain, prints the time and size of each `.o`, checks the
SHA-256 of `build/mc2.o` against `tests/golden/mc2.sha256`, and finally runs
`scripts/test.sh build/mc2` and `scripts/check-obj.sh build/mc1 build/mc2`. `make bootstrap`
(depends on `stage0`, i.e. on `build/mc0` existing) calls the script; `make check` runs
`bootstrap` after all the other targets.

## The criterion is `mc2.o == mc3.o`, not `mc1.o` vs `mc2.o`

`mc1.o` is produced by `mc0` (clang) compiling `src/mc.mc`; `mc2.o` is produced by `mc1` (the
`.mc` itself, now running) compiling the same source. These are two different compilers — even
though the result usually matches byte for byte (and it does, in this project: a lucky
coincidence, not a guarantee), **that is not what proves the fixed point**.

What proves it is `mc2.o == mc3.o`: `mc2` and `mc3` are the **same `mc1` binary** compiling the
**same source** — the only difference between generating `mc2.o` and generating `mc3.o` is that
the second time the compiler doing the compiling is itself, one generation further along. If
`mc2.o == mc3.o`, the compiler reproduces itself without drift: running one more generation
(`mc3` compiling again) would change nothing. That is the fixed point — the net effect of having
cut clang out of the chain.

## `clang` is used exactly once

`clang` only compiles **stage0** — the C that produces `build/mc0`. From there on, everything is
`mc0`/`mc1`/`mc2` compiling `.mc`. Confirmation:

```
$ grep -rn clang scripts/ Makefile
Makefile:1:CC      = clang
scripts/link.sh:3:# ld is not gcc/cc/clang: it stays allowed after the cord is cut (M8).
scripts/bootstrap.sh:9:#     ... different — clang vs mc1)
```

`CC = clang` is only referenced by the `build/mc0` and `build/mc0-san` rules (the latter only for
the sanitizers, never part of the bootstrap chain). The other two hits are comments that mention
the word, not invocations. No script under `scripts/` calls `clang`/`cc`/`gcc` directly.

## `ld` is still used

`ld` (Apple's linker) is not a C compiler — it doesn't interpret `.mc` or `.c`, it only links
already-built Mach-O objects. `scripts/link.sh` still calls
`ld -arch arm64 -platform_version macos ... -lSystem` to turn `mc1.o`/`mc2.o` into runnable
executables; this is allowed at M8 and remains allowed afterward. **Since M11 it has stopped
being necessary**: the `macho-exe` backend (`mc --exe`) writes the signed `MH_EXECUTE` directly —
see the next section.

## M11 — the `ld`-free chain

From M11 on, the compiler writes the executable by itself (`--exe`, an alias for
`--backend=macho-exe`, see `docs/surface.md` § Tier 2 and `docs/macho-notes.md` § M11). The whole
chain, from source to a runnable compiler, with no linker at all:

```
build/mc1 --exe src/mc.mc -o build/mc-exe       # the only step that still uses mc1 (which came from ld)
build/mc-exe src/mc.mc -o x.o                   # ... and from here on nothing uses ld anymore
build/mc-exe --exe src/mc.mc -o build/fix/mc-exe
```

Proofs run (real output):

```
$ build/mc1 --exe src/mc.mc -o build/mc-exe && ls -la build/mc-exe
-rwxr-xr-x  1 schivei  staff  210835 build/mc-exe

$ build/mc-exe src/mc.mc -o tmp/x.o && cmp tmp/x.o build/mc2.o && echo identical
identical                       # the ld-free compiler produces the SAME .o as the compiler built via ld

$ build/mc-exe --exe src/mc.mc -o build/fix/mc-exe && cmp build/mc-exe build/fix/mc-exe
                                # no output: fixed point of the executable, byte for byte

$ scripts/test.sh build/mc-exe        # 32/32 (mc-exe compiling .o + ld)
$ scripts/test-exe.sh build/mc-exe    # 32/32 (mc-exe compiling executables, ld nowhere in sight)
$ scripts/check-obj.sh build/mc1 build/mc-exe   # 32/32 identical objects
```

**The signature's identifier is the output file's name.** That's why
`build/mc-exe --exe src/mc.mc -o build/mc-exe2` does **not** produce bytes identical to
`build/mc-exe`: the identifier `mc-exe2` is one character longer than `mc-exe`, which changes the
size of the `CS_CodeDirectory` and, in turn, the `datasize` of `LC_CODE_SIGNATURE`, the
`filesize` of `__LINKEDIT`, the `LC_UUID` (which is a hash of the content), and the page hashes.
That's exactly 5 fields, and `cmp -l` confirms no other byte changes. With the same *basename* in
a different directory (`-o build/fix/mc-exe`) the result is byte-for-byte identical — that's the
correct way to test the executable's fixed point, and it's what the text above does. The
alternative (a fixed identifier) was deliberately dropped: `codesign -dvvv` showing
`Identifier=mc-exe` is the same convention Apple's own `codesign` uses.

`scripts/test-exe.sh` (target `make test-exe`, included in `make check`) runs the whole
`tests/*.mc` suite along this path: compiles with `--exe`, checks `codesign --verify`, and
compares exit code and stdout against each source's header — 32/32.

### The `--exe` trade-off: an undefined symbol only shows up at `dyld` time

The two output paths fail at different moments when an `extern` doesn't exist anywhere. Source
used in the two runs below:

```
// missing.mc
extern i64 does_not_exist(i64 x);

i64 main() {
    return does_not_exist(1);
}
```

The `.o` + `ld` path refuses **at link time** — `ld` resolves against `libSystem` and knows how
to say no:

```
$ build/mc1 missing.mc -o missing.o
$ echo $?
0
$ scripts/link.sh missing missing.o
Undefined symbols for architecture arm64:
  "_does_not_exist", referenced from:
      _main in missing.o
ld: symbol(s) not found for architecture arm64
$ echo $?
1
```

`--exe` **has no way to validate** this: the `macho-exe` backend emits a `__TEXT,__stubs` stub +
a `__DATA,__got` entry with a bind opcode for every imported symbol, and checking whether the
name really exists would require reading the SDK's `.tbd` files (or
`/usr/lib/libSystem.B.dylib` itself) — an external dependency M11 refuses by design, since the
whole point of the milestone is depending on nothing beyond `dyld` at runtime. The binary comes
out well-formed and signed; the one that refuses is `dyld`, at load time:

```
$ build/mc1 --exe missing.mc -o missing-exe
$ echo $?
0
$ ls -l missing-exe
-rwxr-xr-x  1 schivei  wheel  33272 missing-exe
$ codesign --verify --verbose=4 missing-exe
missing-exe: valid on disk
missing-exe: satisfies its Designated Requirement
$ ./missing-exe
dyld[80040]: Symbol not found: _does_not_exist
  Referenced from: <F1456454-2B44-5ECA-A150-2354A925A8A5> .../missing-exe
  Expected in:     <4FED5EE2-5D3E-35B1-A170-9859C4B683BB> /usr/lib/libSystem.B.dylib
$ echo $?
134
```

Exit 134 is `SIGABRT` (128 + 6), which is how `dyld` kills the process. Note that the ad-hoc
signature is correct and `codesign --verify` passes: signing and symbol resolution are
independent things, and `--exe` gets the first one right without having an opinion on the second.

**Decision:** there is no built-in list of known symbols in the compiler. A heuristic table of
`libSystem` names would give false negatives (a symbol that exists but isn't on the list) and
false positives (a symbol on the list that's missing from the OS version in use), and it would
age with every macOS release — trading a late, exact error for an early, wrong one. Anyone who
wants the check at build time has the `.o` + `ld` path, which remains the default (`--exe` is
opt-in) and is what `make test` and `scripts/bootstrap.sh` use.

**`ld` remains the bootstrap path.** `scripts/bootstrap.sh` hasn't changed: M7's fixed-point
criterion is about `.o` files, and `.o` remains the default output format. `--exe` is a second
output, proven by `make test-exe` and the chain above, not a replacement.

## M15 — the bundle inside the fixed point

`src/bundle_data.mc` is **generated source**: `tools/bundle.mc` reads `tools/bundle.list`,
LZ-compresses every file it names (all of `lib/*.mc` plus every module `src/core.mc` includes) and
writes one blob plus one index. `src/core.mc` includes it, so it is part of `src/mc.mc`, so it is
part of the fixed point:

```
mc0  src/mc.mc -> mc1.o     the blob is data in __DATA,__data -- 134870 bytes of it
mc1  src/mc.mc -> mc2.o
mc2  src/mc.mc -> mc3.o     cmp mc2.o mc3.o
```

The blob contains the *sources* of `lib/` and of the core, and `src/bundle_data.mc` itself is
**not** in the manifest — the bundle cannot contain itself. That is what keeps this a fixed point
and not a recursion: regenerating the bundle changes `src/bundle_data.mc`, but
`src/bundle_data.mc` is not one of the files being compressed, so a second `make bundle` produces
the same bytes.

### Regenerate before you bootstrap

**Whenever `lib/*.mc` or any module of the core changes, run `make bundle` and commit
`src/bundle_data.mc` with the change.** Otherwise the binary carries a `<mc/core>` that is not the
`src/` it was built from — the fixed point would still close (`mc2.o == mc3.o`), but it would be
proving something about a compiler whose bundled copy of itself is stale.

`make check` enforces it, and the order in the Makefile is deliberate:

```
check: budget test check-lex check-ast check-bundle check-asm check-obj bootstrap ...
                                       ^^^^^^^^^^^^                    ^^^^^^^^^
```

`check-bundle` runs **before** `bootstrap`. It regenerates the bundle twice into temporary files
and `cmp`s them against each other (reproducibility) and against the checked-in file
(freshness). A stale bundle fails there with a message that says `make bundle`, instead of failing
later as a mysterious difference.

```
$ scripts/check-bundle.sh build/mc1
ok tools/bundle.mc is reproducible (two runs identical)
ok src/bundle_data.mc matches tools/bundle.list (323997 bytes)
```

### The strongest statement: the bundled core *is* the core

`scripts/check-standalone.sh` copies `build/mc-exe` alone into an empty temporary directory and,
among other things, compiles

```c
#include <mc/core>
#include <user_default>
```

to an object and `cmp`s it against `build/mc2.o`. Those two are the same program said two ways —
`src/mc.mc` is `core.mc` + `user.mc` → `user_default.mc` — so equality means the bundle's copy of
every core module, **including the `mc/bundle_data` that `src/bundle.mc` regenerates on the fly
from the blob**, is byte for byte the `src/` tree the compiler was built from.

```
ok <sys> + <prelude>: hello runs, exit 42
ok <mc/core> + <user_syntax_demo>: taught compiler built and signed
ok the taught compiler compiles <syntax_demo_test> (exit 42)
ok the copied compiler rejects the same source (syntax_demo_test:10: type expected at top level)
ok <mc/core> + <user_default> == src/mc.mc, byte for byte
ok unknown name: bad.mc:1: unknown bundled include: no/such/module
standalone: the binary alone is the toolchain
```

## Binaries are not versioned

`.gitignore` already ignores `build/` (and `*.o`, `*.dSYM`) — `mc0`, `mc1`, `mc2`, `mc3`, and
every intermediate `.o` are build artifacts, never committed. The only fixed-point artifact that
is versioned is the hash: `tests/golden/mc2.sha256` (see `tests/golden/README.md`).

## Divergence diagnosis

If `cmp build/mc2.o build/mc3.o` fails (or the SHA-256 diverges from the golden without an
intentional change to `src/*.mc`), the first step is to compare the codegen's deterministic text
output instead of the object's raw bytes:

```
diff <(build/mc1 --dump-asm src/mc.mc) <(build/mc2 --dump-asm src/mc.mc)
```

That locates the first instruction/label where the two compilers disagree. From there, bisect by
file and then by function:

1. Run the same `diff --dump-asm` isolating one `#include` at a time (`arena.mc`, then
   `macho.mc`, `lex.mc`, `ast.mc`, `parse.mc`, `gen_arm64.mc`, `main.mc`) until you find which
   file diverges — compiling each one alone reproduces the identical error on both sides when the
   file itself is identical (which is what `scripts/check-asm.sh` already checks for every
   `src/*.mc`), so the file that breaks when included in `mc.mc` but not alone points at the real
   interaction.
2. Inside the file, comment out/isolate functions (or run `--dump-asm` on a reduced file with
   just the suspect function and its direct dependencies) until the exact function is isolated.
3. Usual causes of divergence in a self-hosted fixed point (not seen here, but the suspect list
   from `docs/specs/M6-M7.md` § Determinism): unstable table/symbol ordering, unzeroed padding, a
   short file read, some uninitialized-state dependency in the arena.

## The Linux chain (M37)

`stage0/*.c` emits Mach-O and only Mach-O. Porting it would mean writing a second seed and having
two oracles, so a Linux host does not start from `clang` at all — it starts from a `mc` binary
that already exists. Everything after that first binary is the same argument as the macOS chain:
the compiler compiles itself until one generation is byte-identical to the next.

```
SEED src/mc_linux.mc          -> build/mc1l.o   (+ link -> build/mc1l)
build/mc1l  src/mc_linux.mc   -> build/mc2l.o   (+ link -> build/mc2l)
build/mc2l  src/mc_linux.mc   -> build/mc3l.o
cmp build/mc2l.o build/mc3l.o                   <- the criterion
SHA-256 of build/mc2l.o vs tests/golden/mc2-linux-<target>.sha256
```

`scripts/bootstrap-linux.sh [SEED]` runs it (on x86-64 the entry is `src/mc_linux_x86_64.mc` and
the golden `tests/golden/mc2-linux-x86_64.sha256`). Linking is `scripts/link-linux.sh` — `ld.lld`
against the musl sysroot, `MC_SYSROOT` to point it at one the system already has. Three things it
does that the macOS script does not have to:

1. **Find a seed.** An argument, else `build/mc-linux-<target>` (cross-built on macOS, § below),
   else a release asset — `gh release download` when the GitHub CLI is present, otherwise `curl`
   of `mc-<VER>-linux-<arch>.tar.gz` plus its `.sha256`. **The tarball is unpacked only after the
   checksum matches.**
2. **Check the seed is for this host.** `mc --host` prints `os`, `arch` and `sys`; a binary that
   answers anything but `linux/<this machine>` is refused before the chain starts. A macOS `mc`
   cross-compiling Linux objects is not a seed — it cannot run here.
3. **Compare what the two self-hosted stages say.** The seed may legitimately be an older
   compiler, so `mc1l.o` is allowed to differ from `mc2l.o`; what must not differ is
   `mc1l --dump-asm` against `mc2l --dump-asm`.

It ends by running the whole `tests/*.mc` suite with the compiler it just produced
(`scripts/test-linux.sh`, native mode — no Docker, no emulation).

### Cross-building the seed on macOS

```sh
make mc-linux            # build/mc-linux-arm64,  from src/mc.linux-aarch64.toml
make mc-linux-x86_64     # build/mc-linux-x86_64, from src/mc.linux-x86_64.toml
```

`make check-linux-host` then proves both, from macOS, inside `docker run --platform linux/<arch>
alpine:3`: `make check SEED=<binary>` (which starts with the chain above) and the **cross proof** —
the Linux-hosted compiler compiles `src/mc.mc` and the Mach-O object it writes is `cmp`-equal to
`build/mc2.o`, the object macOS wrote for itself. Same compiler, different host.

### Two goldens, two vocabularies

`tests/golden/mc2.sha256` is the macOS chain; `tests/golden/mc2-linux-arm64.sha256` and
`tests/golden/mc2-linux-x86_64.sha256` are the Linux ones. The file names use the *release target*
vocabulary (`arm64`, matching `mc-<VER>-linux-arm64.tar.gz` and `build/mc-linux-arm64`), while
`[target].arch`, `mc --host` and the sysroot directories use the *architecture* vocabulary
(`aarch64`). Both spellings mean the same machine.

See [guide/90-linux-host.md](guide/90-linux-host.md) for the host layer itself and for what
`make check` does and does not cover on Linux.

---

## The Windows chain (M38)

Same argument as the Linux chain, one system further out: `stage0/*.c` emits Mach-O, so a Windows
host starts from an `mc` binary that already exists and compiles itself until one generation is
byte-identical to the next.

```
SEED src/mc_windows.mc          -> build/mc1w.obj  (+ link -> build/mc1w.exe)
build/mc1w.exe src/mc_windows.mc -> build/mc2w.obj (+ link -> build/mc2w.exe)
build/mc2w.exe src/mc_windows.mc -> build/mc3w.obj
cmp build/mc2w.obj build/mc3w.obj                  <- the criterion
SHA-256 of build/mc2w.obj vs tests/golden/mc2-windows-<target>.sha256
```

`scripts/bootstrap-windows.sh [SEED]` runs it (on x64 the entry is `src/mc_windows_x86_64.mc` and
the golden `tests/golden/mc2-windows-x86_64.sha256`). Linking is `scripts/link-windows.sh` —
`lld-link` against the kernel32 import library plus the two objects a system with no C runtime
needs, `winstart.obj` and `mcrt.obj`; `MC_SYSROOT` points at the directory that holds all three.
It does the same three things `bootstrap-linux.sh` does — find a seed (an argument, else
`build/mc-windows-<target>.exe`, else `build/mc-windows-<target>.obj` which it links itself, else a
checksum-verified release asset), check with `mc --host` that the seed is for **this** host, and
compare what the two self-hosted stages say with `--dump-asm` — and then two more:

* it runs the whole suite with the compiler it just produced, through
  `scripts/test-windows.sh --run-only` (the objects arrive in the CI artifact; with none there, the
  bootstrapped compiler cross-compiles them itself first);
* it runs the **cross proof**: `build/mc2w.exe --backend=macho src/mc.mc` is `cmp`-equal to
  `build/mc2.o`, the object macOS wrote for itself. Same compiler, different host. Without that
  reference the step says it was skipped and why.

Every file name carries `.exe` explicitly: under MSYS `[ -x build/mc2w ]` is not reliable. And
nothing here rewrites the binary that is running — a running `.exe` cannot be deleted on Windows,
which is why `mc1w.exe` writes `mc2w.obj` and `lld-link` writes `mc2w.exe` afterwards.

### Cross-building the seed on macOS

```sh
make mc-windows            # build/mc-windows-arm64.exe,  from src/mc.windows-aarch64.toml
make mc-windows-x86_64     # build/mc-windows-x86_64.exe, from src/mc.windows-x86_64.toml
```

Both are one command on a macOS machine with LLVM installed, and neither needs Docker: the sysroot
is one `kernel32.lib` generated by `llvm-dlltool` from a list of names, plus two objects `mc`
compiles itself. There is no `make check-windows-host` equivalent of `make check-linux-host` — a
Windows binary cannot be run in a container on macOS, so the two CI jobs (`mc on windows/arm64
host`, `mc on windows/x86_64 host`) are the only place the chain actually runs.

### Five goldens, two vocabularies

`tests/golden/mc2.sha256` is the macOS chain; `mc2-linux-arm64` and `mc2-linux-x86_64` are the
Linux ones; `mc2-windows-arm64` and `mc2-windows-x86_64` are the Windows ones. The file names use
the *release target* vocabulary (`arm64`, matching `mc-<VER>-windows-arm64.tar.gz`), while
`[target].arch`, `mc --host` and the sysroot directories use the *architecture* vocabulary
(`aarch64`).

The two Windows goldens are computed **on macOS**, because that is where the tree is developed:
they are the SHA-256 of the object a cross-compile writes, which is by construction the object the
Windows-hosted compiler has to write for the same source. See
[../tests/golden/README.md](../tests/golden/README.md).

See [guide/95-windows-host.md](guide/95-windows-host.md) for the host layer itself, the runtime
object, and what `make check` does and does not cover on Windows.
