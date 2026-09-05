# `mc sandbox` — compile and run an arbitrary program in isolation

**Status: step B.** The box exists and runs: the namespaces, the mount tree, `pivot_root`, the
caps, the steps, the wall clock and the report. What is **not** here is step C — Landlock and the
seccomp filter with `SECCOMP_RET_USER_NOTIF`, which are what turn a kill into
`refused: open /etc/shadow`. So exit code **125** is defined and never produced yet, and a program
that reaches for something outside the box is stopped by the *mount tree*, the *network namespace*
and the *rlimits* rather than named: `/etc/shadow` answers `ENOENT` because there is no `/etc`,
and a connect answers `ENETUNREACH` because the network namespace is empty. Every section below
says which of the two it describes, and every measured number gives the host it came from.

The design is `docs/specs/M43.md`. This page is the reference.

---

## What is not isolated

**The kernel.** A program in the box talks to the *host's own Linux kernel* through the fifteen or
so system calls its profile allows, and a bug in one of those — in `openat`, in `mmap`, in
`write` — is not stopped by anything here. Namespaces, Landlock, seccomp and rlimits are all
kernel features enforcing kernel policy in the same kernel; there is no second implementation
between the program and the machine. That is exactly the residual gVisor's user-space kernel and
Firecracker's microVM exist to remove, at 50 MB and a Go runtime or at a guest kernel and
`/dev/kvm`, and neither is used here.

For the project's own tests — fuzz inputs, `--exe` binaries, examples nobody audited — that
residual is accepted, and it is written down rather than papered over. For anything hostile and
public, the answer is policy: a disposable machine that holds nothing, snapshotted, rebuilt from
a script.

**The process cap, when P is root.** `RLIMIT_NPROC` is a real wall for an ordinary user —
measured: at 0 the kernel refuses the *first* `clone` with `EAGAIN`, for a plain `fork` and for
the `clone3(CLONE_VM|CLONE_VFORK)` behind `posix_spawn` alike, and `tests/sandbox/forkbomb.mc`
prints `forked 0`. Started by root it prints `forked 200`, its own ceiling: `copy_process` skips
the check outright for `INIT_USER`, and root's box is mapped `0 0 65536`. Nothing escapes either
way — the children are inside the pid namespace and die with it, and the host's process count is
the same before and after — but the *count* is bounded only by the machine. Two answers, and the
second is the real one: run `mc sandbox` as an ordinary user, and wait for step C's seccomp
profile, which refuses `clone` before it is asked.

Three smaller things are also outside the wall, and each is a deliberate choice:

* **the compiler itself** runs inside the box for `mc sandbox run`, under the compile profile —
  so a malicious source is contained the same way a malicious program is, but a bug in `mc` that
  is reachable from a source file is reachable there too;
* **the diagnostic read of a path argument** (`openat` under `SECCOMP_RET_USER_NOTIF`) is a read
  of the program's own memory and is racy when threads are allowed. Enforcement never depends on
  it: the mount tree and Landlock are what refuse, and the notification only supplies the name
  that goes in the report;
* **timing** is not isolated at all. The box has no clock policy; a program can measure how long
  things take and so can anything sharing the machine.

---

## Hosts

| host | `mc sandbox run\|exec\|check` |
|---|---|
| Linux, unprivileged | the whole thing, through a user namespace; the box's uid 0 **is** the caller. This is the way to run it — see the AppArmor section below |
| Linux, root | the same code path, with the identity map `0 0 65536`. Everything works and one wall is missing: `RLIMIT_NPROC` does not bind for root (§ What is not isolated) |
| macOS | refuses, and prints the Lima command to run instead, exit **126** |
| Windows | refuses, exit **126** |

Measured, both privileges, on Ubuntu 26.04 / kernel 7.0.0-30 — `scripts/test-sandbox.sh`:

| cell | isolation | the suite | a project | overhead per box |
|---|---|---|---|---|
| linux/aarch64, root (Lima `mc-k7`) | 8/8 | 31/31 (1 skipped) | ok | 1.37 ms |
| linux/aarch64, unprivileged | 8/8 | 31/31 (1 skipped) | ok | 1.43 ms |
| linux/x86_64, root (the VPS) | 8/8 | 29/29 (3 skipped) | ok | 4.12 ms |
| linux/x86_64, unprivileged | 8/8 | 29/29 (3 skipped) | ok | 4.98 ms |
| linux/aarch64, `alpine:3` under `docker run --privileged` (kernel 6.12.76-linuxkit, musl) | 8/8 | 31/31 | ok | not measurable (busybox `date` has no `%N`) |

The two unprivileged cells need `kernel.apparmor_restrict_unprivileged_userns=0`; with the stock 1
they print the honest refusal instead, which is itself part of the run.

macOS gets no sandbox on purpose. `sandbox-exec(1)`/`sandbox_init(3)` still exist in macOS 26 but
have been documented as deprecated since 10.8, have no CPU, wall-clock or memory model beyond
`setrlimit`, and cannot name a refusal; `setrlimit` on its own gives caps without isolation.
Neither is worth a line the Mac would have to keep true. What `mc` prints instead is the exact
command:

```
mc: the sandbox is a Linux feature; on this Mac: limactl shell mc-k7 build/mc-linux-arm64 sandbox run PATH (docs/build.md § Lima)
```

Windows prints `mc: the sandbox is a Linux feature; this host is: windows`. Job objects and
AppContainers are a different milestone with no consumer.

---

## `mc sandbox check`

Six lines on stdout, one per capability, and exit 0 only when all five the box needs are there.
It is the guard `make check` and the CI leg consult, in the `test-linux: SKIPPED (...)` style.

```
kernel: 7.0.0-30-generic
userns: ok
landlock: abi 8
seccomp: notif ok
overlay: ok
pidfd: ok
```

| line | how it is measured | values |
|---|---|---|
| `kernel` | `uname(2)`, the `release` field | the string, or `unknown` |
| `userns` | in a forked child: `unshare(CLONE_NEWUSER\|NEWNS\|NEWPID\|NEWNET\|NEWIPC\|NEWUTS)`, then the box's own first mount, `mount(0, "/", 0, MS_PRIVATE\|MS_REC, 0)` | `ok`, `restricted (apparmor)`, `EPERM`, `EACCES`, `errno N`, `cannot fork`, `cannot wait`, `child killed` |
| `landlock` | `landlock_create_ruleset(0, 0, LANDLOCK_CREATE_RULESET_VERSION)`, which creates nothing and returns the ABI | `abi N`, `abi N (below the minimum 4)`, `absent` |
| `seccomp` | `seccomp(SECCOMP_GET_ACTION_AVAIL, 0, &SECCOMP_RET_USER_NOTIF)`, which installs nothing | `notif ok`, `notif absent` |
| `overlay` | `overlay` appears in `/proc/filesystems` | `ok`, `not loaded (modprobe overlay)`, `unknown` |
| `pidfd` | `pidfd_open(getpid(), 0)`, then `close` | `ok`, `absent` |

Two of those rows are not what the design first assumed, and both differences were measured.

**`userns` is two stages, not one.** The design expected `unshare(CLONE_NEWUSER)` to fail with
`EPERM` for an unprivileged unconfined process when
`kernel.apparmor_restrict_unprivileged_userns` is 1. On Ubuntu 26.04 with kernel `7.0.0-30`
(measured on both architectures) **it succeeds**. Since Ubuntu 24.04 the kernel does not refuse
the namespace: it moves the process into the `unprivileged_userns` AppArmor profile
(`/etc/apparmor.d/unprivileged_userns`), which grants `userns`, `file`, `network`, `signal`,
`unix` and `ptrace`, denies every capability, and has no `mount` rule at all. The audit record is

```
apparmor="AUDIT" operation="userns_create" class="namespace"
  info="Userns create - transitioning profile" profile="unconfined"
  target="unprivileged_userns"
```

and the first thing that then fails is the box's first mount:

```
mount(0, "/", 0, MS_PRIVATE|MS_REC, 0)   ->  -13  EACCES   (no mount rule in the profile)
mount("tmpfs", "/tmp", "tmpfs", 0, ...)  ->  -13  EACCES
sethostname("sandbox", 7)                ->   -1  EPERM    (audit deny capability)
```

A probe that stopped at the `unshare` would print `ok` on a host where nothing works, so the
second stage is that mount, run inside the child's own private mount namespace where it changes
nothing outside. When it fails and the sysctl is 1, the answer is `restricted (apparmor)`.

**`overlay` distinguishes "not loaded" from "absent".** `/proc/filesystems` lists the filesystems
the kernel has *registered*, and a module that is present on disk but never loaded is not among
them. Measured: on the Lima oracle, where Docker had already loaded it, the line reads `ok`; on a
VPS running no container engine, it reads `not loaded (modprobe overlay)` while
`/lib/modules/7.0.0-30-generic/kernel/fs/overlayfs/overlay.ko.zst` is right there. Root would
autoload it on the first `mount -t overlay` (the autoload needs `CAP_SYS_ADMIN` in the *init*
user namespace, which the box does not have), so the honest verdict is "not now, and here is the
one command that fixes it".

### The AppArmor restriction

On Ubuntu 23.10 and later, `kernel.apparmor_restrict_unprivileged_userns` is 1 by default. As
shown above, that does not stop an unprivileged process from *creating* namespaces; it stops it
from doing anything with them. Two ways out, both for the unprivileged path only:

```
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

or an AppArmor profile for the `mc` binary that grants `userns,` and `mount,`. Running as root is
not a third way out: it is a different threat model, and the design does not require it.

Neither is applied by anything in this repository. `mc sandbox check` names the condition, and the
CI job runs both configurations so that the fact cannot be forgotten by a green build.

---

## The box

Four processes, and the fourth is not in the design's drawing — the kernel put it there.

```
P  mc, on the host, host uid    parses the command line, resolves /proc/self/exe, opens the
                                pipes, forks I, writes I's uid/gid maps, supervises with ppoll,
                                enforces the wall clock, reaps, prints the report, exits.
I  the box                      unshare(NEWUSER|NEWNS|NEWPID|NEWNET|NEWIPC|NEWUTS); waits for
                                the maps; builds the tree; pivot_root; sethostname; the three
                                inheritable caps; then forks J and waits.
J  the steps, pid 1             the first child of I is pid 1 of the new pid namespace. It runs
                                one child per step and reports each over the status pipe. It is
                                what P kills for the wall clock.
C  one step                     closes every inherited descriptor, asks for no_new_privs, reads
                                one sync byte, sets the three per-step caps, execve.
```

**Why J exists.** A pid namespace dies with its init, so the compile step cannot *be* pid 1 —
once it exits, the kernel refuses to put the run step in the same namespace. The obvious repair,
one fresh namespace per step, is not available either: a second `unshare(CLONE_NEWPID)` answers
**EINVAL**, because `copy_pid_ns()` refuses when the caller's *active* pid namespace is no longer
the one its children would join, which is exactly the state the first unshare leaves. So one child
of I is pid 1 for the whole box and runs the steps underneath it. `SIGKILL` to it from P takes
every process in the namespace with it — that is the wall-clock kill and it is what makes a fork
bomb the box's own problem and nobody else's.

### The tree

In order, all inside I's private mount namespace, the first mount being `MS_PRIVATE|MS_REC` on
`/` so that nothing propagates back:

| path in the box | source | how |
|---|---|---|
| `/` | a tmpfs, `size=<--out>m,mode=755`, `MS_NOSUID\|MS_NODEV` | mounted on a fresh `/tmp/.mc-box<pid>`, which P removes afterwards — it is the only thing the sandbox ever writes outside the box, and it is empty |
| `/mc` | `readlink("/proc/self/exe")`, taken by P before any unshare | bind of a *file* onto an empty file, then remounted read-only |
| `/src` | the source's directory, or `--root DIR` | overlayfs: `lowerdir=DIR`, `upperdir` and `workdir` on the box tmpfs, `userxattr` |
| `/out` | the box tmpfs | where the compiler writes when there is no overlay (below) |
| `/ro0`, `/ro1`, … | each `--ro DIR`, in the order given | bind + remount read-only |
| `/lib`, `/lib64`, `/usr/lib` | the host's, when they exist | bind + remount read-only, so an M42 dynamic binary finds its loader and its libc |
| everything else | — | does not exist: no `/proc`, no `/dev`, no `/etc`, no `/tmp`, no `/home` |

Then `pivot_root(".", ".old")` from inside the new root, `umount2("/.old", MNT_DETACH)`,
`sethostname("sandbox")` and `chdir` to `/src` or to `--cwd`. The environment is three entries and
nothing else: `HOME=/src`, `PATH=/`, the terminator.

`userxattr` is not decoration. An overlay mounted from a user namespace cannot set
`trusted.overlay.*` xattrs — that needs `CAP_SYS_ADMIN` in the *init* namespace, which nobody
here has, root included, because `unshare(CLONE_NEWUSER)` drops it — so the kernel has to be told
to use the `user.overlay.*` names. A kernel that predates the option answers `EINVAL` and the
option is dropped and the mount tried again.

**The overlay road, per host.** `overlayfs` was the design's risk 3, on the suspicion that Lima's
`virtiofs` would refuse it. Measured: it does not. The overlay mounts on **both** hosts —
`virtiofs` under Lima and `ext4` on the VPS — for root and unprivileged alike, and the fallback
below has not been reached by any cell of `scripts/test-sandbox.sh`. It exists anyway, because a
lower filesystem that refuses is a `-EINVAL` away: `/src` becomes a read-only bind, `/out` a
writable directory on the box tmpfs, the compiler writes there, and the report says so. A
*project* cannot be built that way (`mc build` writes inside its own tree) and says so.

### The maps

Who the box is, and the one place root and unprivileged differ. Two kernel answers shaped this,
in this order:

1. `0 65534 1` **alone** — the design's "root inside is nobody outside" — leaves the *caller*
   unmapped: outer uid 0 has no inner number, the box's fsuid becomes the overflow uid, and every
   file it creates answers **EOVERFLOW**. It was the box's very first `mkdir`.
2. `0 65534 1` plus `1 0 1` and a `setuid(0)` fixes that and fails the next test. An overlay
   copy-up into a directory the *lower* layer owns needs permission on that directory, and a tree
   owned by outer 0 is inner 1 with mode 755 — not the box's — so `mc --exe` inside the box
   answered `cannot create: /src/tests/061-pass` on the x86_64 VPS, where the tree belongs to
   root. `CAP_DAC_OVERRIDE` does not help: `capable_wrt_inode_uidgid()` requires the inode's owner
   to be mapped in the namespace asking.

So the maps are:

| P is | `uid_map` and `gid_map` | the box is |
|---|---|---|
| an ordinary user | `0 <uid> 1` — the only line the kernel accepts | uid 0 inside, that user outside, with that user's reach |
| root | `0 0 65536` | root inside and root outside, able to read and write any tree its caller could |

`/proc/<I>/setgroups` is written `deny` first, which the unprivileged `gid_map` requires. What
keeps the root row from being a hole is the tree itself: everything mounted from the host is
read-only, and the only writable filesystem in the box is a tmpfs that dies with it.

### The caps

`RLIMIT_CPU`, `RLIMIT_FSIZE` and `RLIMIT_CORE` are set by I and inherited; `RLIMIT_AS`,
`RLIMIT_STACK` and `RLIMIT_NPROC` are set by C, immediately before `execve`. That split is not
style: `RLIMIT_AS` applies to the process that sets it and I is a fork of `mc` carrying its own
arena, and `RLIMIT_NPROC` is checked by `fork` and I still has to fork the steps.

| cap | value | what it is |
|---|---|---|
| `RLIMIT_CPU` | `--time`, soft = hard | the CPU wall. The kernel sends SIGXCPU at the soft limit and SIGKILL at the hard one; with them equal, SIGKILL is what arrives |
| `RLIMIT_AS` | `--mem` MiB | the memory wall, and the kernel's own: no capability bypasses it |
| `RLIMIT_FSIZE` | `--out` MiB | with the tmpfs `size=`, what the program may write |
| `RLIMIT_NOFILE` | 32 | |
| `RLIMIT_CORE` | 0 | |
| `RLIMIT_STACK` | 8 MiB | |
| `RLIMIT_NPROC` | 0, or 64 with `--allow=threads`, or **16 for the compile step** | the process wall |

The compile step's 16 is not a loophole: `mc build` *writes* a compiler and then runs it, so a
project needs a handful of processes to build at all. Sixteen is more than the three execs a
taught build takes and far less than a bomb.

### The report

One line per event, each starting with `sandbox: `, written when the box is gone so that it can
never interleave with the program's own output — the program's stdout and stderr *are* P's, passed
straight through. Fixed vocabulary, no pid, no timing, no host path; the only variable text is a
number the invocation itself chose.

```
sandbox: compile: exit 0
sandbox: exit 42
sandbox: killed: cpu limit (2 s)
sandbox: killed: wall clock (5 s)
sandbox: killed: signal 11 (SIGSEGV)
sandbox: cannot mount /: EACCES (apparmor restricts unprivileged user namespaces: see docs/reference/sandbox.md § Hosts)
```

| line | when |
|---|---|
| `compile: exit N` | the compile step ended on its own; always printed, including `exit 0` |
| `exit N` | the run step ended on its own. `mc sandbox` exits with that same N |
| `killed: cpu limit (S s)` | a signal ended a step that had spent its whole `--time`. Exit **124** |
| `killed: wall clock (S s)` | `--wall` expired and P killed the box. Exit **124** |
| `killed: signal N (NAME)` | any other signal. Exit **128 + N** |
| `cannot <site>: ERRNO` | the box could not be built. Exit **126** |

`--report FILE` writes the same text to a file **as well as** to stderr (the design said "instead
of"; both is what a script needs, so that it can compare two runs byte for byte and a person still
sees the diagnostic). Two runs of the same case produce byte-identical files — that is asserted by
`scripts/test-sandbox.sh`, along with "no digit sequence of four or more" so that a pid or a time
cannot creep in.

The `cannot` sites are: `unshare`, `mount /`, `the box tmpfs`, `create a directory in the box`,
`bind the compiler at /mc`, `mount /src`, `mount a --ro directory`, `bind the host libraries`,
`pivot_root`, `detach the old root`, `sethostname`, `chdir`, `set a resource limit`,
`fork a step`, `create a pipe`, `write the uid map`, `execute the step`, `open the --stdin file`,
`build a project without an overlay`.

### The steps

| what `run` was given | compile step | run step |
|---|---|---|
| `prog.mc` | `/mc --exe /src/prog.mc -o /src/prog` (`--libc=gnu` when this host's loader is glibc's) | `/src/prog ARGS` |
| `prog.mc` with a `--dump-*` | `/mc --dump-asm /src/prog.mc` | none: the dump **is** the output |
| a directory holding `mc.toml` | `/mc build /src` (`--config` when given) | `/src/<[project].out> ARGS`, when `kind = "exe"` |
| `mc sandbox exec BIN` | none | `/src/BIN ARGS` |

A compile failure ends the box with that exit code and no run step, and the report says
`compile: exit 1`.

Two options widen `/src` beyond the source's own directory, and both were needed by this
repository's own corpus:

* `--root DIR` makes `/src` the tree `DIR` names and compiles `PATH` inside it. Half of
  `tests/*.mc` includes `../lib/sys.mc` and `025-linecount` opens its own source by a path
  relative to the repository root; with `--root .` both resolve inside the box exactly as they do
  outside it, and nothing in `tests/` had to change.
* `--config NAME` names the project file to build, relative to the project directory, and
  `[project].out` stays relative to *that file's* directory. `mc sandbox run --config
  examples/lang/mc.linux-gnu.toml .` is how a project that includes files from outside its own
  directory is built.

---

## The system-call shim

Every system call the sandbox issues goes through one host-layer function
([hooks.md](hooks.md) § 6):

```c
i64 host_syscall6(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f);
```

with the kernel's own result — a small negative value is `-errno`, exactly as `lib/sys_linux.mc`
documents. No libc wrapper is used, for two reasons: `prctl`, `syscall` and `clone` are variadic
in musl and in glibc and this project refuses a variadic `extern`, and `seccomp`, `landlock_*`,
`pidfd_*` and `close_range` have no wrapper at all.

`n` is a number, and no file under `src/sandbox*.mc` writes one: the caller says
`host_sysno(SN_OPENAT)`, an index into the per-architecture table its host file included. The
`SN_*` names are `src/sysno.mc`; the numbers are `src/sysno_linux_aarch64.mc`
(`asm-generic/unistd.h`) and `src/sysno_linux_x86_64.mc` (`syscall_64.tbl`). A call this
architecture does not have — `access` and `arch_prctl` on AArch64 — is `SN_ABSENT` in the table
and `-1` from `host_sysno`. `src/host_macos.mc` and `src/host_windows.mc` carry a table of the
same length with every row absent, so `<mc/core_sandbox>` compiles on every host and what refuses
is `host_os()`.

The shim itself is fourteen words in total.

**AArch64** — eight `#opcode` words, `lib/sys_linux.mc`'s style. Linux takes the number in `x8`
and the arguments in `x0..x5`; the seven parameters arrive in `x0..x6`, so the number is already
in `x0` and every argument is one register too high. The moves run in *ascending* order after
`x8` is taken, because `x8 <- x0` must read the number before `x0` is overwritten and each
`mov xN, x(N+1)` must read a register no earlier move has written:

```
mov x8, x0   0xaa0003e8      mov x3, x4   0xaa0403e3
mov x0, x1   0xaa0103e0      mov x4, x5   0xaa0503e4
mov x1, x2   0xaa0203e1      mov x5, x6   0xaa0603e5
mov x2, x3   0xaa0303e2      svc #0       0xd4000001
```

**x86-64** — six `emit()` words. There is no `#opcode` here because `#opcode` folds one 32-bit
word and x86 instructions are one to fifteen bytes; what is expressible today is a raw word, which
the x86-64 machine passes through unchanged. So the shim is a *byte stream* of 24 bytes cut into
four-byte pieces, and instructions straddle the boundaries:

```
mov rax, rdi                 48 89 f8        0x48f88948
mov rdi, rsi                 48 89 f7        0x8948f789
mov rsi, rdx                 48 89 d6        0xca8948d6
mov rdx, rcx                 48 89 ca        0x4dc2894d
mov r10, r8                  4d 89 c2        0x8b4cc889
mov r8, r9                   4d 89 c8        0x050f104d
mov r9, qword ptr [rbp+16]   4c 8b 4d 10
syscall                      0f 05
```

`rcx` and `r10` swap because `syscall` destroys `rcx`. `[rbp+16]` is the seventh parameter by
construction: the caller pushed it, `call` pushed the return address, and the prologue pushed
`rbp` and set `rbp = rsp` ([objects.md](objects.md) § 4c).

Both encodings come from `llvm-mc`, and three gates keep them from drifting:

| gate | what it asserts | where it runs |
|---|---|---|
| `scripts/check-surface.sh` | the eight AArch64 words in `--dump-asm` | every `make check` |
| `scripts/check-parts.sh` | the six x86-64 words in `--dump-asm --machine=x86_64` | every `make check` |
| `scripts/check-shim.sh` (`make check-shim`) | the shim *runs*: `getpid` through it equals the libc's, `openat` of a missing path is `-2`, a `write` reaches fd 1, and a six-argument `mmap` at offset 4096 reads the right byte | a Linux host; prints `SKIPPED` elsewhere |

The `mmap` case is the one that matters most: the sixth kernel argument is `sys6`'s *seventh*
parameter, which is `x6` on AArch64 and `[rbp+16]` on x86-64 — the one place the two shims differ
in kind rather than in numbers.

Measured (M43 acceptance 1), on Ubuntu 26.04 / kernel 7.0.0-30:

```
linux/aarch64   getpid via the shim ok · openat /nonexistent -2 · write ok · mmap@4096 ok
linux/x86_64    getpid via the shim ok · openat /nonexistent -2 · write ok · mmap@4096 ok
```

---

## The interface

```
mc sandbox run  [OPTS] PATH [--] [ARGS]      compile PATH inside the box, then run it
mc sandbox exec [OPTS] BIN  [--] [ARGS]      run an already-built Linux executable
mc sandbox check                             print what this host can do, exit 0/1
```

The options and the exit codes are in [cli.md](cli.md) § 3c. In one line: `--time`, `--wall`,
`--mem` and `--out` are the four caps; `--allow=threads` widens what the box permits; `--stdin`,
`--ro`, `--cwd`, `--root`, `--config`, `--report` and `--verbose` are the rest; **124** means a cap
stopped the program, **125** a refusal (step C: not produced yet), **126** that the box could not
be set up.

`scripts/test-sandbox.sh` (`make test-sandbox`, inside `make check`) is the gate: the isolation
cases of `tests/sandbox/`, the whole `tests/*.mc` suite compiled *and* run inside the box, `exec`
on two binaries built outside it (one of them dynamic), a project, the determinism of the report,
the proof that no host file was touched, and the overhead number. On a Linux host it runs
natively; from macOS it cross-builds a Linux `mc` and hands the run to Lima, else to
`docker run --privileged`, else prints one `SKIPPED` line with the reason.

---

## The part

`mc sandbox` is `<mc/core_sandbox>`, the sixth part of the composable core
([bundle.md](bundle.md) § The parts). A compiler that leaves it out prints one usage line fewer
and has no `sandbox` subcommand at all; `scripts/check-parts.sh` compiles the part on
`<mc/core_min>` alone and `cmp`s the spelled-out core against `<mc/core>`, so the part cannot
quietly grow a dependency on the driver or on a writer.
