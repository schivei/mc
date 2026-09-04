# `mc` on a Windows host

Until M38 `mc` was a macOS and Linux program that could *target* Windows: M19 taught it to write
COFF objects for `windows/aarch64`, M20 added `windows/x86_64`, and both times the objects were
cross-compiled on macOS and linked and run on a CI runner. Now it is a Windows program too — the
same source, the same core, the same fixed point, hosted on `windows/arm64` and `windows/x86_64`.
This page is the whole story from a bare Windows machine to `make check`.

Two things are not portable and never will be.

The **seed**: `stage0/*.c` is 2848 lines of C that emit Mach-O and only Mach-O — the frozen oracle
every cross-check compares against — so a Windows host does not start from a C compiler. It starts
from an `mc` binary that already exists, either a published release asset or one cross-built on
macOS, and after one bootstrap the machine is self-sufficient. That is the same rule
[90-linux-host.md](90-linux-host.md) states for Linux.

The **C runtime**: there is none here. `mc` on Windows calls kernel32.dll and nothing else — no
MSVCRT, no Visual Studio redistributable, no Windows SDK. Everything a POSIX program takes from
libc is written in mc, in `lib/sys_windows.mc` and `lib/sys_windows_host.mc`, and linked next to
the compiler as an ordinary object (§ 3).

---

## 1. In six commands

Run everything from **Git Bash** (the `sh` that ships with Git for Windows). The scripts are POSIX
shell and the Makefile is GNU make.

```sh
git config --global core.autocrlf false             # BEFORE cloning: see § 7
git clone https://github.com/schivei/mc && cd mc
choco install make llvm                             # GNU make; lld-link comes with LLVM
scripts/bootstrap-windows.sh                        # fetches the seed, reaches the fixed point
make check                                          # the Windows subset
```

`scripts/bootstrap-windows.sh` with no argument looks for `build/mc-windows-<target>.exe` first (a
cross-built compiler, § 5), then for `build/mc-windows-<target>.obj`, which it links itself — that
is what the CI artifact holds — and otherwise downloads a release asset:

```
https://github.com/schivei/mc/releases/download/v<VER>/mc-<VER>-windows-<arch>.tar.gz
https://github.com/schivei/mc/releases/download/v<VER>/mc-<VER>-windows-<arch>.tar.gz.sha256
```

with `<arch>` = `arm64` or `x86_64`. With the GitHub CLI on `PATH` it uses `gh release download`;
otherwise `curl` fetches both files and `MC_SEED_VERSION` says which version. **The tarball is
unpacked only after its SHA-256 matches the `.sha256` file**, and a mismatch stops the script.

You can also hand it a binary you already trust:

```sh
scripts/bootstrap-windows.sh /c/tools/mc.exe
```

The seed has to be a compiler *for this host*, not merely one that runs here — the script asks it:

```sh
$ mc --host
os windows
arch aarch64
sys sys_windows
```

and refuses anything whose answer is not `windows/<this machine>`.

---

## 2. What the host layer is

`src/core.mc` is host-neutral. Everything that depends on the operating system the **compiler
itself runs on** lives in one small file the entry point includes before the core:

| entry point | host file | what it is |
|---|---|---|
| `src/mc.mc` | `src/host_macos.mc` | macOS, arm64 |
| `src/mc_linux.mc` | `src/host_linux_aarch64.mc` | Linux, arm64 |
| `src/mc_linux_x86_64.mc` | `src/host_linux_x86_64.mc` | Linux, x86-64 |
| `src/mc_windows.mc` | `src/host_windows_aarch64.mc` | Windows, arm64 |
| `src/mc_windows_x86_64.mc` | `src/host_windows_x86_64.mc` | Windows, x86-64 |

Each of the five is three `#include` lines. The Windows pair shares `src/host_windows.mc`, which
carries everything that depends on the operating system, and adds the three answers that depend on
the architecture — `host_arch()`, `host_machine()` (`"arm64"` or `"x86_64-win"`, the Win64 half of
the x86-64 machine) and `host_include()`. The full interface is
[../reference/hooks.md](../reference/hooks.md) § 6.

What is Windows-specific in it:

* `O_CREAT 0x100` / `O_TRUNC 0x200` — the values `lib/sys_windows.mc` publishes. They are not a
  kernel's numbers (Windows takes the disposition as a separate argument to `CreateFileA`), but
  every system layer of this project publishes the pair.
* `host_environ()` returns **0**. `CreateProcessA` reads a null `lpEnvironment` as "give the child
  this process's own environment", which is exactly what `posix_spawnp` with `environ` does.
  Windows has no third argument to `main`, so `lib/sys_windows_start.mc` passes 0 and `host_init`
  ignores it.
* `host_has_sdk()` returns **0**. `{sdk}` in an `mc.toml` runs `xcrun`, which is a macOS program;
  on this host writing `{sdk}` is a config error, not a spawn that fails halfway through a build.
* `host_exe_suffix()` returns **`".exe"`**. This is the one thing the driver had to learn (§ 6).

---

## 3. The runtime object: fifteen names Windows does not have

The compiler declares fifteen things `extern` and expects the system to provide them:
`open`, `read`, `write`, `close`, `creat`, `_exit` and `mmap` (`src/arena.mc`), `chmod`
(`src/backend_exe.mc`), and `posix_spawnp`, `posix_spawn_file_actions_{init,addopen,destroy}`,
`waitpid`, `mkdir` and `unlink` (the host file). On macOS every one of them is in libSystem; on
Linux every one of them is in musl. On Windows **none of them exists**.

They cannot be defined inside the compiler either: `src/arena.mc` declares them `extern`, and a
file cannot both declare a name `extern` and define it (`function declared twice`). So they are an
ordinary object linked next to the compiler, exactly the way `winrt.obj` is linked next to every
Windows test:

| file | object | what it holds |
|---|---|---|
| `lib/sys_windows.mc` | `winrt.obj` | the system layer a *program* includes: `write`/`read`/`open`/`creat`/`close`/`exit` over kernel32, plus the command-line split |
| `lib/sys_windows_host.mc` | `mcrt.obj` | that file **plus** the nine names only the compiler needs |
| `lib/sys_windows_start.mc` | `winstart.obj` | `mc_start`, what `-entry:` names |

`lib/sys_windows_host.mc` is architecture-neutral mc code over kernel32 — not one instruction is
written by hand — and is compiled once per architecture. What it does:

* **`posix_spawnp`** joins the argument vector into one command line with the MSVCRT quoting rules
  (a run of *N* backslashes before a quote becomes 2*N*+1 and `\"`; an argument with a space, a tab
  or a quote is wrapped), lays out `STARTUPINFOA` (104 bytes) and `PROCESS_INFORMATION` (24) in
  `u8` arrays through `st*`/`ld*` with `#define` offsets, and calls `CreateProcessA` with
  `lpApplicationName = 0` so that `PATH` is searched and `.exe` is appended for us — which is why
  `cmd = "lld-link"` in an `mc.toml` works with no suffix written anywhere. `dwFlags` stays 0, so
  the child inherits this process's console and its three standard handles and a spawned linker's
  diagnostics reach you unchanged.
* **`waitpid`** waits on the process HANDLE, reads the exit code and stores `(code & 255) << 8`.
  `src/driver.mc` takes the code from bits 8..15 and treats the low seven as a signal number;
  Windows has no signals, so those seven stay 0 and the shape is exact. The mask is what keeps a
  DWORD exit code such as `0x100` from arriving as 0.
* **`mmap`** is `VirtualAlloc(0, len, MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)` with mc's own
  prototype. `src/arena.mc` does not change: `arena_map` already rounds the size up to 64 KiB,
  which is exactly `VirtualAlloc`'s allocation granularity, and already treats both 0 and -1 as a
  refusal.
* **`mkdir`** is `CreateDirectoryA`, **`unlink`** is `DeleteFileA`, **`_exit`** is `ExitProcess`.
* **`chmod`** returns 0. NTFS has no mode bits and there is no execute permission to grant: an
  `.exe` is executable because of its name and its PE header. Its only caller is the Mach-O
  direct-executable backend, which this host never selects — but the symbol still has to link.
* The three **`posix_spawn_file_actions_*`** return -1. The only caller is `drv_sdk`, and it asks
  `host_has_sdk()` first.

### The blocker that came first: `CreateProcessA` takes ten parameters

`MAXPARAMS` was 8, "never passes an argument on the stack", and it is enforced at parse time and
again in `gen_resolve`. M38's first step raised it to **12** in `src/` and taught all three
machines to pass 9..12 on the stack — on AArch64 the caller leaves them at `[sp, #0..#24]`, at the
bottom of its own frame, and the callee reads them at `[x29 + 16 + 8*(i-8)]`; the two x86-64
conventions already had the mechanism. The frozen C seed keeps 8, a documented divergence of the
same kind as `MAXSTRS`/`MAXGLOBALS`/`MAXOPEN` ([../build.md](../build.md) § limits), because
`stage0` only ever compiles `src/mc.mc` and no function there has more than eight parameters.
The whole rule is in [../reference/objects.md](../reference/objects.md) § 4, asserted instruction
by instruction by `scripts/check-surface.sh`, and `tests/mc/080-twelve-params.mc` runs it on all
five targets.

---

## 4. The sysroot is one generated file

There is nothing to download. A Windows program does not link against a copy of `kernel32.dll`: it
links against an **import library**, an archive holding one thunk per exported name and no code
from the DLL at all. `scripts/sysroot-windows.sh` writes the list of names and builds
`kernel32.lib` from it with `llvm-dlltool` — no network, no Windows SDK:

```sh
make sysroot-windows              # build/sysroot/windows-aarch64/kernel32.lib
make sysroot-windows-x86_64       # build/sysroot/windows-x86_64/kernel32.lib
```

The same directory holds the two objects every link line carries, because they are also "everything
this link needs that is not the program":

```sh
make mcrt-windows                 # winstart.obj + mcrt.obj, arm64
make mcrt-windows-x86_64          # the same, x64
```

`scripts/link-windows.sh` is what puts them together; `MC_SYSROOT` overrides the directory.

```sh
scripts/link-windows.sh --arch aarch64 build/hello.exe build/hello.obj
```

which is

```
lld-link -machine:arm64 -subsystem:console -entry:mc_start -nodefaultlib \
         -out:build/hello.exe build/hello.obj \
         <sysroot>/winstart.obj <sysroot>/mcrt.obj <sysroot>/kernel32.lib
```

**The dash form is not a style choice.** Under Git Bash, MSYS rewrites an argument that looks like
a path, so a leading `/out:` becomes `C:/Program Files/Git/out:` before the linker sees it. Every
`lld-link` option in this repository is written with `-`, and the CI jobs also set
`MSYS2_ARG_CONV_EXCL='*'` as a second belt.

---

## 5. Cross-building the Windows compiler from macOS

The compiler for a Windows host is built by the compiler that is running, from the entry point
that names the Windows host layer:

```sh
make mc-windows                   # build/mc-windows-arm64.exe
make mc-windows-x86_64            # build/mc-windows-x86_64.exe
```

Both go through `mc build` with `src/mc.windows-<arch>.toml`, which compiles with the COFF backend
and links with `lld-link` — so a macOS machine with LLVM installed produces a runnable Windows
compiler in one command. Unlike the Linux pair this needs **no Docker at all**: the whole sysroot
is one generated `.lib` plus two objects `mc` compiles itself.

### The CI split: stop at the object

GitHub's Windows runners have `lld-link` and no `mc`, which is a chicken-and-egg: the compiler they
would need is the one being built. So the macOS job stops one step earlier —

```sh
make mc-windows-obj               # build/mc-windows-arm64.obj,   kind = "obj"
make mc-windows-x86_64-obj        # build/mc-windows-x86_64.obj
make mcrt-windows                 # and the sysroot for each
make mcrt-windows-x86_64
```

— and uploads the objects and the two sysroots as one artifact. The Windows job downloads it, runs
`scripts/link-windows.sh`, and from there it is a Windows machine with a compiler on it. The object
is byte for byte the one `src/mc.windows-<arch>.toml` writes on its way to the executable: same
entry, same backend, same compiler.

---

## 6. What the `.exe` suffix costs

Exactly one function and one variable. `mc build` writes a **taught compiler** from
`[compiler].out` and then *runs* it, and on Windows a file that is not called `*.exe` cannot be
launched at all — `CreateProcess` appends `.exe` when it searches, and a PE file without the
extension is not a program. So `host_exe_suffix()` joined the host interface (`""` on macOS and
Linux) and `drv_teach` appends it to the binary it links and to what it spawns. The generated
source keeps the bare name: `<out>.mc` is a source file on every host.

### Paths stay `/`-only

`path_norm` and `path_join` know one separator. Under Git Bash every path in an `mc.toml` and on
the command line is `/`-separated, and every Win32 file API accepts `/` as well as `\`, so nothing
had to change. Two gaps are **documented rather than fixed**:

* a drive-qualified path (`C:/x`) is classified as *relative*, because a path is absolute here only
  when it starts with `/`;
* `drv_mkdirs` therefore calls `mkdir("C:")` on the way down, which `CreateDirectoryA` rejects
  harmlessly.

Both are invisible for a project whose paths are relative to its `mc.toml`, which is every project
in this repository.

---

## 7. CRLF

The repository has a `.gitattributes` with `* -text`: never translate line endings. GitHub's
Windows images ship `core.autocrlf=true`, and this host **compiles `.mc` sources and runs shell
scripts straight out of the checkout**, where a `#!/bin/sh\r` is a hard failure. The M19/M20 jobs
survived without it because their runner only linked and ran prebuilt objects.

The compiler itself is not the fragile half: the lexer treats `\r` as whitespace, so a CRLF
checkout produces the same tokens and the same object and the golden is safe either way. The
scripts are the reason. The CI jobs set `git config --global core.autocrlf false` **before** the
checkout, for the case where `.gitattributes` has not been read yet.

---

## 8. `make check` on Windows

`uname -s` says `MINGW64_NT-...` under Git Bash, so the Makefile's host switch is a `findstring`.
`REF` and `MC` become `build/mc1w.exe` and `build/mc2w.exe` — the two stages of the bootstrap — and
`check` is the subset that can run here:

```
budget bootstrap-windows check-lex check-ast check-asm check-obj
check-bundle check-mc check-toml check-limits check-skipped
```

`bootstrap-windows` is the whole chain and the biggest part of it:

```
seed  src/mc_windows[_x86_64].mc -> build/mc1w.obj  -> link -> build/mc1w.exe
mc1w  the same source            -> build/mc2w.obj  -> link -> build/mc2w.exe
mc2w  the same source            -> build/mc3w.obj
cmp build/mc2w.obj build/mc3w.obj                   <- the fixed point
sha256 build/mc2w.obj vs tests/golden/mc2-windows-<arch>.sha256
build/mc2w.exe --host
scripts/test-windows.sh --arch <arch> --run-only    <- the suite, natively
build/mc2w.exe --backend=macho src/mc.mc == build/mc2.o   <- the cross proof
```

That last line is the proof that a Windows-hosted `mc` is the **same compiler**: the Mach-O object
it writes for `src/mc.mc` is byte for byte the one macOS writes for itself. It needs `build/mc2.o`,
which the macOS CI job uploads; without it the step says it was skipped and why.

`make check-skipped` prints one line per target that does **not** run here, with the reason —
`stage0`/`mc0` (the C seed emits Mach-O only), `bootstrap` (that is the macOS chain), `test-exe`
and `check-standalone` (the Mach-O direct-executable backend), `check-surface`, `check-build`,
`check-minimal`, the cross-compilation suites, the examples (macOS dylibs and `--exe`) and the
documentation and site targets.

---

## 9. Portable examples

Everything in `tests/*.mc` is portable to Windows as written except `032-svc.mc`, which enters the
Darwin kernel directly; on `windows/x86_64` the three tests whose `#opcode` words are AArch64
instructions are skipped too. `tests/windows/070-kernel32.mc`, `071-nested-args.mc` and
`072-six-params.mc` are the Windows-only cases, and `tests/mc/080-twelve-params.mc` runs the
stack-parameter rule here like everywhere else.

A program that wants the system layer writes

```mc
#include <sys_windows>
#include <io>
```

and links with `winstart.obj` and `kernel32.lib` and nothing else. `<sys_windows_host>` is the
compiler's own runtime and a program has no reason to include it — but it is bundled, so a
program that wants to spawn a process can.

---

## See also

* [90-linux-host.md](90-linux-host.md) — the same story for Linux, and where this shape comes from
* [50-cross-compile.md](50-cross-compile.md) — targeting Windows from another host
* [../bootstrap.md](../bootstrap.md) § The Windows chain — the fixed point in detail
* [../ci.md](../ci.md) — the two Windows host jobs and the five release assets
* [../reference/hooks.md](../reference/hooks.md) § 6 — the host interface
* [../reference/objects.md](../reference/objects.md) § 4 — the ABI, including parameters 9..12

## Two facts about the Windows runners

* **`uname -m` lies on Windows on ARM.** Git for Windows is an x64 program and runs emulated
  there, so `uname -m` answers `x86_64` on an ARM64 machine -- and so does the process's own
  `PROCESSOR_ARCHITECTURE`, with no `PROCESSOR_ARCHITEW6432` at all (measured on
  `windows-11-arm`). `scripts/host-arch.sh` therefore reads `RUNNER_ARCH` (GitHub Actions), then
  the SYSTEM environment in the registry, then the process environment; the Makefile's `HOSTARCH`
  and `scripts/bootstrap-windows.sh` go through it, and the CI jobs do not even rely on that: they
  pass `HOSTARCH=aarch64` / `--arch aarch64` explicitly. `MC_HOSTARCH` overrides everything.
* **`/tmp` is not a path the native `mc` can open.** The CI jobs set `MSYS2_ARG_CONV_EXCL='*'` so
  that MSYS never rewrites an `lld-link` option into a path, which also stops it from translating
  the `/tmp/...` directories `mktemp -d` hands the check scripts. The jobs export
  `TMPDIR=$(cygpath -m "$RUNNER_TEMP")` (`D:/a/_temp`), a form both the shell and `mc` accept.
* **The default stack is 1 MiB**, against 8 MiB on macOS and Linux. The compiler is built for the
  latter, so every `mc` executable is linked with `-stack:8388608` (`scripts/link-windows.sh` and the
  two `src/mc.windows-*.toml`).
