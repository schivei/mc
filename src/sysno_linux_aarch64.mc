// sysno_linux_aarch64.mc — the raw system-call shim and the number table for
// Linux on AArch64 (M43 step A, docs/specs/M43.md § 2).
//
// Why a shim at all, and not a libc call: `prctl`, `syscall` and `clone` are
// VARIADIC in musl and in glibc, and this project refuses a variadic extern
// (M5.6 -- `creat` instead of `open`); `seccomp`, `landlock_*`, `pidfd_*` and
// `close_range` have no wrapper in musl at all. One shim answers every one of
// them, and the chain is then identical on both architectures except for the
// numbers in the table at the bottom.
//
// This is lib/sys_linux.mc's technique, one level up: the same #opcode words,
// the same `svc #0`, the same raw -errno result. It is not lib/sys_linux.mc
// itself because the COMPILER links a libc and must not redefine open/read/
// write, and because sys6 takes the number as an argument.

#include "sysno.mc"

#opcode movx6(rd, rm)   0xAA0003E0 | (rm << 16) | rd     // orr xd, xzr, xm
#opcode svc6()          0xD4000001                       // svc #0

// The Linux/AArch64 convention for a system call is: arguments in x0..x5, the
// number in x8, `svc #0`, the raw result in x0 (a small negative value is
// -errno; there is no carry flag involved).
//
// The seven parameters arrive in x0..x6 -- the core's ABI, unchanged by the
// prologue (docs/reference/objects.md § 4) -- so the number is already in x0
// and every argument is one register too high. The moves therefore run in
// ASCENDING order after x8 is taken: x8 <- x0 reads the number before x0 is
// overwritten, and each `mov xN, x(N+1)` reads a register no earlier move has
// written. Descending order would destroy x0 before x8 could read it.
//
// The parameters are also stored to their frame slots by the prologue, which
// reads the same registers and writes only memory -- lib/sys_linux.mc's
// read/write/close rely on exactly that.
i64 sys6(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
    movx6(8, 0);                                 // x8 = n
    movx6(0, 1);
    movx6(1, 2);
    movx6(2, 3);
    movx6(3, 4);
    movx6(4, 5);
    movx6(5, 6);
    svc6();                                      // result stays in x0
}

// asm-generic/unistd.h — the table AArch64 uses. One row per SN_* index of
// src/sysno.mc, in that order.
u16 sysno_tab[] = {
     97,        // SN_UNSHARE
     40,        // SN_MOUNT
     41,        // SN_PIVOT_ROOT
     39,        // SN_UMOUNT2
    444,        // SN_LANDLOCK_CREATE_RULESET
    445,        // SN_LANDLOCK_ADD_RULE
    446,        // SN_LANDLOCK_RESTRICT_SELF
    167,        // SN_PRCTL
    277,        // SN_SECCOMP
     29,        // SN_IOCTL
    434,        // SN_PIDFD_OPEN
    438,        // SN_PIDFD_GETFD
    270,        // SN_PROCESS_VM_READV
    261,        // SN_PRLIMIT64
     73,        // SN_PPOLL
    129,        // SN_KILL
    220,        // SN_CLONE
    435,        // SN_CLONE3
    436,        // SN_CLOSE_RANGE
     56,        // SN_OPENAT
     63,        // SN_READ
     64,        // SN_WRITE
     57,        // SN_CLOSE
     94,        // SN_EXIT_GROUP
    260,        // SN_WAIT4
     59,        // SN_PIPE2
     24,        // SN_DUP3
    172,        // SN_GETPID
    221,        // SN_EXECVE
     49,        // SN_CHDIR
    161,        // SN_SETHOSTNAME
    222,        // SN_MMAP
    215,        // SN_MUNMAP
     78,        // SN_READLINKAT
    160,        // SN_UNAME
    214,        // SN_BRK
    226,        // SN_MPROTECT
     96,        // SN_SET_TID_ADDRESS
    135,        // SN_RT_SIGPROCMASK
     35,        // SN_UNLINKAT
     79,        // SN_NEWFSTATAT
     62,        // SN_LSEEK
     93,        // SN_EXIT
     52,        // SN_FCHMOD
     67,        // SN_PREAD64
     98,        // SN_FUTEX
     99,        // SN_SET_ROBUST_LIST
    293,        // SN_RSEQ
    124,        // SN_SCHED_YIELD
    233,        // SN_MADVISE
    115,        // SN_CLOCK_NANOSLEEP
    101,        // SN_NANOSLEEP
    131,        // SN_TGKILL
    283,        // SN_MEMBARRIER
    SN_ABSENT,  // SN_ACCESS      -- the generic table has only faccessat (48)
    278,        // SN_GETRANDOM
    SN_ABSENT,  // SN_ARCH_PRCTL  -- x86 only
    198,        // SN_SOCKET
    203,        // SN_CONNECT
    200,        // SN_BIND
     34,        // SN_MKDIRAT
    174,        // SN_GETUID
    176,        // SN_GETGID
    113,        // SN_CLOCK_GETTIME
     17,        // SN_GETCWD
    SN_ABSENT,  // SN_OPEN        -- the generic table has only openat
     80,        // SN_FSTAT
     48,        // SN_FACCESSAT
     53,        // SN_FCHMODAT
     95,        // SN_WAITID
    SN_ABSENT,  // SN_CREAT       -- openat(O_CREAT) is the only form
    SN_ABSENT,  // SN_CHMOD       -- fchmodat only
    SN_ABSENT,  // SN_MKDIR       -- mkdirat only
    SN_ABSENT,  // SN_UNLINK      -- unlinkat only
    134,        // SN_RT_SIGACTION
     25,        // SN_FCNTL
     61,        // SN_GETDENTS64
    216,        // SN_MREMAP
     65,        // SN_READV
    SN_ABSENT,  // SN_FORK       -- clone(SIGCHLD) is the only form
    SN_ABSENT   // SN_VFORK
};

// the number of SN_*, or -1 when this architecture has no such call
i64 host_sysno(i64 sn) {
    if (sn < 0 || sn >= SN_COUNT) return -1;
    i64 v = ld16(sysno_tab + sn * 2);
    if (v == SN_ABSENT) return -1;
    return v;
}

// AUDIT_ARCH_AARCH64 (linux/audit.h): EM_AARCH64 183 | __AUDIT_ARCH_64BIT |
// __AUDIT_ARCH_LE. It is the first thing the seccomp filter of M43 step C
// tests, and it belongs here rather than in src/seccomp.mc for the reason the
// number table does: a value that changes with the architecture is the host
// layer's answer, not a constant in a file that compiles for both.
i64 host_audit_arch() { return 0xC00000B7; }
