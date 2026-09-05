// sandbox-exit: 125
// sandbox-stdout:
// sandbox-report: refused: clone with namespace flags
// A clone that asks for a NAMESPACE, refused by name (the post-M43 review,
// docs/specs/M43.md § Implementation notes -- the review).
//
// A fresh user namespace inside the box is the one thing a program in it must
// not have: CAP_SYS_ADMIN in a namespace of its own is where an unprivileged
// process starts collecting capabilities, and every wall this sandbox has
// -- the mount tree, the empty network namespace, the pid namespace -- is a
// namespace someone could try to reopen.
//
// Before the review this was not refused at all in the compile step (`clone`
// was measured into the compile profile as a plain ALLOW) and was refused as
// `syscall 220 (clone)` in the run step -- a number, not a reason. Now every
// clone, clone3, fork and vfork reaches the supervisor, which reads the flags:
// any CLONE_NEW* bit is `refused: clone with namespace flags`, whatever the
// step and whatever the process limit.
//
// The libc `clone(fn, stack, flags, arg)` wrapper issues the clone system call
// with the flags it is given -- it adds none of its own -- and both glibc and
// musl implement it in assembler. It is declared i32 because it returns a C
// `int` (M45; docs/reference/language.md § 2), and the child function never
// runs: the refused call does not return.
#include <sys>
#include <io>

#define CLONE_NEWUSER 0x10000000
#define SIGCHLD 17
#define STACKSZ 65536

extern i32 clone(uptr fn, uptr stack, i64 flags, uptr arg);

u8 kidstack[STACKSZ];

i64 kid(uptr arg) {
    return 0;
}

i64 main() {
    i64 rc = clone(&kid, kidstack + STACKSZ, CLONE_NEWUSER | SIGCHLD, 0);
    puts("cloned ");
    putnum(rc);
    puts("\n");
    return 0;
}
