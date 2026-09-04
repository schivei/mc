// mc-noexe.mc — the compiler that carries tests/proj/noexe.mc, in three lines
// of #include, the same shape as lib/mc_lit_nop.mc.
//
// `<mc/host>` is the host file of the compiler that BUILDS this one (M37), so
// the same three lines produce a working compiler on every host.
#include <mc/host>
#include <mc/core>
#include "noexe.mc"
