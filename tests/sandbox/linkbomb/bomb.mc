// The "linker" of the hostile project: a fork bomb that `mc build` executes
// because mc.toml named it (see mc.toml, and docs/specs/M43.md
// § Implementation notes -- the review).
//
// It is an ordinary mc program compiled by the compiler under test, exactly as
// a taught compiler is inside the box -- scripts/test-sandbox.sh builds it into
// build/ and the box executes it from /src.
//
// The children do nothing but exit: nanosleep is not in the compile profile,
// so a child that slept would end the box at ITS refusal instead of at the
// process limit, and the point of the case is which line the report carries.
// The count is P's and it is cumulative, so children that die immediately
// still reach the limit.
//
// `fork` is declared i32 because it returns a C `int` and the upper half of
// the register is unspecified (M45; docs/reference/language.md § 2).
#include <sys>
#include <io>

extern i32 fork();

i64 main() {
    i64 n = 0;
    loop {
        if (n >= 200) break;
        i64 pid = fork();
        if (pid < 0) break;
        if (pid == 0) exit(0);
        n = n + 1;
    }
    puts("forked ");
    putnum(n);
    puts("\n");
    return 1;
}
