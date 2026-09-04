# Cross-compiling

`mc` runs on macOS arm64 and produces binaries for macOS arm64, **Linux arm64**, **Linux x86-64**,
**Windows on ARM** and **Windows x64**. Each path is a backend, a system layer and four lines of `mc.toml`;
x86-64 adds one more file, a *machine* — the instruction selection behind a target-independent
walker ([../reference/machine.md](../reference/machine.md)). Nothing in the compiler's C seed
knows about any of it.

| target | status |
|---|---|
| macOS arm64 | the host, and the default |
| Linux arm64 (ELF64) | **works**: `[target] os = "linux"` |
| Linux x86-64 (ELF64) | **works**: `[target] os = "linux"`, `arch = "x86_64"` |
| Windows arm64 (COFF) | **works**: `[target] os = "windows"` |
| Windows x64 (COFF) | **works**: `[target] os = "windows"`, `arch = "x86_64"` |
| WebAssembly | planned |
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

## Linux x86-64

One line changes:

```toml
[target]
os   = "linux"
arch = "x86_64"        # instead of aarch64
```

That swaps the object backend for `elf-obj-x86_64` and, behind it, the **machine**: the part of
the code generator that chooses instructions. Everything above the machine — the parser, the
resolver, the walk that turns the AST into frames, depths, labels and calls — is the same code
that produces AArch64. What changes is a register partition (depths in `r8..r11`, four instead of
seven, because x86-64 has fewer caller-saved registers to spare), an ABI (`rdi rsi rdx rcx r8 r9`,
then the stack), and thirty-odd encoders. See [../reference/machine.md](../reference/machine.md).

```
$ mc build . --config linux-x64.toml
compile hello.mc -> build/hello.o
link build/hello.o -> build/hello
$ docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w alpine:3 /w/build/hello
hello
```

The sysroot is a separate directory (`build/sysroot/linux-x86_64`), because the crt objects and
`libc.a` are x86-64 code:

```sh
make sysroot-linux-x86_64
```

What does **not** port is anything that writes instructions by hand — `#opcode`, `emit()` and
`reloc()`. Three of the suite's tests do, and they say so in a header:

```
29/29 tests passed on linux/x86_64
skipped (not portable to this target):
  031-opcode — the #opcode templates are AArch64 words (movz/add); the x86-64 machine emits its own instruction set
  032-svc — lib/sys_svc.mc has the Darwin syscall numbers in x16 and svc #0x80; the Linux equivalent is lib/sys_linux.mc
  033-reloc — the raw word is an AArch64 `bl` and BRANCH26 is a Mach-O/AArch64 relocation; x86-64 calls are R_X86_64_PLT32
  070-nolibc — lib/sys_linux.mc encodes the syscalls and _start as AArch64 `svc #0` words; the x86-64 equivalent would be `syscall`
```

`<sys_linux>` is in that list: its syscalls are AArch64 `svc #0` words, so an x86-64 Linux program
links against musl (`<sys>`) rather than going libc-free. To look at what the x86-64 machine
selects without producing a file:

```
$ mc --dump-asm --machine=x86_64 hello.mc | head
_main:
  push rbp
  mov rbp, rsp
  ...
```

## The sysroot

A Linux link needs musl's `crt1.o`, `crti.o`, `crtn.o` and `libc.a`.
`scripts/sysroot-linux.sh [--arch aarch64|x86_64]` fills `build/sysroot/linux-<arch>` by running
`apk add musl-dev` inside a throwaway Alpine container of the matching platform and copying the
four files out. On an Apple Silicon host the `linux/amd64` container is emulated, which is slower
but only happens once.

```sh
make sysroot-linux            # populate the aarch64 cache
make sysroot-linux-x86_64     # and the x86-64 one
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

## Windows

Same two changes as Linux, in another format: the object is a COFF `.obj` and `[linker]` is
required. On `arch = "aarch64"` the machine does not change either — Windows on ARM is AArch64, and
it is the *file* that is new.

```toml
[project]
entry = "hello.mc"
out   = "build/hello.exe"

[target]
os   = "windows"
arch = "aarch64"

[sysroot]
path = "build/sysroot/windows-aarch64"

[linker]
cmd  = "lld-link"
args = ["/machine:arm64", "/subsystem:console", "/entry:mc_start", "/nodefaultlib",
        "/out:{out}", "{obj}", "build/winstart.obj", "{sysroot}/kernel32.lib"]
```

### x64: the same file, another calling convention

`arch = "x86_64"` writes the same COFF with `IMAGE_FILE_MACHINE_AMD64` and the AMD64 relocation
numbers, over `x86_64-win` — the **Win64** half of the x86-64 machine. It is the same instruction
selection `linux/x86_64` uses, with one task replaced: arguments in `rcx rdx r8 r9`, the fifth and
later at `[rbp+48]` and up, and 32 bytes of shadow space reserved by the caller below every call
([../reference/objects.md](../reference/objects.md) § 4c). Change three lines:

```toml
[target]
os   = "windows"
arch = "x86_64"

[sysroot]
path = "build/sysroot/windows-x86_64"

[linker]
cmd  = "lld-link"
args = ["-machine:x64", "-subsystem:console", "-entry:mc_start", "-nodefaultlib",
        "-out:{out}", "{obj}", "build/winstart.obj", "{sysroot}/kernel32.lib"]
```

`lld-link` takes its options with either prefix. Under Git Bash on a Windows runner MSYS rewrites a
leading `/out:` into a path before the linker sees it, so the scripts here use the dash form.

`build/winstart.obj` in both link lines is the entry point, and you build it the same way you build
anything else — a second `mc build` with `entry = "<the bundled file>"` and `kind = "obj"`:

```toml
[project]
entry = "start.mc"          # one line: #include <sys_windows_start>
out   = "build/winstart.obj"
kind  = "obj"
```

`scripts/test-windows.sh` does exactly that, once per architecture, before it builds any test.

### The sysroot and the layer

The sysroot is one file and there is nothing to download: a Windows program links against an
**import library**, an archive of thunks generated from a list of exported names, so
`scripts/sysroot-windows.sh` writes `kernel32.def` and builds `kernel32.lib` from it with
`llvm-dlltool -m arm64` (or `-m i386:x86-64`; the seven exports are undecorated on both). Its
`--arch` picks which. `make sysroot-windows` and `make sysroot-windows-x86_64` run it, and it is a
cache like the musl one.

`<sys_windows>` is the system layer, and it is the one with no syscall instruction anywhere:
Windows has no stable system-call numbers, so the layer is ordinary mc code over seven kernel32
`extern`s — the same file for both architectures. The entry point is next to it rather than in it:
`<sys_windows_start>` is `mc_start`, which calls `win_setup()` (the `GetCommandLineA()` split) and
then `main`, and it is a file of its own because it is the one place `main` is named as an
`extern`, which a layer a program *includes* cannot do. Compile it alone into `winstart.obj` and
put it in every link line; that is what `-entry:mc_start -nodefaultlib` points at, and there is no
C runtime in the link at all.

It is also the one layer that does **not** pull in `<io>`: on Windows it is linked as an object
*next to* the program rather than taken out of an archive, so a second copy of
`strlen`/`puts`/`putnum` would be a duplicate symbol. Include them yourself:

```mc-no-run
#include <sys_windows>
#include <io>
```

`tests/windows/070-kernel32.mc` is that case. Everything else in the suite links against the layer
the way it links against musl on Linux — the compiled `lib/sys_windows.mc` is one more object on
the command line.

`scripts/test-windows.sh [--arch aarch64|x86_64]` cross-compiles the suite here and the
`windows-11-arm` and `windows-2025` CI jobs link and run it; `make test-windows` and
`make test-windows-x86_64` do the local half (objects, `llvm-readobj` on each, three real
`lld-link` links) and skip themselves without `lld-link` or `llvm-dlltool`. `docs/build.md`
§ Windows targets has the full field-by-field mapping.

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

On x86-64 the same three columns are shorter, because the instruction set needs fewer kinds:

| mc | ELF | addend |
|---|---|---|
| `call rel32` | `R_X86_64_PLT32` (4), at instruction + 1 | −4 |
| `lea r, [rip + disp32]` | `R_X86_64_PC32` (2), at instruction + 3 | −4 |
| `UNSIGNED` | `R_X86_64_64` (1) | 0 |

The addend is −4 because a `rel32` counts from the end of its own field. Both halves — where the
field starts inside the instruction, and what the addend is — match `clang
--target=x86_64-linux-musl -c` of the same constructs.

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
  macOS; `<sys_linux>` is Linux; `<sys_windows>` is Windows. `<io>`'s `strlen`/`puts`/`putnum` are
  written in the language and work on all three — but `<sys_windows>` is the one that does not
  include them for you.
- **`#opcode` is architecture-specific by nature.** A source full of hand-encoded AArch64 words is
  portable to Linux arm64 and to nothing else. `emit()` and `reloc()` are the same story. This is
  the one place the *language* stops being portable, and it is deliberate: it is the escape hatch.
- **Divide by zero is the hardware's answer, not the language's.** `x / 0`, `x % 0` and
  `INT64_MIN / -1` give `0`, `x` and `INT64_MIN` on AArch64, whose `sdiv`/`udiv` never trap, and
  raise `SIGFPE` on x86-64, whose `idiv`/`div` do — one source, two behaviours, with no guard
  emitted on either side. Constants are still caught at compile time (`division by zero`).
  Test a divisor that can be zero yourself; see
  [../core-language.md](../core-language.md) § "Division by zero, and `INT64_MIN / -1`".
- **`#dylib` is a Mach-O mechanism.** On Linux and Windows, name libraries in `[linker].args`
  instead.
- **Syscall numbers differ**, which is the entire reason `<sys_svc>`, `<sys_linux>` and
  `<sys_windows>` are three files rather than one with an `#ifdef` — there is no `#ifdef`, and
  there is not going to be one. Windows does not even have numbers: its boundary is a DLL.

## Next

Two complete programs that use everything so far: [60-examples.md](60-examples.md).

---

## Hosting `mc` on Linux

Everything above is *cross-compilation*: a macOS `mc` writing Linux objects. Since M37 `mc` also
**runs** on Linux — same source, same fixed point, `src/host_linux.mc` instead of
`src/host_macos.mc`. Cross-building the Linux compiler, the seed, the Linux bootstrap chain and
what `make check` covers there are in [90-linux-host.md](90-linux-host.md).
