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
- M6 ✔ (`docs/specs/M6-M7.md`): `src/mc.mc` completo (`arena.mc`, `macho.mc`, `lex.mc`, `ast.mc`,
  `parse.mc`, `gen_arm64.mc`, `main.mc`) — 4310 linhas de `.mc` contra 2678 de C (`stage0/*.c` +
  `mc.h`), fator 1,6. `MAXDEFS 512` nos dois lados (`stage0/parse.c` e `src/parse.mc`). stage0
  2500/3000 linhas (`make budget`). `make mc1` gera `build/mc1`; `check-asm` 39/39, `check-obj`
  24/24, `scripts/test.sh build/mc1` 24/24.
- M7 ✔ (ponto fixo, `scripts/bootstrap.sh` + `make bootstrap`): `mc0→mc1.o`, `mc1→mc2.o`,
  `mc2→mc3.o`, `cmp mc2.o mc3.o` idênticos (163632 bytes). Golden gravado em
  `tests/golden/mc2.sha256` (ver `tests/golden/README.md` para quando atualizar).
- M8 ✔ (`docs/bootstrap.md`): `clang` só compila `stage0` (`CC = clang` no Makefile, alvos
  `build/mc0`/`build/mc0-san`); confirmado com `grep -rn clang scripts/ Makefile`. `ld` continua
  em uso via `scripts/link.sh`. Binários não versionados (`build/` no `.gitignore`).
- M9 ✔ (`docs/specs/M9.md`): `#rule stmt:` implementado no stage0 **e** em `src/parse.mc` —
  tabela linear indexada pelo token de abertura, itens `{literal | nt $nome}` com
  `nt ∈ {expr,stmt,block,ident}`, template parseado na definição (`N_HOLE` para nó, marcador de
  nome para `ident $x`/gensym), casamento sem backtracking, gensym determinístico (`__g<N>` no M9,
  corrigido para `$g<N>` no M10 — ver a entrada do M10),
  `--dump-rules`. `lib/prelude.mc` (36 linhas) dá `while`/`for`/`+=`/`-=`/`++`/`--`; testes
  `050`–`054` na suíte e `tests/err/055-keyword.mc` como caso de erro fora dela.
  `src/macho.mc` migrado para o prelúdio (módulo folha). Fora de escopo por decisão da spec:
  `#rule expr:` (reservado), buraco `type $t` e portanto `struct`.
  — stage0 2747/3000 linhas; `make check` verde: `test` 29/29, `check-lex` 45/45,
  `check-ast` 45/45, `check-asm` 45/45, `check-obj` 29/29, `bootstrap` com ponto fixo
  (`mc2.o == mc3.o`, 181504 bytes) e golden regravado em `tests/golden/mc2.sha256`.
- M10 ✔ (`docs/specs/M10.md`): **Tier 2 — passes e backends ensinados pela superfície**.
  Núcleo (nos dois lados): `&nome` de função/extern vira `uptr` (adrp/add com `PAGE21`+`PAGEOFF12`;
  símbolo indefinido quando `extern`) e o intrínseco `callp(p, a1..a7)` (args em `x0..x6`, `p` em
  `x16`, `blr x16`, mesmo salvamento das profundidades vivas do `bl`, resultado `i64`) —
  `tests/060-callp.mc`. O gen virou duas metades públicas: `gen_lower(root)` (AST → buffer `Ins`
  por função, seções, globais, strings e símbolos, sem encodar) e `gen_encode_all()`, mais
  ~16 acessoras (`gen_func_count/gen_ins_at/gen_prel_*`…). A ordem de criação de símbolos foi
  preservada de propósito: os 29 `.o` anteriores saem **byte a byte iguais** aos do `mc0` pré-M10.
  Hooks só no `.mc` (`src/hooks.mc` com `pass`/`backend`, `src/user.mc` → `lib/user_default.mc`);
  o driver chama `user_init()` antes do parse, aplica os passes sobre a AST e escolhe o backend por
  `--backend=NOME` (default `macho` = `gen_lower`+`gen_encode_all`+`macho_write`). O stage0 em C
  **não** é ensinável: só aceita `--backend=macho` (documentado em `docs/surface.md` § Tier 2).
  Prova: `lib/backend_arm64.mc` (backend `arm64-surface`, reimplementa o encoder inteiro em `.mc`
  sobre a API pública) e `lib/pass_demo.mc` (`x * 1` → `x`), ligados por `lib/user_demo.mc`;
  `make check-surface` liga o demo, recompila e compara — **32/32** objetos idênticos ao backend
  embutido, devolvendo `src/user.mc` ao default (a demonstração é opt-in).
  Junto entraram três correções da revisão do M9: gensym passou de `__g<N>` para `$g<N>` (o lexer
  nunca forma identificador com `$`, então a captura é impossível — `tests/056-gensym-nocapture.mc`),
  `#rule` cujo literal de despacho é palavra-chave ou tipo do núcleo é recusado
  (`nao pode redefinir palavra-chave do nucleo`), e `MAXRULES` estourado usa `err_at` com posição.
  — stage0 2843/3000 linhas (M10 custou +89 e as correções do M9 +7, num total de +96 sobre 2747);
  `make check` verde: `test` 32/32, `check-lex` 54/54, `check-ast` 54/54, `check-asm` 54/54,
  `check-obj` 32/32, `check-surface` 32/32, `bootstrap` com ponto fixo (`mc2.o == mc3.o`,
  191368 bytes) e golden regravado em `tests/golden/mc2.sha256`.
- M11 é o próximo marco. Atualize esta seção ao fechar cada marco.
