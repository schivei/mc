// mc-avx.mc — the compiler that carries examples/avx/avx.mc.
//
//   build/mc1 --exe examples/avx/mc-avx.mc -o build/mc-avx
//   build/mc-avx --backend=elf-obj-x86_64 examples/avx/main.mc -o main.o
#include "../../src/host_macos.mc"
#include "../../src/core.mc"
#include "avx.mc"

void user_init() {
    avx_init();
}
