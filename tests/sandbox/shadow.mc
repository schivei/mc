// sandbox-report: exit 0
// sandbox-exit: 0
// sandbox-stdout: shadow errno=2
// /etc/shadow is not refused in step B: it DOES NOT EXIST. The box's root is a
// tmpfs holding /mc, /src, /out and the bind mounts of the tree in § 3, and
// there is no /etc at all -- so the program gets ENOENT (2) from the kernel and
// prints it. The NAMED refusal, `sandbox: refused: open /etc/shadow` with exit
// 125, is step C's seccomp notification; this file is what proves the mount
// tree on its own, and its expectation changes when step C lands.
#include <sys>
#include <io>

extern uptr fopen(uptr path, uptr mode);
extern uptr __errno_location();

i64 main() {
    uptr f = fopen("/etc/shadow", "r");
    if (f) { puts("shadow OPEN\n"); return 1; }
    puts("shadow errno=");
    putnum(ld32(__errno_location()));
    puts("\n");
    return 0;
}
