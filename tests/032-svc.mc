// expect-exit: 0
// expect-stdout: hi
// skip-linux: lib/sys_svc.mc has the Darwin syscall numbers in x16 and svc #0x80; the Linux equivalent is lib/sys_linux.mc
// The same interface as sys.mc, but with no extern at all: open/read/write/close/exit
// are mov16/svc pairs taught via #opcode in lib/sys_svc.mc.
#include "../lib/sys_svc.mc"

i64 main() {
    write(1, "hi\n", 3);
    return 0;
}
