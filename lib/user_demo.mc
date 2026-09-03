// user_demo.mc — o `user_init` da demonstracao do M10.
//
// Ligar isto e trocar o include de src/user.mc por
//
//     #include "../lib/user_demo.mc"
//
// e rodar `make mc1`. O compilador recompilado passa a ter o backend
// `arm64-surface` (`--backend=arm64-surface`) e o pass `x * 1` -> `x`.
// `make check-surface` faz essa troca sozinho e devolve o repositorio como
// estava. Ver docs/surface.md, secao Tier 2.

#include "backend_arm64.mc"
#include "pass_demo.mc"

void user_init() {
    backend("arm64-surface", &sur_backend);
    pass(&pass_mul1);
}
