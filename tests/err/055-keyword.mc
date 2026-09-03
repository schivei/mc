// CASO DE ERRO — nao entra em scripts/test.sh (por isso mora em tests/err/).
// O primeiro item de um #rule que e um identificador vira palavra-chave
// reservada na hora da definicao (tok_add como word). Depois disso `while` nao
// e mais um T_IDENT, entao nao pode ser nome de variavel.
//
// esperado: tests/err/055-keyword.mc:10: nome de variavel esperado (exit 1)
#include "../../lib/prelude.mc"

i64 main() {
    i64 while = 1;                    // erro: `while` virou palavra-chave
    return while;
}
