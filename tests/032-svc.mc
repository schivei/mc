// expect-exit: 0
// expect-stdout: hi
// A mesma interface de sys.mc, mas sem nenhum extern: open/read/write/close/exit
// sao pares mov16/svc ensinados por #opcode em lib/sys_svc.mc.
#include "../lib/sys_svc.mc"

i64 main() {
    write(1, "hi\n", 3);
    return 0;
}
