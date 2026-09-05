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

#define SN_COUNT                    60
