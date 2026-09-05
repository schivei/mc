// sysno.mc — the syscall NAMES the sandbox uses (M43 step A, docs/specs/M43.md
// § 2). This file is only the enum: one `SN_*` index per system call, and
// nothing else. The NUMBERS live in a table per architecture,
//
//   src/sysno_linux_aarch64.mc   asm-generic/unistd.h, the table AArch64 uses
//   src/sysno_linux_x86_64.mc    arch/x86/entry/syscalls/syscall_64.tbl
//
// and on a host that has no system calls of this shape at all the table is all
// SN_ABSENT (src/host_macos.mc, src/host_windows.mc). Each of the four defines
// `host_sysno(sn)` over its own table, so `src/sandbox*.mc` names no number and
// compiles unchanged for every host: what refuses on a Mac is `host_os()`, not
// a missing symbol.
//
// The order below is the order of the table rows; adding a name means adding a
// row to all four tables, and the length is checked by SN_COUNT.

// the table entry for a system call this architecture does not have (AArch64
// has no `access` and no `arch_prctl`: the generic table only has faccessat).
// 0xFFFF is not a syscall number on either architecture; host_sysno() turns it
// into -1, which is what the caller tests.
#define SN_ABSENT 0xFFFF

// ---- what the box itself issues (§ 1, § 3, § 4) ----
#define SN_UNSHARE                   0
#define SN_MOUNT                     1
#define SN_PIVOT_ROOT                2
#define SN_UMOUNT2                   3
#define SN_LANDLOCK_CREATE_RULESET   4
#define SN_LANDLOCK_ADD_RULE         5
#define SN_LANDLOCK_RESTRICT_SELF    6
#define SN_PRCTL                     7
#define SN_SECCOMP                   8
#define SN_IOCTL                     9
#define SN_PIDFD_OPEN               10
#define SN_PIDFD_GETFD              11
#define SN_PROCESS_VM_READV         12
#define SN_PRLIMIT64                13
#define SN_PPOLL                    14
#define SN_KILL                     15
#define SN_CLONE                    16
#define SN_CLONE3                   17
#define SN_CLOSE_RANGE              18
#define SN_OPENAT                   19
#define SN_READ                     20
#define SN_WRITE                    21
#define SN_CLOSE                    22
#define SN_EXIT_GROUP               23
#define SN_WAIT4                    24
#define SN_PIPE2                    25
#define SN_DUP3                     26
#define SN_GETPID                   27
#define SN_EXECVE                   28
#define SN_CHDIR                    29
#define SN_SETHOSTNAME              30
#define SN_MMAP                     31
#define SN_MUNMAP                   32
#define SN_READLINKAT               33
#define SN_UNAME                    34

// ---- what a profile allows (§ 4): the compile profile, the program profile
// and the --allow=threads delta. They are named here for the same reason the
// rest are: a profile is a list of numbers, and no number may be written in
// src/sandbox*.mc.
#define SN_BRK                      35
#define SN_MPROTECT                 36
#define SN_SET_TID_ADDRESS          37
#define SN_RT_SIGPROCMASK           38
#define SN_UNLINKAT                 39
#define SN_NEWFSTATAT               40
#define SN_LSEEK                    41
#define SN_EXIT                     42
#define SN_FCHMOD                   43
#define SN_PREAD64                  44
#define SN_FUTEX                    45
#define SN_SET_ROBUST_LIST          46
#define SN_RSEQ                     47
#define SN_SCHED_YIELD              48
#define SN_MADVISE                  49
#define SN_CLOCK_NANOSLEEP          50
#define SN_NANOSLEEP                51
#define SN_TGKILL                   52
#define SN_MEMBARRIER               53
#define SN_ACCESS                   54
#define SN_GETRANDOM                55
#define SN_ARCH_PRCTL               56

// ---- never in a profile, named so the report can say what was refused ----
#define SN_SOCKET                   57
#define SN_CONNECT                  58
#define SN_BIND                     59

// ---- step B: what building the box needs on top of step A's list ----
// They are appended rather than filed under "what the box issues" above, so
// that the fifty-nine indices step A measured keep their numbers and the four
// tables stay row-for-row comparable with the diff that added them.
//
//   mkdirat        every directory of the tree in § 3 (there is no `mkdir` on
//                  AArch64: the generic table has only the *at form)
//   getuid/getgid  the two numbers P writes into /proc/<I>/uid_map and gid_map
//   clock_gettime  the supervisor's deadline: ppoll returns early on every
//                  status line, so the wall clock has to be recomputed against
//                  a monotonic start rather than restarted
//   getcwd         a mount source is an absolute path, and `mc sandbox run
//                  tests/013-putnum.mc` is not one
#define SN_MKDIRAT                  60
#define SN_GETUID                   61
#define SN_GETGID                   62
#define SN_CLOCK_GETTIME            63
#define SN_GETCWD                   64

// ---- step C: what the MEASURED profiles named (scripts/sandbox-trace.sh) ----
// The two C libraries do not agree on which form of a call they issue, and the
// two architectures do not agree on which forms exist: glibc on x86-64 issues
// `open`, `creat`, `chmod`, `mkdir` and `unlink`, glibc on AArch64 issues
// `openat`, `fchmodat`, `mkdirat` and `unlinkat` because the generic table has
// nothing else. Every row below was measured with `strace -n` on Ubuntu 26.04
// (kernel 7.0.0-30) and cross-checked against musl's bits/syscall.h for the
// architecture, not remembered.
#define SN_OPEN                     65
#define SN_FSTAT                    66
#define SN_FACCESSAT                67
#define SN_FCHMODAT                 68
#define SN_WAITID                   69
#define SN_CREAT                    70
#define SN_CHMOD                    71
#define SN_MKDIR                    72
#define SN_UNLINK                   73
#define SN_RT_SIGACTION             74
#define SN_FCNTL                    75
#define SN_GETDENTS64               76
#define SN_MREMAP                   77
#define SN_READV                    78
// x86-64 has a `fork` and a `vfork` of its own, and musl uses them where glibc
// uses clone: measured, `tests/sandbox/forkbomb.mc` under musl on x86-64 is
// refused at syscall 57 and under glibc at syscall 56. The generic table has
// neither, so on AArch64 both are absent and every fork is a clone.
#define SN_FORK                     79
#define SN_VFORK                    80

#define SN_COUNT                    81

// ---- the second column: the NAME of each index ----
// `refused: syscall 198 (socket)` needs a name for a number, and the number is
// what the per-architecture table above answers -- so a table of names indexed
// by the SAME SN_* is the only shape in which the two cannot drift apart. A
// name is looked up by walking this table and asking host_sysno() for each
// row, which is why an index absent on this architecture can never be named by
// accident: it has no number to match.
uptr sn_names[] = {
    "unshare", "mount", "pivot_root", "umount2",
    "landlock_create_ruleset", "landlock_add_rule", "landlock_restrict_self",
    "prctl", "seccomp", "ioctl", "pidfd_open", "pidfd_getfd",
    "process_vm_readv", "prlimit64", "ppoll", "kill", "clone", "clone3",
    "close_range", "openat", "read", "write", "close", "exit_group", "wait4",
    "pipe2", "dup3", "getpid", "execve", "chdir", "sethostname", "mmap",
    "munmap", "readlinkat", "uname", "brk", "mprotect", "set_tid_address",
    "rt_sigprocmask", "unlinkat", "newfstatat", "lseek", "exit", "fchmod",
    "pread64", "futex", "set_robust_list", "rseq", "sched_yield", "madvise",
    "clock_nanosleep", "nanosleep", "tgkill", "membarrier", "access",
    "getrandom", "arch_prctl", "socket", "connect", "bind", "mkdirat",
    "getuid", "getgid", "clock_gettime", "getcwd", "open", "fstat",
    "faccessat", "fchmodat", "waitid", "creat", "chmod", "mkdir", "unlink",
    "rt_sigaction", "fcntl", "getdents64", "mremap",
    "readv", "fork", "vfork"
};
