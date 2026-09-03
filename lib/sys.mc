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

#include "io.mc"
