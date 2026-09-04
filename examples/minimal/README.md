# `examples/minimal` — the smallest executable, and what it costs

```mc
// expect-exit: 0
i64 main() { return 0; }
```

That is `main.mc`, the whole program. Four ways of turning it into something the operating
system will run, and the price of each:

```
$ sh examples/minimal/measure.sh
```

| variant | how it is built | config |
|---|---|---|
| macOS `--exe` | `mc` writes and signs the Mach-O itself, no `ld` | [mc.toml](mc.toml) |
| macOS `.o` + `ld` | `mc` writes a relocatable, the system linker finishes it | — (`scripts/link.sh`) |
| Linux musl static | `mc` writes an ELF, `ld.lld` links it against musl | [mc.linux.toml](mc.linux.toml) |
| Linux `-nostdlib` | `mc` writes an ELF, `ld.lld` links it with nothing at all | [mc.nolibc.toml](mc.nolibc.toml) |

The last one is the floor: no C runtime, no libc, no dynamic loader. Its entry point is
`_start` from [`lib/sys_linux.mc`](../../lib/sys_linux.mc), which is written in this language,
and its system calls are `svc #0` taught to the compiler with `#opcode`. That is why it needs a
second entry file, [`nolibc.mc`](nolibc.mc) — `main.mc` itself stays a pure `main` for all four.

## What it measures

Two tables. The first one is sizes and memory and is **byte-identical between runs** on one
machine; the second one is times, which are not, and are kept apart so the first can be diffed.
A header names the machine and the date, because none of these numbers compare across either.

| column | where it comes from |
|---|---|
| file size | `wc -c` |
| code bytes | `__text` size (`otool -l`) / `.text` size (`size -A`) |
| segments / sections | `LC_SEGMENT_64` (`__PAGEZERO` included) or `PT_LOAD`, then section headers |
| max RSS | `/usr/bin/time -l` on macOS, GNU `time -v` in the container on Linux; smallest of several runs |
| peak footprint | `/usr/bin/time -l`, "peak memory footprint" — what `vmmap` calls *Physical footprint (peak)*; macOS only |
| own mapped | what the program asks the kernel to map: Mach-O segment `vmsize` without `__PAGEZERO`, ELF `PT_LOAD` `MemSiz` rounded to the 4 KiB page |
| compile / link / startup | `hyperfine --warmup 3 --min-runs 20` when installed, otherwise a 100-run loop timed with `/usr/bin/time -p` (mean only) |
| compiler RSS | `/usr/bin/time -l` on the compilation itself |

Read the explanation block the script prints after the tables before quoting the max RSS
column: on Linux the kernel keeps the RSS high-water mark across `exec`, so the number is
`max(the measuring process, the program)` and both Linux rows sit on the measurer's floor.

## What it needs

`build/mc1` (`make mc1`) for everything, and for the two Linux rows `ld.lld` (`brew install
lld`) plus a running Docker — they are cross-compiled here and run inside `docker run
--platform linux/arm64 alpine:3`, where the script also installs GNU `time` and `binutils`
(`apk add --no-cache time binutils`) to measure them. The musl sysroot is populated on demand by
[`scripts/sysroot-linux.sh`](../../scripts/sysroot-linux.sh). A missing tool skips its rows and
says why; it is never an error.

## The ceilings

```
$ sh examples/minimal/measure.sh --check
ok   macos --exe size          16 692 <= 17 000 bytes
ok   macos --exe max RSS       1 343 488 <= 2 000 000 bytes
ok   linux nolibc size         1 888 <= 2 000 bytes
all ceilings hold
```

Three assertions, exit 1 on a violation, skipped (not failed) when the tools are missing. They
are regression guards for the backends, not tuning targets: they sit just above what the tree
produces today, so a backend that starts emitting a load command, a section or a page it did not
emit before is caught here instead of in a release.

The numbers themselves, with the explanation of every floor, are in
[docs/guide/80-footprint.md](../../docs/guide/80-footprint.md).
