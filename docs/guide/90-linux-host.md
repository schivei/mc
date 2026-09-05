# `mc` on a Linux host

Until M37 `mc` was a macOS program that could *target* Linux. Now it is a Linux program too: the
same source, the same core, the same fixed point, hosted on `linux/aarch64` and `linux/x86_64`.
This page is the whole story from a bare Linux machine to `make check`.

The one thing that is not portable is the **seed**. `stage0/*.c` is 2848 lines of C that emit
Mach-O and only Mach-O — it is the frozen oracle every cross-check compares against, and porting
it would mean writing a second seed. So a Linux host does not start from `clang`; it starts from a
`mc` binary that already exists. That binary is either a published release asset or one
cross-built on macOS, and after one bootstrap the machine is self-sufficient.

---

## 1. In five commands

```sh
git clone https://github.com/schivei/mc && cd mc
sudo apt-get install -y lld musl-dev musl-tools     # or: apk add lld musl-dev
export MC_SYSROOT=/usr/lib/aarch64-linux-musl       # x86_64-linux-musl on x86-64
scripts/bootstrap-linux.sh                          # fetches the seed, reaches the fixed point
make check                                          # the Linux subset
```

`scripts/bootstrap-linux.sh` with no argument looks for `build/mc-linux-<target>` first (a
cross-built compiler, § 4) and otherwise downloads a release asset:

```
https://github.com/schivei/mc/releases/download/v<VER>/mc-<VER>-linux-<arch>.tar.gz
https://github.com/schivei/mc/releases/download/v<VER>/mc-<VER>-linux-<arch>.tar.gz.sha256
```

with `<arch>` = `arm64` or `x86_64`. With the GitHub CLI on `PATH` it uses `gh release download`,
which follows the latest release by itself; otherwise `curl` fetches both files and
`MC_SEED_VERSION` says which version. **The tarball is unpacked only after its SHA-256 matches
the `.sha256` file**, and a mismatch stops the script.

You can also hand it a binary you already trust:

```sh
scripts/bootstrap-linux.sh /usr/local/bin/mc
```

The seed has to be a compiler *for this host*, not merely one that runs here — the script asks it:

```sh
$ mc --host
os linux
arch aarch64
sys sys_linux
```

and refuses anything whose answer is not `linux/<this machine>`.

---

## 2. What the host layer is

`src/core.mc` is host-neutral. Everything that depends on the operating system the **compiler
itself runs on** lives in one small file that the entry point includes before the core:

| entry point | host file | what it is |
|---|---|---|
| `src/mc.mc` | `src/host_macos.mc` | macOS, arm64 |
| `src/mc_linux.mc` | `src/host_linux_aarch64.mc` | Linux, aarch64 |
| `src/mc_linux_x86_64.mc` | `src/host_linux_x86_64.mc` | Linux, x86-64 |

The two Linux files are three lines each; the operating-system half they share is
`src/host_linux.mc`. Between them the host layer answers seven questions:

| function | macOS | Linux |
|---|---|---|
| `host_os()` | `"macos"` | `"linux"` |
| `host_arch()` | `"aarch64"` | `"aarch64"` / `"x86_64"` |
| `host_machine()` | `"arm64"` | `"arm64"` / `"x86_64"` |
| `host_sys()` | `"sys"` | `"sys_linux"` |
| `host_include()` | `"mc/host_macos"` | `"mc/host_linux_aarch64"` / `…_x86_64` |
| `host_environ()` | `ld64(_NSGetEnviron())` | the `envp` `main` was called with |
| `host_has_sdk()` | 1 (`xcrun` exists) | 0 |

plus `O_CREAT`/`O_TRUNC` (0x200/0x400 on macOS, 0x40/0x200 on Linux) and the `posix_spawnp`,
`waitpid`, `mkdir` and `unlink` declarations — identical on both, because musl has them under the
same names.

`_NSGetEnviron` was the single hard blocker before M37: it is a libSystem routine, and the driver
needed it to hand an environment to `posix_spawnp`. On Linux the environment arrives the way the C
runtime has always passed it — musl's `crt1.o` calls `main(argc, argv, envp)` — so `main` took a
third parameter and hands it to `host_init()` before anything else runs.

### What the host layer decides

* **The default target.** An `mc.toml` with no `[target]` targets the host. On macOS that is the
  `macos`/`aarch64` the driver used to hardcode; on Linux it is that machine's own pair.
* **The default backend.** `mc x.mc -o x.o` writes an object for the host: Mach-O on macOS, ELF on
  Linux, each with the host's architecture. `--backend=` still overrides.
* **The machine the dumps start with.** `--dump-asm` with no `--machine=` lowers for the host.
* **The taught compiler.** `mc build` writes `#include <mc/host>` above `#include <mc/core>` in the
  source it generates, and `<mc/host>` is the host file of the compiler that is *running* — so the
  same `mc.toml` teaches a macOS compiler on macOS and a Linux one on Linux, with nothing in the
  project naming a system.

### The arena

`src/arena.mc` stayed host-neutral, which is what lets `src/lexdump.mc`, `src/tomldump.mc`,
`tools/bundle.mc` and `site/gen/main.mc` be built for either host with no host file at all.
`open`, `read`, `write`, `close`, `creat`, `_exit` and `mmap` exist under the same names in
libSystem and in musl; `O_RDONLY` and `O_WRONLY` are 0 and 1 everywhere. The one value that
differed is the anonymous-mapping flag, and it is written as a single number valid on both
kernels:

```
0x0002  MAP_PRIVATE     both
0x0020  MAP_RENAME      macOS: defined, unused        Linux: MAP_ANONYMOUS
0x1000  MAP_ANON        macOS                          Linux: MAP_EXECUTABLE, ignored since 2.6
```

`0x1022` is therefore `MAP_PRIVATE|MAP_ANON` on macOS and `MAP_PRIVATE|MAP_ANONYMOUS` on Linux,
each with one ignored bit. Both were measured: the mapping succeeds and is writable.

---

## 3. The direct executable (M42)

macOS has had `--exe` since M11: `mc` lays out the segments, resolves the relocations, writes the
bind opcodes and signs the result itself. **Since M42 Linux has the same thing** — `src/backend_elf_exe.mc`,
a dynamic ELF64 `ET_EXEC` with no linker, no crt object and no sysroot
([../reference/objects.md § 8b](../reference/objects.md#8b-the-elf-executable-elf-exe-and-elf-exe-x86_64)):

```sh
mc --exe hello.mc -o hello
./hello
```

`--exe` is not a Mach-O flag any more. It resolves the **host's** executable backend through the
same `target()` registry the default object backend comes from, so on a Linux host it means
`elf-exe` or `elf-exe-x86_64`, and on macOS it still means `macho-exe`. `make check` on a Linux
host runs `test-exe`, which is the whole `tests/*.mc` corpus through it.

**Which libc it asks for is a key, not a guess.** `PT_INTERP` holds an absolute path, and the
writer's default is musl's `/lib/ld-musl-<arch>.so.1`. That default is a constant on purpose — a
probe of the machine would make the same source produce different bytes on two hosts — so on a
**glibc** host (Debian, Ubuntu, Fedora, Arch) `mc --exe` alone writes a binary this machine cannot
start. Saying so is one word, and it is the same word on both roads:

```
$ mc --exe --libc=gnu hello.mc -o hello
```

```toml
[target]
os   = "linux"
arch = "aarch64"
libc = "gnu"                            # the family, not a soname
```

`scripts/test-exe.sh`, `scripts/build-exe.sh` and `scripts/bootstrap-linux.sh` pass that flag by
themselves when the loader on the disk says the host is glibc — the probing is the script's, never
the compiler's — and each says which libc it asked for.

Three consequences worth knowing:

* **`[linker]` is no longer required** for `os = "linux"`. `mc build` with `kind = "exe"` and no
  `[linker]` writes the binary. The section is still supported and is still the only route to a
  **static** libc link, which is what needs a sysroot.
* **A taught compiler is built the same way.** `mc build` builds the compiler for the *host*, not
  for `[target]` — it has to run here, right after it is written — and the host now has a
  direct-executable backend, so a project that teaches the compiler on a Linux host needs no
  `[linker]` at all.
* **The bootstrap chain still links.** `scripts/bootstrap-linux.sh` uses `scripts/link-linux.sh`
  for `mc1l` and `mc2l` on purpose: the SEED may be a published release older than M42, and the
  chain has to work with whatever seed it is handed.

To cross-compile *to macOS* from a Linux host, name the backend: `--backend=macho-exe` writes the
signed Mach-O executable, which will not run where it was built.

---

## 4. Cross-building the Linux compiler from macOS

Two configs in `src/` do it, and neither has a `[compiler]` section — this is the plain compiler:

```sh
build/mc1 build src --config src/mc.linux-aarch64.toml       # -> build/mc-linux-arm64
build/mc1 build src --config src/mc.linux-x86_64.toml        # -> build/mc-linux-x86_64
```

or `make mc-linux` / `make mc-linux-x86_64`. Since M42 neither needs a sysroot, a linker or
Docker: both configs dropped their `[linker]` and `[sysroot]` and `mc build` writes the **dynamic
ELF64 executable** itself, around 880 KB, asking for musl's loader.

Two more configs write the same compiler for a **glibc** host — the same files with
`[target].libc = "gnu"` added and nothing else changed:

```sh
build/mc1 build src --config src/mc.linux-aarch64-gnu.toml   # -> build/mc-linux-arm64-gnu
build/mc1 build src --config src/mc.linux-x86_64-gnu.toml    # -> build/mc-linux-x86_64-gnu
```

### Without Docker: stop at the object

The sysroot step is the one that needs Docker — `scripts/sysroot-linux.sh` copies
`crt1.o crti.o crtn.o libc.a` out of an `alpine:3` container — and the link step is the one that
needs `ld.lld`. A machine with neither can still do the compiler's half, because `kind = "obj"`
makes `mc build` compile and return before either is consulted:

```sh
make mc-linux-obj             # build/mc-linux-arm64.o    ELF64 relocatable, aarch64
make mc-linux-x86_64-obj      # build/mc-linux-x86_64.o   ELF64 relocatable, x86-64
```

`src/mc.linux-aarch64-obj.toml` and `src/mc.linux-x86_64-obj.toml` are the two configs, and they
differ from their siblings only in `kind` and in having no `[linker]` and no `[sysroot]`. The
object then travels to a Linux machine, which links it with its own musl:

```sh
MC_SYSROOT=/usr/lib/aarch64-linux-musl \
    scripts/link-linux.sh build/mc-linux-arm64 build/mc-linux-arm64.o
chmod 755 build/mc-linux-arm64
build/mc-linux-arm64 --host          # os linux / arch aarch64 / sys sys_linux
```

With the four files already in `MC_SYSROOT`, `scripts/link-linux.sh` runs `ld.lld` and nothing
else; it only falls back to `scripts/sysroot-linux.sh` when one of them is missing. The object is
byte for byte the one the executable config writes on its way to the link step.

This is exactly what CI does — GitHub's macOS runners have no Docker, so the compiling job ships
objects and the two Linux jobs link them ([../ci.md](../ci.md) § M37). Locally, where Docker is
usually there, `make mc-linux` is the shorter road.

`make check-linux-host` is the proof, run from macOS. It runs **two cells per architecture**, one
per libc, because a dynamic executable names its loader by path and the two libcs are two
different systems to be hosted on. `--arch` and `--libc` narrow it.

**musl**, inside `docker run --platform linux/<arch> alpine:3`:

1. `make check SEED=build/mc-linux-<target>`, which starts with `scripts/bootstrap-linux.sh` —
   seed → `mc1l` → `mc2l` → `mc3l`, `cmp mc2l.o mc3l.o`, the golden — and then runs the Linux
   cross-check subset;
2. the **cross proof**: the Linux-hosted compiler compiles `src/mc.mc`, a macOS program, with
   `--backend=macho` (its *default* backend is the host's, which is ELF), and the Mach-O object it
   writes is compared byte for byte with the one macOS wrote for itself (`build/mc2.o`). They are
   equal. That is the strongest statement available that hosting changed
   nothing about the compiler.

**glibc**, inside `docker run --platform linux/<arch> ubuntu:latest` — the newest Ubuntu, this
repository's glibc baseline. The seed is `build/mc-linux-<target>-gnu`, and **nothing is installed
in the container**: no `make`, no `lld`, no `musl-dev`.

1. `scripts/bootstrap-linux.sh --libc glibc <seed>` — the same four stages, with every executable
   written by the previous compiler through `mc build` instead of by a linker, then the whole
   suite through `scripts/test-linux.sh --exe --libc glibc`, natively;
2. the same cross proof.

The golden is the same file in both cells: an ELF object records no interpreter, so the musl chain
and the glibc chain have to write the same `mc2l.o`, and they do.

---

## 5. `make check` on Linux

The Makefile switches on `uname -s`. On Linux `check` is:

```
budget bootstrap-linux check-lex check-ast check-asm check-obj
check-bundle check-mc test-exe check-toml check-sysroots check-limits check-skipped
```

`test-exe` joined the list at M42: `--exe` on a Linux host writes a dynamic ELF64 executable, so
the whole suite goes through it natively, with no linker. On a **glibc** host the script reaches
the same backend through `mc build` with the two per-libc keys, and prints which road it took —
`mc --exe`'s default interpreter is musl's and cannot be told otherwise from a command line.

`bootstrap-linux` ends by running the whole `tests/*.mc` suite with the compiler it just
bootstrapped (`scripts/test-linux.sh`, native mode — no Docker, no emulation), which is why `test`
is not listed a second time; `make test` still runs it on its own.

Three cross-checks report a little differently on Linux, and each says so in its own output:

* `check-obj` compares ELF objects for *this* machine, so a test carrying `// skip-linux:` or
  `// skip-<arch>:` — the headers `scripts/test-linux.sh` already reads — has nothing to compare
  and is printed as `skip NAME (reason)`: 31/31 on aarch64 (`032-svc`), 29/29 on x86_64
  (`032-svc`, `031-opcode`, `033-reloc`, whose `#opcode` words are AArch64).
* `check-limits`' last row measures the *seed's* arena as the max RSS of a real `build/mc0` run.
  There is no `mc0` here, so the row says
  `SKIPPED (no build/mc0 on this host: the C seed is macOS-only)`; the macOS job guards that
  ceiling.
* `check-mc` runs the four `tests/mc/*.mc` cases; the two that assert `build/mc0` *rejects*
  `#embed` and `#include <name>` need the seed and are not run.

Two more mean something weaker here, and the Makefile says so in a comment:
`check-lex` and `check-ast` compare the compiled-in lexer/parser against the same lexer/parser
built as its own program. On macOS the other side is `mc0`, the frozen C seed — an oracle. On
Linux there is no C seed, so it is a build-and-run gate rather than a cross-check.

`check-skipped` prints one line per macOS-only target with the reason:

```
bootstrap: SKIPPED (macOS chain: mc0 -> mc1 -> mc2 -> mc3; bootstrap-linux is the Linux one)
check-standalone: SKIPPED (its criterion is a signed Mach-O executable)
check-surface: SKIPPED (its cases build taught compilers with --exe)
check-build: SKIPPED (tests/proj targets macos/aarch64 through ld)
check-minimal: SKIPPED (its ceilings are measured on the macOS backends)
check-examples/check-lang/check-conc/check-desktop: SKIPPED (macOS dylibs and --exe)
check-docs/site/check-site: SKIPPED (their samples are built with --exe)
```

Those are honest gaps, not silent ones. `check-lang`, `check-conc` and `check-examples` all build
taught compilers and run them, and each example currently pins `os = "macos"`; `examples/conc` and
`examples/api` ship a `mc.linux.toml` (§ 6) that a Linux machine can drive by hand, but neither is
in `make check` yet.

---

## 6. Portable examples

`examples/conc` shows the pattern for a program whose *runtime* is per-system. The platform layer
— `pthread_*`, the semaphore, the LSE probe — moved out of `lib/` into two directories:

```
examples/conc/lib/macos/thread.mc     libdispatch semaphores, macOS pthread initializers
examples/conc/lib/linux/thread.mc     sem_init/sem_wait/sem_post, all-zero initializers, getauxval
```

`lib/rt.mc` writes `#include "thread.mc"` and there is no `thread.mc` next to it any more, so the
`#include` roots decide: `[include] paths = ["lib", "lib/macos"]` in `mc.toml`, `["lib",
"lib/linux"]` in `mc.linux.toml`. For the single-file CLI — which has no `mc.toml` to read — the
same root comes from the new flag:

```sh
mc-conc --include=examples/conc/lib/macos --exe tests/01-await-chain.lx -o prog
```

The three counting-semaphore functions `gate_new`/`gate_wait`/`gate_post` moved into the platform
file with the declarations they belong to: macOS stubs POSIX unnamed semaphores out (`sem_init`
returns `ENOSYS`) and libdispatch does not exist on Linux, so it is the one primitive with no
portable spelling.

`examples/api/mc.linux.toml` links SQLite statically. It is **not** exercised in CI: the musl
sysroot is `apk add musl-dev`, four files, with no SQLite in it. A machine that wants to run it
needs `apk add sqlite-static` (or the distribution's `libsqlite3.a`) next to the crt objects.

---

## 7. Working in the cloud

The practical shape of this milestone: a cloud Linux box can now do everything except run the C
seed and the Mach-O-only checks. Clone, `scripts/bootstrap-linux.sh`, `make check`, edit,
bootstrap again. The macOS machine stays the place where `mc0` proves the .mc compiler still
agrees with the frozen C oracle (`check-lex`, `check-ast`, `check-asm`, `check-obj` against
`build/mc0`), and CI runs both: `make check (macOS arm64)` plus `mc on linux/arm64 host` and
`mc on linux/x86_64 host` — the macOS job cross-compiling the objects, each Linux job linking its
own and bootstrapping it on real hardware, with no Docker anywhere in CI (see
[../ci.md](../ci.md) § M37).

---

Next: [../bootstrap.md](../bootstrap.md) § The Linux chain for the chain itself, and
[../build.md](../build.md) for `mc.toml`.
