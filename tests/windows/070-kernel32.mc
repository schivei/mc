// expect-exit: 3
// expect-stdout: no crt: argc=1
// No C runtime at all: <sys_windows> gives read/write/open/close/exit as
// kernel32 calls and provides mc_start, so the link is
// `lld-link /entry:mc_start /nodefaultlib prog.obj kernel32.lib` -- no crt
// object, no libc, and nothing next to it. <io> comes after it because the
// Windows layer deliberately does not carry io.mc (see lib/sys_windows.mc).
// argc is what proves mc_start really split GetCommandLineA: the shell hands
// the program exactly one argument here, the path it was started with.
#include <sys_windows>
#include <io>

i64 main(i64 argc, uptr argv) {
    puts("no crt: argc=");
    putnum(argc);
    puts("\n");
    if (ld8(ld64(argv)) == 0) return 1;      // argv[0] is a non-empty string
    return argc + 2;
}
