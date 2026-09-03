// core.mc — o compilador sem o ponto de extensao: so a lista de #include, na
// ordem de dependencia, exatamente como o stage0 compila stage0/*.c contra mc.h.
//
//   arena.mc     xalloc/buf_*/out_*/die/err_at/read_file/write_file e os limites
//                compartilhados (MAXSECS, MAXPARAMS), o papel do mc.h
//   macho.mc     secoes, simbolos, relocacoes e a escrita do MH_OBJECT
//   lex.mc       tabela de tokens mutavel e lexer incremental
//   ast.mc       nos em array plano na arena + dump
//   parse.mc     descida recursiva + Pratt dirigido por tabela + dobra
//   gen_arm64.mc buffer de instrucoes, encoders AArch64 e --dump-asm
//   sha256.mc    SHA-256 puro, para a assinatura ad-hoc e o UUID do executavel
//   backend_exe.mc backend `macho-exe`: MH_EXECUTE assinado, sem `ld` (M11)
//   hooks.mc     Tier 2/3: passes (pass), backends (backend), sintaxe (syntax)
//   main.mc      CLI
//
// macho.mc vem antes de lex.mc porque parse.mc usa sec_new (via sec_make) e as
// constantes R_* que defs_init registra; e a mesma ordem que src/astdump.mc ja
// usava na fatia 3.
//
// Falta aqui exatamente uma coisa: `void user_init()`. Quem inclui core.mc tem
// de defini-la — e ela que registra passes, backends, sintaxe e aliases (M10,
// M12). O compilador padrao e src/mc.mc: core.mc + src/user.mc, que por sua vez
// pega o user_init vazio de lib/user_default.mc. Um compilador ensinado e um
// arquivo proprio, fora de src/:
//
//     #include "../../src/core.mc"
//     #include "oop.mc"
//     void user_init() { syntax("class", &oop_class); }
//
// Ver docs/surface.md § Tier 3.

#include "arena.mc"
#include "macho.mc"
#include "lex.mc"
#include "ast.mc"
#include "parse.mc"
#include "gen_arm64.mc"
#include "sha256.mc"
#include "backend_exe.mc"
#include "hooks.mc"
#include "main.mc"
