// sys.mc — the core's minimal I/O via libSystem: the five externs and, via
// io.mc, the utilities written in the language itself. Include with
// #include "sys.mc". The alternative without libSystem is lib/sys_svc.mc
// (same interface, via #opcode svc).

// open is variadic in libSystem and on Apple's arm64 the mode goes on the
// stack, which the core does not set up: to create a file with permissions
// use creat, which is not variadic.
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
extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern uptr _NSGetEnviron();

#include "io.mc"
