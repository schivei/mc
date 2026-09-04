// mc_badmach.mc — the compiler that carries lib/user_badmach.mc (M24).
//
//   build/mc1 --exe lib/mc_badmach.mc -o build/mc-badmach
//   build/mc-badmach --dump-machine x.mc | grep '  bin '     ->  bin  taught
#include "../src/host_macos.mc"
#include "../src/core.mc"
#include "user_badmach.mc"
