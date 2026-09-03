# Plano: `mc` — mini compilador auto-hospedável e ensinável pela superfície

## Contexto

Repositório vazio (`main` sem commits). O objetivo é um compilador deliberadamente **minúsculo** no núcleo — tipos básicos, ponteiro opaco, aritmética/lógica, bitwise/shift, `loop {}` — cujo diferencial é o **ferramental de ensino pela superfície**: o próprio código-fonte registra novos lexemas/tokens, estende o parser, opera a AST e emite bytes de object file dizendo em que seção/símbolo eles vão.

Decisões fixadas com o usuário:

| Decisão | Escolha |
|---|---|
| Host do stage0 | **C23**, o menor possível, compilado por clang **uma única vez** |
| Requisito crítico | Stage1 em diante é **auto-hospedado**: nunca mais usa gcc/cc/clang |
| Alvo inicial | **AArch64 + Mach-O** (esta máquina: darwin arm64, Xcode 26 / ld-1267) |
| Extensão | **Pela superfície**, na própria linguagem; outras ISAs/saídas são ensinadas assim depois |
| Saída | Fase 1: `.o` (MH_OBJECT) + `ld` da Apple. Fase 2 (pós ponto fixo): executável direto com assinatura ad-hoc |
| Sintaxe | **"C de escola / C de Arduino"**: `tipo nome`, sem `fn`/`->`/`:`; ponteiro **único e opaco `uptr`** (sem sigilos `*`); diretivas `#...` para ensinar o compilador |
| Referências externas | Escrever tudo do zero neste repositório |

Tese organizadora: **stage0 não precisa compilar "a linguagem"; precisa compilar um programa — `src/mc.mc`.** Toda dúvida de escopo se responde com "isso aparece no fonte do próprio compilador?".

Nome: arquivos `.mc`, binário `mc`.

---

## A linguagem, por exemplo (é isto que o stage0 compila)

```c
#include "sys.mc"                 // include textual, once-only

#define HEAP_SIZE 1048576         // constante dobrada em compile time (só expressões constantes)

u8  heap[HEAP_SIZE];              // array global = reserva em __bss; o nome vale um uptr
i64 hp = 0;                       // global em __data

uptr alloc(i64 n) {
    uptr p = heap + hp;           // uptr é opaco: aritmética em bytes, sem escala
    hp = hp + ((n + 7) & ~7);
    return p;
}

i64 fib(i64 n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

void putnum(i64 v) {
    u8 buf[24];                   // array local = espaço no frame
    i64 i = 24;
    loop {
        i = i - 1;
        st8(buf + i, '0' + v % 10);   // acesso à memória por largura explícita
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);
}

i64 main(i64 argc, uptr argv) {
    uptr first = ld64(argv);      // argv[0] sem sigilo: ld64 lê 8 bytes em argv
    putnum(fib(24));              // imprime 46368
    write(1, "\n", 1);            // string literal vale um uptr para __cstring
    return 0;
}
```

### Núcleo — o que o stage0 implementa (e nada mais)

**Tipos (7 palavras):** `u8 u16 u32 u64 i64 uptr void`. `i64` é o inteiro de trabalho; `u8` para bytes; `u16/u32` porque os campos Mach-O exigem (`n_desc`, `n_strx`); `uptr` é o único ponteiro — opaco, sem tipo apontado, aritmética em bytes. Sem `i8/i16/i32`, sem float, sem bool (comparações dão `i64` 0/1). Comparações só com sinal (endereços < 2^63; documentar).

**Memória (intrinsics, não sintaxe):** `ld8 ld16 ld32 ld64` (leitura, zero-extend) e `st8 st16 st32 st64(p, v)`; `&x` dá o `uptr` de um local/global; nome de array decai para `uptr`. Sem `*p`, sem `p->f`, sem `p[i]`.

**Operadores:** `+ - * / %` · `& | ^ ~ << >>` (`>>` aritmético só em `i64`) · `== != < <= > >=` · `&& || !` **com curto-circuito** (obrigatório: `p != 0 && ld8(p) == 'x'`) · unário `-` e `&` · cast C `(u32) x` (inequívoco: após `(` vem palavra-chave de tipo) · atribuição só `=`.

**Controle:** `if (c) stmt [else stmt]`, `loop { }`, `break;` / `break 2;` (N níveis, dispensa labels), `continue;`, `return [e];`. Sem `while`/`for`/`switch`/`goto` — vêm do prelúdio.

**Declarações (C de escola):** `tipo nome(tipo a, ...) { }` (máx. 8 params → nunca passa argumento pela pilha; erro se exceder; sem variádicas); `tipo x = e;` local; `tipo x[N];` array local/global (N constante); globais no top-level com inicializador constante; `extern tipo nome(tipo a, ...);` (símbolo indefinido — é como `write`/`open` da libSystem entram; o compilador prefixa `_`). Duas passadas no top-level → recursão mútua sem forward declaration.

**Literais:** inteiro dec/hex, char `'a'` `'\n'`, string (vai para `__cstring`, NUL-terminada).

**Alocação:** arena estática `u8 heap[...]` em `__bss` + bump pointer, sem `free`. Vem zerada pelo kernel. Sem malloc, sem mmap.

**I/O:** só o que está em `lib/sys.mc`: `open read write close exit`. Impl padrão = `extern` da libSystem; impl alternativa via `#opcode svc` (número em `x16`, `svc #0x80`; `SYS_exit=1 read=3 write=4 open=5 close=6`, verificados no `sys/syscall.h` do SDK), selecionada por flag.

**Estilo obrigatório do `mc.mc`:** nunca `ld64(n + 16)` cru no meio do código; sempre `#define NODE_LHS 16` + acessoras `node_lhs(n)` / `set_node_lhs(n, v)`. Quando `struct` chegar pela superfície, trocam-se 20 acessoras, não 3.000 call sites.

Lexemas do núcleo: 7 tipos + `if else loop break continue return extern` + diretivas `#include #define #token #infix #prefix #rule #section #opcode` + pontuação `( ) { } [ ] , ;` + operadores acima. Tudo o mais é ensinado.

---

## Superfície de ensino (Tier 1 — funciona já no stage0 em C)

Diretivas `#...` no estilo pré-processador, processadas **em tempo de compilação, em ordem de aparição**, mutando as tabelas do núcleo:

```c
// 1. Lexer: novo lexema (id sequencial ≥ 256, casamento por maior prefixo)
#token "<=>"
#token "+="

// 2. Parser de expressões: tabela Pratt. $1/$2 são os operandos; a expansão é
//    parseada na hora e vira AST com buracos.
#infix  "<=>" 6 left   cmp3($1, $2)
#prefix "~~"           bitrev($1)

// 3. Parser de statements: padrão plano -> template. Cada item é um token literal
//    ou "nt $nome" (nt: expr | stmt | block | ident | type), lido como um parâmetro C.
//    O 1º item é sempre um token literal: regras são indexadas por ele (zero backtracking).
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }

#rule stmt: for ( stmt $init expr $cond ; expr $step ) block $b
    => { $init loop { if (!$cond) break; $b $step; } }

#rule stmt: ident $x += expr $e ;
    => $x = $x + $e;

// 4. Placement: tudo que vier depois vai para esta seção até o próximo #section
//    ("dizer para onde eles vão"). Default: __TEXT,__text para código, __DATA,__data
//    para globais inicializados, __DATA,__bss para arrays sem inicializador.
#section __DATA __mytable 0
u64 table[64];

#section __TEXT __text 0x80000400

// 5. Encoders: ensina uma instrução. Chamada com argumentos constantes emite a
//    palavra dobrada direto no fluxo de código da função atual.
#opcode mov16(rd, imm)   0xD2800000 | (imm << 5) | rd
#opcode svc(imm)         0xD4000001 | (imm << 5)

i64 sys_write(i64 fd, uptr buf, i64 n) {
    mov16(16, 4);            // x16 = SYS_write; x0..x2 já carregam os args na entrada
    svc(0x80);               // resultado fica em x0 e é o valor de retorno
}

// 6. Bytes e relocações crus, para o que #opcode não cobre:
//    emit(u32 constante); reloc(TIPO, "_simbolo") amarra uma relocação à próxima palavra.
void call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);
}
```

Regras que mantêm o mecanismo pequeno:
1. Padrão de `#rule` é sequência plana — sem alternação, opcional ou recursão no padrão.
2. Primeiro item é token literal → indexação por token, sem backtracking.
3. Template é parseado pelo parser existente no momento da definição (os `$nome` viram `Hole(i)`); expansão é cópia de árvore — nunca substituição textual, logo sem bugs de precedência.
4. Higiene: só gensym — `$$tmp` no template vira local fresco por expansão. Nada mais.
5. Reexpansão no resultado com teto de 64 níveis.
6. Tamanho do frame calculado **depois** da expansão (os gensyms são locais).
7. `#define` é constante dobrada, não macro textual; `#opcode` só aceita argumentos constantes (senão erro).

**Tier 2 — programático (stage1+, custo zero em C):** como o compilador é escrito em `.mc`, um pass de AST ou um backend novo é um módulo `.mc` incluído via `#include` que chama `pass(fn)` / `backend("nome", fn)` na inicialização. Recompilar `mc` com esse módulo **é** ensinar o compilador. Sem interpretador, sem dylib, sem ABI de plugin. A AST é dado plano em arena com offsets `#define`, e os primitivos de saída são funções comuns: `sec_new(seg, sect, flags)`, `sym_def(name, sec, off, global)`, `reloc_add(sec, off, sym, type, pcrel, len)`, `emit_u32(sec, w)`. Um backend na superfície é só código que os chama.

---

## Arquitetura

```
 L1  superfície (.mc)    #token #infix #prefix #rule #section #opcode  emit() reloc()
                         + módulos .mc com pass()/backend()  (stage1+)
 ───────────────────────────────────────────────────────────────────────────────────
 L0  núcleo              lexer c/ tabela de tokens mutável
     (stage0 em C,      Pratt dirigido por tabela + statements + expansor de #rule
      depois em mc.mc)   AST plana em arena → checagem mínima de tipos
                         buffer linear de instruções → encoders AArch64 → writer Mach-O
```

### Layout do repositório

```
mini_compiler/
  Makefile                    alvos: stage0, test, bootstrap, budget
  stage0/                     C23, ≤ 3000 linhas (verificado em CI); só open/read/write/close/exit da libc
    arena.c  lex.c  parse.c  ast.c  types.c  gen_arm64.c  macho.c  main.c  mc.h
  lib/
    sys.mc                    open/read/write/close/exit (extern libSystem por padrão; #opcode svc atrás de flag)
    prelude.mc                while/for/+=/++/struct via #rule (M9) — só via #include explícito, versionado
  src/                        compilador auto-hospedado (mesma divisão do stage0)
    mc.mc  lex.mc  parse.mc  ast.mc  types.mc  gen_arm64.mc  macho.mc  obj.mc
  tests/
    NNN-nome.mc               cabeçalho `// expect-exit: N` / `// expect-stdout: ...`
    golden/                   SHA-256 de mc2.o
  scripts/
    build-stage0.sh  test.sh  link.sh  bootstrap.sh  loc-budget.sh
  docs/
    core-language.md  surface.md  determinism.md  macho-notes.md
```

Orçamento do stage0 (meta ≤ 3000 linhas): lexer + tabela de tokens 350 · Pratt + tabela 250 · statements + `#rule` 400 · `#define/#section/#opcode` + folder de constantes 150 · tipos 150 · símbolos 200 · buffer de instruções + ~40 encoders 700 · Mach-O 550 · driver/arena/erros/dumps 250.

### Codegen e Mach-O

- **Sem IR.** AST → buffer linear `{opcode, operandos, label}` → encoders. Obrigatório de qualquer forma (fixups de branch), dá `--dump-asm` de graça e é a costura onde `#opcode`/`emit()` e um backend da superfície se encaixam.
- **Registradores por profundidade:** profundidade da pilha de expressão é estática (statements ≠ expressões — invariante documentado). Profundidade 0..6 → `x9..x15`; ≥7 spilla no frame. Locais e arrays locais **sempre** no frame, endereçados como `[sp, #k]` (offset positivo, resolvido após conhecer o tamanho do frame; equivale a `[x29, #-k]` mas cobre os 4095 bytes com `ldr/str` escalados — `[x29,#-k]` exigiria `ldur/stur` de 256 bytes). Antes de `bl`: spill do que está vivo, `ldr` args em `x0..x7`, resultado em `x0`. Frame alinhado a 16; `sub sp` limitado a 4095 → erro claro.
- **Prólogo/epílogo fixos:** `stp x29,x30,[sp,#-16]!; mov x29,sp; sub sp,sp,#N; str args` / inverso + `ret`. Args são gravados no frame mas `x0..x7` permanecem intactos → funções só-`#opcode` (como `sys_write`) veem os argumentos nos registradores da ABI.
- **Mach-O `.o`** (valores verificados nos headers do SDK): `MH_MAGIC_64=0xfeedfacf`, `CPU_TYPE_ARM64=0x0100000C`, subtype 0, `MH_OBJECT=1`, flags `MH_SUBSECTIONS_VIA_SYMBOLS=0x2000`. Load commands: `LC_SEGMENT_64` (segname vazio; `__TEXT,__text` flags `0x80000400`; `__TEXT,__cstring` `S_CSTRING_LITERALS`; `__DATA,__data`; `__DATA,__bss` `S_ZEROFILL`; mais o que `#section` criar), `LC_BUILD_VERSION` (**obrigatório** para o ld-prime; platform 1, minos/sdk hardcoded), `LC_SYMTAB`, `LC_DYSYMTAB` (locais → extdef → undef, partição **estável**). `n_sect` 1-based; strtab começa com `\0`, preenchida a múltiplo de 8.
- **Relocações — quatro:** `BRANCH26=2` (bl), `PAGE21=3` + `PAGEOFF12=4` (adrp/add para strings, globais, arrays), `UNSIGNED=0` len 3 (ponteiros em `__data`); `ADDEND=10` precede quando há addend. Word de bitfields LE `symbolnum:24 | pcrel:1 | length:2 | extern:1 | type:4`, emitidas em ordem decrescente de endereço.
- **Todo campo escrito byte a byte com helpers LE** (`put_u32`, `put_u64`) — nunca `fwrite(&struct)`. Translitera 1:1 para `.mc` (que não tem struct).
- **Link:** `ld -arch arm64 -platform_version macos 13.0 <sdk> -syslibroot $(xcrun --show-sdk-path) -lSystem -o out out.o` em `scripts/link.sh`. `main(argc, argv)` chega em `x0/x1`.

---

## Determinismo (`docs/determinism.md`)

1. Nunca hashear ponteiros; nunca iterar hash table para produzir saída — array paralelo em ordem de inserção.
2. Symtab por partição estável; nada de `qsort`.
3. I/O do stage0 em C com a **mesma forma** da versão `.mc` (`open`/`read` em loop/`close`), sem `stdio`.
4. Sem `__FILE__`, data, caminho absoluto, `N_OSO`/stabs, `ar`. `LC_BUILD_VERSION` hardcoded.
5. Zerar todo padding/alinhamento explicitamente.
6. Build de referência do stage0 com `-O1`; CI adicional com `-O0 -fwrapv -fno-strict-aliasing -fsanitize=undefined,address`.
7. `--dump-tokens/--dump-ast/--dump-syms/--dump-asm` com texto determinístico **desde o M1**.
8. Comparar `.o`, não executáveis linkados. Golden SHA-256 de `mc2.o` versionado.

---

## Marcos

| # | Marco | Aceite | Onde costuma falhar |
|---|---|---|---|
| **M0** | `stage0/macho.c` escreve à mão um `.o` com `movz x0,#42; ret` em `_main` | `link.sh && ./t; echo $?` → `42` | `LC_BUILD_VERSION` ausente, `n_sect` 1-based, offsets do segmento |
| **M0.5** | mesmo `.o` com `_start` + `svc #0x80` escrevendo `hi` (link `-static -e _start`) | imprime `hi` | número de syscall, ld recusando estático |
| **M1** | lexer + `#token` + Pratt + `#infix/#prefix` + `i64 main() { return 40 + 2; }` | exit 42; `--dump-tokens/--dump-ast` estáveis | alinhamento de sp, x29/x30 |
| **M2** | locais, if/else, loop/break N, chamadas, recursão, `/ %`, arrays locais, `ld*/st*` | `fib(24)` imprime `46368` via `putnum` em `.mc` | convenção de chamada, spill antes de `bl` |
| **M3** | globais, arrays globais, strings, `&x`, `#include`, `#define`, `extern`, arena | programa abre o próprio fonte e imprime a contagem de linhas | extensão de sinal, alinhamento `u16/u32` |
| **M4** | tokenizador escrito em `.mc` | histograma de tokens do próprio fonte == o do stage0 em C | — (cross-check gratuito) |
| **M5** | 4 relocações, `#section`, `#opcode`, `emit()`/`reloc()`; `sys.mc` via `svc` | `otool -r`/`nm` sãos; `sys_write` por `svc` roda | `PAGEOFF12` em `add` vs `ldr`, `r_extern` |
| **M6** | `src/mc.mc` completo **só com o núcleo** (sem `#rule`, sem prelúdio) → `mc1` | `mc1` passa a mesma suíte que o stage0 | tudo — aqui os `--dump-*` se pagam |
| **M7** | ponto fixo | `mc1 mc.mc → mc2.o`, `mc2 mc.mc → mc3.o`, `cmp` idênticos; golden gravado | ordem de tabelas, padding, leituras curtas |
| **M8** | cortar o cordão | `make bootstrap` só usa clang para o stage0; binários não versionados; `loc-budget.sh` ≤ 3000 |
| **M9** | `#rule` no stage0 **e** em `mc.mc`; `lib/prelude.mc` com `while`/`for`/`+=`/`++`/`struct` | programa com `while`/`struct` gera `.o` **idêntico** sob stage0 e `mc1`; migrar um módulo folha do `mc.mc` e reverificar M7 | ordem de expansão, gensym |
| **M10** | backend ensinado pela superfície: módulo `.mc` com `backend("asm", fn)` emitindo texto AArch64 | `__text` do backend da superfície byte a byte igual ao embutido no corpus | primitivos de emissão insuficientes (é o que este marco existe para descobrir) |
| **M11** | executável direto (`MH_EXECUTE`): `__PAGEZERO/__TEXT/__DATA/__LINKEDIT`, `LC_LOAD_DYLINKER`, `LC_LOAD_DYLIB libSystem`, `LC_MAIN`, bind de `_open/_read/_write/_close/_exit`, `LC_CODE_SIGNATURE` ad-hoc (CodeDirectory v0x20400, SHA-256 por página 4 KiB, `CS_ADHOC`) | `mc --exe` roda sem `ld`; `codesign -dvvv` válido; ponto fixo segue valendo por esse caminho | SHA-256 em `.mc` (~150 linhas), `execSegBase/Limit`, bind opcodes |

Ordem inegociável: **M6 e M7 antes de M9.** Prelúdio antes do ponto fixo acopla os dois problemas mais difíceis e impede bissecção.

---

## Verificação

- `make stage0` — clang C23 (`-std=c2x -O1 -Wall -Wextra`) gera `build/mc0`; `make stage0-san` com sanitizers.
- `make test` — `scripts/test.sh <compilador>` compila cada `tests/*.mc`, linka via `link.sh`, compara exit code/stdout com o cabeçalho; roda com `mc0`, `mc1`, `mc2`.
- `make bootstrap` — `mc0 src/mc.mc → mc1` · `mc1 src/mc.mc → mc2.o` · `mc2 src/mc.mc → mc3.o` · `cmp` · confere golden.
- `make budget` — falha se `stage0/*.c` > 3000 linhas.
- Inspeção manual nos marcos Mach-O: `otool -hlv`, `otool -r`, `nm -m`, `codesign -dvvv` (M11).
- Divergência no M7: `diff <(mc1 --dump-asm src/mc.mc) <(mc2 --dump-asm src/mc.mc)` e bissectar por função.

## Riscos que matam o projeto (e o freio de cada um)

1. `mc.mc` sem acessoras → M7 insuportável. **Acessoras desde a primeira linha.**
2. Prelúdio antes do ponto fixo. **M9 só depois do M7.**
3. Mecanismo de superfície virando um Scheme. **Teto de 3000 linhas no CI.**
4. `--dump-*` deixado para depois. **Entra no M1.**
5. Sem M10, a extensibilidade é hipótese. **M10 é parte do escopo.**
6. M11 (assinatura) atrasar tudo. **Fica atrás do ponto fixo; `ld` continua caminho válido.**
