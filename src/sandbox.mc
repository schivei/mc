// sandbox.mc — `mc sandbox run|exec|check` (M43, docs/specs/M43.md,
// docs/reference/sandbox.md).
//
// This file is P, the supervisor: the option parser, the plan (which steps run
// and with which argv), the pipes, the uid/gid maps, the wall clock, the
// report and the exit code. The box itself -- I, its mount tree and the step
// children -- is src/sandbox_box.mc, which is compiled after this one and
// reaches back into the record and the helpers defined here.
//
//   P  mc, on the host, host uid          this file
//   I  the box, a child of P              src/sandbox_box.mc
//   C  one step, pid 1 of a pid namespace src/sandbox_box.mc
//
// Everything here goes through the host layer's raw system-call shim
// (host_syscall6, src/sysno_linux_*.mc) and names system calls by their SN_*
// index, never by number: the same source compiles for both architectures and
// for a host that has no system calls of this shape at all, where host_os() is
// what refuses.
//
// STEP B is the box, the caps and the report. Landlock, the seccomp filter and
// the notification channel that turns a kill into `refused: open /etc/shadow`
// are step C; src/sandbox_box.mc carries the marked hook where they go, and
// nothing here pretends they are there -- exit code 125 exists and is not
// reached yet.
//
// It depends on <mc/core_min>, on the host file, and -- for `run DIR`, which
// has to know which file `mc build` is going to write -- on src/toml.mc, which
// <mc/core_sandbox> includes for itself (the #include is once-only, so a
// compiler that also has <mc/core_build> pays for it once).

#include "../lib/prelude.mc"

// ---- errno, as the kernel returns it: a small negative result ----
// Only the four the code TESTS for are named; every other number the kernel
// hands back reaches the report through sb_errname().
#define E_PERM     1
#define E_INTR     4
#define E_NOENT    2
#define E_AGAIN   11
#define E_NOMEM   12
#define E_ACCES   13
#define E_NOSYS   38

// ---- what the probes in `check` need. None of these is a syscall NUMBER;
// they are the arguments the syscalls take, and they are the same on every
// architecture Linux runs on.
#define SB_SIGCHLD                    17
#define SB_SIGKILL                     9
#define SB_SIGXCPU                    24
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

// mount(2) flags. MS_PRIVATE|MS_REC on `/` is the box's first mount, so
// nothing it does afterwards propagates back to the host's mount table.
#define SB_MS_RDONLY                   1
#define SB_MS_NOSUID                   2
#define SB_MS_NODEV                    4
#define SB_MS_REMOUNT                 32
#define SB_MS_BIND                  4096
#define SB_MS_REC                 0x4000
#define SB_MS_PRIVATE            0x40000
#define SB_MS_PRIVATE_REC        0x44000
#define SB_MNT_DETACH                  2

// openat(2). The names without the SB_ prefix belong to the host file
// (src/host_linux.mc) and are the values of the host mc RUNS on; these are the
// values of the kernel it TALKS to, which is Linux by construction here.
#define SB_AT_FDCWD                 -100
#define SB_AT_REMOVEDIR            0x200
#define SB_O_RDONLY                    0
#define SB_O_WRONLY                    1
#define SB_O_CREAT                  0x40
#define SB_O_CLOEXEC              0x80000
#define SB_MODE_755                  493
#define SB_MODE_600                  384

#define SB_LANDLOCK_ABI_VERSION        1   // LANDLOCK_CREATE_RULESET_VERSION
#define SB_LANDLOCK_ABI_MIN            4   // ABI 4 is the floor (§ 0)
#define SB_LANDLOCK_ABI_SCOPE          6   // ABI 6 added the scoped field
#define SB_SECCOMP_GET_ACTION_AVAIL    2
#define SB_RET_USER_NOTIF     0x7FC00000   // SECCOMP_RET_USER_NOTIF

// prctl(2), close_range(2), poll(2), clock_gettime(2)
#define SB_PR_SET_NO_NEW_PRIVS        38
#define SB_CLOSE_RANGE_UNSHARE         2
#define SB_FD_MAX             0xFFFFFFFF
#define SB_POLLIN                      1
#define SB_POLLERR                     8
#define SB_POLLHUP                  0x10
#define SB_CLOCK_MONOTONIC             1

// getrlimit(2) resources. The struct is two u64 (soft, hard), written byte by
// byte like every other record this project hands to a kernel.
#define SB_RLIMIT_CPU                  0
#define SB_RLIMIT_FSIZE                1
#define SB_RLIMIT_STACK                3
#define SB_RLIMIT_CORE                 4
#define SB_RLIMIT_NPROC                6
#define SB_RLIMIT_NOFILE               7
#define SB_RLIMIT_AS                   9
#define SB_NOFILE                     32
// How many processes each step may CREATE, counted by P on the notifications
// (src/seccomp.mc). The compile step needs a handful -- `mc build` writes a
// compiler, spawns it, and may spawn [linker].cmd -- and sixteen is far more
// than the two or three a taught build takes; the run step gets none unless
// --allow=threads is given.
//
// Behind each counter is an RLIMIT_NPROC that has to be LOOSER, or the
// kernel's EAGAIN arrives before the supervisor's sentence (measured at step
// C, note 13: with both at 64 the fork bomb printed `forked 60` and was never
// refused). SB_NPROC_COMPILE_WALL is that backstop for the compile step.
#define SB_NPROC_COMPILE              16
#define SB_NPROC_COMPILE_WALL         32
// The process cap with --allow=threads is counted by P, on the clone
// notifications, so that the refusal has a NAME (`refused: process limit
// (64)`). RLIMIT_NPROC is the backstop behind it and is deliberately looser:
// with both at 64 the kernel's EAGAIN would arrive first -- the box already
// holds I, J and C against the same user -- and the program would see a failed
// fork instead of the supervisor's sentence. Measured: at 64/64 the fork bomb
// printed `forked 60` and was never refused.
#define SB_NPROC_THREADS              64
#define SB_NPROC_BACKSTOP            128
#define SB_STACK_MIB                   8

// `struct utsname`: six NUL-terminated fields of _UTSNAME_LENGTH (65) bytes --
// sysname, nodename, release, version, machine, domainname.
#define SB_UTS_FIELD  65
#define SB_UTS_SIZE  390
#define SB_UTS_RELEASE 130                 // 2 * SB_UTS_FIELD

// ---- the maxima of the four caps (§ 6, docs/reference/cli.md § 3c) ----
// A day, a tebibyte, sixty-four gibibytes. Bigger than anything the playground
// or the suite asks for and small enough that the products below -- MiB times
// 1048576 for RLIMIT_AS and RLIMIT_FSIZE -- stay far inside an i64.
#define SB_SECS_MAX     86400              // --time and --wall, in seconds
#define SB_MEM_MAX    1048576              // --mem, in MiB: 1 TiB
#define SB_OUT_MAX      65536              // --out, in MiB: 64 GiB

// ---- the exit codes of § 6 ----
#define SB_EXIT_CAP     124                // a cap stopped it (cpu, wall)
#define SB_EXIT_REFUSED 125                // a refusal stopped it -- step C's,
                                           // defined here and not produced yet
#define SB_EXIT_SETUP   126                // the box could not be set up

// ---- the two steps ----
#define SB_STEP_COMPILE 0
#define SB_STEP_RUN     1

// ---- where a box setup can fail, as one number over the status pipe ----
// I is a child: it cannot print a diagnostic that keeps the report's order, and
// it must not write host paths into it either. So it names the SITE, P owns the
// sentence, and the errno travels as a number.
#define SBE_UNSHARE      1
#define SBE_MOUNT_ROOT   2
#define SBE_TMPFS        3
#define SBE_MKDIR        4
#define SBE_BIND_MC      5
#define SBE_SRC          6
#define SBE_RO           7
#define SBE_LIB          8
#define SBE_PIVOT        9
#define SBE_UMOUNT      10
#define SBE_HOSTNAME    11
#define SBE_CHDIR       12
#define SBE_RLIMIT      13
#define SBE_FORK        14
#define SBE_PIPE        15
#define SBE_MAPS        16
#define SBE_EXEC        17
#define SBE_STDIN       18
#define SBE_PROJECT     19
#define SBE_LANDLOCK    20               // step C: the two walls, and the one
#define SBE_SECCOMP     21               // way P can fail to reach the listener
#define SBE_LISTENER    22

// ---- the record (§ B3) ----
// Every piece of sandbox state lives here, in ONE arena block, and is reached
// through an accessor over a named offset. The reason is a number: the frozen
// seed's MAXGLOBALS is 512, `mc limits src/mc.mc` reported 437 with step A's
// sixteen globals in, and scripts/check-limits.sh fails at 90% (460). A record
// costs ONE global for the whole milestone.
#define SB_MAXRO 16

#define SB_TIME        0    // --time S,  RLIMIT_CPU seconds
#define SB_WALL        8    // --wall S,  the supervisor's deadline
#define SB_MEM        16    // --mem MiB, RLIMIT_AS
#define SB_OUT        24    // --out MiB, the tmpfs size and RLIMIT_FSIZE
#define SB_THREADS    32    // --allow=threads
#define SB_VERBOSE    40    // --verbose
#define SB_LIBC       48    // --libc=musl|gnu, 0 = from the host's own loader
#define SB_STDIN      56    // --stdin FILE, 0 = EOF
#define SB_CWD        64    // --cwd DIR, inside the box
#define SB_REPORT     72    // --report FILE, 0 = stderr only
#define SB_NRO        80    // how many --ro
#define SB_ARGI       88    // index of PATH/BIN in argv
#define SB_RUN        96    // 1 = `run` (compile, then run), 0 = `exec`
#define SB_DUMP      104    // a --dump-* passed after `run`: the dump IS the run
#define SB_SELF      112    // /proc/self/exe, resolved before any unshare
#define SB_SRCDIR    120    // the host directory that becomes /src
#define SB_ENTRY     128    // the source's name inside /src, 0 for a project
#define SB_STEM      136    // that name without its .mc, the compiler's -o
#define SB_OUTDIR    144    // "/src", or "/out" when the overlay was refused
#define SB_BOXDIR    152    // the host directory the box tmpfs is mounted on
#define SB_ARGV      160    // the process argv, for the run step's own arguments
#define SB_ARGC      168
#define SB_AV0       176    // the compile step's argv, NULL-terminated
#define SB_AV1       184    // the run step's
#define SB_BIN0      192    // what each step execve's
#define SB_BIN1      200
#define SB_SPR       208    // status pipe: I writes, P reads
#define SB_SPW       216
#define SB_MPR       224    // map pipe: P writes one byte, I reads it
#define SB_MPW       232
#define SB_INFD      240    // the step's stdin
#define SB_PIDI      248    // the box
#define SB_PIDC      256    // the step child, as P's namespace numbers it
#define SB_STEP      264    // the step being reported
#define SB_WALLHIT   272    // 1 once P killed the box for the wall clock
#define SB_NOOVL     280    // 1 when the overlay road was refused
#define SB_RC        288    // what `mc sandbox` will return
#define SB_DONE      296    // 1 once a terminal event was recorded
#define SB_ERRC      304    // a setup failure: the site, then the errno
#define SB_ERRNO     312
#define SB_DEAD      320    // the deadline, in milliseconds since SB_T0
#define SB_LINELEN   328    // bytes of a status line already read
#define SB_KIND      336    // [project].kind of a `run DIR`
#define SB_CONF      344    // --config NAME, the mc.toml of a `run DIR`
#define SB_ROOT      352    // --root DIR, the tree that becomes /src
#define SB_RO        360    // SB_MAXRO * 8 = 128 bytes of --ro directories
#define SB_ENV       488    // 3 * 8: HOME=/src, PATH=/, 0
#define SB_RLIM      512    // 16: struct rlimit
#define SB_TS        528    // 16: struct timespec
#define SB_POLL      544    // 8: struct pollfd
#define SB_RU        552    // 144: struct rusage
#define SB_WORD      696    // 16: one small argument passed by address
#define SB_UTS       712    // 390: struct utsname
#define SB_LINE     1104    // 256: the status line being assembled
#define SB_PATH     1360    // 512: a path being built
#define SB_OPTS     1872    // 512: a mount option string being built
#define SB_BUF      2384    // 4096: what a /proc probe reads
#define SB_RBUF     6480    // 24: the report, a BUF record

// ---- step C: the two walls and the explain channel -------------------------
// Everything the filter, the notification and the report of a refusal need.
// It is in the same record for the same reason the rest is (§ B3): the frozen
// seed's MAXGLOBALS is 512 and `mc limits src/mc.mc` has to stay under 460.
#define SB_LFD      6504    // the seccomp listener P holds, -1 when none
#define SB_SYNCR    6512    // the sync pipe: C reads one byte, P writes it
#define SB_SYNCW    6520
#define SB_MMTOT    6528    // the running total of what the step has mapped
#define SB_NCLONE   6536    // clone/clone3 notifications counted for this step
#define SB_NEXEC    6544    // execve notifications counted for this step
#define SB_EXECMAX  6552    // how many this step is allowed
#define SB_NPROF    6560    // how many numbers the profile resolved to
#define SB_NOTIF    6568    // 80: struct seccomp_notif
#define SB_RESP     6648    // 24: struct seccomp_notif_resp
#define SB_IOV      6672    // 32: two struct iovec, local then remote
#define SB_LLATTR   6704    // 24: struct landlock_ruleset_attr
#define SB_PBATTR   6728    // 16: struct landlock_path_beneath_attr (12 used)
#define SB_FPROG    6744    // 16: struct sock_fprog
#define SB_PROF     6760    // SB_MAXPROF * 8: the profile, as kernel numbers
#define SB_BPF      7784    // 2048: the filter, 256 struct sock_filter
#define SB_RPATH    9832    // 4104: a path read out of the step
#define SB_PROCMAX 13936    // how many processes this step may create
#define SB_SIZE    13944

#define SB_MAXPROF 128

uptr sb_state = 0;                          // the one global of the milestone

uptr sb_rec() {
    if (sb_state == 0) {
        sb_state = xalloc(SB_SIZE);
        mem_zero(sb_state, SB_SIZE);
        buf_init(sb_state + SB_RBUF);
        // the defaults the interface publishes (§ 6)
        st64(sb_state + SB_TIME, 2);
        st64(sb_state + SB_WALL, 5);
        st64(sb_state + SB_MEM, 256);
        st64(sb_state + SB_OUT, 64);
        st64(sb_state + SB_OUTDIR, "/src");
        st64(sb_state + SB_INFD, -1);
        st64(sb_state + SB_LFD, -1);
        st64(sb_state + SB_KIND, "exe");
    }
    return sb_state;
}

i64  sb_time()     { return ld64(sb_rec() + SB_TIME); }
i64  sb_wall()     { return ld64(sb_rec() + SB_WALL); }
i64  sb_mem()      { return ld64(sb_rec() + SB_MEM); }
i64  sb_out()      { return ld64(sb_rec() + SB_OUT); }
i64  sb_threads()  { return ld64(sb_rec() + SB_THREADS); }
i64  sb_verbose()  { return ld64(sb_rec() + SB_VERBOSE); }
uptr sb_libc()     { return ld64(sb_rec() + SB_LIBC); }
uptr sb_stdin()    { return ld64(sb_rec() + SB_STDIN); }
uptr sb_cwd()      { return ld64(sb_rec() + SB_CWD); }
uptr sb_reportf()  { return ld64(sb_rec() + SB_REPORT); }
i64  sb_nro()      { return ld64(sb_rec() + SB_NRO); }
i64  sb_argi()     { return ld64(sb_rec() + SB_ARGI); }
i64  sb_is_run()   { return ld64(sb_rec() + SB_RUN); }
uptr sb_dump()     { return ld64(sb_rec() + SB_DUMP); }
uptr sb_self()     { return ld64(sb_rec() + SB_SELF); }
uptr sb_srcdir()   { return ld64(sb_rec() + SB_SRCDIR); }
uptr sb_entry()    { return ld64(sb_rec() + SB_ENTRY); }
uptr sb_stem()     { return ld64(sb_rec() + SB_STEM); }
uptr sb_outdir()   { return ld64(sb_rec() + SB_OUTDIR); }
uptr sb_boxdir()   { return ld64(sb_rec() + SB_BOXDIR); }
uptr sb_argv()     { return ld64(sb_rec() + SB_ARGV); }
i64  sb_argc()     { return ld64(sb_rec() + SB_ARGC); }
uptr sb_av0()      { return ld64(sb_rec() + SB_AV0); }
uptr sb_av1()      { return ld64(sb_rec() + SB_AV1); }
uptr sb_bin0()     { return ld64(sb_rec() + SB_BIN0); }
uptr sb_bin1()     { return ld64(sb_rec() + SB_BIN1); }
i64  sb_spr()      { return ld64(sb_rec() + SB_SPR); }
i64  sb_spw()      { return ld64(sb_rec() + SB_SPW); }
i64  sb_mpr()      { return ld64(sb_rec() + SB_MPR); }
i64  sb_mpw()      { return ld64(sb_rec() + SB_MPW); }
i64  sb_infd()     { return ld64(sb_rec() + SB_INFD); }
i64  sb_pidi()     { return ld64(sb_rec() + SB_PIDI); }
i64  sb_pidc()     { return ld64(sb_rec() + SB_PIDC); }
i64  sb_step()     { return ld64(sb_rec() + SB_STEP); }
i64  sb_wallhit()  { return ld64(sb_rec() + SB_WALLHIT); }
i64  sb_noovl()    { return ld64(sb_rec() + SB_NOOVL); }
i64  sb_rc()       { return ld64(sb_rec() + SB_RC); }
i64  sb_done()     { return ld64(sb_rec() + SB_DONE); }
i64  sb_errc()     { return ld64(sb_rec() + SB_ERRC); }
i64  sb_errno()    { return ld64(sb_rec() + SB_ERRNO); }
i64  sb_dead()     { return ld64(sb_rec() + SB_DEAD); }
i64  sb_linelen()  { return ld64(sb_rec() + SB_LINELEN); }
uptr sb_kind()     { return ld64(sb_rec() + SB_KIND); }
uptr sb_conf()     { return ld64(sb_rec() + SB_CONF); }
uptr sb_root()     { return ld64(sb_rec() + SB_ROOT); }
i64  sb_lfd()      { return ld64(sb_rec() + SB_LFD); }
i64  sb_syncr()    { return ld64(sb_rec() + SB_SYNCR); }
i64  sb_syncw()    { return ld64(sb_rec() + SB_SYNCW); }
i64  sb_mmtot()    { return ld64(sb_rec() + SB_MMTOT); }
i64  sb_nclone()   { return ld64(sb_rec() + SB_NCLONE); }
i64  sb_nexec()    { return ld64(sb_rec() + SB_NEXEC); }
i64  sb_execmax()  { return ld64(sb_rec() + SB_EXECMAX); }
i64  sb_nprof()    { return ld64(sb_rec() + SB_NPROF); }
i64  sb_procmax()  { return ld64(sb_rec() + SB_PROCMAX); }

void set_sb_time(i64 v)    { st64(sb_rec() + SB_TIME, v); }
void set_sb_wall(i64 v)    { st64(sb_rec() + SB_WALL, v); }
void set_sb_mem(i64 v)     { st64(sb_rec() + SB_MEM, v); }
void set_sb_out(i64 v)     { st64(sb_rec() + SB_OUT, v); }
void set_sb_threads(i64 v) { st64(sb_rec() + SB_THREADS, v); }
void set_sb_verbose(i64 v) { st64(sb_rec() + SB_VERBOSE, v); }
void set_sb_libc(uptr v)   { st64(sb_rec() + SB_LIBC, v); }
void set_sb_stdin(uptr v)  { st64(sb_rec() + SB_STDIN, v); }
void set_sb_cwd(uptr v)    { st64(sb_rec() + SB_CWD, v); }
void set_sb_reportf(uptr v){ st64(sb_rec() + SB_REPORT, v); }
void set_sb_nro(i64 v)     { st64(sb_rec() + SB_NRO, v); }
void set_sb_argi(i64 v)    { st64(sb_rec() + SB_ARGI, v); }
void set_sb_is_run(i64 v)  { st64(sb_rec() + SB_RUN, v); }
void set_sb_dump(uptr v)   { st64(sb_rec() + SB_DUMP, v); }
void set_sb_self(uptr v)   { st64(sb_rec() + SB_SELF, v); }
void set_sb_srcdir(uptr v) { st64(sb_rec() + SB_SRCDIR, v); }
void set_sb_entry(uptr v)  { st64(sb_rec() + SB_ENTRY, v); }
void set_sb_stem(uptr v)   { st64(sb_rec() + SB_STEM, v); }
void set_sb_outdir(uptr v) { st64(sb_rec() + SB_OUTDIR, v); }
void set_sb_boxdir(uptr v) { st64(sb_rec() + SB_BOXDIR, v); }
void set_sb_argv(uptr v)   { st64(sb_rec() + SB_ARGV, v); }
void set_sb_argc(i64 v)    { st64(sb_rec() + SB_ARGC, v); }
void set_sb_av0(uptr v)    { st64(sb_rec() + SB_AV0, v); }
void set_sb_av1(uptr v)    { st64(sb_rec() + SB_AV1, v); }
void set_sb_bin0(uptr v)   { st64(sb_rec() + SB_BIN0, v); }
void set_sb_bin1(uptr v)   { st64(sb_rec() + SB_BIN1, v); }
void set_sb_spr(i64 v)     { st64(sb_rec() + SB_SPR, v); }
void set_sb_spw(i64 v)     { st64(sb_rec() + SB_SPW, v); }
void set_sb_mpr(i64 v)     { st64(sb_rec() + SB_MPR, v); }
void set_sb_mpw(i64 v)     { st64(sb_rec() + SB_MPW, v); }
void set_sb_infd(i64 v)    { st64(sb_rec() + SB_INFD, v); }
void set_sb_pidi(i64 v)    { st64(sb_rec() + SB_PIDI, v); }
void set_sb_pidc(i64 v)    { st64(sb_rec() + SB_PIDC, v); }
void set_sb_step(i64 v)    { st64(sb_rec() + SB_STEP, v); }
void set_sb_wallhit(i64 v) { st64(sb_rec() + SB_WALLHIT, v); }
void set_sb_noovl(i64 v)   { st64(sb_rec() + SB_NOOVL, v); }
void set_sb_rc(i64 v)      { st64(sb_rec() + SB_RC, v); }
void set_sb_done(i64 v)    { st64(sb_rec() + SB_DONE, v); }
void set_sb_errc(i64 v)    { st64(sb_rec() + SB_ERRC, v); }
void set_sb_errno(i64 v)   { st64(sb_rec() + SB_ERRNO, v); }
void set_sb_dead(i64 v)    { st64(sb_rec() + SB_DEAD, v); }
void set_sb_linelen(i64 v) { st64(sb_rec() + SB_LINELEN, v); }
void set_sb_kind(uptr v)   { st64(sb_rec() + SB_KIND, v); }
void set_sb_conf(uptr v)   { st64(sb_rec() + SB_CONF, v); }
void set_sb_root(uptr v)   { st64(sb_rec() + SB_ROOT, v); }
void set_sb_lfd(i64 v)     { st64(sb_rec() + SB_LFD, v); }
void set_sb_syncr(i64 v)   { st64(sb_rec() + SB_SYNCR, v); }
void set_sb_syncw(i64 v)   { st64(sb_rec() + SB_SYNCW, v); }
void set_sb_mmtot(i64 v)   { st64(sb_rec() + SB_MMTOT, v); }
void set_sb_nclone(i64 v)  { st64(sb_rec() + SB_NCLONE, v); }
void set_sb_nexec(i64 v)   { st64(sb_rec() + SB_NEXEC, v); }
void set_sb_execmax(i64 v) { st64(sb_rec() + SB_EXECMAX, v); }
void set_sb_nprof(i64 v)   { st64(sb_rec() + SB_NPROF, v); }
void set_sb_procmax(i64 v) { st64(sb_rec() + SB_PROCMAX, v); }

// the buffers, by address
uptr sb_env()   { return sb_rec() + SB_ENV; }
uptr sb_rlim()  { return sb_rec() + SB_RLIM; }
uptr sb_ts()    { return sb_rec() + SB_TS; }
uptr sb_pollp() { return sb_rec() + SB_POLL; }
uptr sb_ru()    { return sb_rec() + SB_RU; }
uptr sb_word()  { return sb_rec() + SB_WORD; }
uptr sb_uts()   { return sb_rec() + SB_UTS; }
uptr sb_line()  { return sb_rec() + SB_LINE; }
uptr sb_path()  { return sb_rec() + SB_PATH; }
uptr sb_optsb() { return sb_rec() + SB_OPTS; }
uptr sb_buf()   { return sb_rec() + SB_BUF; }
uptr sb_rbuf()  { return sb_rec() + SB_RBUF; }
uptr sb_notifp(){ return sb_rec() + SB_NOTIF; }
uptr sb_respp() { return sb_rec() + SB_RESP; }
uptr sb_iovp()  { return sb_rec() + SB_IOV; }
uptr sb_llattr(){ return sb_rec() + SB_LLATTR; }
uptr sb_pbattr(){ return sb_rec() + SB_PBATTR; }
uptr sb_fprogp(){ return sb_rec() + SB_FPROG; }
uptr sb_profp() { return sb_rec() + SB_PROF; }
uptr sb_bpfp()  { return sb_rec() + SB_BPF; }
uptr sb_rpath() { return sb_rec() + SB_RPATH; }

uptr sb_ro_at(i64 i) { return ld64(sb_rec() + SB_RO + i * 8); }

void sb_ro_add(uptr d) {
    st64(sb_rec() + SB_RO + sb_nro() * 8, d);
    set_sb_nro(sb_nro() + 1);
}

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

// the name of a small errno, or `errno N`. The report has to be readable by a
// person and stable across runs, and these sixteen cover every failure the box
// has produced on either host.
uptr sb_errname(i64 e) {
    if (e == 1)  return "EPERM";
    if (e == 2)  return "ENOENT";
    if (e == 4)  return "EINTR";
    if (e == 5)  return "EIO";
    if (e == 9)  return "EBADF";
    if (e == 11) return "EAGAIN";
    if (e == 12) return "ENOMEM";
    if (e == 13) return "EACCES";
    if (e == 16) return "EBUSY";
    if (e == 17) return "EEXIST";
    if (e == 19) return "ENODEV";
    if (e == 20) return "ENOTDIR";
    if (e == 21) return "EISDIR";
    if (e == 22) return "EINVAL";
    if (e == 28) return "ENOSPC";
    if (e == 38) return "ENOSYS";
    return tm_cat("errno ", tm_num_str(e));
}

// the name of a signal, for `killed: signal N (NAME)`. Both architectures agree
// on every number below (the ones that differ, SIGSTKFLT and friends, are not
// ways a program in the box dies).
uptr sb_signame(i64 s) {
    if (s == 2)  return "SIGINT";
    if (s == 4)  return "SIGILL";
    if (s == 6)  return "SIGABRT";
    if (s == 7)  return "SIGBUS";
    if (s == 8)  return "SIGFPE";
    if (s == 9)  return "SIGKILL";
    if (s == 11) return "SIGSEGV";
    if (s == 13) return "SIGPIPE";
    if (s == 15) return "SIGTERM";
    if (s == 24) return "SIGXCPU";
    if (s == 25) return "SIGXFSZ";
    return "signal";
}

// a non-negative decimal, -1 when it is not a number at all, -2 when it is
// too big to be one. Used for --time/--wall/--mem/--out, where a bad value has
// to be a diagnostic and not a silent 0 -- and, since the post-M43 review, not
// a WRAPPED one either: the accumulation used to run unbounded, so
// `--mem 999999999999999999999999` came back as whatever the low 64 bits of
// that were and was then multiplied by 1048576 for RLIMIT_AS.
//
// The ceiling is one number for all four options and it is far above every
// per-option maximum below (SB_MEM_MAX is the largest, a million); what it
// bounds is the arithmetic, so `v * 10 + d` can never reach 2^63.
#define SB_NUM_CEIL 1000000000000
#define SB_NUM_BAD  -1
#define SB_NUM_BIG  -2

i64 sb_num(uptr s) {
    if (s == 0) return SB_NUM_BAD;
    if (ld8(s) == 0) return SB_NUM_BAD;
    i64 v = 0;
    i64 i = 0;
    loop {
        i64 c = ld8(s + i);
        if (c == 0) break;
        if (c < '0' || c > '9') return SB_NUM_BAD;
        v = v * 10 + (c - '0');
        if (v > SB_NUM_CEIL) return SB_NUM_BIG;
        i = i + 1;
    }
    return v;
}

// n bytes of `path` into the record's scratch buffer, NUL-terminated; -errno on
// failure. Everything `check` reads from /proc goes through here, with the shim
// rather than the compiler's own open/read: this is also what proves the shim
// on the host.
i64 sb_slurp(uptr path) {
    st8(sb_buf(), 0);
    i64 fd = sb_sys(SN_OPENAT, SB_AT_FDCWD, path, SB_O_RDONLY, 0, 0, 0);
    if (fd < 0) return fd;
    i64 n = sb_sys(SN_READ, fd, sb_buf(), 4095, 0, 0, 0);
    sb_sys(SN_CLOSE, fd, 0, 0, 0, 0, 0);
    if (n < 0) return n;
    st8(sb_buf() + n, 0);
    return n;
}

// is `needle` anywhere in what sb_slurp just read? /proc/filesystems writes one
// filesystem per line, `nodev\toverlay`, so a plain substring search over the
// buffer is what answers "is overlay a filesystem this kernel knows".
i64 sb_buf_has(uptr needle, i64 n) {
    i64 i = 0;
    loop {
        if (ld8(sb_buf() + i) == 0) break;
        if (mem_eq(sb_buf() + i, needle, n)) return 1;
        i = i + 1;
    }
    return 0;
}

// ---- paths ----
// A mount source is an absolute path and `mc sandbox run tests/013-putnum.mc`
// is not one, so every path the user gives is resolved against getcwd(2) and
// normalised by the compiler's own path_join (src/lex.mc).
uptr sb_getcwd() {
    i64 n = sb_sys(SN_GETCWD, sb_path(), 512, 0, 0, 0, 0);
    if (n <= 0) return "/";
    return xstrdup(sb_path(), cstrlen(sb_path()));
}

uptr sb_abs(uptr p) {
    if (ld8(p) == '/') return path_norm(xstrdup(p, cstrlen(p)));
    return path_join(tm_cat(sb_getcwd(), "/."), p);
}

// everything after the last '/'
uptr sb_base(uptr p) {
    i64 n = cstrlen(p);
    i64 cut = 0;
    i64 i = 0;
    while (i < n) {
        if (ld8(p + i) == '/') cut = i + 1;
        i = i + 1;
    }
    return xstrdup(p + cut, n - cut);
}

// everything before it, or "/" -- p is absolute by the time this is called
uptr sb_dirname(uptr p) {
    i64 n = cstrlen(p);
    i64 cut = 0;
    i64 i = 0;
    while (i < n) {
        if (ld8(p + i) == '/') cut = i;
        i = i + 1;
    }
    if (cut == 0) return "/";
    return xstrdup(p, cut);
}

i64 sb_ends(uptr s, uptr suf) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(suf);
    if (m > n) return 0;
    return mem_eq(s + n - m, suf, m);
}

// the name without its `.mc`
uptr sb_strip_mc(uptr p) {
    if (!sb_ends(p, ".mc")) return p;
    return xstrdup(p, cstrlen(p) - 3);
}

// Does this path exist, and is it a directory? A `struct stat` would answer
// both, and its layout DIFFERS between the two architectures (st_mode is at
// offset 16 on AArch64 and at 24 on x86-64) -- so the question is asked with
// openat instead, which has the same shape everywhere: a directory accepts a
// trailing "/." and a file answers ENOTDIR.
i64 sb_exists(uptr p) {
    i64 fd = sb_sys(SN_OPENAT, SB_AT_FDCWD, p, SB_O_RDONLY, 0, 0, 0);
    if (fd < 0) return 0;
    sb_sys(SN_CLOSE, fd, 0, 0, 0, 0, 0);
    return 1;
}

i64 sb_is_dir(uptr p) { return sb_exists(tm_cat(p, "/.")); }

// milliseconds on the monotonic clock. It never reaches the report -- the wall
// clock is a decision, not a measurement to print (§ 6: no digit that changes
// between runs).
i64 sb_now_ms() {
    if (sb_sys(SN_CLOCK_GETTIME, SB_CLOCK_MONOTONIC, sb_ts(), 0, 0, 0, 0) < 0) return 0;
    return ld64(sb_ts()) * 1000 + ld64(sb_ts() + 8) / 1000000;
}

void sb_kill_box();                              // defined below, with the supervisor
void sb_note_setup(i64 site, i64 err);
void sb_notif_pump();                            // src/seccomp.mc: the policy

// ---- the report (§ 6) ----
// One line per event, each starting with `sandbox: `, fixed vocabulary, no
// timing, no pid, no host path. It is buffered and written when the box is
// gone, so the program's own stdout and stderr -- which are P's own fds, passed
// straight through -- are never interleaved with it.
void sb_say(uptr text) {
    buf_put(sb_rbuf(), "sandbox: ", 9);
    buf_put(sb_rbuf(), text, cstrlen(text));
    buf_u8(sb_rbuf(), '\n');
}

// the report to stderr, and -- when --report was given -- to that file as well.
// § 6 wrote "instead of stderr"; both is what the milestone asks for, so that a
// script can compare two runs byte for byte without losing the diagnostic a
// person reads.
void sb_report_flush() {
    out_bytes(2, buf_p(sb_rbuf()), buf_len(sb_rbuf()));
    if (sb_reportf()) write_file(sb_reportf(), sb_rbuf());
}

// ---- `mc sandbox check` (§ 6) ----
// One line per capability, on stdout, in a fixed vocabulary; exit 1 when any of
// the five the box needs is missing. This is the guard `make check` and the CI
// leg consult, in the `test-linux: SKIPPED (...)` style.

// the kernel release out of uname(2)
void sb_check_kernel() {
    out_str(1, "kernel: ");
    if (sb_sys(SN_UNAME, sb_uts(), 0, 0, 0, 0, 0) < 0) { out_str(1, "unknown\n"); return; }
    out_str(1, sb_uts() + SB_UTS_RELEASE);
    out_str(1, "\n");
}

// 1 when kernel.apparmor_restrict_unprivileged_userns is on. Ubuntu has shipped
// it as 1 since 23.10, and it is the ONE thing that makes the unprivileged path
// fail on a stock install (§ Risks 1) -- so an EPERM from unshare is reported
// as `restricted (apparmor)` when it is on and as a bare `EPERM` when it is not.
i64 sb_apparmor_userns() {
    if (sb_slurp("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") < 0) return 0;
    return ld8(sb_buf()) != '0' && ld8(sb_buf()) != 0;
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
    st64(sb_word(), 0);
    i64 w = sb_sys(SN_WAIT4, pid, sb_word(), 0, 0, 0, 0);
    if (w < 0) { out_str(1, "cannot wait\n"); return 0; }
    i64 st = ld32(sb_word());
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
    // ABI 6 is what added the `scoped` field -- abstract unix sockets and
    // signals scoped to the Landlock domain. Below it the ruleset simply does
    // not carry that word, so the box loses one restriction silently: a
    // program could signal a process outside the box if one were visible to
    // it, and could name an abstract unix socket. Nothing in the box makes
    // either reachable (the pid namespace hides every other process and the
    // network namespace is empty), which is why 4 and not 6 is the floor --
    // but a missing wall is said out loud rather than assumed away.
    if (abi < SB_LANDLOCK_ABI_SCOPE) { out_str(1, " (no scoped signals below 6)\n"); return 1; }
    out_str(1, "\n");
    return 1;
}

// SECCOMP_GET_ACTION_AVAIL asks whether the kernel knows an action, without
// installing anything. USER_NOTIF is the one this design is built on: it is
// what turns a kill into a sentence (§ 4, decision 4).
i64 sb_check_seccomp() {
    out_str(1, "seccomp: ");
    st32(sb_word(), SB_RET_USER_NOTIF);
    if (sb_sys(SN_SECCOMP, SB_SECCOMP_GET_ACTION_AVAIL, 0, sb_word(), 0, 0, 0) < 0) {
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
// is measured by the box itself (§ Risks 3), which falls back to a read-only
// bind and an /out tmpfs when it is not.
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
    set_sb_nro(0);
    set_sb_argi(0);
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--")) { i = i + 1; break; }
        if (ld8(a) != '-') break;                // the first non-option is PATH/BIN

        // § 5: a --dump-* after `run` makes the dump the whole box -- one step,
        // and its stdout is the output. The flag is passed to /mc unchanged.
        if (mem_eq(a, "--dump-", 7)) {
            set_sb_dump(a);
            i = i + 1;
            continue;
        }
        uptr v = opt_val(a, "--allow=");
        if (v) {
            if (!str_eq(v, "threads")) { sb_err2("unknown --allow value", v); return 2; }
            set_sb_threads(1);
            i = i + 1;
            continue;
        }
        v = opt_val(a, "--libc=");
        if (v) {
            if (!str_eq(v, "musl") && !str_eq(v, "gnu")) { sb_err2("unknown --libc value", v); return 2; }
            set_sb_libc(v);
            i = i + 1;
            continue;
        }
        if (str_eq(a, "--verbose")) { set_sb_verbose(1); i = i + 1; continue; }

        // the ones that take the next argument
        i64 num = 0;
        if (str_eq(a, "--time") || str_eq(a, "--wall") || str_eq(a, "--mem") || str_eq(a, "--out")) num = 1;
        i64 takes = num;
        if (str_eq(a, "--stdin") || str_eq(a, "--ro") || str_eq(a, "--cwd") || str_eq(a, "--report")) takes = 1;
        if (str_eq(a, "--config") || str_eq(a, "--root")) takes = 1;
        if (!takes) { sb_err2("unknown sandbox option", a); return 2; }
        if (i + 1 >= argc) { sb_err2("option requires an argument", a); return 2; }
        uptr w = ld64(argv + (i + 1) * 8);
        if (num) {
            i64 n = sb_num(w);
            if (n == SB_NUM_BIG) { sb_err2(a, "number too large"); return 2; }
            if (n < 0) { sb_err2("not a number", w); return 2; }
            // Every cap has a maximum, and every cap has a minimum of one.
            // The maxima are documented in docs/reference/cli.md § 3c: a day
            // of CPU or of wall clock, a tebibyte of address space, sixty-four
            // gibibytes of output. They are not the kernel's limits -- they
            // are the largest values that still MEAN something here, and a
            // value past one of them is a typo or an attack, never a request.
            // Zero is refused for all four: --time 0 or --wall 0 kills the box
            // before it runs, --mem 0 is an RLIMIT_AS nothing can start under,
            // and --out 0 is a tmpfs the mount refuses.
            i64 max = SB_SECS_MAX;
            if (str_eq(a, "--mem")) max = SB_MEM_MAX;
            if (str_eq(a, "--out")) max = SB_OUT_MAX;
            if (n > max) { sb_err2(a, tm_cat("at most ", tm_num_str(max))); return 2; }
            if (n < 1) { sb_err2(a, "must be at least 1"); return 2; }
            if (str_eq(a, "--time")) set_sb_time(n);
            if (str_eq(a, "--wall")) set_sb_wall(n);
            if (str_eq(a, "--mem"))  set_sb_mem(n);
            if (str_eq(a, "--out"))  set_sb_out(n);
        }
        if (str_eq(a, "--stdin"))  set_sb_stdin(w);
        if (str_eq(a, "--cwd"))    set_sb_cwd(w);
        if (str_eq(a, "--report")) set_sb_reportf(w);
        if (str_eq(a, "--config")) set_sb_conf(w);
        if (str_eq(a, "--root"))   set_sb_root(w);
        if (str_eq(a, "--ro")) {
            if (sb_nro() >= SB_MAXRO) { sb_err("too many --ro directories"); return 2; }
            sb_ro_add(w);
        }
        i = i + 2;
    }
    set_sb_argi(i);
    return 0;
}

// ---- the plan (§ 5) ----
// What the box will do, decided on the host, where the paths still exist.
//
//   prog.mc          /mc --exe /src/prog.mc -o <outdir>/prog   then <outdir>/prog
//   prog.mc --dump-* /mc --dump-asm /src/prog.mc               and nothing else
//   DIR (mc.toml)    /mc build /src                            then /src/<out>
//   exec BIN         nothing                                   then /src/BIN
//
// Only the names are settled here: the argv arrays are built by sb_argv_build,
// which the box calls once it knows whether /src is writable (the overlay road)
// or read-only with an /out beside it (the fallback).
i64 sb_plan(i64 argc, uptr argv) {
    set_sb_argv(argv);
    set_sb_argc(argc);
    uptr p = sb_abs(ld64(argv + sb_argi() * 8));
    if (!sb_exists(p)) { sb_err2("cannot open", p); return SB_EXIT_SETUP; }

    if (sb_is_run() && sb_is_dir(p)) {
        // a project: `mc build /src` writes what [project].out names, and only
        // a `kind = "exe"` is something to run afterwards.
        set_sb_srcdir(p);
        set_sb_entry(0);
        uptr name = "mc.toml";
        if (sb_conf()) name = sb_conf();
        uptr cfg = tm_cat(tm_cat(p, "/"), name);
        if (!sb_exists(cfg)) { sb_err2("no such config in the project", cfg); return SB_EXIT_SETUP; }
        toml_parse(cfg);
        uptr o = toml_get("project.out");
        if (o == 0) { sb_err2("no [project].out in", cfg); return SB_EXIT_SETUP; }
        // [project].out is relative to the CONFIG's own directory, which is not
        // necessarily the root of /src: `mc sandbox run . --config
        // examples/lang/mc.linux.toml` is how a project that includes files
        // from outside its own directory is built -- /src is then the tree that
        // holds both, and the overlay still keeps every byte of it read-only
        // from the host's point of view.
        uptr sub = "";
        i64 k = cstrlen(name);
        while (k > 0) {
            if (ld8(name + k - 1) == '/') break;
            k = k - 1;
        }
        if (k > 0) sub = xstrdup(name, k);       // with its trailing slash
        set_sb_stem(tm_cat(sub, o));
        uptr k = toml_get("project.kind");
        if (k) set_sb_kind(k);
        return 0;
    }

    // Which tree becomes /src. By default it is the source's own directory,
    // which is the smallest thing that can compile it; --root widens it to a
    // tree the source is inside, and that is what a source reaching a file
    // BESIDE its own directory needs -- `#include "../lib/sys.mc"` resolves in
    // the box exactly as it does on the host, or not at all.
    uptr dir = sb_dirname(p);
    uptr rel = sb_base(p);
    if (sb_root()) {
        dir = sb_abs(sb_root());
        i64 n = cstrlen(dir);
        if (!mem_eq(p, dir, n) || ld8(p + n) != '/') {
            sb_err2("not inside --root", p);
            return SB_EXIT_SETUP;
        }
        rel = xstrdup(p + n + 1, cstrlen(p) - n - 1);
    }
    set_sb_srcdir(dir);
    set_sb_entry(rel);
    set_sb_stem(sb_strip_mc(rel));
    if (sb_is_run() && !sb_ends(p, ".mc")) {
        sb_err2("sandbox run takes a .mc source or a project directory", p);
        return SB_EXIT_SETUP;
    }
    return 0;
}

// The compile step needs to know which libc family the box will offer it: the
// binary it writes names its own loader BY PATH (M42), and /lib comes from this
// host. --libc= wins; otherwise it is whichever loader is on this host's disk.
// It is RESOLVED, not asked twice: step C's filter is built inside the box,
// where /lib is a read-only bind and the question "is there a musl loader on
// this disk" would be answered by the box's own tree. So P settles it here,
// before any fork, and every later reader -- the compile step's flag, the
// profile the filter is built from -- reads the same word.
void sb_resolve_libc() {
    if (sb_libc()) return;
    uptr l = "musl";
    if (!sb_exists(tm_cat(tm_cat("/lib/ld-musl-", host_arch()), ".so.1"))) l = "gnu";
    set_sb_libc(l);
}

uptr sb_libc_flag() {
    if (str_eq(sb_libc(), "musl")) return 0;     // the compiler's own default
    return "--libc=gnu";
}

// the argv of both steps, in the box, once the road for /src is known
void sb_argv_build() {
    uptr av = xalloc(9 * 8);
    i64 n = 0;
    st64(av + n * 8, "/mc"); n = n + 1;
    if (sb_entry() == 0) {
        st64(av + n * 8, "build"); n = n + 1;
        st64(av + n * 8, "/src");  n = n + 1;
        if (sb_conf()) {
            st64(av + n * 8, "--config"); n = n + 1;
            st64(av + n * 8, tm_cat("/src/", sb_conf())); n = n + 1;
        }
    } else if (sb_dump()) {
        st64(av + n * 8, sb_dump()); n = n + 1;
        st64(av + n * 8, tm_cat("/src/", sb_entry())); n = n + 1;
    } else {
        st64(av + n * 8, "--exe"); n = n + 1;
        st64(av + n * 8, tm_cat("/src/", sb_entry())); n = n + 1;
        st64(av + n * 8, "-o"); n = n + 1;
        st64(av + n * 8, tm_cat(tm_cat(sb_outdir(), "/"), sb_stem())); n = n + 1;
        uptr lf = sb_libc_flag();
        if (lf) { st64(av + n * 8, lf); n = n + 1; }
    }
    st64(av + n * 8, 0);
    set_sb_av0(av);
    set_sb_bin0("/mc");

    // the run step: the program, then everything the user put after PATH
    uptr prog = tm_cat(tm_cat(sb_outdir(), "/"), sb_stem());
    if (sb_entry() == 0) prog = tm_cat("/src/", sb_stem());
    if (!sb_is_run()) prog = tm_cat("/src/", sb_entry());
    i64 extra = sb_argc() - sb_argi() - 1;
    if (extra < 0) extra = 0;
    uptr rv = xalloc((extra + 2) * 8);
    st64(rv, prog);
    i64 i = 0;
    while (i < extra) {
        st64(rv + (i + 1) * 8, ld64(sb_argv() + (sb_argi() + 1 + i) * 8));
        i = i + 1;
    }
    st64(rv + (extra + 1) * 8, 0);
    set_sb_av1(rv);
    set_sb_bin1(prog);
}

// ---- the uid and gid maps, written by P (§ 1) ----
// Unprivileged, /proc/<I>/uid_map may map only P's own uid, and only after
// /proc/<I>/setgroups has been written `deny`. As root, the box's uid 0 maps to
// host 65534 so that "root inside" is nobody outside. One code path, one
// number: the outer uid is P's, unless P is root.
i64 sb_write_file_raw(uptr path, uptr text) {
    i64 fd = sb_sys(SN_OPENAT, SB_AT_FDCWD, path, SB_O_WRONLY, 0, 0, 0);
    if (fd < 0) return fd;
    i64 n = sb_sys(SN_WRITE, fd, text, cstrlen(text), 0, 0, 0);
    sb_sys(SN_CLOSE, fd, 0, 0, 0, 0, 0);
    if (n < 0) return n;
    return 0;
}

// The map itself, and the one place root and unprivileged differ. § 1 wrote
// "as root, P maps the box's uid 0 to host 65534 so that root inside is nobody
// outside". Two kernel answers, in this order, say otherwise:
//
//   1. `0 65534 1` ALONE leaves the caller unmapped -- outer uid 0 has no inner
//      number, the box's fsuid becomes the overflow uid, and every file it
//      creates answers EOVERFLOW. (Measured on both hosts; it was the box's
//      first mkdir.)
//   2. `0 65534 1` + `1 0 1` + setuid(0) fixes that and fails the next test: an
//      overlay copy-up into a directory the LOWER layer owns needs permission
//      on that directory, and a tree owned by outer 0 is inner 1 -- mode 755,
//      not the box's -- so `mc --exe` inside the box answered `cannot create:
//      /src/tests/061-pass` on the x86_64 VPS, where the tree belongs to root.
//      CAP_DAC_OVERRIDE does not help: capable_wrt_inode_uidgid() requires the
//      inode's owner to be MAPPED in the namespace asking.
//
// So the root map is the full identity range, `0 0 65536`: every ordinary uid
// is mapped, the box is root-in-its-own-namespace exactly as it is
// root-on-the-host, and it can read and write any tree its caller could. What
// keeps that from being a hole is the tree itself -- everything mounted from
// the host is read-only, and the only writable filesystem in the box is a
// tmpfs that dies with it (§ 3).
//
// Unprivileged, `0 <uid> 1` is the ONLY line the kernel accepts, and it maps
// the caller: the box's uid 0 IS the caller, with the caller's own reach.
uptr sb_map_text(i64 id) {
    if (id == 0) return "0 0 65536\n";
    return tm_cat("0 ", tm_cat(tm_num_str(id), " 1\n"));
}

i64 sb_write_maps(i64 pid) {
    uptr d = tm_cat("/proc/", tm_cat(tm_num_str(pid), "/"));
    i64 uid = sb_sys(SN_GETUID, 0, 0, 0, 0, 0, 0);
    i64 gid = sb_sys(SN_GETGID, 0, 0, 0, 0, 0, 0);
    // setgroups must be denied before an unprivileged gid_map, and is allowed
    // (and pointless) for a privileged one -- so its result is not the answer.
    sb_write_file_raw(tm_cat(d, "setgroups"), "deny");
    i64 rc = sb_write_file_raw(tm_cat(d, "gid_map"), sb_map_text(gid));
    if (rc < 0) return rc;
    return sb_write_file_raw(tm_cat(d, "uid_map"), sb_map_text(uid));
}

// ---- the supervisor (§ 1, § 4 Time) ----
// I speaks one line per event over the status pipe, in a vocabulary of five
// letters. The step number travels in every line, so the order P sees can never
// make it attribute a status to the wrong step.
//
//   U                 the namespaces exist; the maps are wanted
//   O                 the overlay was refused and /src is read-only
//   E <site> <errno>  the box could not be built
//   P <pid>           a step child, as P's own namespace numbers it
//   X <step> <code>   that step exited
//   S <step> <sig> <cpu>  a signal killed it; cpu is 1 when the step had spent
//                         its whole --time when it died, which is what tells a
//                         cpu cap from a program that died for its own reasons
i64 sb_field(uptr s, i64 k) {
    i64 i = 0;
    i64 f = 0;
    loop {
        while (ld8(s + i) == ' ') { i = i + 1; }
        if (ld8(s + i) == 0) return -1;
        if (f == k) {
            i64 v = 0;
            i64 neg = 0;
            if (ld8(s + i) == '-') { neg = 1; i = i + 1; }
            while (ld8(s + i) >= '0' && ld8(s + i) <= '9') {
                v = v * 10 + (ld8(s + i) - '0');
                i = i + 1;
            }
            if (neg) return 0 - v;
            return v;
        }
        while (ld8(s + i) != ' ' && ld8(s + i) != 0) { i = i + 1; }
        f = f + 1;
    }
}

// What the explain channel saw, under --verbose only. The execve count is not
// noise -- it is exactly the number § 5 predicts, one for a run step and three
// for a taught build (/mc, the compiler `mc build` writes, and that compiler's
// --entry-only child) -- but it is a fact about the STEP and not an event of
// the box, so it stays out of the fixed vocabulary of the report.
void sb_note_counts(i64 step) {
    if (!sb_verbose()) return;
    uptr pre = "";
    if (step == SB_STEP_COMPILE) pre = "compile: ";
    sb_say(tm_cat(pre, tm_cat("execve ", tm_num_str(sb_nexec()))));
}

void sb_note_exit(i64 step, i64 code) {
    if (sb_done()) return;                       // a terminal event is final
    sb_note_counts(step);
    if (step == SB_STEP_COMPILE) {
        sb_say(tm_cat("compile: exit ", tm_num_str(code)));
        if (code != 0) { set_sb_rc(code); set_sb_done(1); }
        return;
    }
    sb_say(tm_cat("exit ", tm_num_str(code)));
    set_sb_rc(code);
    set_sb_done(1);
}

void sb_note_signal(i64 step, i64 sig, i64 cpu) {
    if (sb_done()) return;
    uptr pre = "";
    if (step == SB_STEP_COMPILE) pre = "compile: ";
    if (sb_wallhit()) {
        sb_say(tm_cat(pre, tm_cat("killed: wall clock (", tm_cat(tm_num_str(sb_wall()), " s)"))));
        set_sb_rc(SB_EXIT_CAP);
    } else if (cpu) {
        sb_say(tm_cat(pre, tm_cat("killed: cpu limit (", tm_cat(tm_num_str(sb_time()), " s)"))));
        set_sb_rc(SB_EXIT_CAP);
    } else {
        sb_say(tm_cat(pre, tm_cat("killed: signal ",
              tm_cat(tm_num_str(sig), tm_cat(" (", tm_cat(sb_signame(sig), ")"))))));
        set_sb_rc(128 + sig);
    }
    set_sb_done(1);
}

// the FIRST failure is the one to report: a box that could not write its maps
// then fails at its first mount, and `cannot mount /` would blame the symptom.
void sb_note_setup(i64 site, i64 err) {
    if (sb_errc()) return;
    set_sb_errc(site);
    set_sb_errno(err);
}

// one complete status line
void sb_line_do(uptr s) {
    i64 c = ld8(s);
    if (c == 'U') {
        i64 m = sb_write_maps(sb_pidi());
        if (m < 0) sb_note_setup(SBE_MAPS, 0 - m);
        sb_sys(SN_WRITE, sb_mpw(), "1", 1, 0, 0, 0);
        sb_sys(SN_CLOSE, sb_mpw(), 0, 0, 0, 0, 0);
        set_sb_mpw(-1);
        return;
    }
    if (c == 'O') { set_sb_noovl(1); return; }
    if (c == 'B') { set_sb_step(sb_field(s + 1, 0)); return; }
    if (c == 'E') { sb_note_setup(sb_field(s + 1, 0), sb_field(s + 1, 1)); return; }
    if (c == 'P') { set_sb_pidc(sb_field(s + 1, 0)); return; }
    if (c == 'L') { sb_fetch_listener(sb_field(s + 1, 0)); return; }
    if (c == 'X') { sb_note_exit(sb_field(s + 1, 0), sb_field(s + 1, 1)); return; }
    if (c == 'S') { sb_note_signal(sb_field(s + 1, 0), sb_field(s + 1, 1), sb_field(s + 1, 2)); return; }
}

// bytes from the status pipe into the line buffer, one line at a time. The
// bytes land in the record's scratch buffer, which nothing else touches while
// the box is alive.
void sb_pump(i64 n) {
    i64 i = 0;
    while (i < n) {
        i64 ch = ld8(sb_buf() + i);
        if (ch == '\n') {
            st8(sb_line() + sb_linelen(), 0);
            sb_line_do(sb_line());
            set_sb_linelen(0);
        } else if (sb_linelen() < 190) {
            st8(sb_line() + sb_linelen(), ch);
            set_sb_linelen(sb_linelen() + 1);
        }
        i = i + 1;
    }
}

// ---- the listener (§ 4) ----------------------------------------------------
// P has to hold the seccomp listener before C runs a single instruction of the
// program, and it cannot open it directly: the listener is a descriptor in C,
// and C lives in a pid namespace whose numbers mean nothing here -- P cannot
// even NAME C until the first notification arrives, which is exactly what it
// needs the listener for. So the fd travels in two hops of pidfd_getfd(2),
// each one between a process and one of its own descendants:
//
//   J  pidfd_open(C) + pidfd_getfd(fd, <the number C reported>)   -> L in J
//   P  pidfd_open(J) + pidfd_getfd(fd, L)                         -> the listener
//
// Both hops need PTRACE_MODE_ATTACH_REALCREDS on the target, and both have it
// for the same two reasons: same real uid (the user namespace remaps, it does
// not change the credentials), and a descendant, which is what Yama's
// ptrace_scope = 1 -- the value measured on both hosts -- allows.
//
// P is the one that then releases C, by writing the sync byte. Until it does,
// C is blocked on a read and has issued nothing.
void sb_fetch_listener(i64 jfd) {
    if (sb_lfd() >= 0) { sb_sys(SN_CLOSE, sb_lfd(), 0, 0, 0, 0, 0); set_sb_lfd(-1); }
    i64 pf = sb_sys(SN_PIDFD_OPEN, sb_pidc(), 0, 0, 0, 0, 0);
    if (pf < 0) { sb_note_setup(SBE_LISTENER, 0 - pf); sb_kill_box(); return; }
    i64 l = sb_sys(SN_PIDFD_GETFD, pf, jfd, 0, 0, 0, 0);
    sb_sys(SN_CLOSE, pf, 0, 0, 0, 0, 0);
    if (l < 0) { sb_note_setup(SBE_LISTENER, 0 - l); sb_kill_box(); return; }
    set_sb_lfd(l);

    // the counters are per step: a compile that mapped 40 MiB says nothing
    // about what the program it wrote may map.
    set_sb_mmtot(0);
    set_sb_nclone(0);
    set_sb_nexec(0);
    // How many execve's this step may make. The compile step is allowed three
    // -- /mc itself, the compiler `mc build` teaches, and that compiler's own
    // --entry-only child (§ 5) -- and the run step exactly one, its own.
    i64 mx = 1;
    if (sb_step() == SB_STEP_COMPILE) mx = 3;
    set_sb_execmax(mx);
    // And how many PROCESSES. Every clone, clone3, fork and vfork is a
    // notification (src/seccomp.mc, sb_notified) and is counted here, so this
    // is the named wall a fork bomb hits -- in the compile step too, which is
    // where `mc build` runs whatever [linker].cmd the source tree named.
    i64 pm = 0;
    if (sb_step() == SB_STEP_COMPILE) pm = SB_NPROC_COMPILE;
    if (sb_step() == SB_STEP_RUN && sb_threads()) pm = SB_NPROC_THREADS;
    set_sb_procmax(pm);

    sb_sys(SN_WRITE, sb_syncw(), "1", 1, 0, 0, 0);
}

// SIGKILL to the step child is the wall-clock mechanism: C is pid 1 of its own
// pid namespace, so the kernel takes every descendant with it (§ Risks 6).
void sb_kill_box() {
    if (sb_pidc() > 0) sb_sys(SN_KILL, sb_pidc(), SB_SIGKILL, 0, 0, 0, 0);
    if (sb_pidi() > 0) sb_sys(SN_KILL, sb_pidi(), SB_SIGKILL, 0, 0, 0, 0);
}

void sb_supervise() {
    i64 t0 = sb_now_ms();
    set_sb_dead(t0 + sb_wall() * 1000);
    loop {
        i64 rem = sb_dead() - sb_now_ms();
        if (rem < 0) rem = 0;
        st64(sb_ts(), rem / 1000);
        st64(sb_ts() + 8, (rem % 1000) * 1000000);
        st32(sb_pollp(), sb_spr());
        st16(sb_pollp() + 4, SB_POLLIN);
        st16(sb_pollp() + 6, 0);
        // and the seccomp listener, once a step has one: a notification is a
        // step waiting for an answer, so it is polled beside the status pipe
        // and never with a blocking read of its own (§ 4).
        i64 nfd = 1;
        if (sb_lfd() >= 0) {
            st32(sb_pollp() + 8, sb_lfd());
            st16(sb_pollp() + 12, SB_POLLIN);
            st16(sb_pollp() + 14, 0);
            nfd = 2;
        }
        i64 n = sb_sys(SN_PPOLL, sb_pollp(), nfd, sb_ts(), 0, 8, 0);
        if (n == 0 - E_INTR) continue;
        if (n < 0) break;
        if (n == 0) {
            // the wall clock, or the two seconds of grace after it
            if (sb_wallhit()) { sb_kill_box(); break; }
            set_sb_wallhit(1);
            // The box is about to lose the process that reports: J is pid 1 of
            // the pid namespace and killing it is what takes the step with it,
            // so the wall-clock line is one P writes itself, for the step the
            // last `B` named.
            sb_note_signal(sb_step(), SB_SIGKILL, 0);
            sb_kill_box();
            set_sb_dead(sb_now_ms() + 2000);
            continue;
        }
        // the notification first: a step blocked on one cannot make progress,
        // and its answer may be what ends the box.
        if (nfd == 2) {
            i64 rev = ld16(sb_pollp() + 14);
            if (rev & SB_POLLIN) sb_notif_pump();
            else if (rev & (SB_POLLHUP | SB_POLLERR)) {
                // every process under that filter is gone: the listener is a
                // dead descriptor and polling it again would spin.
                sb_sys(SN_CLOSE, sb_lfd(), 0, 0, 0, 0, 0);
                set_sb_lfd(-1);
            }
        }
        if (!(ld16(sb_pollp() + 6) & (SB_POLLIN | SB_POLLHUP))) continue;
        i64 r = sb_sys(SN_READ, sb_spr(), sb_buf(), 4095, 0, 0, 0);
        if (r == 0 - E_INTR) continue;
        if (r <= 0) break;                        // the box is gone
        sb_pump(r);
    }
    st64(sb_word(), 0);
    sb_sys(SN_WAIT4, sb_pidi(), sb_word(), 0, sb_ru(), 0, 0);
}

// ---- what the box left behind ----
// The tmpfs and everything in it died with the mount namespace; the empty
// directory it was mounted on is P's to remove, and it is the ONLY thing the
// sandbox ever writes outside the box (acceptance 6: `find -newer` empty).
void sb_cleanup() {
    if (sb_boxdir()) sb_sys(SN_UNLINKAT, SB_AT_FDCWD, sb_boxdir(), SB_AT_REMOVEDIR, 0, 0, 0);
}

uptr sb_site_msg(i64 site) {
    if (site == SBE_UNSHARE)    return "cannot unshare";
    if (site == SBE_MOUNT_ROOT) return "cannot mount /";
    if (site == SBE_TMPFS)      return "cannot mount the box tmpfs";
    if (site == SBE_MKDIR)      return "cannot create a directory in the box";
    if (site == SBE_BIND_MC)    return "cannot bind the compiler at /mc";
    if (site == SBE_SRC)        return "cannot mount /src";
    if (site == SBE_RO)         return "cannot mount a --ro directory";
    if (site == SBE_LIB)        return "cannot bind the host libraries";
    if (site == SBE_PIVOT)      return "cannot pivot_root";
    if (site == SBE_UMOUNT)     return "cannot detach the old root";
    if (site == SBE_HOSTNAME)   return "cannot sethostname";
    if (site == SBE_CHDIR)      return "cannot chdir";
    if (site == SBE_RLIMIT)     return "cannot set a resource limit";
    if (site == SBE_FORK)       return "cannot fork a step";
    if (site == SBE_PIPE)       return "cannot create a pipe";
    if (site == SBE_MAPS)       return "cannot write the uid map";
    if (site == SBE_EXEC)       return "cannot execute the step";
    if (site == SBE_STDIN)      return "cannot open the --stdin file";
    if (site == SBE_PROJECT)    return "cannot build a project without an overlay";
    if (site == SBE_LANDLOCK)   return "cannot install the Landlock ruleset";
    if (site == SBE_SECCOMP)    return "cannot install the seccomp filter";
    if (site == SBE_LISTENER)   return "cannot fetch the seccomp listener";
    return "cannot set up the box";
}

// The one place the AppArmor story is told to a person: the box's first mount
// is where an unprivileged process on a stock Ubuntu stops, and the sentence
// says so and points at the fix (§ Implementation notes -- step A, deviation 4).
void sb_note_cannot() {
    uptr m = tm_cat(sb_site_msg(sb_errc()), tm_cat(": ", sb_errname(sb_errno())));
    if (sb_errno() == E_ACCES && sb_errc() == SBE_MOUNT_ROOT && sb_apparmor_userns())
        m = tm_cat(m, " (apparmor restricts unprivileged user namespaces: see docs/reference/sandbox.md § Hosts)");
    sb_say(m);
    set_sb_rc(SB_EXIT_SETUP);
}

// ---- the box, from the host's side ----
void sb_box_main();                              // src/sandbox_box.mc

i64 sb_go() {
    // /proc/self/exe BEFORE any unshare: it is the file the box binds at /mc,
    // and once the mount namespace is private the host path is gone.
    i64 n = sb_sys(SN_READLINKAT, SB_AT_FDCWD, "/proc/self/exe", sb_path(), 511, 0, 0);
    if (n <= 0) { sb_err("cannot resolve /proc/self/exe"); return SB_EXIT_SETUP; }
    st8(sb_path() + n, 0);
    set_sb_self(xstrdup(sb_path(), n));

    // stdin: the named file, or a pipe whose write end is already closed --
    // which is EOF, the documented default, and not a /dev/null the box has no
    // /dev to hold.
    if (sb_stdin()) {
        i64 fd = sb_sys(SN_OPENAT, SB_AT_FDCWD, sb_stdin(), SB_O_RDONLY, 0, 0, 0);
        if (fd < 0) { sb_note_setup(SBE_STDIN, 0 - fd); sb_note_cannot(); sb_report_flush(); return sb_rc(); }
        set_sb_infd(fd);
    } else {
        if (sb_sys(SN_PIPE2, sb_word(), 0, 0, 0, 0, 0) < 0) { sb_err("cannot create a pipe"); return SB_EXIT_SETUP; }
        set_sb_infd(ld32(sb_word()));
        sb_sys(SN_CLOSE, ld32(sb_word() + 4), 0, 0, 0, 0, 0);
    }

    if (sb_sys(SN_PIPE2, sb_word(), 0, 0, 0, 0, 0) < 0) { sb_err("cannot create a pipe"); return SB_EXIT_SETUP; }
    set_sb_spr(ld32(sb_word()));
    set_sb_spw(ld32(sb_word() + 4));
    if (sb_sys(SN_PIPE2, sb_word(), 0, 0, 0, 0, 0) < 0) { sb_err("cannot create a pipe"); return SB_EXIT_SETUP; }
    set_sb_mpr(ld32(sb_word()));
    set_sb_mpw(ld32(sb_word() + 4));

    // The sync pipe of step C, and the reason it is made HERE rather than per
    // step inside the box: the byte on it means "P is holding your listener",
    // so P has to be the one that writes it, and C -- which is three forks
    // away and closes every other descriptor -- has to inherit the read end.
    // Its number is P's own, which is what makes it nameable on both sides.
    if (sb_sys(SN_PIPE2, sb_word(), 0, 0, 0, 0, 0) < 0) { sb_err("cannot create a pipe"); return SB_EXIT_SETUP; }
    set_sb_syncr(ld32(sb_word()));
    set_sb_syncw(ld32(sb_word() + 4));
    sb_resolve_libc();

    // the environment every step gets: fixed, three entries, no leak of the
    // host's (§ 3). HOME is /src so that anything the compiler caches lands in
    // the box and dies with it.
    st64(sb_env() + 0,  "HOME=/src");
    st64(sb_env() + 8,  "PATH=/");
    st64(sb_env() + 16, 0);

    i64 pid = sb_sys(SN_CLONE, SB_SIGCHLD, 0, 0, 0, 0, 0);
    if (pid < 0) { sb_err("cannot fork the box"); return SB_EXIT_SETUP; }
    if (pid == 0) {
        sb_sys(SN_CLOSE, sb_spr(), 0, 0, 0, 0, 0);
        sb_sys(SN_CLOSE, sb_mpw(), 0, 0, 0, 0, 0);
        sb_sys(SN_CLOSE, sb_syncw(), 0, 0, 0, 0, 0);
        sb_box_main();                           // never returns
    }
    set_sb_pidi(pid);
    set_sb_boxdir(tm_cat("/tmp/.mc-box", tm_num_str(pid)));   // the box names it after its own pid
    sb_sys(SN_CLOSE, sb_spw(), 0, 0, 0, 0, 0);
    sb_sys(SN_CLOSE, sb_mpr(), 0, 0, 0, 0, 0);
    sb_sys(SN_CLOSE, sb_syncr(), 0, 0, 0, 0, 0);
    sb_sys(SN_CLOSE, sb_infd(), 0, 0, 0, 0, 0);

    sb_supervise();
    if (sb_lfd() >= 0) { sb_sys(SN_CLOSE, sb_lfd(), 0, 0, 0, 0, 0); set_sb_lfd(-1); }
    sb_sys(SN_CLOSE, sb_syncw(), 0, 0, 0, 0, 0);
    sb_cleanup();

    // --verbose is the one line that is not deterministic, and it says so in
    // docs/reference/cli.md: what the kernel charged the whole box, out of the
    // rusage P's own wait4 filled in (RUSAGE_BOTH -- I's own plus every child
    // it reaped, which is all of them).
    if (sb_verbose()) {
        i64 ms = ld64(sb_ru()) * 1000 + ld64(sb_ru() + 8) / 1000
               + ld64(sb_ru() + 16) * 1000 + ld64(sb_ru() + 24) / 1000;
        sb_say(tm_cat("rusage: cpu ", tm_cat(tm_num_str(ms),
               tm_cat(" ms, maxrss ", tm_cat(tm_num_str(ld64(sb_ru() + 32)), " kb")))));
    }

    if (sb_errc()) sb_note_cannot();
    else if (!sb_done()) { sb_say("the box ended without a status"); set_sb_rc(SB_EXIT_SETUP); }
    sb_report_flush();
    return sb_rc();
}

// ---- the subcommand ----
void sb_usage() {
    out_str(2, "usage: mc sandbox run  [OPTS] PATH [--] [ARGS]\n");
    out_str(2, "       mc sandbox exec [OPTS] BIN  [--] [ARGS]\n");
    out_str(2, "       mc sandbox check\n");
    out_str(2, "OPTS:  --time S  --wall S  --mem MiB  --out MiB  --allow=threads --libc=musl|gnu\n");
    out_str(2, "       --stdin FILE  --ro DIR  --cwd DIR  --root DIR  --report FILE  --config NAME  --verbose\n");
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
    set_sb_is_run(run);

    i64 rc = sb_parse(argc, argv, 3);
    if (rc) return rc;
    if (sb_argi() >= argc) {
        if (run) sb_err("sandbox run needs a source path");
        else     sb_err("sandbox exec needs a program");
        return 2;
    }

    if (!host_sandbox_supported()) {
        if (run) return sb_unsupported("sandbox run PATH");
        return sb_unsupported("sandbox exec BIN");
    }

    rc = sb_plan(argc, argv);
    if (rc) return rc;
    return sb_go();
}
