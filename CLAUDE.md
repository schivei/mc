# mc — mini compilador auto-hospedável, ensinável pela superfície

Leia `docs/plan.md` antes de qualquer trabalho: ele fixa a linguagem, a superfície de ensino,
a arquitetura, o orçamento e os marcos. Este arquivo só resume as regras operacionais.

## Papéis
O usuário é o dono; a sessão principal é o **arquiteto** e **delega toda criação** a agentes
(`.claude/agents/`): `stage0-dev` (C23), `mc-dev` (código `.mc`), `reviewer`, `verifier`, `docs-writer`.
Agentes reportam fatos (comandos rodados + saída), nunca suposições.

## Regras invioláveis
- `stage0/*.c` ≤ 3000 linhas no total (`make budget`). Estourar é falha de build.
- stage0 usa da libc **apenas** `open/read/write/close/_exit` (arena.c). Nada de stdio/malloc/qsort.
- Todo campo de arquivo é escrito byte a byte em little-endian via `buf_u8/u16/u32/u64`. Nunca `fwrite(&struct)`.
- Determinismo (`docs/plan.md` § Determinismo): sem hash de ponteiros, sem iterar hash tables para saída,
  partição estável de símbolos, sem `__FILE__`/datas/caminhos, padding zerado.
- Código C tem o **mesmo formato** que terá em `.mc`: funções pequenas, dados planos em arena,
  sem struct-em-arquivo, sem macros textuais espertas. O stage0 será transliterado 1:1 para `src/*.mc`.
- Comentários e mensagens em português, sem acento nos identificadores. Sem emojis.
- Não olhar nem copiar código de outros projetos do usuário (`~/projects/langs` é proibido).

## Comandos
- `make stage0` → `build/mc0` · `make stage0-san` (sanitizers) · `make budget` · `make test`
- `scripts/link.sh OUT IN.o` liga com `ld -lSystem` (ld é permitido; gcc/cc/clang só para o stage0).
- Inspeção: `otool -hlv X.o`, `otool -r X.o`, `nm -m X.o`.

## Estado
- M0 ✔ (`.o` manual, exit 42) · M0.5 ✔ (svc funciona sob dyld; estático é morto pelo kernel)
- M1 ✔ verificado e revisado (lexer, Pratt, AST, dumps, codegen constante)
- M2 ✔ verificado e revisado (locais, chamadas, extern, ld/st, spill)
- M3 ✔ (globais, arrays, strings, `&x`, `#include`, `#define`, `extern`, arena)
- M4 ✔ (tokenizador em `.mc`; `make check-lex` cruza `--dump-tokens` com `src/lexdump.mc`)
- M5 ✔ (4 relocações, `#section`, `#opcode`, `emit()`/`reloc()`, `lib/sys_svc.mc`)
- M5.5 ✔ (`\0` proibido em string, `path_join` normaliza `.`/`..`, token carrega arquivo,
  `#define` vs nome, ordem das seções, array global inicializado, `udiv`, protótipo)
  — 2492/3000 linhas, `make test` 24/24, `make check-lex` 31/31
- M5.6 ✔ (`reloc()` só gruda em palavra crua; `__data` e `#section` sem ALIGN com
  alinhamento 16; `MAXSECS`/`MAXPARAMS` só em `mc.h`; `creat` no lugar de `open`
  variádica ao escrever arquivo — `stage0/arena.c`, `lib/sys.mc`, `lib/sys_svc.mc`,
  `src/arena.mc`; `cmp_cond` por tabela)
  — 2497/3000 linhas, `make test` 24/24, `make check-lex` 36/36
- M6 em andamento (`docs/specs/M6-M7.md`): `src/macho.mc` ✔, `src/parse.mc` em curso.
  Atualize esta seção ao fechar cada marco.
