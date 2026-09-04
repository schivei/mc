// expect-exit: 0
// expect-stdout: nested=1234 callp=5678
// M20: the argument-staging proof. On Win64 the argument registers are
// rcx rdx r8 r9 and TWO of them, r8 and r9, are also the machine's depth
// registers for depths 0 and 1 -- so a call whose later arguments are
// themselves calls is where a wrong ordering would clobber a value still to be
// read. x86_reg_args writes the table in ascending index and every depth
// register's own argument index is smaller than its position in it, so the
// source is always already consumed; this test is what makes that argument
// executable rather than only written down. The same through callp, where the
// pointer has to reach rax BEFORE any argument register is written because it
// may itself be living in r8..r11.
//
// It is portable: on arm64 the eight argument registers are disjoint from the
// depth registers and the test simply passes.
#include <sys_windows>
#include <io>

i64 add4(i64 a, i64 b, i64 c, i64 d) { return a * 1000 + b * 100 + c * 10 + d; }
i64 g(i64 x, i64 y) { return x + y; }
i64 h(i64 z) { return z * 2; }

i64 main(i64 argc, uptr argv) {
    puts("nested=");
    putnum(add4(1, 2, g(1, 2), h(2)));           // 1000 + 200 + 30 + 4
    uptr p = &add4;
    puts(" callp=");
    putnum(callp(p, 5, 6, g(3, 4), h(4)));       // 5000 + 600 + 70 + 8
    puts("\n");
    return 0;
}
