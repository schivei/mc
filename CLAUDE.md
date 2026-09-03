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
- `make mc1` → `build/mc1` · `make check` roda tudo · `make test-exe` roda a suíte por `--exe`.
- `scripts/link.sh OUT IN.o` liga com `ld -lSystem` (ld é permitido; gcc/cc/clang só para o stage0).
  Desde o M11 ele é opcional: `build/mc1 --exe prog.mc -o prog` escreve o executável assinado direto.
- Inspeção: `otool -hlv X.o`, `otool -r X.o`, `nm -m X.o`; do executável, `otool -l`,
  `codesign -dvvv`, `codesign --verify --verbose=4`.

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
- M11 ✔ verificado e revisado; plano concluído; ver `docs/bootstrap.md` (`docs/specs/M11.md`):
  **executável direto (`mc --exe`), sem `ld`**. O executável é um
  backend em `.mc` — `src/backend_exe.mc` (858 linhas), registrado por padrão no driver como
  `macho-exe`, com `--exe` de apelido. Ele reusa `gen_lower` + `gen_encode_all` (o mesmo encoder e
  as mesmas seções/relocs do backend `macho`) e faz o que o `ld` fazia: layout de segmentos com
  páginas de 16 KiB (`__PAGEZERO`/`__TEXT`/`__DATA`/`__LINKEDIT`, um `LC_SEGMENT_64` por segname
  distinto), resolução própria de `BRANCH26`/`PAGE21`/`PAGEOFF12`/`UNSIGNED`, `__TEXT,__stubs` +
  `__DATA,__got` por símbolo importado com **bind opcodes** (`LC_DYLD_INFO_ONLY`, sem lazy/weak/
  export), **rebase** para todo `UNSIGNED` (PIE), as 13 load commands (`LC_MAIN`, `LC_LOAD_DYLINKER`,
  `LC_LOAD_DYLIB libSystem`, `LC_UUID` derivado do SHA-256 do conteúdo, `LC_CODE_SIGNATURE`) e
  **assinatura ad-hoc** (`CS_SuperBlob`/`CS_CodeDirectory` v0x20400, SHA-256 por página de 4 KiB,
  `CS_ADHOC`, `execSeg*`, identificador = basename da saída). `src/sha256.mc` (177 linhas) é o
  SHA-256 escrito na linguagem, conferido contra `shasum -a 256` em 7 vetores. Campos verificados um
  a um contra a referência do `ld` (`-no_fixup_chains`) — ver `docs/macho-notes.md` § M11.
  `--exe` **não existe no stage0**: o C é semente e continua só com `--backend=macho`.
  Provas: `scripts/test-exe.sh` (alvo `make test-exe`, dentro de `make check`) roda toda a suíte por
  `--exe` — **32/32**, com `codesign --verify` em cada binário; `codesign -dvvv` mostra
  `flags=0x2(adhoc)`. Auto-hospedagem sem `ld`: `build/mc1 --exe src/mc.mc -o build/mc-exe`
  (210835 bytes), `build/mc-exe src/mc.mc -o x.o` idêntico a `build/mc2.o`, e
  `build/mc-exe --exe src/mc.mc -o build/fix/mc-exe` idêntico byte a byte a `build/mc-exe`
  (o ponto fixo do executável só vale com o mesmo *basename*: o identificador da assinatura é o nome
  do arquivo de saída, como no `codesign` — ver `docs/bootstrap.md` § M11).
  Junto entraram duas correções da revisão do M10, ambas só em `src/`: `MAXFUNCS` subiu de 512 para
  1024 (o C já era 1024; com os dois arquivos novos o `mc1 → mc2` teria morrido com `funcoes
  demais`) e `user_init()` passou a ser chamado **depois** de `tok_init()`/`lex_init()` (antes dele,
  um `user_init` com `tok_add` deslocava `K_U8..K_EXTERN` e quebrava o núcleo —
  `lib/user_tokadd.mc` + o novo caso em `scripts/check-surface.sh` travam isso).
  — stage0 **intocado**, 2843/3000 linhas; `make check` verde: `test` 32/32, `check-lex` 57/57,
  `check-ast` 57/57, `check-asm` 57/57, `check-obj` 32/32, `check-surface` 32/32, `test-exe` 32/32,
  `bootstrap` com ponto fixo (`mc2.o == mc3.o`, 225424 bytes) e golden regravado em
  `tests/golden/mc2.sha256` (o `diff` de `--dump-asm` entre `mc1` e `mc2` sai vazio).
- Lote pós-M11 (revisão): `reloc(UNSIGNED, "sym")` seguido de `emit()`/`#opcode` era aceito e
  registrava uma relocação de 8 bytes (`length 3`) sobre uma palavra de 4, passando por cima da
  instrução seguinte — reproduzido nos dois backends (`otool -r`: `address 00000008, length 3`).
  `gen_word` agora recusa nos dois lados com a mesma mensagem, `reloc UNSIGNED exige 8 bytes: use
  inicializador de array global` (`stage0/gen_arm64.c` +3 linhas, `src/gen_arm64.mc` +3);
  `tests/err/062-reloc-unsigned.mc` documenta o caso (fora de `scripts/test.sh`, como o `055`).
  Docs: `docs/surface.md` § `emit()`/`reloc()`; trade-off do `--exe` com símbolo indefinido
  (`.o` + `ld` recusa no link; `--exe` gera o binário e o `dyld` mata com `Symbol not found`,
  exit 134) em `docs/bootstrap.md` § M11, `docs/core-language.md` § `extern` e
  `docs/specs/M11.md` § Riscos — decisão registrada: sem lista heurística de símbolos.
  — stage0 2846/3000 linhas; `make check` verde: `test` 32/32, `check-lex` 57/57, `check-ast` 57/57,
  `check-asm` 57/57, `check-obj` 32/32, `check-surface` 32/32, `test-exe` 32/32, `bootstrap` com
  ponto fixo (`mc2.o == mc3.o`, 225640 bytes; o `diff` de `--dump-asm` entre `mc1` e `mc2` sai
  vazio) e golden regravado uma vez em `tests/golden/mc2.sha256` — o delta do codegen é só o guarda
  novo em `gen_word` (17 instruções) mais o deslocamento de +1 nos índices `l_strN` a partir de 285.
- Arena 32 MiB (era 256): `HEAP_SIZE` caiu nos dois lados (`stage0/arena.c`, `src/arena.mc`) porque
  o autocompilar toca só 14,5 MiB (`vmmap`; `/usr/bin/time -l build/mc1 src/mc.mc` dá RSS máximo de
  16744448 bytes = 15,97 MiB). Único delta de codegen: o imediato de `HEAP_SIZE` em `xalloc`
  (`movk x10, #4096, lsl #16` → `movk x10, #512, lsl #16`); `__bss` de `mc2.o` passou de
  `0x1002ed70` para `0x0202ed70` e `build/mc1` de `__DATA vmsize 0x10030000` para `0x2030000`.
  `mc2.o` continua com 225640 bytes (zerofill não ocupa arquivo) e golden regravado em
  `tests/golden/mc2.sha256` (`ddc21ac6…b829a` → `f42cda85…39c28`). Estouro é limpo: `arena
  exhausted`, exit 1 (sintético de 1000 funções × 12 statements, 14001 linhas; com 11 statements,
  13001 linhas, ainda compila). `make check` verde: `test` 32/32, `check-lex`/`check-ast`/`check-asm`
  57/57, `check-obj` 32/32, `check-surface` 32/32, `test-exe` 32/32, `bootstrap` com ponto fixo.
- M12-núcleo ✔ (seção A de `docs/specs/M12.md`): **Tier 3 — sintaxe ensinada por código**. Só no
  `.mc`; `stage0/` intocado (2846/3000). `src/core.mc` (41 linhas) é o compilador **sem**
  `user.mc`, e `src/mc.mc` virou `#include "core.mc"` + `#include "user.mc"`: um compilador
  ensinado deixou de ser uma edição de `src/user.mc` e passou a ser um arquivo próprio
  (`#include "../src/core.mc"` + módulos + `void user_init()`). `src/astdump.mc` ganhou
  `#include "hooks.mc"` porque `parse.mc` agora consulta as tabelas que moram lá.
  Registros novos em `src/hooks.mc` (+109 linhas): `syntax(palavra, &f)` (posição de topo,
  `MAXSYNTAX 32`), `syntax_stmt(palavra, &f)` (posição de statement) e
  `type_alias(nome, TY_*)` (`MAXALIAS 64`) — tabelas lineares, último registro vence, e as três
  recusam palavra-chave do núcleo (`word_add`, testado com `type_alias("if",…)` e
  `syntax_stmt("return",…)`: `nao pode redefinir palavra-chave do nucleo`).
  `src/parse.mc` (+219): `parse_top` consulta `syntax_find` antes de exigir um tipo e devolve 0
  (o handler entrega por `top_add`); `parse_stmt` consulta `syntax_stmt_find` antes do despacho de
  `#rule` e aceita o nó devolvido (0 → `N_BLOCK` vazio); `type_of_token` cai em `alias_find`, o que
  faz o alias valer de uma vez em global, local, parâmetro, `extern`, cast e `p_type`.
  API pública fixa: `p_id/p_val/p_name/p_line/p_file/p_next/p_accept/p_expect/p_ident/p_type`,
  `parse_expr(0)/parse_stmt()/parse_block()/parse_params()`, `parse_function(ty,name,params)`,
  `top_add(n)`, `def_add(name,val,line,fl)`, `param_new(ty,name)`, `list_append(head,n)`.
  `#dylib "caminho"` (`D_DYLIB 8`, no fim da lista de `lex.mc`): tabela de caminhos
  (`MAXDYLIBS 8`, ordinal = índice + 2), `cur_dylib`, `extern_lib_find(name)` (default 1);
  `#dylib ""` volta à libSystem. `src/backend_exe.mc` (+56) emite um `LC_LOAD_DYLIB` por dylib,
  põe o ordinal no `n_desc` e troca de `BIND_SET_DYLIB_ORD_IMM` por símbolo. Verificado com
  `/usr/lib/libsqlite3.dylib`: `otool -L` mostra as duas, `nm -m` mostra `(from libsqlite3)`,
  `dyld_info -fixups` mostra os três binds nas dylibs certas e o programa imprime `3051000`
  (= SQLite 3.51.0, igual ao `sqlite3 --version` do sistema). O `.o` + `ld` ignora `#dylib` (o
  `ld` recusa com `symbol(s) not found`), como já documentado para o M11.
  Provas: `lib/user_syntax_demo.mc` (64 linhas: `unless` via `syntax_stmt`, `enum Nome { … }` via
  `syntax` gerando `#define`s + alias, `type_alias("bool", TY_U8)`),
  `lib/syntax_demo_test.mc` (usa os três, sai 42) e o entry `lib/mc_syntax_demo.mc`
  (`#include "../src/core.mc"` + o demo). Caso novo em `scripts/check-surface.sh` (agora
  `check-surface.sh MC0 MC1`, e o alvo depende de `build/mc1`): `mc1 --exe lib/mc_syntax_demo.mc`,
  o binário compila o teste por `--exe`, roda e sai 42 — e o compilador padrão **recusa** o mesmo
  fonte (`tipo esperado no topo`).
  — `make check` verde: `budget` 2846/3000, `test` 32/32, `check-lex` 61/61, `check-ast` 61/61,
  `check-asm` 61/61, `check-obj` 32/32, `check-surface` 32/32 + Tier 3, `test-exe` 32/32,
  `bootstrap` com ponto fixo (`mc2.o == mc3.o`, 235960 bytes; `diff` de `--dump-asm` entre `mc1` e
  `mc2` vazio) e golden regravado uma vez em `tests/golden/mc2.sha256`
  (`f42cda85…39c28` → `905f52c1…fbbc4`). Auto-hospedagem sem `ld` mantida:
  `build/mc1 --exe src/mc.mc -o build/mc-exe` e `build/mc-exe src/mc.mc` idêntico a `build/mc2.o`.
- M12 ✔ (seção B de `docs/specs/M12.md`): **`examples/api`** — uma API HTTP de todos com
  persistência em SQLite escrita com `class`, `interface`, `bool` e `str`, quatro coisas que a
  linguagem não tem. `src/` e `stage0/` **intocados** por esta seção: a superfície inteira vem de
  `examples/api/oop.mc` (458 linhas, roda dentro do compilador pela API pública do parser) mais
  `examples/api/mc-api.mc` (20 linhas: `#include "../../src/core.mc"` + `oop.mc` + `user_init()`
  com dois `syntax` e dois `type_alias`). Programa: `main.mc` (359 linhas) com
  `class Request`/`Response`/`Todo`/`Db`, `interface Handler` e `class TodoHandler : Handler` /
  `class HealthHandler : Handler`; roteamento por tabela linear de (prefixo, `Handler`) despachada
  pela vtable (`callp`, M10) — o laço principal nunca sabe qual handler chama. As sete declarações
  `class`/`interface` viram **39** declarações comuns (`--dump-ast`), com
  `TODO_ID=0 TODO_TITLE=8 TODO_DONE=16 TODO_SIZE=24 HANDLER_HANDLE=0 TODOHANDLER_SIZE=8`
  conferidos por um programa que os imprime. Bibliotecas do outro agente: `lib/rt.mc` (arena fixa de
  4 MiB, strbuf, strings), `lib/http.mc` (sockets, requisição/resposta HTTP/1.1) e `lib/sqlite.mc`
  (`#dylib "/usr/lib/libsqlite3.dylib"` + 13 externs + wrappers). Rotas: `GET /health` →
  `{"ok":true}`, `GET /todos` → lista JSON, `POST /todos` (corpo = título) → `201` com o todo criado,
  `DELETE /todos/N` → `{"deleted":N}`, 404 para o resto; argumentos `PORTA CAMINHO_DO_BANCO`, uma
  conexão por vez.
  `examples/api/test.sh` (139 linhas) sobe o servidor numa porta livre com banco temporário, bate em
  cada rota com `curl`, compara corpo **e** status, confere o estado final com o `sqlite3` do sistema
  (`2|pagar conta|0`) e mata o servidor. `examples/api/Makefile`: `mc-api`, `api`, `test-oop`,
  `test-lib`, `test-api`, `test`, `clean` — nenhuma dependência além de `../../build/mc1` (construído
  pela raiz se faltar), `curl` e `sqlite3`. O Makefile da raiz ganhou `check-examples`
  (`make -C examples/api test`) dentro de `make check`.
  Provas: `build/api` 55616 bytes, `codesign --verify` ok e `flags=0x2(adhoc)`, `otool -L` com
  libSystem **e** libsqlite3, `nm -m` com 13 símbolos `_sqlite3_*` `(from libsqlite3)`; o compilador
  padrão recusa o mesmo fonte (`examples/api/main.mc:27: tipo esperado no parametro` — `str`).
  Detalhe operacional que custou um build: sobrescrever um executável assinado no mesmo inode faz o
  kernel matar a execução seguinte com `Killed: 9`, então o `Makefile` e o `test.sh` dão `rm -f` no
  alvo antes de cada compilação. Docs: `examples/api/README.md` (novo) e `docs/surface.md` § Tier 3
  ganhou "O exemplo real: `examples/api`".
  — `stage0/` intocado, 2846/3000; `make check` verde de ponta a ponta: `test` 32/32, `check-lex`
  61/61, `check-ast` 61/61, `check-asm` 61/61, `check-obj` 32/32, `check-surface` 32/32,
  `test-exe` 32/32, `bootstrap` com ponto fixo (`mc2.o == mc3.o`) e golden **inalterado**
  (`905f52c1…fbbc4` confere com `tests/golden/mc2.sha256`), `check-examples` verde.
- M13 é o próximo marco (`docs/specs/M13.md`: dimensionar a memória do programa em tempo de
  compilação — a arena fixa de 4 MiB de `examples/api/lib/rt.mc` é mais um caso motivador).
  Atualize esta seção ao fechar cada marco.
