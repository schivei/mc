# `mc sandbox` — compile and run an arbitrary program in isolation

**Status: complete** (M43, four steps; the CI job of step D is what proves the unprivileged path).
The box is there — namespaces, a mount tree, `pivot_root`, the caps,
the steps, the wall clock and the report — and so are the two walls that make a refusal a
*sentence*: a **Landlock** ruleset over the box's roots and a **seccomp** filter whose default
action is not a kill but a question to the supervisor. A program that reaches outside the box is
named and the box stops:

```
sandbox: refused: open /etc/shadow
sandbox: refused: syscall 198 (socket)
sandbox: refused: mmap 8589934592 bytes over the cap (268435456)
sandbox: refused: clone with namespace flags
sandbox: refused: process limit (16)
```

each with exit code **125**. Every measured number below gives the host it came from.

The design is `docs/specs/M43.md`. This page is the reference; the task-oriented half — "I have a
file I do not trust and I want to know what it does" — is
[../guide/99-sandbox.md](../guide/99-sandbox.md).

---

## What is not isolated

**The kernel.** A program in the box talks to the *host's own Linux kernel* through the system
calls its profile allows — **sixteen** for a musl program, **twenty-two** for a glibc one on
AArch64, measured and listed below — and a bug in one of those, in `openat`, in `mmap`, in
`write`, is not stopped by anything here. Namespaces, Landlock, seccomp and rlimits are all
kernel features enforcing kernel policy in the same kernel; there is no second implementation
between the program and the machine. That is exactly the residual gVisor's user-space kernel and
Firecracker's microVM exist to remove, at 50 MB and a Go runtime or at a guest kernel and
`/dev/kvm`, and neither is used here.

For the project's own tests — fuzz inputs, `--exe` binaries, examples nobody audited — that
residual is accepted, and it is written down rather than papered over. For anything hostile and
public, the answer is policy: a disposable machine that holds nothing, snapshotted, rebuilt from
a script.

**Not the compile step's forks — not any more.** This section used to say that the *compile*
step's process count was unbounded for a box started by root: `mc build` writes a compiler and
runs it, so `clone` was measured into the compile profile as a plain ALLOW, and the only thing
behind it was `RLIMIT_NPROC`, which `copy_process` skips outright for `INIT_USER`. The post-M43
review took that apart with `mc build`'s own `[linker].cmd` (§ The explain channel), and the fix
is above: no profile allows a process-creating call, every one of the four is counted by the
supervisor against a per-step limit, and a namespace flag is refused by name. Measured on both
architectures and both privileges: `refused: process limit (16)`, exit 125, and the host's
process count is the same before and after.

Four smaller things are outside the wall, and each is a deliberate choice:

* **the compiler itself** runs inside the box for `mc sandbox run`, under the compile profile —
  so a malicious source is contained the same way a malicious program is, but a bug in `mc` that
  is reachable from a source file is reachable there too;
* **the diagnostic read of a path argument** (`openat` under `SECCOMP_RET_USER_NOTIF`) is a read
  of the program's own memory with `process_vm_readv`, and with `--allow=threads` another thread
  may overwrite that buffer between the read and the kernel's own — the classic TOCTOU of a
  syscall-argument inspector. Enforcement never depends on it: the mount tree and Landlock are
  what refuse a path, and the notification only supplies the *name* that goes in the report. The
  worst a race can do is put the wrong path in one line of the report. Without `--allow=threads`
  a step is single-threaded and there is no race at all — the filter refuses every way of making
  a thread;
* **timing** is not isolated at all. The box has no clock policy; a program can measure how long
  things take and so can anything sharing the machine;
* **below Landlock ABI 6 the scoped restrictions do not exist.** ABI 6 (kernel 6.12) added the
  `scoped` field — abstract unix sockets and signals confined to the Landlock domain — and the
  floor this sandbox accepts is 4. On a kernel between them the ruleset simply does not carry
  that word, and the box loses one wall: nothing in it makes another process or an abstract
  socket *reachable* (the pid namespace hides every process, the network namespace is empty), but
  the second wall is absent. It is not silent: `mc sandbox check` prints
  `landlock: abi N (no scoped signals below 6)` and still exits 0. Both measured hosts report
  abi 8 and the GitHub runners abi 7, so the line is proved by building with the constant raised,
  not by a host that shows it.

---

## Hosts

| host | `mc sandbox run\|exec\|check` |
|---|---|
| Linux, unprivileged | the whole thing, through a user namespace; the box's uid 0 **is** the caller. This is the way to run it — see the AppArmor section below |
| Linux, root | the same code path, with the identity map `0 0 65536`. Everything works and one wall is missing: `RLIMIT_NPROC` does not bind for root (§ What is not isolated) |
| macOS | refuses, and prints the Lima command to run instead, exit **126** |
| Windows | refuses, exit **126** |

Measured with step C in, both privileges, on Ubuntu 26.04 / kernel 7.0.0-30 —
`scripts/test-sandbox.sh`. "isolation" is the ten cases of `tests/sandbox/` (eight programs, one
of them run twice); "the suite" is every `tests/*.mc` compiled *and* run inside the box.

| cell | isolation | the suite | `exec` | a project | overhead per box |
|---|---|---|---|---|---|
| linux/aarch64, glibc, root (Lima `mc-k7`) | 10/10 | 31/31 (1 skipped) | 2/2 | ok | 1.74 ms |
| linux/aarch64, glibc, unprivileged | 10/10 | 31/31 (1 skipped) | 2/2 | ok | 1.70 ms |
| linux/x86_64, musl, root (the VPS) | 10/10 | 29/29 (3 skipped) | 2/2 | ok | 3.0–4.5 ms |
| linux/x86_64, musl, unprivileged | 10/10 | 29/29 (3 skipped) | 2/2 | ok | 3.7 ms |
| linux/aarch64, musl, `alpine:3` under `docker run --privileged` | 10/10 | 31/31 | 2/2 | ok | not measurable (busybox `date` has no `%N`) |

And the four cells CI runs on every pull request — GitHub's `ubuntu-24.04-arm` and
`ubuntu-latest`, both **kernel 6.17.0-1022-azure, glibc 2.39, Landlock abi 7**, each as an
ordinary user and under `sudo` ([ci.md](../ci.md) § the sandbox jobs). These are the only cells
where the unprivileged path runs with the AppArmor restriction *off*:

| cell | isolation | the suite | `exec` | a project | overhead per box |
|---|---|---|---|---|---|
| linux/arm64 runner, unprivileged (sysctl 0) | 10/10 | 31/31 (1 skipped) | 2/2 | ok | 2.21 ms |
| linux/arm64 runner, root | 10/10 | 31/31 (1 skipped) | 2/2 | ok | 2.11 ms |
| linux/x86_64 runner, unprivileged (sysctl 0) | 10/10 | 29/29 (3 skipped) | 2/2 | ok | 2.17 ms |
| linux/x86_64 runner, root | 10/10 | 29/29 (3 skipped) | 2/2 | ok | 2.11 ms |

What each runner answers, in both states of the sysctl, is printed by the job before the cells
run:

```
kernel.apparmor_restrict_unprivileged_userns = 1     as the runner ships
  userns: restricted (apparmor)                      mc sandbox check exits 1
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  userns: ok                                         mc sandbox check exits 0
```

and inside `docker run` on the same runner **without** `--privileged`, `check` says
`userns: EPERM` and a run is `sandbox: cannot unshare: EPERM`, exit **126** — the third refusal
of the acceptance list, asserted rather than described.

**One thing a container adds, measured in step D:** under Docker Desktop on macOS a checkout
*bind-mounted from the Mac* is a `fakeowner` mount, and `execve` of a file on it **inside** the
box answers `EACCES` — `sandbox: cannot execute the step`, exit 126 — while the very same image,
kernel and compiler run the whole suite when the tree is on the container's own filesystem
(`cp` it to `/opt` and it passes). Lima does not have the problem, which is why it is the first
delegate `scripts/test-sandbox.sh` tries; a container is the second, and on a Mac it wants the
tree copied in rather than mounted. Nothing about the box depends on it: the CI cells run on real
Ubuntu hosts, and the container cell there asserts a *refusal*.

The x86-64 host is a shared VPS and its numbers move: an unboxed `return 0` program measured
between 272 µs and 828 µs across the same afternoon, so the box's own cost there is quoted as a
range. On the quiet AArch64 VM the two steps can be compared directly, and that is the number to
quote for what the two walls cost:

| | plain | boxed | the box | the walls |
|---|---|---|---|---|
| step B (no filter, no Landlock) | 199 µs | 1619 µs | 1420 µs | — |
| step C | 199 µs | 1916 µs | 1717 µs | **+297 µs, +21%** |

That is one Landlock ruleset with eight rules, one `seccomp` install, two `pidfd_getfd` hops and
about a dozen notification round trips for a program that does nothing. On the x86-64 host the
same difference is inside the machine's noise.

The glibc profile on x86-64 was measured and exercised separately, on the same VPS, with
`--libc=gnu` and the glibc-linked compiler: the ten isolation cases and the suite behave exactly
as they do under musl, with the two numbers that differ named by the architecture and the C
library (`socket` is 41 there, and a fork is `clone` 56 under glibc where musl uses `fork` 57).

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
| `landlock` | `landlock_create_ruleset(0, 0, LANDLOCK_CREATE_RULESET_VERSION)`, which creates nothing and returns the ABI | `abi N`, `abi N (no scoped signals below 6)`, `abi N (below the minimum 4)`, `absent` |
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
| `/etc/ld.so.cache` | the host's, when it exists | bind of a *file* onto an empty file, read-only. The **only** thing of `/etc` that is there |
| everything else | — | does not exist: no `/proc`, no `/dev`, no `/tmp`, no `/home`, and nothing else of `/etc` |

**Why the cache is in the box**, since it was not in the design and it is one host file more than
"nothing": glibc's loader opens `/etc/ld.so.cache` at every start, and when it is missing it
falls back to searching the default directories — a *different* code path that issues calls the
same binary never issues on the host. The seccomp profiles are measured outside the box (below),
so a box that loads a program differently from the host is a box the measurement is not about.
Both halves of that were paid for in refusals before the cache went in: on AArch64
`tests/sandbox/shadow.mc` answered `refused: syscall 233 (madvise)` instead of naming the file it
opened, and on x86-64 *every* dynamic program died with `refused: syscall 262 (newfstatat)` while
the loader probed `/lib/x86_64-linux-gnu/glibc-hwcaps/x86-64-v4/`. The cache is world-readable, it
is a list of library names, and it comes in read-only and granted read-only by Landlock;
`/etc/shadow` is still absent, and still refused by name.

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
| `RLIMIT_NPROC` | 0, **32 for the compile step**, or 128 with `--allow=threads` | the process wall behind the supervisor's counter |

The process wall is two walls, and the rlimit is the second one. The named wall is P's counter on
the notifications — 16 for a compile, 0 for a run, 64 with `--allow=threads` (§ The explain
channel) — and it only produces a sentence if it is reached first, so every rlimit above it is
deliberately looser. The compile step's allowance is not a loophole either: `mc build` *writes* a
compiler and then runs it, and may run `[linker].cmd`, so a project needs a handful of processes
to build at all. Sixteen is more than a taught build takes and far less than a bomb.

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
| `refused: <what>` | the filter asked and the answer was no. Exit **125**; the five forms are in § The explain channel |
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
`build a project without an overlay`, `install the Landlock ruleset`, `install the seccomp
filter`, `fetch the seccomp listener`.

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

## The two walls

Both are installed by **C**, the process that `execve`s, in one place: after
`prctl(PR_SET_NO_NEW_PRIVS)` and before the byte that releases it. They have to be there and
nowhere else — a seccomp filter and a Landlock domain are inherited, cumulative and irrevocable,
so I cannot install them (it still has to fork the steps) and the program cannot be trusted to
install them itself.

### Landlock

A filesystem policy attached to the *process*, independent of the mounts. If a bind were ever
wrong, a path outside the roots still answers `EACCES`.

The ruleset **handles** every access right the running kernel knows about and **grants** them per
root; anything handled and not granted is denied. The mask is built up from the ABI the kernel
reports (`landlock_create_ruleset(0, 0, LANDLOCK_CREATE_RULESET_VERSION)` — it creates nothing
and answers the version), because a bit an older kernel does not know is `EINVAL`:

| ABI | what joins the mask |
|---|---|
| 1 (5.13) | the thirteen filesystem rights: execute, read/write a file, read a directory, remove, and the eight `MAKE_*` |
| 2 (5.19) | `REFER` — a rename or link across directories |
| 3 (6.2) | `TRUNCATE` |
| 4 (6.7) | the **network** field: TCP bind and connect, handled and granted to nobody |
| 5 (6.10) | `IOCTL_DEV` |
| 6 (6.12) | the **scoped** field: abstract unix sockets and signals, scoped to the domain |

The floor is 4 (`mc sandbox check` refuses below it); the baseline measures **abi 8**, and the
mask stops at the six levels above because a bit this compiler has never heard of cannot be asked
for safely.

| root | granted |
|---|---|
| `/src`, `/out` | everything handled — they are the writable pair, the overlay upper and the box tmpfs |
| `/mc` | execute + read file. It is a **file**, and a rule on a file may not carry a directory right: `READ_DIR` on it is `EINVAL` from `landlock_add_rule`, which is how the first version of this failed |
| `/lib`, `/lib64`, `/usr/lib` | execute + read file + read directory |
| `/etc/ld.so.cache` | read file, and nothing else of `/etc` |
| `/ro0`, `/ro1`, … | read file + read directory |

A root that does not exist in this box is skipped, not an error. Then
`landlock_restrict_self(fd, 0)`, and the descriptor is closed.

### The seccomp filter

A classic-BPF program over `struct seccomp_data`, installed with
`seccomp(SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_NEW_LISTENER, &prog)` — whose **return value
is a descriptor**, the listener the supervisor answers on. Its shape is fixed and every jump in it
is forward:

```
0            ld  [4]                 the architecture
1            jeq AUDIT_ARCH_*        no  -> KILL_PROCESS
2            ld  [0]                 the system call number
3            jge 0x40000000          yes -> KILL_PROCESS   (the x86-64 x32 ABI)
4 .. 4+m-1   jeq <allowed number>    yes -> ALLOW
[clone block, four instructions, only with --allow=threads]
d            ret USER_NOTIF          the fall-through: ask the supervisor
d+1          ret ALLOW
d+2          ret KILL_PROCESS
```

The architecture comes from the host layer (`host_audit_arch()`: `0xC00000B7` on AArch64,
`0xC000003E` on x86-64) and not from a constant in the filter builder, for the same reason the
syscall numbers do. `KILL_PROCESS` appears exactly twice, and neither is a policy: a filter
evaluated against the wrong architecture, or against x32's different numbering, is a filter whose
allowlist means something else.

The clone block is the one row whose *argument* decides. With `--allow=threads`:

```
jeq clone      no -> the default
ld  [16]                              args[0], the flags
jset CLONE_THREAD      not set -> the default
jset CLONE_NEW*        set     -> the default,  else ALLOW
```

so a real thread is allowed without asking and everything else — a `fork`, a `vfork`, a
`clone3`, a namespace — becomes a question. `clone3` cannot be flag-tested at all: its flags live
in a struct in the caller's memory, which BPF cannot read, so it stays a notification and the
supervisor reads the struct.

What the block does **not** do is decide whether a process may be created. `clone` is never one
of the `m` allowed numbers either — `sb_notified()` keeps all four process-creating calls out of
every profile — so without `--allow=threads` there is no block and every one of them falls
through to the supervisor, and with it the block is a *fast path for a real thread* and nothing
else. A filter cannot name a refusal (its only verdicts are ALLOW, a `KILL` with no explanation,
an errno, and the question), which is why the namespace decision is P's and not the BPF's.

---

## The profiles

The allowlist is not written; it is **measured**. `scripts/sandbox-trace.sh` (`make
sandbox-trace`) runs `strace -f` over every `tests/*.mc` compiled and then executed, over `mc
build examples/lang`, and over two probes it writes itself, and records what it saw:

```
tools/sandbox/<arch>-<libc>-compile.list      the compile step: /mc, and any compiler it teaches
tools/sandbox/<arch>-<libc>-program.list      the run step: an mc program plus its loader
tools/sandbox/<arch>-<libc>-threads.list      what --allow=threads adds
```

`src/sandbox_profiles.mc` is generated from those twelve files: per architecture a base (musl), a
glibc delta **per step**, and one shared threads delta. `sh scripts/sandbox-trace.sh --check`
(`make sandbox-trace-check`) re-traces the host it runs on and compares, and the CI job runs it on
both architectures on every pull request.

**The two directions of that comparison are not the same kind of fact.** A call in the trace that
the list does not have is a box that would refuse a legitimate program: it fails. A list entry
this host's trace never used is a `note` line, because the list is the **union over the C library
versions the project supports**, and no single host can exercise them all — measured with one
compiler and one corpus:

| | start-up | spawn |
|---|---|---|
| glibc 2.43 (Ubuntu 26.04: Lima, the VPS) | `madvise`, `getrandom` | `clone3` |
| glibc 2.39 (Ubuntu 24.04: both GitHub runners) | `rt_sigaction` | `clone3` **and** `clone` |

`sh scripts/sandbox-trace.sh --union` is how a host adds what it needs without erasing what
another host needs; `--strict` restores the two-way failure and is only meaningful on the host
that last wrote the list with a plain, replacing run. Regenerating the `.mc` from the lists must
reproduce it byte for byte in every mode.

Four more facts, each of which cost a refusal to learn:

* **The trace runs outside the box.** Tracing the box would record the box's own setup —
  `unshare`, `mount`, `pivot_root` — which must never be in a profile, and once a filter exists
  the measurement is circular: a call missing from the profile is refused before it can be
  observed. The two command lines traced are exactly the two the box runs.
* **`strace -c` is not used.** Its summary drops `exit_group`, which never returns and is
  therefore never counted — and a profile without `exit_group` refuses every program at its last
  instruction.
* **The corpus needs a program that uses the C library.** Every `tests/*.mc` writes with a raw
  `write` and allocates nothing, so their traces say nothing about `malloc`, stdio, a directory
  listing or a signal mask. The script writes one that does all four, and allocates **four
  megabytes in one block** on purpose: that is what makes glibc advise `MADV_HUGEPAGE` on the
  chunk *every* time. Without it `madvise` appeared in five runs out of sixty — and a profile
  measured from a corpus that hits a call one run in twelve is a box that refuses a legitimate
  program one run in twelve.
* **The delta is per step, not per libc alone.** `read` is in musl's *compile* trace and not in
  its *program* trace, so a single glibc delta over both kinds would not give a glibc program the
  `read` it needs (measured: `refused: syscall 0 (read)`); `clone3` is in the compile trace only,
  so the same union would hand a glibc *program* a way to fork that the profile exists to refuse.

Two things are in every profile whatever the trace said, and they are C's own: the **`read`** that
waits for the supervisor's sync byte and the **`close`** of its copy of the listener. They cannot
be moved earlier — the listener does not exist until the filter is installed, and P must hold it
before the program runs.

Five calls are **never** in the allowlist even though every profile contains them, because they
are what the supervisor's table decides on: `openat`, `open`, `mmap`, `munmap` and `execve`. They
are allowed in the end — the answer is `CONTINUE` — but through P, and that is the round trip the
overhead above pays for.

The sizes, measured (aarch64 first, x86-64 second):

| profile | musl | glibc |
|---|---|---|
| compile | 18 / 19 | +9 / +7 |
| program | 16 / 17 | +9 / +9 |
| `--allow=threads` delta | 7 shared entries; `clone` and `clone3` appear as comments, never as rows | |

The glibc compile delta on AArch64 is nine and not eight because of the 2.39 row above:
`rt_sigaction` is in the list and no 2.43 host asks for it.

---

## The explain channel

The listener is a descriptor in C, and C lives in a pid namespace whose numbers mean nothing to P
— which cannot even *name* C until the first notification arrives, which is what it needs the
listener for. So the descriptor travels in **two hops of `pidfd_getfd(2)`**, each between a
process and one of its own descendants:

```
C  installs the walls, reports [READY, <fd>] to J over its error pipe, blocks on a read
J  pidfd_open(C) + pidfd_getfd(fd, <that number>)   -> L in J,  announced to P as `L <L>`
P  pidfd_open(J) + pidfd_getfd(fd, L)               -> the listener
P  writes one byte to the sync pipe                 -> C closes its copy and execve's
```

Both hops need `PTRACE_MODE_ATTACH_REALCREDS` on the target and both have it for the same two
reasons: the same real uid (a user namespace remaps credentials, it does not change them) and a
descendant, which is what Yama's `ptrace_scope` allows — **1** on both measured hosts, the
restricted setting, and the one this arrangement is designed for. The sync pipe is created by P
*before* the box exists, so that the byte meaning "your listener is held" comes from the process
that holds it.

P then polls the listener beside the status pipe, and answers by table:

| what arrives | what P does |
|---|---|
| `openat`, `open` | reads the path with `process_vm_readv`; under one of the box's roots (or relative, or one of the loader's two configuration files) → `SECCOMP_USER_NOTIF_FLAG_CONTINUE`, after `SECCOMP_IOCTL_NOTIF_ID_VALID` says the notification is still live. Otherwise `refused: open PATH` |
| `mmap` | adds the length to a running total (`munmap` subtracts); over `--mem` → `refused: mmap N bytes over the cap (M)`, else CONTINUE |
| `clone`, `fork`, `vfork` | any `CLONE_NEW*` bit in the flags → `refused: clone with namespace flags`. Otherwise counted against the step's process limit: the one past it is `refused: process limit (N)` |
| `clone3` | the same two decisions, but the flags live in a `struct clone_args` the caller owns, so P reads its first eight bytes with `process_vm_readv` (the size is `args[1]`). A struct it cannot read is `refused: clone3 with unreadable arguments` |
| `execve` | counted per step — three for a compile, one for a run — then `refused: execve` |

**No profile allows a call that makes a process.** `clone`, `clone3`, `fork` and `vfork` are
dropped from every allowlist before the filter is built (`sb_notified`, `src/seccomp.mc`), so all
four always arrive here. They used to be left to the measurement: `mc build` really does fork, so
`clone` was traced into the *compile* profile and written there as a plain ALLOW — a call the
supervisor never sees. `mc build` also runs whatever `[linker].cmd` the source tree's own
`mc.toml` names, so a hostile tree chose which binary the compile step executed, and that binary
forked in a loop with nothing in the report but `compile: exit 1` (measured: twelve children
unprivileged, **two hundred** as root, where `RLIMIT_NPROC` does not bind at all). A
`clone(CLONE_NEWUSER|SIGCHLD)` in the same position simply succeeded. That is
`tests/sandbox/linkbomb/`, and the answer is the table above.

The process limits are per step, and they are P's counters, not the kernel's:

| step | processes | why |
|---|---|---|
| compile | **16** | `mc build` writes a compiler, spawns it, and may spawn `[linker].cmd`; two or three is what a taught build costs |
| run | **0** | a program in the box does not fork |
| run, `--allow=threads` | **64** | a *thread* never reaches P (the filter's flag test allows it); what is counted is a new process |

Behind each counter is an `RLIMIT_NPROC` that is deliberately **looser** — 32 for a compile, 128
with `--allow=threads` — because the two walls race and the named one has to win: with both at
the same number the kernel's `EAGAIN` arrives first and the program sees a failed fork instead of
a sentence.
| anything else | `refused: syscall N (name)`, the number this architecture uses and the name from the one table that carries both columns |

Every refusal is one line, exit code **125**, and the end of the box.

**A refused call never returns.** The notification is *not* answered, which is a deviation from
the design's table (it has P answer `-EPERM` or `-EACCES` and then kill). It was measured:
answering wakes the step inside its system call, and it then runs for as long as the `SIGKILL`
takes to arrive — `tests/sandbox/shadow.mc` printed `shadow errno=13` and `connect.mc` printed
`socket refused` on some runs and not others. Left unanswered, the step's output ends exactly
where the refusal happened, which is what makes an `.expect` file possible at all.

**What the numbers in a refusal are.** A system call number is a property of the architecture
*and* of the C library that issued it. `socket` is 198 on AArch64 and 41 on x86-64; a `fork` is
`clone` (220 / 56) under glibc, and `fork` (57) under musl on x86-64, where that system call
exists and the generic table has no such thing. `tests/sandbox/` carries one expectation per
(architecture, libc) where they differ, which is why the headers read
`sandbox-report-x86_64-musl:`. A refused *fork* no longer needs one: it is counted, not named, so
`refused: process limit (0)` is the same line on every host.

**What `--verbose` adds here**: one line per step with the execve count. It is not noise —
measured, `mc sandbox run --config examples/lang/mc.linux-gnu.toml .` prints `compile: execve 2`
(the compiler, then the compiler it taught, which compiles the entry in-process under
`--entry-only`) and `execve 1` for the run step. The design priced three for a taught build; two
is what it costs. Three is still the ceiling.

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
stopped the program, **125** a refusal, **126** that the box could not be set up.

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
