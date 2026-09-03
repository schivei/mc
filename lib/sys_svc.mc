// sys_svc.mc — mesma interface de sys.mc, sem libSystem: cada chamada de sistema
// e um par de palavras ensinadas por #opcode. x16 leva o numero da syscall e
// svc #0x80 entra no kernel; x0..x7 ja chegam com os argumentos porque o prologo
// grava os parametros no frame sem tocar nos registradores da ABI, e a funcao sem
// return termina no epilogo preservando o x0 que a syscall deixou.
//
// Atencao: a syscall sinaliza erro com a flag de carry e devolve errno em x0.
// Aqui o x0 cru e devolvido como esta — nao ha traducao para -errno.

#opcode mov16(rd, imm) 0xD2800000 | (imm << 5) | rd
#opcode svc(imm)       0xD4000001 | (imm << 5)

// numeros BSD (sys/syscall.h)
#define SYS_EXIT 1
#define SYS_READ 3
#define SYS_WRITE 4
#define SYS_OPEN 5
#define SYS_CLOSE 6

i64 open(uptr path, i64 flags, i64 mode) {
    mov16(16, SYS_OPEN);
    svc(0x80);
}

i64 read(i64 fd, uptr buf, i64 n) {
    mov16(16, SYS_READ);
    svc(0x80);
}

i64 write(i64 fd, uptr buf, i64 n) {
    mov16(16, SYS_WRITE);
    svc(0x80);
}

i64 close(i64 fd) {
    mov16(16, SYS_CLOSE);
    svc(0x80);
}

void exit(i64 code) {
    mov16(16, SYS_EXIT);
    svc(0x80);
}

#include "io.mc"
