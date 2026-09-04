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

**The directory itself is never probed** — only the marker files, which are files. On a Windows
host `open` is `CreateFileA(..., FILE_ATTRIBUTE_NORMAL, ...)` (`lib/sys_windows.mc`), and that
call will not open a directory: a probe of the directory would report every populated sysroot on
the machine as absent. Nothing is lost by dropping it, because a directory that is not there is a
directory none of whose markers open, and `no crt1.o` is as true of a missing directory as of an
empty one. The same rule governs the `fetch` check of § 7: a row member that lands *as* the
destination directory is not probed either.

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

The Windows row is the one **relative** candidate in this step (the Linux ones are absolute, the
macOS one comes back absolute from `xcrun`), and like every relative path in `mc.toml` it is taken
against the **config's directory**, not the working directory: `mc build ../myapp` probes
`../myapp/build/sysroot/windows-aarch64`. With no config — `mc sysroot list|path` — there is
nothing to be relative to and it is the working directory.

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
         /Users/me/.mc/sysroots/linux-aarch64 (no crt1.o)
  run:   sh scripts/sysroot-linux.sh --arch aarch64
```

One text, shared by every road into the chain. Each `tried:` line is a directory and the reason it
was refused: `no <marker>`, the first marker file of § 2 that the directory does not hold. A
directory that does not exist at all reads the same, because there is no separate directory probe
— see § 2.

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
mc sysroot stub [DIR] [--config FILE]
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
| download | `curl --proto '=https' --proto-redir '=https' -fLsS -o FILE URL` is spawned (`curl.exe` on Windows), falling back to `wget -q -O FILE URL` where the host layer names one. `mc` speaks no HTTP and no TLS: an `http://` fetch of a checksummed file would still be a downgrade nobody should ship |
| verify | `sha256` from `src/sha256.mc`, over the bytes just written, plus the length. One implementation on three hosts, and part of the compiler rather than of a script |
| extract | one `tar` spawn, no shell: `-xzf` for an Alpine `.apk` (a gzip tar), `-xJf` for a `.tar.xz`, `-xf` for the `.zip` rows, which exist only for a Windows host — its bundled `tar.exe` is libarchive and reads zip, and is not to be trusted with xz |
| check | **every member of the row**, not just the markers, then the markers. See below |
| manifest | `manifest.toml` beside the files: target, kind, url, sha256, size, strip and the member list. **No date** ([../determinism.md](../determinism.md)), so two fetches of the same row write the same file |

Every row is an `https://` URL, but `-L` follows redirects, so the two `--proto` flags say the
HTTPS-only rule to the program that does the transfer and not only to the table: a 3xx to an
`http://` mirror is refused rather than followed. The `wget` fallback keeps its two flags and has
no equivalent restriction — busybox's `wget` is what an Alpine host has, and it knows neither
`--https-only` nor `--proto`, so demanding one there would cost the fallback itself. The sha256
check guards the bytes either way; the flags guard the connection.

**The check step is stricter than the marker test of § 2**, and deliberately so. The markers are
all the resolution chain has, because a directory somebody built by hand has no row behind it. A
fetch knows more: it has the archive's own file list. An extraction cut short — a full disk, a
killed `tar` — can land `crt1.o` and `libc.a` and stop before `crti.o`, and the marker test would
call that directory a sysroot. So `fetch` tests each landed member — the member path with the
row's `--strip-components` removed — and only then the markers. For the llvm-mingw rows nothing is
left of the path and the member *is* the destination directory; that one is skipped, for the
reason § 2 gives, and the markers it would have stood in for are tested a line later anyway.

Anything that goes wrong — no downloader on `PATH`, a non-zero `curl`, a checksum or size
mismatch, a `tar` that failed, an archive that did not carry one of its own members or a marker —
deletes the download, says which of those happened, prints the `run:`/`or:` block of § 5 and exits
**2**. There is one text to get right and one to document.

Two orderings matter on that road. `manifest.toml` is written **after** the check, never before:
it is the claim that this directory holds what the row says, and that claim does not go over an
extraction that did not finish. And a refused extraction has its **marker files removed**, so the
partial directory cannot pass the chain's marker test on the next `mc build` — the rest of the
debris is inert, and a second `fetch` extracts over it.

**Only a missing program makes `fetch` try the second downloader.** `drv_spawn_ok`
(`src/driver.mc`) returns -1 for `ENOENT` and for nothing else: `posix_spawnp` hands back the
error number rather than setting `errno`, so an `EACCES` (a `curl` that is there and not
executable) or an `ENOEXEC` (a `curl` that is there and not a program) is a real failure and stops
the build with `mc: cannot spawn: curl (error 13)`, instead of being reported as
`no downloader on this PATH` about a `curl` that is on the `PATH`.

The Windows shim answers in the same vocabulary (`lib/sys_windows_host.mc`, `posix_spawnp` over
`CreateProcessA`), which is the only reason the rule holds on that host too:

| `GetLastError()` after a failed `CreateProcessA` | returned |
|---|---|
| `ERROR_FILE_NOT_FOUND` (2), `ERROR_PATH_NOT_FOUND` (3) | `ENOENT` (2) — the program is not there, try the next tool |
| anything else | that value, unchanged (a 0 becomes 1) — a real failure, named with its number |

and the command line that did not fit in `WH_CMDMAX` returns `E2BIG` (7) before any process is
created, because running a truncated command line would run the *wrong* command.
`GetLastError` is therefore one of the names `scripts/sysroot-windows.sh` puts in `kernel32.def`.

Where the files land, when `--sysroot-dir` is not given, is § 4's cache: `[sysroot].cache` is not
consulted (there is no config here), so it is `host_home()/.mc/sysroots/<os>-<arch>` or nothing.

**`stub`** is the fourth one and the only one that reads an `mc.toml`: it is the front half of a
build — parse `[project].entry`, work out which library each `extern` belongs to, write one import
file per library — and stops there. No object, no link, and no `[linker]` required. § 9 is what it
writes.

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

## 9. The stub writers — a link needs a name list, not a library

A linker wants two things from a library: its **name** and the list of symbols it exports.
Neither is code, and neither is anything that has to be downloaded — and `mc` already knows both
at the moment the link line is assembled, because the program declared its `extern`s and
`#dylib` / `[libs]` / `[externs]` said which library each one belongs to. `src/stubs.mc` turns
that into files a linker accepts.

| `[target].os` | what is written, per library |
|---|---|
| `macos` | `<stubs>/<lib>.tbd`, a TBD v4 text file listing exactly the symbols this program asks for |
| `windows` | `<stubs>/<lib>.def`, then `llvm-dlltool -m <machine> -d <def> -D <dll> -l <lib>.lib` spawned over it |
| `linux` | nothing: `mc: no stub writer for: linux: a static libc is code, not a name list`. That is what `mc sysroot fetch linux-<arch>` is for |

The library a symbol belongs to is `extern_lib_find` — the same answer the executable backend uses
for its bind ordinals. Ordinal 1 is the default every unclaimed `extern` falls to: `libSystem` on
macOS, `kernel32` on Windows.

```
$ mc sysroot stub tests/proj --config tests/proj/stub.toml
stubs 2 -> tests/proj/build/stubs

$ cat tests/proj/build/stubs/libSystem.tbd
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-macos ]
install-name: '/usr/lib/libSystem.B.dylib'
current-version: 1.0
exports:
  - targets: [ arm64-macos ]
    symbols: [ _open, _creat, _read, _write, _close, _exit, _mmap, _munmap, _posix_spawnp, _waitpid, __NSGetEnviron, dyld_stub_binder ]
...
```

`dyld_stub_binder` is added unconditionally to the libSystem stub: no program declares it, and it
is what `-lSystem` really contributes to a lazily-bound image.

### `{stubs}` in `[linker].args`

The placeholder that makes a build use them. It expands to
`<dirname of [project].out>/stubs` — `build/stubs` for the usual `out = "build/app"` — and is
**lazy** in exactly the way `{sdk}` is: the files are written on the first argument that mentions
it, once per build, and never otherwise.

```toml
[linker]
cmd  = "ld64.lld"
args = ["-arch", "arm64", "-platform_version", "macos", "13.0", "13.0",
        "-e", "_main", "-o", "{out}", "{obj}",
        "{stubs}/libSystem.tbd", "{stubs}/libsqlite3.tbd"]
```

That is `tests/proj/stub.toml`, and `scripts/check-stubs.sh` builds it with a `PATH` holding one
single program, `ld64.lld` — no `xcrun`, no SDK, no `-lSystem` — then **runs** the binary and
compares its output. `otool -L` shows `/usr/lib/libSystem.B.dylib` and `/usr/lib/libsqlite3.dylib`,
the two install names the stubs recorded.

`ld64.lld` and not Apple's `ld`, deliberately: a machine that has `ld` has the Command Line Tools,
and the CLT bring an SDK with them. "macOS with a linker and no SDK" is honestly the LLVM linker,
and that is the shape these stubs are for.

### What the synthesizer cannot do

* **Data exports.** A `.def` entry for a data symbol needs a `DATA` keyword that cannot be
  inferred from an `extern` declaration. A program importing a variable rather than a function
  needs a real import library — which is what `mc sysroot fetch windows-<arch>` is still for.
* **Frameworks, re-exports, umbrellas, ObjC classes.** The `.tbd` writer emits one `exports`
  block with a symbol list and nothing else.
* **Anything `mc` never saw.** The stub lists what the program declares. A third-party object
  linked in beside it brings symbols `mc` has no declaration for; those need the real library.

Nothing here redistributes anything: a symbol NAME is not SDK content, and the files carry no
code at all.

---

## Files

| file | what it holds |
|---|---|
| `src/sysroot.mc` | `path_exists`, the markers, the probes, the cache, the message, and `mc sysroot` |
| `src/sysroots.mc` | the pinned rows of § 8 |
| `src/stubs.mc` | the `.tbd` and `.def` writers of § 9 |
| `src/driver.mc` | `drv_sysroot()`, the one call site — `{sysroot}` in `drv_ph` |
| `src/host_*.mc` | `host_home()`, `host_downloader()`, `host_downloader_alt()` |
| `scripts/sysroot-linux.sh` | the local road for a Linux sysroot: `apk add musl-dev` in `alpine:3` |
| `scripts/sysroot-windows.sh` | the local road for a Windows one: a `.def` and `llvm-dlltool` |
| `tests/proj/sysroot-*.toml` | the three cases `scripts/check-build.sh` runs |
| `tests/golden/sysroot-list.txt` | what `mc sysroot list` must print, on every host |
| `scripts/check-sysroots.sh` | the table and the golden, checked (`make check-sysroots`) |
| `scripts/check-stubs.sh` | the stub writers, linked and run (`make check-stubs`) |
| `tests/proj/stub.toml`, `stub-windows.toml` | the two configs it builds |

## See also

* [toml.md](toml.md) § `[sysroot]` — the two keys
* [cli.md](cli.md) — `--sysroot-dir`, and exit code 2
* [diagnostics.md](diagnostics.md) — the message, with its cause and fix
* [../guide/50-cross-compile.md](../guide/50-cross-compile.md) — the task-oriented version
* [../build.md](../build.md) § Linux targets — what a Linux `mc.toml` looks like
