// sys.mc — I/O minima do nucleo pela libSystem: os cinco externs e, via io.mc,
// os utilitarios escritos na propria linguagem. Incluir com #include "sys.mc".
// A alternativa sem libSystem e lib/sys_svc.mc (mesma interface, via #opcode svc).

extern i64 open(uptr path, i64 flags, i64 mode);
extern i64 read(i64 fd, uptr buf, i64 n);
extern i64 write(i64 fd, uptr buf, i64 n);
extern i64 close(i64 fd);
extern void exit(i64 code);

#include "io.mc"
