// sys_linux.mc — the same interface as sys.mc, on Linux and with no libc at
// all: each system call is a handful of words taught through #opcode. It is
// lib/sys_svc.mc's sibling — same idea, other kernel (M16, docs/build.md
// § Linux targets).
//
// Linux/AArch64 calling convention for a system call: arguments in x0..x5, the
// call number in x8, `svc #0`, result in x0. That differs from Darwin twice
// over — Darwin puts the number in x16 and enters with `svc #0x80` — so the two
// files cannot share a single opcode table.
//
// Warning: on Linux the error is the RETURN VALUE, a small negative number
// (-errno); there is no carry flag involved. As in sys_svc.mc, x0 is handed back
// raw, with no translation.
//
// Link with `-nostdlib -e _start`: this file provides the entry point too, so a
// program that includes it needs neither crt1.o nor libc.a.

#opcode mov16(rd, imm)      0xD2800000 | (imm << 5) | rd     // movz xd, #imm
#opcode movn16(rd, imm)     0x92800000 | (imm << 5) | rd     // movn xd, #imm  -> ~imm
#opcode movx(rd, rm)        0xAA0003E0 | (rm << 16) | rd     // orr xd, xzr, xm
#opcode addi(rd, rn, imm)   0x91000000 | (imm << 10) | (rn << 5) | rd
#opcode ldrx(rt, rn, off)   0xF9400000 | ((off / 8) << 10) | (rn << 5) | rt
#opcode svc0()              0xD4000001                       // svc #0

// asm-generic/unistd.h, which is the table AArch64 uses
#define SYS_FCHMOD     52
#define SYS_OPENAT     56
#define SYS_CLOSE      57
#define SYS_READ       63
#define SYS_WRITE      64
#define SYS_EXIT_GROUP 94

// AT_FDCWD is -100; movn xd, #99 is the shortest way to say it
#define AT_FDCWD_NOT 99

// asm-generic/fcntl.h. These are NOT the macOS values in lib/sys.mc:
// O_CREAT is 0x40 here and 0x200 there, O_TRUNC 0x200 here and 0x400 there.
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT  0x40
#define O_TRUNC  0x200

#define CREAT_FLAGS 0x241             // O_WRONLY | O_CREAT | O_TRUNC

// There is no `open` system call on AArch64, only `openat`. The three arguments
// arrive in x0..x2 and have to slide up one register before x0 becomes AT_FDCWD
// — hence the moves in descending order, so nothing is overwritten before it is
// read.
i64 open(uptr path, i64 flags, i64 mode) {
    movx(3, 2);
    movx(2, 1);
    movx(1, 0);
    movn16(0, AT_FDCWD_NOT);
    mov16(8, SYS_OPENAT);
    svc0();
}

// creat(path, mode) is openat with fixed flags: path arrives in x0 and the mode
// in x1, so the mode goes to x3 BEFORE x1 is reused for the path.
i64 creat(uptr path, i64 mode) {
    movx(3, 1);
    movx(1, 0);
    mov16(2, CREAT_FLAGS);
    movn16(0, AT_FDCWD_NOT);
    mov16(8, SYS_OPENAT);
    svc0();
}

i64 read(i64 fd, uptr buf, i64 n) {
    mov16(8, SYS_READ);
    svc0();
}

i64 write(i64 fd, uptr buf, i64 n) {
    mov16(8, SYS_WRITE);
    svc0();
}

i64 close(i64 fd) {
    mov16(8, SYS_CLOSE);
    svc0();
}

// `chmod` is not a system call here either; fchmod on an open descriptor is
i64 fchmod(i64 fd, i64 mode) {
    mov16(8, SYS_FCHMOD);
    svc0();
}

void exit(i64 code) {
    mov16(8, SYS_EXIT_GROUP);
    svc0();
}

// ---- entry point ----
// The kernel enters `_start` with sp pointing at the entry stack:
//
//     [sp]      argc
//     [sp + 8]  argv[0] ... argv[argc-1], NULL, envp...
//
// and every register undefined. The core's prologue is always
// `stp x29, x30, [sp, #-16]!` + `mov x29, sp` + a `sub sp, sp, #frame` that
// disappears when the frame is empty — and this function has no parameters and
// no locals, so its frame IS empty. So after the prologue x29 is the entry sp
// minus the 16 bytes of the stp: argc sits at x29 + 16 and argv starts at
// x29 + 24. (scripts/test-linux.sh's no-libc case checks argc, which is what
// would break first if that prologue ever changed.)
//
// main is called with (argc, argv) and its result goes straight to exit_group —
// x0 already holds it, so nothing has to move.
#define ENTRY_ARGC 16
#define ENTRY_ARGV 24

i64 _start() {
    ldrx(0, 29, ENTRY_ARGC);              // x0 = argc
    addi(1, 29, ENTRY_ARGV);              // x1 = argv
    reloc(BRANCH26, "_main");
    emit(0x94000000);                     // bl main
    mov16(8, SYS_EXIT_GROUP);
    svc0();
}

#include "io.mc"
