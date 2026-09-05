// sandbox.mc — `mc sandbox run|exec|check` (M43, docs/specs/M43.md,
// docs/reference/sandbox.md).
//
// STEP A carries the option parser, `check`, and the refusals. The box itself
// -- the three processes, the mount tree, Landlock, the seccomp listener and
// the report -- is step B; `run` and `exec` say so rather than pretending.
//
// Everything here goes through the host layer's raw system-call shim
// (host_syscall6, src/sysno_linux_*.mc) and names system calls by their SN_*
// index, never by number: the same source compiles for both architectures and
// for a host that has no system calls of this shape at all, where host_os() is
// what refuses.
//
// It depends on <mc/core_min> and on the host file, and on nothing else --
// scripts/check-parts.sh § 1b compiles `<mc/core_min>` + `<mc/core_sandbox>` on
// its own.

// ---- errno, as the kernel returns it: a small negative result ----
#define E_PERM     1
#define E_NOENT    2
#define E_ACCES   13
#define E_NOSYS   38

// ---- what the probes in `check` need. None of these is a syscall NUMBER;
// they are the arguments the syscalls take, and they are the same on every
// architecture Linux runs on.
#define SB_SIGCHLD                    17
// The six namespaces the box unshares in ONE call (§ 1). They are one constant
// and not six calls for the reason the AppArmor note below gives: asking for
// CLONE_NEWUSER on its own and then for the rest is a DIFFERENT question, and
// the kernel answers it differently (a nested user namespace from a process
// whose uid is unmapped is EPERM even for root).
#define SB_CLONE_NEWNS        0x00020000
#define SB_CLONE_NEWUTS       0x04000000
#define SB_CLONE_NEWIPC       0x08000000
#define SB_CLONE_NEWUSER      0x10000000
#define SB_CLONE_NEWPID       0x20000000
#define SB_CLONE_NEWNET       0x40000000
#define SB_CLONE_BOX          0x7C020000   // the six above

// the box's first mount: MS_PRIVATE | MS_REC on `/`, so nothing propagates back
#define SB_MS_REC                 0x4000
#define SB_MS_PRIVATE            0x40000
#define SB_MS_PRIVATE_REC        0x44000

#define SB_LANDLOCK_ABI_VERSION        1   // LANDLOCK_CREATE_RULESET_VERSION
#define SB_LANDLOCK_ABI_MIN            4   // ABI 4 is the floor (§ 0)
#define SB_SECCOMP_GET_ACTION_AVAIL    2
#define SB_RET_USER_NOTIF     0x7FC00000   // SECCOMP_RET_USER_NOTIF
#define SB_AT_FDCWD                 -100
#define SB_O_RDONLY                    0

// `struct utsname`: six NUL-terminated fields of _UTSNAME_LENGTH (65) bytes --
// sysname, nodename, release, version, machine, domainname.
#define SB_UTS_FIELD  65
#define SB_UTS_SIZE  390
#define SB_UTS_RELEASE 130                 // 2 * SB_UTS_FIELD

#define SB_SLURP 4096                      // what a /proc probe reads

// ---- the exit codes of § 6 ----
#define SB_EXIT_CAP     124                // a cap stopped it (cpu, wall)
#define SB_EXIT_REFUSED 125                // a refusal stopped it
#define SB_EXIT_SETUP   126                // the box could not be set up

// ---- options (§ 6). Step A parses and validates them; step B is what reads
// them. The defaults are the ones the interface publishes.
#define SB_MAXRO 16

i64  sb_time    = 2;                       // --time S,  RLIMIT_CPU seconds
i64  sb_wall    = 5;                       // --wall S,  the supervisor's ppoll
i64  sb_mem     = 256;                     // --mem MiB, RLIMIT_AS
i64  sb_out     = 64;                      // --out MiB, the tmpfs and RLIMIT_FSIZE
i64  sb_threads = 0;                       // --allow=threads
i64  sb_verbose = 0;                       // --verbose
uptr sb_libc    = 0;                       // --libc=musl|gnu, 0 = from PT_INTERP
uptr sb_stdin   = 0;                       // --stdin FILE, 0 = EOF
uptr sb_cwd     = 0;                       // --cwd DIR, inside /src
uptr sb_report  = 0;                       // --report FILE, 0 = stderr
uptr sb_ro[SB_MAXRO];                      // --ro DIR, repeatable
i64  sb_nro     = 0;
i64  sb_argi    = 0;                       // index of PATH/BIN in argv

u8 sb_uts[SB_UTS_SIZE];
u8 sb_buf[SB_SLURP];
u8 sb_word[8];                             // one u32 argument passed by address

// ---- the shim, by name ----
// The raw kernel result (-errno on failure), or -ENOSYS when this host has no
// such system call at all -- which is what src/host_macos.mc's all-absent table
// and its host_syscall6 both answer.
i64 sb_sys(i64 sn, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
    i64 n = host_sysno(sn);
    if (n < 0) return 0 - E_NOSYS;
    return host_syscall6(n, a, b, c, d, e, f);
}

// ---- small helpers ----
void sb_err(uptr msg) { out_str(2, "mc: "); out_str(2, msg); out_str(2, "\n"); }

void sb_err2(uptr msg, uptr detail) {
    out_str(2, "mc: "); out_str(2, msg); out_str(2, ": "); out_str(2, detail); out_str(2, "\n");
}

// a non-negative decimal, or -1. Used for --time/--wall/--mem/--out, where a
// bad value has to be a diagnostic and not a silent 0.
i64 sb_num(uptr s) {
    if (s == 0) return -1;
    if (ld8(s) == 0) return -1;
    i64 v = 0;
    i64 i = 0;
    loop {
        i64 c = ld8(s + i);
        if (c == 0) break;
        if (c < '0' || c > '9') return -1;
        v = v * 10 + (c - '0');
        i = i + 1;
    }
    return v;
}

// n bytes of `path` into sb_buf, NUL-terminated; -errno on failure. Everything
// `check` reads from /proc goes through here, with the shim rather than the
// compiler's own open/read: this is also what proves the shim on the host.
i64 sb_slurp(uptr path) {
    st8(sb_buf, 0);
    i64 fd = sb_sys(SN_OPENAT, SB_AT_FDCWD, path, SB_O_RDONLY, 0, 0, 0);
    if (fd < 0) return fd;
    i64 n = sb_sys(SN_READ, fd, sb_buf, SB_SLURP - 1, 0, 0, 0);
    sb_sys(SN_CLOSE, fd, 0, 0, 0, 0, 0);
    if (n < 0) return n;
    st8(sb_buf + n, 0);
    return n;
}

// is `needle` a whole line-tail of what sb_slurp just read? /proc/filesystems
// writes one filesystem per line, `nodev\toverlay`, so a plain substring search
// over the buffer is what answers "is overlay a filesystem this kernel knows".
i64 sb_buf_has(uptr needle, i64 n) {
    i64 i = 0;
    loop {
        if (ld8(sb_buf + i) == 0) break;
        if (mem_eq(sb_buf + i, needle, n)) return 1;
        i = i + 1;
    }
    return 0;
}

// ---- `mc sandbox check` (§ 6) ----
// One line per capability, on stdout, in a fixed vocabulary; exit 1 when any of
// the five the box needs is missing. This is the guard `make check` and the CI
// leg consult, in the `test-linux: SKIPPED (...)` style.

// the kernel release out of uname(2)
void sb_check_kernel() {
    out_str(1, "kernel: ");
    if (sb_sys(SN_UNAME, sb_uts, 0, 0, 0, 0, 0) < 0) { out_str(1, "unknown\n"); return; }
    out_str(1, sb_uts + SB_UTS_RELEASE);
    out_str(1, "\n");
}

// 1 when kernel.apparmor_restrict_unprivileged_userns is on. Ubuntu has shipped
// it as 1 since 23.10, and it is the ONE thing that makes the unprivileged path
// fail on a stock install (§ Risks 1) -- so an EPERM from unshare is reported
// as `restricted (apparmor)` when it is on and as a bare `EPERM` when it is not.
i64 sb_apparmor_userns() {
    if (sb_slurp("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") < 0) return 0;
    return ld8(sb_buf) != '0' && ld8(sb_buf) != 0;
}

// The probe runs IN A CHILD, because a namespace is not something a process can
// leave: `mc` itself must come out of `check` unchanged. `fork` is
// clone(SIGCHLD, 0, 0, 0, 0) -- AArch64 has no fork -- and returns into this
// same frame in the child, which is safe because nothing shares the stack (no
// CLONE_VM, § 1). The child never returns from the `if`.
//
// It is TWO stages, and that is a correction the kernel made to the spec.
// § Risks 1 expected `unshare(CLONE_NEWUSER)` to fail with EPERM for an
// unprivileged unconfined process when
// kernel.apparmor_restrict_unprivileged_userns is 1. Measured on Ubuntu 26.04 /
// kernel 7.0.0-30 (aarch64 and x86_64), unprivileged, with the sysctl at 1:
// THE UNSHARE SUCCEEDS -- all six namespaces at once. The audit record is
//
//   apparmor="AUDIT" operation="userns_create" info="Userns create -
//   transitioning profile" profile="unconfined" target="unprivileged_userns"
//
// -- since 24.04 the kernel does not refuse the namespace, it moves the process
// into the `unprivileged_userns` profile (/etc/apparmor.d/unprivileged_userns),
// which grants `userns`, `file`, `network`, `signal`, `unix`, `ptrace` and
// `audit deny capability`, and grants no `mount` rule at all. So the FIRST
// thing that fails is the box's first mount:
//
//   mount(0, "/", 0, MS_PRIVATE|MS_REC, 0)   -> -13  EACCES  (no mount rule)
//   sethostname("sandbox", 7)                -> -1   EPERM   (deny capability)
//
// A probe that stopped at the unshare would print `ok` on a host where nothing
// works, so the second stage is the box's own first mount, run inside the
// child's private mount namespace where it changes nothing outside.
//
// The child hands its result back as an exit status: 0 when both stages passed,
// the errno of the unshare, or 128 + the errno of the mount.
i64 sb_check_userns() {
    out_str(1, "userns: ");
    i64 pid = sb_sys(SN_CLONE, SB_SIGCHLD, 0, 0, 0, 0, 0);
    if (pid < 0) { out_str(1, "cannot fork\n"); return 0; }
    if (pid == 0) {
        i64 rc = sb_sys(SN_UNSHARE, SB_CLONE_BOX, 0, 0, 0, 0, 0);
        if (rc < 0) sb_sys(SN_EXIT_GROUP, (0 - rc) & 0x7f, 0, 0, 0, 0, 0);
        rc = sb_sys(SN_MOUNT, 0, "/", 0, SB_MS_PRIVATE_REC, 0, 0);
        if (rc < 0) sb_sys(SN_EXIT_GROUP, 128 + ((0 - rc) & 0x7f), 0, 0, 0, 0, 0);
        sb_sys(SN_EXIT_GROUP, 0, 0, 0, 0, 0, 0);
    }
    st64(sb_word, 0);
    i64 w = sb_sys(SN_WAIT4, pid, sb_word, 0, 0, 0, 0);
    if (w < 0) { out_str(1, "cannot wait\n"); return 0; }
    i64 st = ld32(sb_word);
    if (st & 0x7f) { out_str(1, "child killed\n"); return 0; }   // died of a signal
    i64 err = (st >> 8) & 0xff;
    if (err == 0) { out_str(1, "ok\n"); return 1; }
    if (err >= 128) err = err - 128;             // the namespaces were made, the mount was not
    if (sb_apparmor_userns()) { out_str(1, "restricted (apparmor)\n"); return 0; }
    if (err == E_PERM)  { out_str(1, "EPERM\n");  return 0; }
    if (err == E_ACCES) { out_str(1, "EACCES\n"); return 0; }
    out_str(1, "errno ");
    out_num(1, err);
    out_str(1, "\n");
    return 0;
}

// landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION) is the
// documented way to ask which ABI this kernel implements; it creates nothing.
i64 sb_check_landlock() {
    out_str(1, "landlock: ");
    i64 abi = sb_sys(SN_LANDLOCK_CREATE_RULESET, 0, 0, SB_LANDLOCK_ABI_VERSION, 0, 0, 0);
    if (abi < 0) { out_str(1, "absent\n"); return 0; }
    out_str(1, "abi ");
    out_num(1, abi);
    if (abi < SB_LANDLOCK_ABI_MIN) { out_str(1, " (below the minimum 4)\n"); return 0; }
    out_str(1, "\n");
    return 1;
}

// SECCOMP_GET_ACTION_AVAIL asks whether the kernel knows an action, without
// installing anything. USER_NOTIF is the one this design is built on: it is
// what turns a kill into a sentence (§ 4, decision 4).
i64 sb_check_seccomp() {
    out_str(1, "seccomp: ");
    st32(sb_word, SB_RET_USER_NOTIF);
    if (sb_sys(SN_SECCOMP, SB_SECCOMP_GET_ACTION_AVAIL, 0, sb_word, 0, 0, 0) < 0) {
        out_str(1, "notif absent\n");
        return 0;
    }
    out_str(1, "notif ok\n");
    return 1;
}

// Without root there is no way to MOUNT an overlay outside a user namespace, so
// the probe is what the kernel is willing to say for free: /proc/filesystems is
// the list of filesystems this kernel has REGISTERED. It answers "the driver is
// there and loaded"; whether an overlay over THIS lower filesystem is accepted
// is measured by the box itself (§ Risks 3), not here.
//
// `not loaded` is a distinct answer from `absent`, and the difference was
// measured: on the Lima oracle Docker had already loaded the module and
// /proc/filesystems lists `nodev overlay`; on the x86_64 VPS, which runs no
// container engine, it does not -- while
// /lib/modules/7.0.0-30-generic/kernel/fs/overlayfs/overlay.ko.zst is right
// there. A `mount -t overlay` by root would autoload it (request_module needs
// CAP_SYS_ADMIN in the INIT user namespace, which the box does not have), so
// the honest verdict is "not now, and here is the one command that fixes it".
i64 sb_check_overlay() {
    out_str(1, "overlay: ");
    if (sb_slurp("/proc/filesystems") < 0) { out_str(1, "unknown\n"); return 0; }
    if (!sb_buf_has("overlay", 7)) { out_str(1, "not loaded (modprobe overlay)\n"); return 0; }
    out_str(1, "ok\n");
    return 1;
}

// pidfd_open on this very process: the supervisor reaches the seccomp listener
// through one of these (§ 4), and a kernel without it cannot explain a refusal.
i64 sb_check_pidfd() {
    out_str(1, "pidfd: ");
    i64 pid = sb_sys(SN_GETPID, 0, 0, 0, 0, 0, 0);
    i64 fd = sb_sys(SN_PIDFD_OPEN, pid, 0, 0, 0, 0, 0);
    if (fd < 0) { out_str(1, "absent\n"); return 0; }
    sb_sys(SN_CLOSE, fd, 0, 0, 0, 0, 0);
    out_str(1, "ok\n");
    return 1;
}

i64 sb_check() {
    sb_check_kernel();
    i64 ok = sb_check_userns();
    if (!sb_check_landlock()) ok = 0;
    if (!sb_check_seccomp())  ok = 0;
    if (!sb_check_overlay())  ok = 0;
    if (!sb_check_pidfd())    ok = 0;
    if (ok) return 0;
    return 1;
}

// ---- the refusals (§ 7) ----
// macOS and Windows do not get a sandbox, and they say what to run instead
// rather than failing halfway through one. sandbox-exec(1) is not used: it has
// been documented as deprecated since 10.8, has no CPU/wall/memory model beyond
// setrlimit, and cannot name a refusal (§ 7).
i64 sb_unsupported(uptr tail) {
    if (str_eq(host_os(), "macos")) {
        out_str(2, "mc: the sandbox is a Linux feature; on this Mac: limactl shell mc-k7 build/mc-linux-arm64 ");
        out_str(2, tail);
        out_str(2, " (docs/build.md § Lima)\n");
        return SB_EXIT_SETUP;
    }
    sb_err2("the sandbox is a Linux feature; this host is", host_os());
    return SB_EXIT_SETUP;
}

// ---- option parsing (§ 6) ----
// Returns 0 on success, an exit code otherwise. `i` starts at the first token
// after the verb; on success sb_argi is the index of PATH/BIN and everything
// after it (or after `--`) belongs to the program.
i64 sb_parse(i64 argc, uptr argv, i64 i) {
    sb_nro = 0;
    sb_argi = 0;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--")) { i = i + 1; break; }
        if (ld8(a) != '-') break;                // the first non-option is PATH/BIN

        uptr v = opt_val(a, "--allow=");
        if (v) {
            if (!str_eq(v, "threads")) { sb_err2("unknown --allow value", v); return 2; }
            sb_threads = 1;
            i = i + 1;
            continue;
        }
        v = opt_val(a, "--libc=");
        if (v) {
            if (!str_eq(v, "musl") && !str_eq(v, "gnu")) { sb_err2("unknown --libc value", v); return 2; }
            sb_libc = v;
            i = i + 1;
            continue;
        }
        if (str_eq(a, "--verbose")) { sb_verbose = 1; i = i + 1; continue; }

        // the ones that take the next argument
        i64 num = 0;
        if (str_eq(a, "--time") || str_eq(a, "--wall") || str_eq(a, "--mem") || str_eq(a, "--out")) num = 1;
        i64 takes = num;
        if (str_eq(a, "--stdin") || str_eq(a, "--ro") || str_eq(a, "--cwd") || str_eq(a, "--report")) takes = 1;
        if (!takes) { sb_err2("unknown sandbox option", a); return 2; }
        if (i + 1 >= argc) { sb_err2("option requires an argument", a); return 2; }
        uptr w = ld64(argv + (i + 1) * 8);
        if (num) {
            i64 n = sb_num(w);
            if (n < 0) { sb_err2("not a number", w); return 2; }
            if (str_eq(a, "--time")) sb_time = n;
            if (str_eq(a, "--wall")) sb_wall = n;
            if (str_eq(a, "--mem"))  sb_mem  = n;
            if (str_eq(a, "--out"))  sb_out  = n;
        }
        if (str_eq(a, "--stdin"))  sb_stdin  = w;
        if (str_eq(a, "--cwd"))    sb_cwd    = w;
        if (str_eq(a, "--report")) sb_report = w;
        if (str_eq(a, "--ro")) {
            if (sb_nro >= SB_MAXRO) { sb_err("too many --ro directories"); return 2; }
            st64(sb_ro + sb_nro * 8, w);
            sb_nro = sb_nro + 1;
        }
        i = i + 2;
    }
    sb_argi = i;
    return 0;
}

// ---- the subcommand ----
void sb_usage() {
    out_str(2, "usage: mc sandbox run  [OPTS] PATH [--] [ARGS]\n");
    out_str(2, "       mc sandbox exec [OPTS] BIN  [--] [ARGS]\n");
    out_str(2, "       mc sandbox check\n");
    out_str(2, "OPTS:  --time S  --wall S  --mem MiB  --out MiB  --allow=threads --libc=musl|gnu\n");
    out_str(2, "       --stdin FILE  --ro DIR  --cwd DIR  --report FILE  --verbose\n");
}

i64 sandbox_cmd(i64 argc, uptr argv) {
    if (argc < 3) { sb_usage(); return 2; }
    uptr verb = ld64(argv + 16);

    if (str_eq(verb, "check")) {
        if (!host_sandbox_supported()) return sb_unsupported("sandbox check");
        return sb_check();
    }

    i64 run = str_eq(verb, "run");
    if (!run && !str_eq(verb, "exec")) { sb_err2("unknown sandbox subcommand", verb); sb_usage(); return 2; }

    i64 rc = sb_parse(argc, argv, 3);
    if (rc) return rc;
    if (sb_argi >= argc) {
        if (run) sb_err("sandbox run needs a source path");
        else     sb_err("sandbox exec needs a program");
        return 2;
    }

    if (!host_sandbox_supported()) {
        if (run) return sb_unsupported("sandbox run PATH");
        return sb_unsupported("sandbox exec BIN");
    }

    // Step B is the box: three processes, the mount tree, Landlock, the seccomp
    // listener, the report. Saying so is the honest answer until it exists.
    if (run) sb_err("sandbox run: not in this step");
    else     sb_err("sandbox exec: not in this step");
    return SB_EXIT_SETUP;
}
