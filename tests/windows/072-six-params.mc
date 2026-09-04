// expect-exit: 0
// expect-stdout: sum=21 open=1
// M20: the shadow space and the stack-parameter offsets, against real kernel32.
// `six` has six parameters, so on Win64 the fifth and sixth arrive on the stack
// at [rbp+48] and [rbp+56] -- 16 for the saved rbp and the return address, plus
// the 32 bytes of shadow space the CALLER reserved. CreateFileA takes seven
// arguments, so three of them travel on the stack above the same 32 bytes, and
// a missing `sub rsp, 32` would corrupt this caller's frame precisely because
// the callee is a real Win64 function that uses its home space.
//
// The file it opens is its own source, which exists because the suite is run
// from the repository root (tests/025-linecount.mc depends on the same thing).
// Nothing is created and nothing is written.
//
// Portable: on arm64 all six parameters and all seven arguments are registers.
#include <sys_windows>
#include <io>

i64 six(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f) {
    return a + b + c + d + e + f;
}

i64 main(i64 argc, uptr argv) {
    puts("sum=");
    putnum(six(1, 2, 3, 4, 5, 6));
    uptr h = CreateFileA("tests/windows/072-six-params.mc", GENERIC_READ,
                         FILE_SHARE_READ, 0, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, 0);
    i64 ok = 0;
    if (h != INVALID_HANDLE) {
        CloseHandle(h);
        ok = 1;
    }
    puts(" open=");
    putnum(ok);
    puts("\n");
    return 0;
}
