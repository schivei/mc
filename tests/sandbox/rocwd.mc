// sandbox-exit: 0
// sandbox-stdout: ro ok cwd ok
// sandbox-opts: --ro tests --cwd /ro0
// The two options that put something else in the box beside /src: `--ro DIR`
// binds a host directory READ-ONLY at /ro0, /ro1, ... in the order given, and
// `--cwd` says where the step starts (an absolute path is a path in the box, a
// relative one is under /src).
//
// So this program, whose own source is at /src/rocwd.mc, opens
// `013-putnum.mc` -- a RELATIVE path, which only resolves because the step's
// working directory is the read-only bind of tests/ -- and then proves the
// mount is read-only by trying to create a file in it.
#include <sys>
#include <io>

extern uptr fopen(uptr path, uptr mode);

i64 main() {
    uptr f = fopen("013-putnum.mc", "r");
    if (f == 0) { puts("ro MISSING\n"); return 1; }
    puts("ro ok ");
    uptr w = fopen("should-not-exist.txt", "w");
    if (w) { puts("cwd WRITABLE\n"); return 1; }
    puts("cwd ok\n");
    return 0;
}
