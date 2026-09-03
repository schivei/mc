// expect-exit: 0
// expect-stdout: 26
// Abre o proprio fonte (caminho relativo a raiz do repo, onde test.sh roda),
// conta os \n em blocos de 4096 bytes e imprime o total.
#include "../lib/sys.mc"

u8 buf[4096];

i64 main() {
    i64 fd = open("tests/025-linecount.mc", O_RDONLY, 0);
    if (fd < 0) return 1;
    i64 lines = 0;
    loop {
        i64 n = read(fd, buf, 4096);
        if (n <= 0) break;
        i64 i = 0;
        loop {
            if (i >= n) break;
            if (ld8(buf + i) == 10) lines = lines + 1;
            i = i + 1;
        }
    }
    close(fd);
    putnum(lines);
    return 0;
}
