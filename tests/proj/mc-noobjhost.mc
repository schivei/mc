// mc-noobjhost.mc — the compiler that carries tests/proj/noobjhost.mc, in three
// lines of #include, the same shape as tests/proj/mc-noexe.mc.
//
// `<mc/host>` is the host file of the compiler that BUILDS this one (M37), so
// the same three lines produce a working compiler on every host.
#include <mc/host>
#include <mc/core>
#include "noobjhost.mc"
