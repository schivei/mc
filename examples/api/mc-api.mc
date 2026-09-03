// mc-api.mc — o compilador deste exemplo: o nucleo do `mc` mais `class`,
// `interface` e dois aliases de tipo. Nao edita `src/`: pega o compilador
// inteiro menos o `user_init` por `src/core.mc` e fornece o `user_init`.
//
//   make -C examples/api mc-api      # build/mc-api, via `build/mc1 --exe`
//   examples/api/build/mc-api --exe tests/oop_test.mc -o build/oop_test
//
// O compilador padrao (`build/mc1`) recusa o mesmo fonte com
// `tipo esperado no topo` na linha do primeiro `interface`: a sintaxe pertence
// a este arquivo, nao a linguagem. Ver docs/surface.md § Tier 3.

#include "../../src/core.mc"
#include "oop.mc"

void user_init() {
    syntax("class", &oop_class);                 // declaracao de topo
    syntax("interface", &oop_interface);         // declaracao de topo
    type_alias("bool", TY_U8);                   // tipo novo, sem sintaxe nova
    type_alias("str", TY_UPTR);
}
