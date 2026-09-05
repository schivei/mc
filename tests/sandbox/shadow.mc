// sandbox-report: refused: open /etc/shadow
// sandbox-exit: 125
// sandbox-stdout:
// The named refusal (M43 step C, § 4): every openat and open reaches the
// supervisor as a SECCOMP_RET_USER_NOTIF notification, P reads the path out of
// this process with process_vm_readv, finds it under none of the box's roots,
// and stops the box -- `sandbox: refused: open /etc/shadow`, exit 125.
//
// TWO walls would have stopped it anyway, and that is the point of naming it:
// there is no /etc in the box (the tree of § 3 is a tmpfs with /mc, /src, /out
// and the read-only binds), and Landlock grants nothing outside those roots.
// What step C adds is the sentence. The refused call never returns -- P kills
// the box while this process is still inside the openat -- so nothing below is
// printed and the expected stdout is empty.
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
