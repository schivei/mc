// sys_svc.mc — the same interface as sys.mc, without libSystem: each system
// call is a pair of words taught via #opcode. x16 carries the syscall number
// and svc #0x80 enters the kernel; x0..x7 already arrive with the arguments
// because the prologue writes the parameters to the frame without touching
// the ABI registers, and a function with no return ends in the epilogue
// preserving the x0 the syscall left.
//
// Warning: the syscall signals an error with the carry flag and returns errno
// in x0. Here the raw x0 is returned as is — there is no translation to -errno.

#opcode mov16(rd, imm) 0xD2800000 | (imm << 5) | rd
#opcode movx(rd, rm)   0xAA0003E0 | (rm << 16) | rd    // orr rd, xzr, rm
#opcode svc(imm)       0xD4000001 | (imm << 5)

// BSD numbers (sys/syscall.h)
#define SYS_EXIT 1
#define SYS_READ 3
#define SYS_WRITE 4
#define SYS_OPEN 5
#define SYS_CLOSE 6

i64 open(uptr path, i64 flags, i64 mode) {
    mov16(16, SYS_OPEN);
    svc(0x80);
}

// creat(path, mode) == open(path, O_WRONLY|O_CREAT|O_TRUNC, mode): there is no
// dedicated syscall, only open's with fixed flags. The arguments arrive in x0
// (path) and x1 (mode); movx copies the mode to x2 BEFORE x1 receives the flags.
#define CREAT_FLAGS 0x601             // O_WRONLY | O_CREAT | O_TRUNC

i64 creat(uptr path, i64 mode) {
    movx(2, 1);
    mov16(1, CREAT_FLAGS);
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
