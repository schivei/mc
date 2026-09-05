// sandbox-exit: 125
// sandbox-stdout:
// sandbox-report: refused: clone with namespace flags
// The same refusal, through clone3 -- the call a BPF filter cannot inspect
// (the post-M43 review, docs/specs/M43.md § Implementation notes -- the
// review; docs/reference/sandbox.md § The filter).
//
// clone(2) carries its flags in a register, so the seccomp filter can test
// them itself. clone3(2) carries them in a `struct clone_args` in the caller's
// memory, and classic BPF cannot follow a pointer: the only way to know what a
// clone3 is asking for is to read the struct out of the process. So clone3 is
// ALWAYS a notification, and the supervisor reads the first eight bytes of the
// struct -- the u64 `flags` -- with process_vm_readv, exactly as it reads the
// path of an openat. A struct it cannot read is refused too
// (`clone3 with unreadable arguments`).
//
// This matters beyond the test: glibc's posix_spawn uses clone3, so the call
// is on the ordinary road of `mc build` inside the box (measured on both
// architectures with glibc 2.43). What is refused here is a clone3 that asks
// for a NAMESPACE.
//
// The system call number is 435 on both architectures -- clone3 arrived after
// the tables diverged -- so one number serves the whole corpus. It is issued
// through libc's `syscall`, which both glibc and musl implement in assembler
// and which passes its arguments through unchanged.
//
// struct clone_args, version 0 (64 bytes): u64 flags, pidfd, child_tid,
// parent_tid, exit_signal, stack, stack_size, tls.
#include <sys>
#include <io>

#define SYS_CLONE3 435
#define CLONE_NEWUSER 0x10000000
#define SIGCHLD 17
#define CLONE_ARGS_VER0 64
#define STACKSZ 65536

extern i64 syscall(i64 n, i64 a, i64 b);

u8 cargs[CLONE_ARGS_VER0];
u8 kidstack[STACKSZ];

i64 main() {
    i64 i = 0;
    loop {
        if (i >= CLONE_ARGS_VER0) break;
        st8(cargs + i, 0);
        i = i + 1;
    }
    st64(cargs, CLONE_NEWUSER);              // flags
    st64(cargs + 32, SIGCHLD);               // exit_signal
    st64(cargs + 40, kidstack);              // stack
    st64(cargs + 48, STACKSZ);               // stack_size
    i64 rc = syscall(SYS_CLONE3, cargs, CLONE_ARGS_VER0);
    puts("cloned3 ");
    putnum(rc);
    puts("\n");
    return 0;
}
