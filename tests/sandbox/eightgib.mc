// sandbox-exit: 125
// sandbox-stdout:
// sandbox-report: refused: mmap 8589934592 bytes over the cap (268435456)
// The memory cap (M43 § 4). Every mmap and munmap reaches the supervisor,
// which keeps a running total of what the step has mapped and compares it with
// --mem: 8 GiB in a 256 MiB box is `sandbox: refused: mmap 8589934592 bytes
// over the cap (268435456)`, exit 125.
//
// It asks the kernel DIRECTLY rather than through malloc, and that is what
// makes the number in the report exactly the number in this file: glibc adds a
// page of its own for the chunk header, so the same test through malloc(8 GiB)
// reports 8589938688 -- true, and impossible to write down here.
//
// RLIMIT_AS is the wall under it and does not need the supervisor: with the
// filter removed the mmap answers MAP_FAILED, because --mem is also a hard
// resource limit the kernel enforces on its own.
//
// mmap itself comes from <sys>, which declares it for exactly this reason (it
// is a libSystem routine on macOS and a system call on Linux, and both sides
// call it by that name).
#include <sys>
#include <io>

i64 main() {
    // PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS -- the same numbers on
    // both architectures (src/arena.mc says so too).
    uptr p = mmap(0, 8589934592, 3, 0x22, -1, 0);
    if (p == 0 || p + 1 == 0) { puts("mmap refused\n"); return 0; }
    // If it ever succeeds, touch every page so the cap is measured and not
    // merely reserved.
    i64 i = 0;
    loop {
        if (i >= 8589934592) break;
        st8(p + i, 1);
        i = i + 4096;
    }
    puts("mmap ok\n");
    return 0;
}
