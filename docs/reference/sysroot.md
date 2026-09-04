# Sysroots — where a cross link finds its files

A cross link needs files `mc` does not write: musl's `crt1.o`, `crti.o`, `crtn.o` and `libc.a` for
a Linux target, an import library for a Windows one, an SDK (or a stub) for the `.o` + `ld` road
on macOS. `{sysroot}` in `[linker].args` is where they come from, and this page is the whole
story of how that placeholder is resolved.

Nothing on this page is reached by compiling: the chain runs at LINK time, once per build, and
only because some `[linker].args` value mentions `{sysroot}` — exactly the laziness `{sdk}` has.

**`mc build` never downloads.** The chain looks at directories and gives up with a message; the
only thing in `mc` that reaches the network is `mc sysroot fetch`, and it requires `--yes`.

---

## 1. The resolution chain

`src/sysroot.mc`, `sysroot_find(os, arch)`, in this order:

| step | what is tried | when |
|---|---|---|
| 1 | `[sysroot].path`, resolved against the **config's** directory | whenever the key is there |
| 2 | the running system (§ 3) | only when `host_os()`/`host_arch()` equal the target's |
| 3 | the cache (§ 4) | always, when 1 and 2 did not answer |
| 4 | `sysroot_missing()` — the message of § 5, exit **2** | when nothing answered |

**An explicit path stops the chain.** If `[sysroot].path` is there and the directory is not a
sysroot, `mc` says so and stops; it does not fall through to the probes. A path that is written
down and wrong is a mistake to report, not a reason to go looking somewhere else.

**A cross build never picks up the host's own libc.** Step 2 is skipped by construction when the
target is not the host's own pair, which is why `mc build` for `linux/x86_64` on an
`aarch64` Linux box does not silently link the wrong `libc.a`.

## 2. "Present" is a marker-file test

`mc` has no `opendir`. It has `open` (`src/arena.mc`), so `path_exists(p)` is `open(p, O_RDONLY)`
followed by `close`, and each target declares the names that say a directory is populated:

| `[target].os` | markers |
|---|---|
| `linux` | `crt1.o` **and** `libc.a` |
| `windows` | `kernel32.lib` **or** `libkernel32.a` |
| `macos` | `usr/lib/libSystem.tbd` |

`crt1.o` alone is not enough: Alpine's `musl` package has the loader and the startup object,
`musl-dev` has `libc.a` as well, and only the second one can link.

The Windows marker names two files because there are two roads to the same thing:
`scripts/sysroot-windows.sh` builds `kernel32.lib` with `llvm-dlltool`, and `mc sysroot fetch`
unpacks llvm-mingw's `libkernel32.a`. Either one makes the directory a sysroot; the message
quotes the first.

## 3. The running-system probes

Tried in order, first populated one wins:

| host | probed |
|---|---|
| `linux` | `/usr/lib/<arch>-linux-musl` (Debian/Ubuntu `musl-dev`, the layout the CI host legs use), `/usr/lib/musl/lib`, `/usr/lib` (Alpine, where `apk add musl-dev` puts all four) |
| `macos` | `xcrun --show-sdk-path` — the same value `{sdk}` expands to, and cached the same way, so asking for both runs `xcrun` once. Nothing is probed when `host_has_sdk()` is 0 |
| `windows` | `build/sysroot/windows-<arch>`, where `scripts/sysroot-windows.sh` writes the import library. `mc` cannot regenerate one — that is `llvm-dlltool` — so a miss points at the script |

## 4. The cache

| what | where |
|---|---|
| `--sysroot-dir DIR` | **DIR itself** is the sysroot for this target. Highest precedence in step 3, and what CI passes, so no job depends on `HOME` |
| `[sysroot].cache = "ROOT"` | the sysroot is `ROOT/<os>-<arch>`. `ROOT` is relative to the config's directory, like every other path in `mc.toml` |
| neither | `host_home()/.mc/sysroots/<os>-<arch>` |

`host_home()` is the host layer's answer (`docs/reference/hooks.md` § The host layer): `HOME` out
of `host_environ()` on macOS and Linux; on Windows there is no environment array at all
(`host_environ()` is 0 there), so `src/host_windows.mc` asks kernel32 for `USERPROFILE` through
`GetEnvironmentVariableA`. With no home and no override, step 3 reports that and the chain ends.

## 5. The message, and exit code 2

```
mc: no sysroot for linux-aarch64
  tried: build/sysroot/linux-aarch64 (no crt1.o)
         /Users/me/.mc/sysroots/linux-aarch64 (absent)
  run:   sh scripts/sysroot-linux.sh --arch aarch64
```

One text, shared by every road into the chain. Each `tried:` line is a directory and the reason it
was refused — `absent` when it does not open at all, `no <marker>` when it does but is not a
sysroot.

**Exit code 2** is this message and nothing else. `docs/reference/cli.md` § Exit codes: 1 is a
diagnostic, 3 is the limits verdict, 2 is "the environment is not ready". A script may therefore
tell "your sysroot is missing" from "your program does not compile" without reading the text.

## 6. macOS needs none of this for `--exe`

The built-in Mach-O writer (`--exe`, `macho-exe`, `src/backend_exe.mc`) binds dylibs by ordinal
and signs the file itself. It needs **no SDK, no linker and no sysroot**, and on macOS it is what
an `mc.toml` with no `[linker]` uses. Everything on this page matters for the `.o` + `ld` road and
for cross-compiling; it does not stand between you and a macOS binary.

## 7. `mc sysroot` — list, path, fetch

```
mc sysroot list
mc sysroot path <os>-<arch>
mc sysroot fetch <os>-<arch> [--yes] [--sysroot-dir DIR]
```

**`list`** walks the target registry crossed with the pinned table of § 8 and touches no file at
all: no `open`, no probe, no absolute path. That is what makes one golden
(`tests/golden/sysroot-list.txt`) valid on macOS, Linux and Windows alike.

```
$ mc sysroot list
target           source
macos-aarch64    stubs (synthesized)
linux-aarch64    musl-dev (alpine v3.22)
linux-x86_64     musl-dev (alpine v3.22)
windows-aarch64  import libraries (llvm-mingw 20260826)
windows-x86_64   import libraries (llvm-mingw 20260826)
```

**`path`** runs the chain of § 1 for one target and prints the directory it resolved to, or the
message of § 5 and exit 2. It is the one command that answers "where is it on THIS machine".

**`fetch`** prints the plan — url, size, sha256, destination — and stops. With `--yes` it then
downloads, verifies, extracts and writes a manifest:

```
$ mc sysroot fetch linux-aarch64 --yes --sysroot-dir build/sysroot/linux-aarch64
fetch  linux-aarch64
url    https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/musl-dev-1.2.5-r12.apk
size   2556920 bytes
sha256 576f4aabcfa01d10d6baa2d5d87de436b76e58ae76eedf9db7627051365e1fe3
into   build/sysroot/linux-aarch64
sysroot linux-aarch64 -> build/sysroot/linux-aarch64
```

There is no prompt. `mc` has no `isatty` and inventing one for this is not worth an `extern`, so
requiring the flag is the honest version of "asks for confirmation". Without `--yes` the plan is
printed, `nothing was downloaded: re-run with --yes` follows, and the exit code is 0.

| step | how |
|---|---|
| download | `curl -fLsS -o FILE URL` is spawned (`curl.exe` on Windows), falling back to `wget -q -O FILE URL` where the host layer names one. `mc` speaks no HTTP and no TLS: an `http://` fetch of a checksummed file would still be a downgrade nobody should ship |
| verify | `sha256` from `src/sha256.mc`, over the bytes just written, plus the length. One implementation on three hosts, and part of the compiler rather than of a script |
| extract | one `tar` spawn, no shell: `-xzf` for an Alpine `.apk` (a gzip tar), `-xJf` for a `.tar.xz`, `-xf` for the `.zip` rows, which exist only for a Windows host — its bundled `tar.exe` is libarchive and reads zip, and is not to be trusted with xz |
| manifest | `manifest.toml` beside the files: target, kind, url, sha256, size, strip and the member list. **No date** ([../determinism.md](../determinism.md)), so two fetches of the same row write the same file |

Anything that goes wrong — no downloader on `PATH`, a non-zero `curl`, a checksum or size
mismatch, a `tar` that failed, an archive that did not carry the marker — deletes the download,
says which of those happened, prints the `run:`/`or:` block of § 5 and exits **2**. There is one
text to get right and one to document.

Where the files land, when `--sysroot-dir` is not given, is § 4's cache: `[sysroot].cache` is not
consulted (there is no config here), so it is `host_home()/.mc/sysroots/<os>-<arch>` or nothing.

## 8. The pinned sources

One row per (target, host). Pinned by version **and** by sha256 — never resolved through an index
file (`APKINDEX.tar.gz`, GitHub's `/latest`), because those move under us and a build that
downloads a different file next week is not reproducible. `src/sysroots.mc` holds the same table
in code, and `scripts/check-sysroots.sh` (inside `make check`) diffs the two, so a pin that moves
in one and not in the other fails the build.

| target | host | url | sha256 | size | strip |
|---|---|---|---|---|---|
| `macos-aarch64` | any | - | - | - | - |
| `linux-aarch64` | any | `https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/musl-dev-1.2.5-r12.apk` | `576f4aabcfa01d10d6baa2d5d87de436b76e58ae76eedf9db7627051365e1fe3` | 2556920 | 2 |
| `linux-x86_64` | any | `https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/musl-dev-1.2.5-r12.apk` | `1c2068d910cfdbbcb4eb107a5a478f8b48edf3a6311953c8fa5180c5190efab3` | 3427570 | 2 |
| `windows-aarch64` | `macos` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-macos-universal.tar.xz` | `48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f` | 124220620 | 3 |
| `windows-aarch64` | `linux:aarch64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-aarch64.tar.xz` | `4eb475cccf5e5e37ea3b693a52227e70a86ae70abafceb9ecd83887e67699c9d` | 77875280 | 3 |
| `windows-aarch64` | `linux:x86_64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64.tar.xz` | `cee8d2ce3da5145ce4dc882e70d0b0719a783d53a99752c60948fc0659975a65` | 83880560 | 3 |
| `windows-aarch64` | `windows:aarch64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-aarch64.zip` | `dbce5a314c44cf44d02ab0d0e6bce948955b46429274df25544f9cfea4986f7b` | 185650782 | 3 |
| `windows-aarch64` | `windows:x86_64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-x86_64.zip` | `ae601f4e0f72bbdf441ad2df8bb16f037e2e9251559ea6b37b4057aef39c06c3` | 190721391 | 3 |
| `windows-x86_64` | `macos` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-macos-universal.tar.xz` | `48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f` | 124220620 | 3 |
| `windows-x86_64` | `linux:aarch64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-aarch64.tar.xz` | `4eb475cccf5e5e37ea3b693a52227e70a86ae70abafceb9ecd83887e67699c9d` | 77875280 | 3 |
| `windows-x86_64` | `linux:x86_64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64.tar.xz` | `cee8d2ce3da5145ce4dc882e70d0b0719a783d53a99752c60948fc0659975a65` | 83880560 | 3 |
| `windows-x86_64` | `windows:aarch64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-aarch64.zip` | `dbce5a314c44cf44d02ab0d0e6bce948955b46429274df25544f9cfea4986f7b` | 185650782 | 3 |
| `windows-x86_64` | `windows:x86_64` | `https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-x86_64.zip` | `ae601f4e0f72bbdf441ad2df8bb16f037e2e9251559ea6b37b4057aef39c06c3` | 190721391 | 3 |

`host` is which machine the row is for: `any`, an operating system, or an `os:arch` pair. The
Windows rows differ per host because llvm-mingw ships one archive per host platform — the import
libraries inside are the same files, and one archive serves both Windows targets, only the member
path differs (`aarch64-w64-mingw32/lib` or `x86_64-w64-mingw32/lib`).

What each row extracts:

| kind | members |
|---|---|
| musl-dev | `usr/lib/crt1.o`, `usr/lib/crti.o`, `usr/lib/crtn.o`, `usr/lib/libc.a` — `musl-dev` alone carries all four; the `musl` package holds only the dynamic loader, which a static link never uses |
| llvm-mingw | `<archive>/<triple>/lib` — the whole import-library directory, about 80 MB and 467 files |
| stubs | nothing is downloaded for macOS: `--exe` needs no SDK (§ 6) |

**`lld-link` and mingw `lib*.a`.** The spec left one fact open: whether `lld-link` — the linker
every Windows `mc.toml` names — accepts mingw-style `lib*.a` import archives, or whether the fetch
would have to build `.lib` files from mingw-w64's `.def` sources instead. It was verified before
this landed and it does, on both architectures: a `coff-obj-arm64` object from `mc` declaring
`extern i64 htons(i64)` links against `aarch64-w64-mingw32/lib/libws2_32.a` with exit 0, and the
resulting PE carries a proper `WS2_32.dll` import for `htons` with an lld-synthesized ARM64 thunk;
the same holds for `coff-obj-x86_64` and `-machine:x64`. The commands and their output are in
[../specs/M25.md](../specs/M25.md) § Decisions 6.

**A pin that rots** is a maintenance issue, not a red pull request: `check-sysroots.sh` makes no
network request. Alpine prunes old point releases when a branch ages out; when that happens the
row changes in a commit with its new hash in the same diff, and until then the message of § 5
prints the URL so a mirror can be substituted by hand.

---

## Files

| file | what it holds |
|---|---|
| `src/sysroot.mc` | `path_exists`, the markers, the probes, the cache, the message, and `mc sysroot` |
| `src/sysroots.mc` | the pinned rows of § 8 |
| `src/driver.mc` | `drv_sysroot()`, the one call site — `{sysroot}` in `drv_ph` |
| `src/host_*.mc` | `host_home()`, `host_downloader()`, `host_downloader_alt()` |
| `scripts/sysroot-linux.sh` | the local road for a Linux sysroot: `apk add musl-dev` in `alpine:3` |
| `scripts/sysroot-windows.sh` | the local road for a Windows one: a `.def` and `llvm-dlltool` |
| `tests/proj/sysroot-*.toml` | the three cases `scripts/check-build.sh` runs |
| `tests/golden/sysroot-list.txt` | what `mc sysroot list` must print, on every host |
| `scripts/check-sysroots.sh` | the table and the golden, checked (`make check-sysroots`) |

## See also

* [toml.md](toml.md) § `[sysroot]` — the two keys
* [cli.md](cli.md) — `--sysroot-dir`, and exit code 2
* [diagnostics.md](diagnostics.md) — the message, with its cause and fix
* [../guide/50-cross-compile.md](../guide/50-cross-compile.md) — the task-oriented version
* [../build.md](../build.md) § Linux targets — what a Linux `mc.toml` looks like
