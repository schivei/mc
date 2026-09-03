// user_tokadd.mc — regressao do M10: um `user_init` que mexe na tabela do lexer.
//
// Este modulo nao ensina nada: ele so registra um lexema novo. Existe para
// travar a ordem de inicializacao do driver. Os ids das palavras do nucleo
// (`K_U8`..`K_EXTERN` = 256..269) sao as 14 primeiras entradas que `tok_init`
// cria, na ordem em que as cria; se `user_init` rodasse antes de `tok_init`,
// este `tok_add` levaria o id 256 e deslocaria todas elas — o nucleo inteiro
// passaria a ler `u8` como `u16` e por aí adiante. `scripts/check-surface.sh`
// liga este modulo, recompila o compilador e confere que `tests/001-return42.mc`
// continua compilando e devolvendo 42.
//
// Ver src/main.mc: `user_init()` e chamado depois de `tok_init()` e
// `lex_init()`, e antes de qualquer token ser lido — o lexer e incremental,
// entao um `tok_add` daqui ainda vale para o fonte inteiro.

void user_init() {
    tok_add("<+>", 3);
}
