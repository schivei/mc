// sandbox-exit: 0
// sandbox-stdout: libc ok
// sandbox-report: exit 0
// An ORDINARY C-library program, and the case the rest of tests/sandbox/ does
// not cover: everything else here either reaches for something the box refuses
// or writes with a raw `write`. This one allocates four megabytes, reads a
// file through stdio and hands both back, which is what the seccomp profile
// has to allow without a word (M43 step C, § 4).
//
// It is also the dynamic case: it names glibc's or musl's loader in its
// PT_INTERP and finds it, and its libc beside it, only because the box binds
// /lib, /lib64 and /usr/lib read-only and nothing else of the host (§ 3).
// scripts/test-sandbox.sh runs it twice -- once through `mc sandbox run`,
// which compiles it inside the box, and once through `mc sandbox exec` on a
// binary built OUTSIDE it.
//
// The file it opens is its own executable, `libcuser`, which is in /src both
// ways round: `run` writes it there and `exec` puts the binary's own directory
// there.
//
// Four megabytes in one block is not an arbitrary number: it is what makes
// glibc advise MADV_HUGEPAGE on the chunk, and `madvise` is in the measured
// profile for exactly that reason (scripts/sandbox-trace.sh).
#include <sys>
#include <io>

extern uptr malloc(i64 n);
extern void free(uptr p);
extern uptr fopen(uptr path, uptr mode);
extern i64 fread(uptr p, i64 sz, i64 n, uptr f);
extern i32 fclose(uptr f);

i64 main() {
    uptr p = malloc(4194304);
    if (p == 0) { puts("malloc failed\n"); return 1; }
    st8(p, 1);
    free(p);

    uptr f = fopen("libcuser", "r");
    if (f == 0) { puts("fopen failed\n"); return 1; }
    uptr b = malloc(8192);
    i64 n = fread(b, 1, 4096, f);
    fclose(f);
    free(b);
    if (n <= 0) { puts("fread failed\n"); return 1; }

    puts("libc ok\n");
    return 0;
}
