// sandbox-exit: 125
// sandbox-stdout:
// sandbox-report: refused: process limit (0)
// sandbox-alt-opts: --allow=threads
// sandbox-alt-exit: 125
// sandbox-alt-report: refused: process limit (64)
// A fork bomb, refused at its FIRST fork and by name (M43 step C, § 4; the
// message is the post-M43 review's).
//
// No profile allows a call that makes a process -- clone, clone3, fork or
// vfork -- so every one of them reaches the supervisor as a notification and
// is COUNTED against the step's process limit. A run step is allowed none, so
// the first fork is `sandbox: refused: process limit (0)`, exit 125. Nothing
// below is printed: the refused call never returns.
//
// Until the review the same case was refused as `syscall 220 (clone)` -- 56 on
// x86-64 under glibc, 57 (`fork`) under musl -- and this file carried three
// expectation headers, one per (architecture, C library) pair, because the
// NUMBER of the call was in the report. Counting instead of naming the entry
// point gives one line on every host, and it is the same line the compile step
// prints with a limit of 16 (tests/sandbox/linkbomb/).
//
// With `--allow=threads` the filter tests the flags instead: a real thread
// (CLONE_THREAD set, no CLONE_NEW* bit) is allowed without asking, and a new
// PROCESS -- which is what this is -- is counted. The sixty-fifth is
// `sandbox: refused: process limit (64)`, and that is the second half of this
// file's expectations.
//
// Under step B, with no filter at all, the wall was RLIMIT_NPROC: 0 for the
// run step, so the kernel refused the first clone with EAGAIN and the program
// printed `forked 0` -- unless the box had been started by root, where
// copy_process skips the check for INIT_USER and it printed `forked 200`.
//
// `fork` is declared i32 and not i64 on purpose: it returns a C `int`, the two
// ABIs leave the upper half of the register unspecified, and an i64 declaration
// read glibc\'s -1 as 4294967295 here -- a fork bomb that looked unbounded
// because its own test could not see a failure (M45; docs/reference/language.md
// § 2).
//
// Whatever it does fork stays inside the pid namespace and dies with it, which
// is the property the test script checks from outside: the host\'s process
// count before and after is the same.
#include <sys>
#include <io>

extern i32 fork();
extern i32 usleep(i64 us);

i64 main() {
    i64 n = 0;
    loop {
        if (n >= 200) break;
        i64 pid = fork();
        if (pid < 0) break;
        if (pid == 0) { usleep(2000000); exit(0); }
        n = n + 1;
    }
    puts("forked ");
    putnum(n);
    puts("\n");
    return 0;
}
