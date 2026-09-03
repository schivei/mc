# 50 — Cross-compiling

`mc` runs on macOS arm64 and produces binaries for macOS arm64 and **Linux arm64**. The Linux
path is a backend (`elf-obj`), a system layer (`<sys_linux>`) and four lines of `mc.toml`;
nothing in the compiler's C seed knows about any of it.

| target | status |
|---|---|
| macOS arm64 | the host, and the default |
| Linux arm64 (ELF64) | **works**: `[target] os = "linux"` |
| Linux x86-64 | planned — needs the machine-interface split ([../reference/machine.md](../reference/machine.md)) |
| Windows arm64 / x64 (COFF) | planned |
| `mc` *hosted* on Linux or Windows | not yet: the project driver uses `posix_spawnp` and `_NSGetEnviron` |

## Linux arm64

Two things change and nothing else: the object comes out as an ELF64 `ET_REL` instead of a
Mach-O, and `[linker]` becomes **required** — there is no direct-executable backend for Linux.

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
$ mc build . --config linux.toml
compile hello.mc -> build/hello.o
link build/hello.o -> build/hello
$ docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3 /w/build/hello
hello
```

Asking for a Linux executable without a linker says so, at the position of the offending value:

```
$ mc build tests/proj --config /tmp/d.toml
/tmp/d.toml:6:6: linux requires [linker]: there is no direct executable: target.os
```

The object backend is also reachable from the single-file CLI, which is useful when you only want
to look at what came out:

```mc backend=elf-obj
#include <sys_linux>

i64 main() {
    write(1, "hello\n", 6);
    return 0;
}
```

```
$ mc --backend=elf-obj hello.mc -o hello.o
$ llvm-readobj --file-headers hello.o | head -5
```

## The sysroot

A Linux link needs musl's `crt1.o`, `crti.o`, `crtn.o` and `libc.a`. `scripts/sysroot-linux.sh`
fills `build/sysroot/linux-aarch64` by running `apk add musl-dev` inside a throwaway
`linux/arm64` Alpine container and copying the four files out.

```sh
make sysroot-linux        # populate the cache
```

It is a cache: with the four files already present it does nothing, so repeated runs pull no
image. `scripts/test-linux.sh` calls it by itself whenever a file is missing, so a half-populated
sysroot is repaired instead of failing every test.

`{sysroot}` in `[linker].args` expands to `[sysroot].path`, resolved against the config's
directory like every other path. A missing `sysroot.path` is only an error when some argument
actually uses the placeholder.

> **Planned (M25):** `mc sysroot fetch` / `mc sysroot list`, with checksums and an offline
> fallback, plus synthesized text stubs for Apple SDKs so a macOS link needs no SDK at all. Not
> in this checkout: today the sysroot is a directory you point at.

## No libc at all

`<sys_linux>` is `<sys_svc>`'s Linux sibling: `open`/`creat`/`read`/`write`/`close`/`fchmod`/
`exit` as raw `svc #0` with the call number in `x8` (openat 56, close 57, read 63, write 64,
fchmod 52, exit_group 94; `AT_FDCWD` is `-100`, written as `movn x0, #99`). It also supplies
`_start`, which reads `argc`/`argv` off the entry stack, calls `main` and exits — so the link
needs no crt objects and no libc:

```toml
[linker]
cmd  = "ld.lld"
args = ["-nostdlib", "-e", "_start", "-o", "{out}", "{obj}"]
```

`tests/linux/070-nolibc.mc` is exactly that case.

The `O_RDONLY`/`O_WRONLY`/`O_CREAT`/`O_TRUNC` constants live in each system layer rather than in
`<io>`, because they are per-system values: `O_CREAT` is `0x200` on macOS and `0x40` on Linux.

## What the ELF writer does

`gen_lower` and `gen_encode_all` are format-neutral: the same sections, symbols and relocations
that feed the Mach-O writer feed the ELF one. The translation:

| mc | ELF |
|---|---|
| `__TEXT,__text` | `.text`, `SHT_PROGBITS`, `AX`, align 4 |
| `__TEXT,__cstring` | `.rodata`, `SHT_PROGBITS`, `A`, align 1 |
| `__DATA,__data` | `.data`, `SHT_PROGBITS`, `WA`, align 16 |
| `__DATA,__bss` | `.bss`, `SHT_NOBITS`, `WA`, align 16 |
| `#section SEG SECT` | `.seg.sect` — leading underscores dropped, lowercased (`__TEXT,__hot` → `.text.hot`) |
| symbol `_main` | `main` — the leading `_` the compiler adds is dropped |
| symbol `l_str0` | `.Lstr0` — string labels become assembler temporaries |
| `BRANCH26` | `R_AARCH64_CALL26` (283) |
| `PAGE21` | `R_AARCH64_ADR_PREL_PG_HI21` (275) |
| `PAGEOFF12` on an `add` | `R_AARCH64_ADD_ABS_LO12_NC` (277) |
| `PAGEOFF12` on an ldr/str | `R_AARCH64_LDST{8,16,32,64}_ABS_LO12_NC` (278/284/285/286), by access width |
| `UNSIGNED` | `R_AARCH64_ABS64` (257) |

Symbols come out in the same stable partition Mach-O needs — locals, defined globals, undefined —
because that is also what ELF requires for `sh_info`. Relocations are sorted by ascending offset,
the ELF convention, and every `r_addend` is 0: the encoder leaves the relocated immediate zeroed,
so there is no implicit addend to carry.

Every field was verified against `clang --target=aarch64-linux-musl -c` of equivalent C, with
`llvm-readobj --all` and `llvm-objdump -dr`. The one difference that is not the writer's: `mc`
always materialises a global's address with `adrp` + `add`, so it asks for `ADD_ABS_LO12_NC`
where clang folds the offset into the load and asks for `LDST64_ABS_LO12_NC`.

## Running the suite on Linux

`scripts/test-linux.sh` cross-compiles every test, links each one with `ld.lld`, and runs it
inside `docker run --rm --platform linux/arm64 -v <repo>:/w -w /w alpine:3`, comparing exit code
and stdout against the same `// expect-exit:` and `// expect-stdout:` headers the macOS suites
use. The repository root is the mount and the working directory, because a test may open its own
source by a relative path.

```
32/32 tests passed on linux/arm64
skipped (macOS only):
  032-svc — lib/sys_svc.mc has the Darwin syscall numbers in x16 and svc #0x80; the Linux equivalent is lib/sys_linux.mc
```

Exactly one test carries a `// skip-linux:` header. Everything else is portable as written,
including the custom `#section`s, the hand-written `#opcode` encodings, and the
`reloc(BRANCH26, "_helper")` whose symbol name loses its `_` on the way into ELF exactly like
the definition's.

`make test-linux` is inside `make check` but guarded: without `ld.lld` in `PATH`, or with Docker
not running, it prints `test-linux: SKIPPED (...)` and the build stays green.

## Portability checklist for your own code

- **Pick the system layer per target.** `<sys>` (libSystem) and `<sys_svc>` (Darwin syscalls) are
  macOS; `<sys_linux>` is Linux. `<io>`'s `strlen`/`puts`/`putnum` are written in the language and
  work on both.
- **`#opcode` is architecture-specific by nature.** A source full of hand-encoded AArch64 words is
  portable to Linux arm64 and to nothing else.
- **`#dylib` is a Mach-O mechanism.** On Linux, name libraries in `[linker].args` instead.
- **Syscall numbers differ**, which is the entire reason `<sys_svc>` and `<sys_linux>` are two
  files rather than one with an `#ifdef` — there is no `#ifdef`, and there is not going to be one.

## Next

Two complete programs that use everything so far: [60-examples.md](60-examples.md).
