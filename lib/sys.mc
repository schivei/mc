// sys.mc — the core's minimal I/O via libSystem: the five externs and, via
// io.mc, the utilities written in the language itself. Include with
// #include "sys.mc". The alternative without libSystem is lib/sys_svc.mc
// (same interface, via #opcode svc).

// macOS values (sys/fcntl.h). They live here and not in io.mc because they are
// per-system: lib/sys_linux.mc declares the Linux ones (M16).
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0x200
#define O_TRUNC 0x400

// open is variadic in libSystem and on Apple's arm64 the mode goes on the
// stack, which the core does not set up: to create a file with permissions
// use creat, which is not variadic.
//
// M45, and this is a MEASUREMENT and not a preference: these five return a C
// `int` (`read`/`write` a `ssize_t`), and after M45 the truthful declaration
// would be a four-byte one. They stay `i64` because libSystem's syscall
// wrappers hand back a FULL 64-bit -1 -- measured on this host with the
// pre-milestone compiler: open("/nonexistent") = 0xffffffffffffffff,
// close(-1) = 0xffffffffffffffff, waitpid(-1) = 0xffffffffffffffff
// (docs/specs/M45.md § Implementation notes 1c) -- so nothing here is wrong,
// and `u32` would cost a mask on every I/O call in every program that includes
// this file, including the ten tests/*.mc the frozen seed cross-checks.
//
// That is NOT true of an ordinary C function: `int f(void) { return -1; }`
// compiled by clang is `mov w0, #-0x1; ret`, and a program that calls one
// writes its own `extern i32 f();` -- which works, because a program is not a
// file the seed compiles.
extern i64 open(uptr path, i64 flags, i64 mode);
extern i64 creat(uptr path, i64 mode);
extern i64 read(i64 fd, uptr buf, i64 n);
extern i64 write(i64 fd, uptr buf, i64 n);
extern i64 close(i64 fd);
extern void exit(i64 code);

// M14: running another program. `mc build` uses exactly these two to spawn the
// linker and the compiler it has just taught (src/driver.mc), and they are here
// so any program can do the same.
//
//   u8 pid[8]; st64(pid, 0);
//   u8 av[3 * 8]; st64(av + 0, "ls"); st64(av + 8, "-l"); st64(av + 16, 0);
//   posix_spawnp(pid, "ls", 0, 0, av, ld64(_NSGetEnviron()));
//   u8 st[8]; st64(st, 0);
//   waitpid(ld64(pid), st, 0);            // exit code = (ld32(st) >> 8) & 255
//
// There is NO equivalent in lib/sys_svc.mc, and that is deliberate: sys_svc.mc
// exists to show the core does not need libc for I/O, and posix_spawn is not a
// syscall -- it is a libSystem routine that marshals a struct this language
// cannot lay out into __posix_spawn(2). A program that wants to spawn without
// libSystem has to fork/exec by hand, which the core does not offer either.
// M23: anonymous memory straight from the kernel, which is how the compiler's
// own arena grows past its static heap (src/arena.mc). PROT_READ|PROT_WRITE is
// 3 and MAP_PRIVATE|MAP_ANON is 0x1002; fd is -1 and off 0:
//
//   uptr p = mmap(0, 1 << 20, 3, 0x1002, 0 - 1, 0);   // 0 - 1 == MAP_FAILED
//
// There is no equivalent in lib/sys_svc.mc for the same reason as posix_spawn:
// mmap on macOS is a libSystem routine, not a stable syscall number.
extern uptr mmap(uptr addr, i64 len, i64 prot, i64 flags, i64 fd, i64 off);
extern i64 munmap(uptr addr, i64 len);

extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern uptr _NSGetEnviron();

#include "io.mc"
