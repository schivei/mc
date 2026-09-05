// sandbox-exit: 0
// sandbox-stdout: socket ok connect=-1 errno=101
// The network namespace (§ 3): the box unshares CLONE_NEWNET, so its network
// stack is a fresh one with nothing but a DOWN loopback. `socket` still
// succeeds -- creating one is not reaching anything -- and the connect to
// 1.1.1.1:80 answers ENETUNREACH (101), which is the kernel saying there is no
// route because there is no interface.
//
// The NAMED refusal, `sandbox: refused: syscall 198 (socket)` with exit 125, is
// step C's seccomp profile; the empty namespace is the wall that exists
// without it, and this is what measures it.
#include <sys>
#include <io>

// both return a C `int`: i32, so that a -1 is a -1 (M45)
extern i32 socket(i64 domain, i64 type, i64 proto);
extern i32 connect(i64 fd, uptr addr, i64 len);
extern uptr __errno_location();

i64 main() {
    i64 fd = socket(2, 1, 0);                    // AF_INET, SOCK_STREAM
    if (fd < 0) { puts("socket refused\n"); return 0; }
    puts("socket ok ");
    // struct sockaddr_in, Linux: sa_family u16 = 2, port u16 big-endian = 80,
    // then the address in network order -- 1.1.1.1.
    u8 sa[16];
    i64 i = 0;
    loop { if (i >= 16) break; st8(sa + i, 0); i = i + 1; }
    st16(sa, 2);
    st8(sa + 2, 0);
    st8(sa + 3, 80);
    st8(sa + 4, 1); st8(sa + 5, 1); st8(sa + 6, 1); st8(sa + 7, 1);
    i64 rc = connect(fd, sa, 16);
    puts("connect=");
    if (rc < 0) puts("-1"); else putnum(rc);
    puts(" errno=");
    putnum(ld32(__errno_location()));
    puts("\n");
    return 0;
}
