// sys.mc — I/O minima do nucleo: os externs da libSystem, as flags de open e
// tres utilitarios escritos na propria linguagem. Incluir com #include "sys.mc".

extern i64 open(uptr path, i64 flags, i64 mode);
extern i64 read(i64 fd, uptr buf, i64 n);
extern i64 write(i64 fd, uptr buf, i64 n);
extern i64 close(i64 fd);
extern void exit(i64 code);

// valores do macOS (sys/fcntl.h)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 0x200
#define O_TRUNC 0x400

// comprimento de uma string NUL-terminada
i64 strlen(uptr s) {
    i64 n = 0;
    loop {
        if (ld8(s + n) == 0) break;
        n = n + 1;
    }
    return n;
}

// escreve a string em stdout, sem o NUL
void puts(uptr s) {
    write(1, s, strlen(s));
}

// escreve um inteiro nao negativo em stdout, sem quebra de linha
void putnum(i64 v) {
    u8 buf[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(buf + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);
}
