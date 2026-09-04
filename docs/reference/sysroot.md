# Sysroots — where a cross link finds its files

A cross link needs files `mc` does not write: musl's `crt1.o`, `crti.o`, `crtn.o` and `libc.a` for
a Linux target, an import library for a Windows one, an SDK (or a stub) for the `.o` + `ld` road
on macOS. `{sysroot}` in `[linker].args` is where they come from, and this page is the whole
story of how that placeholder is resolved.

Nothing on this page is reached by compiling: the chain runs at LINK time, once per build, and
only because some `[linker].args` value mentions `{sysroot}` — exactly the laziness `{sdk}` has.

**`mc build` never downloads.** The chain looks at directories and gives up with a message.
Nothing in it reaches the network.

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
| `windows` | `kernel32.lib` |
| `macos` | `usr/lib/libSystem.tbd` |

`crt1.o` alone is not enough: Alpine's `musl` package has the loader and the startup object,
`musl-dev` has `libc.a` as well, and only the second one can link.

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

---

## Files

| file | what it holds |
|---|---|
| `src/sysroot.mc` | `path_exists`, the markers, the probes, the cache and the message |
| `src/driver.mc` | `drv_sysroot()`, the one call site — `{sysroot}` in `drv_ph` |
| `src/host_*.mc` | `host_home()`, `host_downloader()`, `host_downloader_alt()` |
| `scripts/sysroot-linux.sh` | the local road for a Linux sysroot: `apk add musl-dev` in `alpine:3` |
| `scripts/sysroot-windows.sh` | the local road for a Windows one: a `.def` and `llvm-dlltool` |
| `tests/proj/sysroot-*.toml` | the three cases `scripts/check-build.sh` runs |

## See also

* [toml.md](toml.md) § `[sysroot]` — the two keys
* [cli.md](cli.md) — `--sysroot-dir`, and exit code 2
* [diagnostics.md](diagnostics.md) — the message, with its cause and fix
* [../guide/50-cross-compile.md](../guide/50-cross-compile.md) — the task-oriented version
* [../build.md](../build.md) § Linux targets — what a Linux `mc.toml` looks like
