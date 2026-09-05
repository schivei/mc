// sandbox-exit: 0
// sandbox-stdout: malloc refused
// The memory cap (§ 4): RLIMIT_AS is --mem MiB, hard, and it is the kernel\'s
// own wall -- no capability bypasses it. Asking for 8 GiB of address space in a
// 256 MiB box makes the mmap behind malloc fail, and the program is told so
// rather than being killed.
//
// The NAMED refusal, `sandbox: refused: mmap 8589934592 bytes over the cap`
// with exit 125, is step C\'s notification; this is what the kernel does on its
// own, which is what step B can honestly claim.
#include <sys>
#include <io>

extern uptr malloc(i64 n);

i64 main() {
    uptr p = malloc(8589934592);                 // 8 GiB
    if (p == 0) { puts("malloc refused\n"); return 0; }
    // If it ever succeeds, touch every page so the cap is measured and not
    // merely reserved.
    i64 i = 0;
    loop {
        if (i >= 8589934592) break;
        st8(p + i, 1);
        i = i + 4096;
    }
    puts("malloc ok\n");
    return 0;
}
