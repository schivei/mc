// mc_syntax_demo.mc — um compilador ensinado, inteiro, em duas linhas de
// #include. Nao edita `src/`: pega o nucleo por `src/core.mc` (que e o
// compilador menos o `user_init`) e o `user_init` vem de user_syntax_demo.mc.
//
//   build/mc1 --exe lib/mc_syntax_demo.mc -o build/mc-syntax-demo
//   build/mc-syntax-demo --exe lib/syntax_demo_test.mc -o /tmp/t && /tmp/t; echo $?
//   42
//
// E o mesmo padrao de examples/api/mc-api.mc. `make check-surface` faz os dois
// passos e confere o 42. Ver docs/surface.md § Tier 3.

#include "../src/core.mc"
#include "user_syntax_demo.mc"
