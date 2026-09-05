# `mc sandbox` — compile and run an arbitrary program in isolation

**Status: step A.** What exists today is the system-call shim, the `<mc/core_sandbox>` part,
`mc sandbox check`, the option parser and the refusals. `run` and `exec` say
`mc: sandbox run: not in this step` and exit 126 on Linux; the box itself — the three processes,
the mount tree, Landlock, the seccomp listener and the report — is step B. Everything below that
describes the box is written as design, and the sections that are measured say so and give the
host they were measured on.

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
| Linux, root | the whole thing; the box's uid 0 maps to host 65534 |
| Linux, unprivileged | the same code path through a user namespace — see the AppArmor section below |
| macOS | refuses, and prints the Lima command to run instead, exit **126** |
| Windows | refuses, exit **126** |

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
`--mem` and `--out` are the four caps; `--allow=threads` widens the syscall profile; `--stdin`,
`--ro`, `--cwd`, `--report` and `--verbose` are the rest; **124** means a cap stopped the program,
**125** a refusal, **126** that the box could not be set up.

---

## The part

`mc sandbox` is `<mc/core_sandbox>`, the sixth part of the composable core
([bundle.md](bundle.md) § The parts). A compiler that leaves it out prints one usage line fewer
and has no `sandbox` subcommand at all; `scripts/check-parts.sh` compiles the part on
`<mc/core_min>` alone and `cmp`s the spelled-out core against `<mc/core>`, so the part cannot
quietly grow a dependency on the driver or on a writer.
