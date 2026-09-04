# Footprint

How big is the smallest thing `mc` can produce, and how much memory does it use? The answer is
a number per target, and almost none of it is the program.

```mc
// expect-exit: 0
i64 main() { return 0; }
```

That is `examples/minimal/main.mc` in full. `examples/minimal/measure.sh` compiles it four ways
and prints what each one costs:

```
$ sh examples/minimal/measure.sh
```

It needs `build/mc1` for everything and, for the two Linux rows, `ld.lld` and a running Docker
— those are cross-compiled on macOS and then measured inside `docker run --platform linux/arm64
alpine:3`. A missing tool skips its rows and says so.

## The numbers

Measured on **2026-09-03**, Mac16,12 (Apple M4), macOS 26.6.2 25G83, arm64; Linux rows in
`alpine:3` `linux/arm64` under Docker, musl from `scripts/sysroot-linux.sh`. Both the machine
and the date matter: nothing here compares across either.

| variant | file size | code bytes | segments/sections | max RSS | peak footprint | own mapped |
|---|---:|---:|---:|---:|---:|---:|
| macOS `--exe` (no `ld`) | 16 692 | 28 | 3 / 1 | 1 343 488 | 950 560 | 32 768 |
| macOS `.o` + `ld` | 16 840 | 28 | 3 / 1 | 1 359 872 | 950 560 | 32 768 |
| Linux musl static | 32 592 | 2 504 | 4 / 21 | 262 144 | — | 16 384 |
| Linux `nolibc` `_start` | 1 888 | 756 | 2 / 5 | 262 144 | — | 8 192 |

All figures in bytes. *Code bytes* is `__text` on Mach-O and `.text` on ELF; *segments* counts
`LC_SEGMENT_64` (`__PAGEZERO` included) or `PT_LOAD`, and *sections* excludes ELF's mandatory
null section header. *Own mapped* is what the program itself asks the kernel to map — segment
`vmsize` without `__PAGEZERO` on Mach-O, `PT_LOAD` `MemSiz` rounded up to the 4 KiB page on ELF.
Every number in this table is read out of the file or is a kernel high-water mark that does not
move: the table is byte-identical run to run, which is what makes it a regression guard.

Timings are printed separately, because they are not:

| variant | compile mean | compiler RSS | link mean | startup mean |
|---|---:|---:|---:|---:|
| macOS `--exe` (no `ld`) | 3.30 ms | 1 753 088 | — | 1.50 ms |
| macOS `.o` + `ld` | 1.70 ms | 1 671 168 | 30.50 ms | 1.40 ms |
| Linux musl static | 16.00 ms | 39 337 984 | — | 0.40 ms |
| Linux `nolibc` `_start` | 14.70 ms | 26 820 608 | — | 0.80 ms |

The mean of a 100-run loop each (`hyperfine --warmup 3 --min-runs 20` is used instead when it is
installed, and then the script also prints a per-run minimum). *Compiler RSS* is `mc`'s own peak
while producing that artifact — the arena the run reserved, not the program's memory. The two
Linux rows compile *and* link inside one `mc build`, which is why their link column is empty;
their startup is measured inside the container and excludes Docker's own container setup.

Three things stand out, and the rest of this page is why.

* Linking the same object with `ld` instead of letting `mc` write the executable costs
  **148 bytes** and about **30 ms**.
* The macOS binaries map 32 KiB of their own and report **1.3 MB** of RSS.
* The same program is **1 888 bytes** on Linux with no libc and **32 592** with one.

## macOS: one 16 KiB page plus 308 bytes

arm64 macOS has a 16 KiB page and every segment starts on one. The Mach-O header, the 12 load
commands (624 bytes of them) and the 28 bytes of code therefore all live inside the first
`__TEXT` page, and the file is that whole page plus `__LINKEDIT` — the symbol table and the
ad-hoc `CS_SuperBlob` signature, which has to be last in the file:

```
16 384  __TEXT, one page: header + load commands + __text (28 bytes)
   308  __LINKEDIT: symtab + the ad-hoc code signature
------
16 692
```

Nothing in that layout is negotiable. A segment cannot be shorter than a page, a Mach-O
executable that is not signed will not launch on Apple silicon, and the signature has to be at
the end. `mc --exe` writes and signs it itself ([70-bootstrap.md](70-bootstrap.md)); the
identifier inside the signature is the output's **basename**, so the same program written to a
longer file name produces a longer `CodeDirectory` and a bigger file. That is why every variant
in `examples/minimal` is named `minimal`.

Handing the object to `ld` instead costs 148 bytes, and every one of them is in `__LINKEDIT`
(456 against 308): `ld` also writes chained fixups, a function-starts table and a data-in-code
table. Its four extra load commands are free, because they sit inside a page that is there
either way.

## macOS: 1.3 MB of RSS for a program that calls nothing

Both macOS rows map 32 KiB of their own — two pages, `__TEXT` and `__LINKEDIT` — and report
over a megabyte of resident memory. That is not the program: a Mach-O executable on macOS is
started by `dyld`, which maps itself and libSystem out of the shared cache before `main` runs.
The *peak footprint* column (950 560 bytes, what `vmmap` calls **Physical footprint (peak)**) is
the part the kernel actually charges to this process; the difference is shared with every other
process on the machine.

The obvious escape — a static executable with no `dyld` — is not available: the kernel refuses
to exec a static Mach-O, which is what M0.5 established and why `lib/sys_svc.mc` makes raw `svc`
calls from inside a dynamically linked binary instead ([70-bootstrap.md](70-bootstrap.md)).
On macOS, roughly a megabyte is the floor for *any* process.

## Linux, musl: 2 504 bytes of `.text` for 28 bytes of program

The static musl link is the conventional one: `crt1.o`, `crti.o`, `libc.a`, `crtn.o`, entry
point `_start` inside the C runtime. `crt1.o` calls `__libc_start_main`, which brings in the
auxv walk, the TLS and stack-guard setup and the exit machinery — 2 504 bytes of `.text` around
28 bytes of program, in four `PT_LOAD` segments.

The file is ten times bigger than what it loads, and that is Alpine's `libc.a` carrying debug
information which `ld.lld` copies through: `strip` takes this exact binary from 32 592 bytes to
**3 984**, and from 21 sections to 10, without touching a single loadable byte. None of it is
`mc`'s doing — a C hello-world links exactly the same way.

## Linux, no libc: 1 888 bytes, and that is the floor

`#include <sys_linux>` ([50-cross-compile.md](50-cross-compile.md)) is the kernel interface
written in this language: `svc #0` with the call number in `x8`, taught to the compiler with
`#opcode`, plus a `_start` that reads `argc`/`argv` off the entry stack, calls `main` and hands
`x0` to `exit_group`. The link is then `ld.lld -nostdlib -e _start` — no crt objects, no
`libc.a`, nothing to relocate, two `PT_LOAD` segments and 8 KiB mapped.

Most of even those 756 bytes of `.text` is dead code: `mc` emits every function it parses, and
`<sys_linux>` defines `open`/`creat`/`read`/`write`/`close`/`fchmod`/`exit` plus `lib/io.mc`'s
`strlen`/`puts`/`putnum`, none of which this program calls. `strip` takes the file to 1 360
bytes; the remainder is the ELF header, the program headers and the section table.

This is the honest floor of the toolchain as it stands: a program, an entry point and a system
call, with nothing between them and the kernel.

## Why the Linux max-RSS column is a floor, not a measurement

Both Linux rows report the same 262 144 bytes, and neither of them uses that much. Linux keeps
a process's RSS high-water mark **across `exec`**, so what `wait4` hands the measuring program
is `max(what the measurer had mapped when it forked, what the program used)`. GNU `time`'s own
image is about 256 KiB, and both of these programs are far below it, so both land on that floor.
The same two binaries measured with busybox's `time`, whose image is about 716 KiB, report
716 KiB instead — same programs, different measurer, different answer.

The *own mapped* column is the one that separates them: 16 KiB against 8 KiB, computed from the
`PT_LOAD` headers and independent of who is watching.

## The ceilings

```
$ sh examples/minimal/measure.sh --check
ok   macos --exe size          16 692 <= 17 000 bytes
ok   macos --exe max RSS       1 343 488 <= 2 000 000 bytes
ok   linux nolibc size         1 888 <= 2 000 bytes
all ceilings hold
```

Exit 1 on a violation; a target whose tools are missing is skipped, not failed. The ceilings sit
just above what the tree produces today, on purpose: they are regression guards for the
backends, so a load command, a section or a page that starts appearing where it did not before
is caught here rather than in a release.

## What is not measured yet

There is no Windows (COFF) and no wasm backend, so those rows do not exist — see the target
table in [50-cross-compile.md](50-cross-compile.md) for what is planned and what the
machine-interface split in [../reference/machine.md](../reference/machine.md) has to land first.
Each of them will bring its own floor: a COFF image has a section alignment far larger than its
contents, and a wasm module under WASI pays for the module preamble and for whatever the host
runtime instantiates before the entry point runs. The shape of this page — one table, one
paragraph per floor — is meant to survive their arrival.
