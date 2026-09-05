// sandbox-exit: 0
// sandbox-stdout: forked 0
// sandbox-stdout-root: forked 200
// A fork bomb, bounded by the box and not by this program: it forks in a loop
// and stops at the first refusal, printing how many children it got. Zero is
// the answer with RLIMIT_NPROC at 0 -- the run step\'s default -- and the
// kernel refuses the FIRST clone with EAGAIN.
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
