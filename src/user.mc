// user.mc — ponto de extensao do usuario (Tier 2).
//
// Este arquivo e a unica costura entre o compilador e os modulos de quem o
// ensina: ele diz quais modulos entram no binario. Por padrao entra so o
// `user_init` vazio de lib/user_default.mc — o compilador padrao, sem passes
// nem backends alem do `macho` embutido.
//
// Para ensinar o compilador, troque o include abaixo pelo seu modulo e rode
// `make mc1`. Por exemplo, para ligar a demonstracao do M10 (o backend
// `arm64-surface` e o pass `x * 1` -> `x`):
//
//     #include "../lib/user_default.mc"
//
// Nao ha dylib, nao ha ABI de plugin: o modulo e compilado junto com o resto do
// compilador. Ver docs/surface.md, secao Tier 2.

#include "../lib/user_default.mc"
