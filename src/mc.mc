// mc.mc — o compilador padrao: o nucleo (core.mc) mais o ponto de extensao do
// usuario (user.mc, que por padrao so tem um `user_init` vazio).
//
// A divisao existe desde o M12: um compilador ensinado nao edita src/, ele e um
// arquivo proprio que inclui `src/core.mc` e define o seu proprio `user_init`
// (ver docs/surface.md § Tier 3 e examples/api/mc-api.mc). src/user.mc continua
// sendo a costura de quem prefere ensinar o compilador padrao no lugar.

#include "core.mc"
#include "user.mc"
