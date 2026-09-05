// sysno_linux_x86_64.mc — the raw system-call shim and the number table for
// Linux on x86-64 (M43 step A, docs/specs/M43.md § 2). The AArch64 sibling,
// src/sysno_linux_aarch64.mc, carries the reasons; this file carries the bytes.
//
// There is no #opcode here because #opcode folds ONE 32-bit word and x86
// instructions are one to fifteen bytes: what is expressible today is a raw
// word through emit(), which src/machine_x86_64.mc passes through unchanged
// (descriptor row 45, X_EMIT, encoded little-endian by buf_u32). So the shim is
// written as a BYTE STREAM cut into six four-byte words, and an instruction may
// straddle a word boundary -- the comments below give the assembler line each
// byte belongs to.
//
// The Linux/x86-64 convention for a system call is: number in rax, arguments in
// rdi, rsi, rdx, r10, r8, r9, `syscall`, raw result in rax (a small negative
// value is -errno). The C convention this function is called under puts its
// seven parameters in rdi, rsi, rdx, rcx, r8, r9 and at [rbp+16] -- one place
// too high, exactly as on AArch64, and with rcx and r10 swapped because
// `syscall` itself destroys rcx.
//
// [rbp+16] is the seventh argument by construction: the caller pushed it, then
// `call` pushed the return address, then this function's prologue pushed rbp
// and set rbp = rsp (src/machine_x86_64.mc, x86_prologue_body), so the three
// eight-byte words above rbp are the saved rbp, the return address and the
// argument (M17 step B, docs/reference/objects.md § 4c).
//
// The bytes come from
//   llvm-mc -triple=x86_64-linux-musl -x86-asm-syntax=intel --show-encoding
// and scripts/check-parts.sh asserts the six words in --dump-asm --machine=x86_64.

#include "sysno.mc"

//  mov rax, rdi                 48 89 f8
//  mov rdi, rsi                 48 89 f7
//  mov rsi, rdx                 48 89 d6
//  mov rdx, rcx                 48 89 ca
//  mov r10, r8                  4d 89 c2
//  mov r8, r9                   4d 89 c8
//  mov r9, qword ptr [rbp+16]   4c 8b 4d 10
//  syscall                      0f 05
//
// twenty-four bytes, little-endian, four at a time:
//
//   0x48F88948  48 89 f8 | 48        mov rax,rdi ; mov rdi,rsi (1/3)
//   0x8948F789  89 f7    | 48 89     mov rdi,rsi (2/3, 3/3) ; mov rsi,rdx (1/2)
//   0xCA8948D6  d6       | 48 89 ca  mov rsi,rdx (2/2) ; mov rdx,rcx
//   0x4DC2894D  4d 89 c2 | 4d        mov r10,r8 ; mov r8,r9 (1/3)
//   0x8B4CC889  89 c8    | 4c 8b     mov r8,r9 (2/3, 3/3) ; mov r9,[rbp+16] (1/2)
//   0x050F104D  4d 10    | 0f 05     mov r9,[rbp+16] (2/2) ; syscall
i64 sys6(i64 n, i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
    emit(0x48F88948);
    emit(0x8948F789);
    emit(0xCA8948D6);
    emit(0x4DC2894D);
    emit(0x8B4CC889);
    emit(0x050F104D);                            // result stays in rax
}

// arch/x86/entry/syscalls/syscall_64.tbl. One row per SN_* index of
// src/sysno.mc, in that order.
u16 sysno_tab[] = {
    272,        // SN_UNSHARE
    165,        // SN_MOUNT
    155,        // SN_PIVOT_ROOT
    166,        // SN_UMOUNT2
    444,        // SN_LANDLOCK_CREATE_RULESET
    445,        // SN_LANDLOCK_ADD_RULE
    446,        // SN_LANDLOCK_RESTRICT_SELF
    157,        // SN_PRCTL
    317,        // SN_SECCOMP
     16,        // SN_IOCTL
    434,        // SN_PIDFD_OPEN
    438,        // SN_PIDFD_GETFD
    310,        // SN_PROCESS_VM_READV
    302,        // SN_PRLIMIT64
    271,        // SN_PPOLL
     62,        // SN_KILL
     56,        // SN_CLONE
    435,        // SN_CLONE3
    436,        // SN_CLOSE_RANGE
    257,        // SN_OPENAT
      0,        // SN_READ
      1,        // SN_WRITE
      3,        // SN_CLOSE
    231,        // SN_EXIT_GROUP
     61,        // SN_WAIT4
    293,        // SN_PIPE2
    292,        // SN_DUP3
     39,        // SN_GETPID
     59,        // SN_EXECVE
     80,        // SN_CHDIR
    170,        // SN_SETHOSTNAME
      9,        // SN_MMAP
     11,        // SN_MUNMAP
    267,        // SN_READLINKAT
     63,        // SN_UNAME
     12,        // SN_BRK
     10,        // SN_MPROTECT
    218,        // SN_SET_TID_ADDRESS
     14,        // SN_RT_SIGPROCMASK
    263,        // SN_UNLINKAT
    262,        // SN_NEWFSTATAT
      8,        // SN_LSEEK
     60,        // SN_EXIT
     91,        // SN_FCHMOD
     17,        // SN_PREAD64
    202,        // SN_FUTEX
    273,        // SN_SET_ROBUST_LIST
    334,        // SN_RSEQ
     24,        // SN_SCHED_YIELD
     28,        // SN_MADVISE
    230,        // SN_CLOCK_NANOSLEEP
     35,        // SN_NANOSLEEP
    234,        // SN_TGKILL
    324,        // SN_MEMBARRIER
     21,        // SN_ACCESS
    318,        // SN_GETRANDOM
    158,        // SN_ARCH_PRCTL
     41,        // SN_SOCKET
     42,        // SN_CONNECT
     49,        // SN_BIND
    258,        // SN_MKDIRAT
    102,        // SN_GETUID
    104,        // SN_GETGID
    228,        // SN_CLOCK_GETTIME
     79,        // SN_GETCWD
      2,        // SN_OPEN
      5,        // SN_FSTAT
    269,        // SN_FACCESSAT
    268,        // SN_FCHMODAT
    247,        // SN_WAITID
     85,        // SN_CREAT
     90,        // SN_CHMOD
     83,        // SN_MKDIR
     87,        // SN_UNLINK
     13,        // SN_RT_SIGACTION
     72,        // SN_FCNTL
    217,        // SN_GETDENTS64
     25,        // SN_MREMAP
     19,        // SN_READV
     57,        // SN_FORK
     58         // SN_VFORK
};

// the number of SN_*, or -1 when this architecture has no such call
i64 host_sysno(i64 sn) {
    if (sn < 0 || sn >= SN_COUNT) return -1;
    i64 v = ld16(sysno_tab + sn * 2);
    if (v == SN_ABSENT) return -1;
    return v;
}

// AUDIT_ARCH_X86_64 (linux/audit.h): EM_X86_64 62 | __AUDIT_ARCH_64BIT |
// __AUDIT_ARCH_LE. See the AArch64 sibling for why it lives here.
i64 host_audit_arch() { return 0xC000003E; }
