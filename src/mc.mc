// mc.mc — o compilador auto-hospedado: so a lista de #include, na ordem de
// dependencia, exatamente como o stage0 compila stage0/*.c contra mc.h.
//
//   arena.mc     xalloc/buf_*/out_*/die/err_at/read_file/write_file e os limites
//                compartilhados (MAXSECS, MAXPARAMS), o papel do mc.h
//   macho.mc     secoes, simbolos, relocacoes e a escrita do MH_OBJECT
//   lex.mc       tabela de tokens mutavel e lexer incremental
//   ast.mc       nos em array plano na arena + dump
//   parse.mc     descida recursiva + Pratt dirigido por tabela + dobra
//   gen_arm64.mc buffer de instrucoes, encoders AArch64 e --dump-asm
//   hooks.mc     Tier 2: tabelas de passes (pass) e de backends (backend)
//   user.mc      ponto de extensao do usuario; por padrao lib/user_default.mc
//   main.mc      CLI
//
// macho.mc vem antes de lex.mc porque parse.mc usa sec_new (via sec_make) e as
// constantes R_* que defs_init registra; e a mesma ordem que src/astdump.mc ja
// usava na fatia 3.

#include "arena.mc"
#include "macho.mc"
#include "lex.mc"
#include "ast.mc"
#include "parse.mc"
#include "gen_arm64.mc"
#include "hooks.mc"
#include "user.mc"
#include "main.mc"
