// expect-exit: 3
// expect-stdout: no libc: argc=1
// skip-x86_64: lib/sys_linux.mc encodes the syscalls and _start as AArch64 `svc #0` words; the x86-64 equivalent would be `syscall`
// No libc at all: <sys_linux> gives read/write/open/close/exit as raw `svc #0`
// syscalls and provides _start, so the link is `ld.lld -nostdlib -e _start`.
// argc is what proves _start really read the entry stack: the kernel hands the
// program exactly one argument here, argv[0].
#include <sys_linux>

i64 main(i64 argc, uptr argv) {
    puts("no libc: argc=");
    putnum(argc);
    puts("\n");
    if (ld8(ld64(argv)) == 0) return 1;      // argv[0] is a non-empty string
    return argc + 2;
}
