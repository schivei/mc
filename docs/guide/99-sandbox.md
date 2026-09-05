# Run something you do not trust

You have an `.mc` file from somewhere else — a bug report, a fuzzer, a student, a pull request —
and you want to know what it does without giving it your machine. On Linux, one command:

```
mc sandbox run untrusted.mc
```

It compiles the file **inside** a box and runs what it built **inside** the same box: a fresh set
of namespaces, a root that is not your root, no network, four caps, and a filter that refuses
anything the program has no business doing. When it stops, you get a sentence:

```
sandbox: compile: exit 0
sandbox: refused: open /etc/shadow
```

and exit code **125**.

This page is the task-oriented half. The mechanism — the four processes, the mount tree, the maps,
Landlock, seccomp, the profiles and, above all, [what is *not*
isolated](../reference/sandbox.md#what-is-not-isolated) — is in
[../reference/sandbox.md](../reference/sandbox.md); every flag is in
[../reference/cli.md](../reference/cli.md) § 3c.

> The samples on this page are ordinary `mc` programs, and `make check-docs` compiles them on the
> machine that renders these docs — a Mac. It does not run them through the box: **there is no box
> on macOS** (§ 7 below). What the box does with them is proved by
> `scripts/test-sandbox.sh` on Linux, where each one has a `tests/sandbox/` twin.

---

## 1. First, ask the kernel

```
$ mc sandbox check
kernel: 7.0.0-30-generic
userns: ok
landlock: abi 8
seccomp: notif ok
overlay: ok
pidfd: ok
```

Exit 0 means this host can build a box. Anything else names what is missing, and the two answers
you are most likely to see are `userns: restricted (apparmor)` — § 7 — and `overlay: not loaded
(modprobe overlay)`, which is one `sudo modprobe overlay` away.

## 2. A program that behaves

```mc
// expect-exit: 0
// expect-stdout: 46368
#include <sys>

i64 fib(i64 n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

i64 main() {
    putnum(fib(24));
    write(1, "\n", 1);
    return 0;
}
```

```
$ mc sandbox run fib.mc
46368
sandbox: compile: exit 0
sandbox: exit 0
```

Its stdout is byte for byte what it prints outside the box; the report goes to stderr, so a pipe
sees only the program. Nothing was written to your tree: the compiler wrote its executable into
the box's own upper layer, which died with the box.

## 3. A program that does not

```mc
#include <sys>

// It never gets to read anything: /etc is not in the box, and the box says
// which path it refused. Outside the box, as root, this prints the file.
i64 main() {
    i64 fd = open("/etc/shadow", O_RDONLY, 0);
    if (fd < 0) return 1;
    u8 buf[64];
    read(fd, buf, 64);
    write(1, buf, 64);
    return 0;
}
```

```
$ mc sandbox run shadow.mc ; echo "exit $?"
sandbox: compile: exit 0
sandbox: refused: open /etc/shadow
exit 125
```

The same shape covers the other four ways out. Each is one of `tests/sandbox/`:

| the program tries | the box says | exit |
|---|---|---|
| `open("/etc/shadow")` | `refused: open /etc/shadow` | 125 |
| `socket(AF_INET, ...)` | `refused: syscall 198 (socket)` (41 on x86-64) | 125 |
| `clone`/`fork` in a loop | `refused: syscall 220 (clone)` | 125 |
| `mmap` of 8 GiB | `refused: mmap 8589934592 bytes over the cap (268435456)` | 125 |
| a loop that never ends | `killed: cpu limit (2 s)` | 124 |
| a sleep longer than the box | `killed: wall clock (5 s)` | 124 |

**124 is a cap, 125 is a refusal, 126 is "the box could not be built".** A program that simply
fails on its own keeps its own exit code.

## 4. Turning the dials

```
$ mc sandbox run --time 10 --wall 30 --mem 1024 --out 256 slow.mc
```

`--time` is CPU seconds, `--wall` is the clock, `--mem` is address space, `--out` is how much the
program may write. The defaults — 2 s, 5 s, 256 MiB, 64 MiB — are sized for "a test somebody sent
me", not for a build. Two more you will want:

* `--stdin FILE` gives the program an input; without it, `read` sees EOF at once.
* `--allow=threads` lets it make real threads. Every *other* way of making a process is then
  counted rather than refused outright, up to 64 — `refused: process limit (64)`.

## 5. A binary you already have

`run` compiles; `exec` does not:

```
$ mc --exe prog.mc -o prog
$ mc sandbox exec prog arg1 arg2
```

The box binds `/lib`, `/lib64` and `/usr/lib` read-only and nothing else of the host, which is
exactly enough for a dynamic binary to find its loader and its C library — and not enough for it
to find your files.

## 6. A whole project

```
$ mc sandbox run --time 120 --wall 300 --mem 4096 --config mc.linux.toml examples/lang
```

Given a directory with an `mc.toml`, the compile step is `mc build` — so a project that teaches
the compiler builds its taught compiler inside the box too, and the program that compiler compiles
is the run step. Two options exist for trees that reach outside themselves:

* `--root DIR` makes `/src` the tree you name instead of the source's own directory, which is how
  a test that includes `../lib/sys.mc` still resolves it;
* `--config NAME` picks the project file.

## 7. When there is no box

**macOS and Windows have none**, and `mc` says so rather than pretending:

```
$ mc sandbox run x.mc
mc: the sandbox is a Linux feature; on this Mac: limactl shell mc-k7 build/mc-linux-arm64 sandbox run PATH (docs/build.md § Lima)
```

exit 126. On **Ubuntu 23.10 and later** an unprivileged user meets one more wall, and it is not
`mc`'s: `kernel.apparmor_restrict_unprivileged_userns` is 1, so the box is refused at its first
mount and `check` says `userns: restricted (apparmor)`. Either

```
$ sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
```

or give the `mc` binary an AppArmor profile granting `userns,` and `mount,`. Running the whole
thing as **root** works too and is the worse answer: with a root box `RLIMIT_NPROC` stops binding
([../reference/sandbox.md](../reference/sandbox.md#what-is-not-isolated)). Inside a container the
box needs `--privileged`, for the same reason: the default seccomp profile keeps `unshare`,
`mount` and `pivot_root` behind `CAP_SYS_ADMIN`.

## 8. What it costs, and what it does not buy

A box costs about **1.7 ms** on a quiet AArch64 machine (2.0 ms with both walls installed; the
walls are +21%), and 3–5 ms on a busy shared x86-64 VPS. That is per *run*, not per program: it
is cheap enough to put in a loop, which is what `scripts/test-sandbox.sh` does with the whole test
suite.

What it does not buy is a different kernel. Every allowed system call goes to the **host's own
Linux kernel**, and a bug in one of those is not stopped by anything here — that is the first
sentence of [What is not isolated](../reference/sandbox.md#what-is-not-isolated), and it is worth
reading before you use this for anything hostile and public. For the project's own purposes —
fuzz inputs, examples nobody audited, a suite of 30 programs — it is the right trade.

## 9. In your own checks

```
$ sh scripts/test-sandbox.sh            # the whole suite, through the box
$ make test-sandbox                     # the same, inside make check
```

and in CI, the `sandbox` jobs run it as root **and** as an ordinary user with the AppArmor sysctl
off, on both architectures, plus `sh scripts/sandbox-trace.sh --check`, which re-measures the
seccomp profiles with `strace` and fails when the compiler has gained a system call the profile
does not have ([../ci.md](../ci.md) § M43).
