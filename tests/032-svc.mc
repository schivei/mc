// expect-exit: 0
// expect-stdout: hi
// The same interface as sys.mc, but with no extern at all: open/read/write/close/exit
// are mov16/svc pairs taught via #opcode in lib/sys_svc.mc.
#include "../lib/sys_svc.mc"

i64 main() {
    write(1, "hi\n", 3);
    return 0;
}
