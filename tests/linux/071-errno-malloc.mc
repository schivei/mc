// expect-exit: 0
// expect-stdout: errno=2 malloc ok
// M42: past what the section-0 probe measured. The probe called `write`, which
// needs nothing of libc but a file descriptor; this needs libc to have
// INITIALISED ITSELF -- `errno` is thread-local in both musl and glibc, and
// `malloc` has its own arena -- from an entry point that is not `crt1.o`.
//
// That is the one assumption a crt-less dynamic executable rests on: the loader
// finishes libc's own start-up before it transfers to `_start`. It holds on
// musl and on glibc, on both architectures, and this file is where that is
// checked rather than believed (docs/reference/objects.md § 8b).
//
// write/exit come out of libc here, which is why lib/sys.mc -- written for
// macOS -- is the right include: the names are the same.
//
// The failing call is `fopen` and not `open` on purpose. `open` returns an
// `int`, and both AAPCS64 and the SysV x86-64 ABI leave the upper 32 bits of
// the result register unspecified for a 32-bit return -- an `extern i64 open`
// reads all 64, so `fd >= 0` is allowed to be TRUE for a -1. (Measured on the
// day this landed, musl and glibc both happened to sign-extend, so the hazard
// is latent: docs/specs/M42.md note 10, and M45 is the fix.) It is a
// pre-existing mc-wide question about narrow return values, not something
// this milestone decides, so this test does not depend on it -- `fopen`
// returns a pointer, all 64 bits of it. It also drags in stdio, which is more
// start-up state than `open` needs.
#include "../../lib/sys.mc"

extern uptr fopen(uptr path, uptr mode);
extern uptr __errno_location();
extern uptr malloc(i64 n);
extern void free(uptr p);

i64 main() {
    // ENOENT is 2 on Linux, in both libcs. Reading it at all is the point:
    // errno lives in thread-local storage the loader set up.
    uptr f = fopen("/nonexistent-m42/nope", "r");
    if (f != 0) return 1;
    puts("errno=");
    putnum(ld32(__errno_location()));

    uptr p = malloc(4096);
    if (p == 0) return 2;
    st64(p, 42);
    st64(p + 4088, 7);
    if (ld64(p) != 42) return 3;
    if (ld64(p + 4088) != 7) return 4;
    free(p);
    puts(" malloc ok\n");
    return 0;
}
