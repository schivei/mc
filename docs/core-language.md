# core-language.md — linguagem núcleo `.mc`

Referência da linguagem núcleo especificada em `docs/plan.md` e detalhada em
`docs/specs/M1.md`…`M5.5.md`. Estado do código (`stage0/`) neste marco (**M5.5 fechado**): lexer,
parser Pratt, AST, codegen ARM64 e escritor Mach-O completos para tudo abaixo — `make test` roda
24/24 testes (`tests/001-return42.mc` … `tests/043-include-norm.mc`) e todo exemplo deste documento
foi compilado e executado de verdade com `build/mc0` para confirmar o texto. Só continuam
**planejados**: `#rule`/prelúdio com `while`/`for` (**M9**), `pass()`/`backend()` programático
(**M10**) e executável direto `MH_EXECUTE` (**M11**) — ver `docs/surface.md`.

## Tipos

7 palavras, registradas na tabela do núcleo na inicialização do lexer.

| Tipo | Tamanho | Uso |
|---|---|---|
| `u8` | 1 byte | bytes, campos Mach-O pequenos |
| `u16` | 2 bytes | `n_desc` e afins |
| `u32` | 4 bytes | `n_strx` e afins, palavra de instrução |
| `u64` | 8 bytes | valores largos sem sinal |
| `i64` | 8 bytes | inteiro de trabalho — a maioria das expressões |
| `uptr` | 8 bytes | único tipo ponteiro: opaco, sem tipo apontado, aritmética em bytes |
| `void` | — | retorno sem valor |

Sem `i8/i16/i32`, sem `float`, sem `bool` — comparações produzem `i64` 0/1. Comparações são sempre
com sinal (endereços ficam abaixo de 2^63, por convenção documentada, não verificada em runtime).

## Literais

- Inteiro decimal e hex (`0x...`).
- Char `'a'`, escapes `\n \t \r \0 \\ \' \"` — dobra direto para `N_INT` (não existe kind de AST
  separado para char). `\0` é válido em char literal.
- String `"..."` — bytes decodificados em arena, emitidos em `__TEXT,__cstring` com NUL final,
  dedup por conteúdo (busca linear, primeira ocorrência ganha o símbolo `l_strN`).
  `\0` dentro de string literal é **erro**: `__cstring` é `S_CSTRING_LITERALS` e o `ld` funde
  literais pelo primeiro NUL, o que faria `"a\0b"` e `"a"` virarem o mesmo endereço. Testado:
  ```
  $ build/mc0 t.mc      # write(1, "a\0b", 3);
  t.mc:2: \0 nao permitido em string
  ```

## Operadores e precedência

Tabela Pratt do núcleo, maior prec liga mais forte.

| Prec | Operadores | Nota |
|---|---|---|
| 11 | `f(a, b)` (chamada) | args em `x0..x7` |
| 10 | `* / %` | ver "Divisão e módulo" abaixo |
| 9 | `+ -` | |
| 8 | `<< >>` | `>>` aritmético (`asr`) só se o operando esquerdo é `i64`; senão lógico (`lsr`) |
| 7 | `< <= > >=` | resultado 0/1 via `cset` |
| 6 | `== !=` | idem |
| 5 | `&` | bitwise |
| 4 | `^` | bitwise |
| 3 | `\|` | bitwise |
| 2 | `&&` | curto-circuito obrigatório |
| 1 | `\|\|` | curto-circuito obrigatório |

Unários prefixos `- ~ !`. `&x` (endereço de local/global) — prefixo, mesma precedência de unário.
Cast C `(u32) x` (inequívoco: depois de `(` vem palavra-chave de tipo) — `and`/`mov wd,wn` para
mascarar u8/u16/u32. Atribuição `x = e` (só `=`, sem `+=` nativo).

### Divisão e módulo sem sinal

`/` e `%` usam `sdiv`/`msub` (com sinal) só quando o tipo do operando **esquerdo** é `i64`; para
`u8/u16/u32/u64/uptr` à esquerda usam `udiv`/`msub` sem sinal — mesma regra de decisão de `>>`.
`fold()` (dobra de constantes) espelha o mesmo critério. Testado (`tests/041-udiv.mc`):

```c
u64 big = 0xFFFFFFFFFFFFFFFF;
if (big / 2 != 0x7FFFFFFFFFFFFFFF) return 1;                       // udiv, em runtime
if ((u64) 0xFFFFFFFFFFFFFFFF / 2 != 0x7FFFFFFFFFFFFFFF) return 2;  // udiv, dobrado em compile time
i64 neg = 0 - 8;
if (neg / 2 != 0 - 4) return 5;                                    // i64 continua com sinal (sdiv)
```

## Intrinsics de memória

`ld8 ld16 ld32 ld64` (leitura, zero-extend) e `st8 st16 st32 st64(p, v)` (escrita). Não existe `*p`
nem `p->f`: acesso é sempre por largura explícita. Nome de array decai para `uptr` automaticamente.

## Arrays

- Array local (`u8 buf[24];` dentro de função) — espaço no frame.
- Array global (`u8 heap[HEAP_SIZE];` no top-level) — reserva em `__bss` sem inicializador ou
  `__data` com inicializador.
- **Inicializador de array global**: `tipo v[N] = { e1, e2, ... };` ou `tipo v[] = { ... }` (N
  inferido da lista). Elementos são constantes dobradas, escritas com a largura do tipo; `N` maior
  que a contagem preenche o resto com zero, contagem maior que `N` é erro. Vai para `__data`
  (alinhado a 16). Para `uptr`, um elemento string literal grava 8 bytes zero mais uma relocação
  `R_UNSIGNED` apontando para o símbolo `l_strN` daquela string (ver `docs/macho-notes.md`).
  Testado (`tests/040-arrinit.mc`):
  ```c
  uptr names[] = {"zero", "um", "dois"};   // N inferido: 3 ponteiros em __data
  u32  t[4] = {1, 2, 3};                   // N > count: o 4o elemento sai zerado
  i64  soma[2] = {20 + 22, 7 * 6};         // dobra de constante no elemento
  // ld64(names + 8) -> ponteiro para "um"; ld32(t+12) == 0; ld64(soma) == 42
  ```

## Limite de frame e de array local

Array local: `nelem * largura` não pode passar de 4095 bytes (checado no parser e de novo no
codegen) — erro `array local grande demais`. Frame inteiro da função (todos os locais + área de
spill, arredondado a 16) também não pode passar de 4095 bytes (`sub sp, sp, #imm` só cabe em 12
bits) — erro `frame grande demais`. Testado:
```
u8 big[4080];   // ok, frame cabe
u8 big[4096];   // array local grande demais (nelem*largura > 4095)
u8 big[4090];   // frame grande demais (arredondado a 16 estoura o subimediato)
```

## Controle

- `if (c) stmt [else stmt]`.
- `loop { }`. Não há `while`/`for` no núcleo; vêm do prelúdio via `#rule` (**M9, implementado** —
  `lib/prelude.mc`, § Prelúdio abaixo).
- `break;` / `break N;` (sai N níveis, sem precisar de labels; N maior que a profundidade de loops
  é erro).
- `continue;`.
- `return [e];`.

## Funções

`tipo nome(tipo a, ...) { }` — máximo 8 parâmetros (nunca argumento pela pilha; exceder é erro; sem
variádicas). Duas passadas no top-level permitem chamar uma função antes de defini-la e recursão
mútua sem forward declaration.

### Protótipo

`tipo nome(params);` no top-level (sem corpo, sem `extern`) registra a assinatura antes da
definição; a definição posterior precisa bater tipo de retorno e aridade; protótipo sem definição
nem `extern` no fim da unidade é erro. Testado (`tests/042-proto.mc`):
```c
i64  soma(i64 a, i64 b);        // usado antes de definido
i64  dobro(i64 x);              // definido depois de quem o chama
i64 main() { mostra(soma(dobro(20), 2)); return 0; }  // stdout "42\n", exit 0
i64 soma(i64 a, i64 b) { return a + b; }
i64 dobro(i64 x) { return x + x; }
```

## `extern`

`extern tipo nome(tipo a, ...);` declara símbolo indefinido (`_nome` sem corpo — é como
`write`/`open` da libSystem entram, ver `lib/sys.mc`).

## `#include` e `#define`

- `#include "arquivo.mc"`: inclusão textual, once-only, relativa ao diretório do arquivo que
  inclui. `path_join` normaliza `.` e `..` lexicamente (sem tocar o filesystem) antes do
  once-only, então dois caminhos que apontam para o mesmo arquivo por rotas textuais diferentes
  (`inc/c.mc` e `inc/a/../c.mc`) contam como uma inclusão só. Profundidade máx. 16. Testado
  (`tests/043-include-norm.mc`): `#include "inc/c.mc"` e `#include "./inc/a/b.mc"` (que por sua vez
  inclui `../c.mc`) resolvem para o mesmo arquivo — `comum()` não é declarada duas vezes.
- `#define NOME expr`: expr parseada e dobrada na definição (via `fold()`), constante — não é
  macro textual. Redefinir = erro. Uso precisa vir depois da definição (ordem do fonte).
- **`#define` vs nome**: declarar local, parâmetro, global ou função com um nome já usado por
  `#define` é erro `nome ja definido por #define`, seja qual for a ordem entre os dois. Testado:
  ```
  #define LIMIT 10
  i64 LIMIT = 5;      // t.mc:2: nome ja definido por #define
  i64 f(i64 N)         // idem para parametro, se N ja for #define
  ```

## Prelúdio (`lib/prelude.mc`) — `while`, `for`, `+=`, `-=`, `++`, `--`

Nada disso é sintaxe do núcleo: são seis `#rule stmt:` e quatro `#token` escritos na própria
linguagem, num arquivo que só entra por `#include` explícito (§ `docs/surface.md` § `#rule`). O
núcleo continua compilando sem ele — `src/lex.mc`, `src/parse.mc` e `src/gen_arm64.mc` não o
incluem; `src/macho.mc` inclui, e é o módulo folha migrado no M9.

```c
#include "../lib/prelude.mc"

i64 soma(i64 n) {
    i64 s = 0;
    for (i64 i = 0; i < n; i = i + 1) {   // passo e `ident $x = expr $step`
        s += i;
    }
    i64 k = n;
    while (k > 0) {                        // corpo e sempre um bloco: { }
        k--;
    }
    return s;
}
```

O que o prelúdio dá e o que ele **não** dá:

| Escrito | Vira |
|---|---|
| `while (c) { B }` | `loop { if (!c) break; { B } }` |
| `for (INIT COND ; x = PASSO) { B }` | `{ INIT loop { if (!COND) break; { B } x = PASSO; } }` |
| `x += e;` · `x -= e;` | `x = x + e;` · `x = x - e;` |
| `x++;` · `x--;` | `x = x + 1;` · `x = x - 1;` |

- **O corpo é sempre um bloco.** O padrão diz `block $b`, então `while (c) x++;` sem chaves é erro.
- **O passo do `for` é `ident $x = expr $step`, não uma expressão qualquer.** No núcleo a
  atribuição é um *statement*, não um operador (`=` não está na tabela Pratt), então um `expr`
  sozinho no lugar do passo só poderia ser uma chamada de função — inútil para um contador. Por
  isso o passo se escreve `i = i + 1` (e não `i++`, que é um statement inteiro, com `;`).
- **`for (; c; i = i + 1)` não existe**: o padrão exige um `stmt $init` e o núcleo não tem
  statement vazio. Onde o C usa `for` sem inicializador, o `.mc` usa `while`.
- **`while` e `for` viram palavras reservadas** a partir do `#include`: o primeiro item literal de
  uma regra é registrado como lexema (`tok_add`), então `i64 while = 1;` passa a ser erro
  (`nome de variavel esperado`) — ver `tests/err/055-keyword.mc`.

### `continue` dentro de `for` pula o passo

O passo fica **no fim do corpo** do `loop` gerado, e `continue` volta para o topo do `loop` — logo
`continue` pula o passo, exatamente como pularia num `loop{}` escrito à mão. Não é um bug do
prelúdio: é a consequência direta de o núcleo não ter cláusula de passo, e o `#rule` não inventar
uma. Quem sai por `continue` precisa avançar o contador antes:

```c
for (k = 0; k < 10; k = k + 1) {
    if (k % 2) { k = k + 1; continue; }   // sem esta linha o laco nao anda
    t = t + k;
}
```

`tests/051-for.mc` cobre os dois casos (o `for` normal e o `continue` que anda na mão). `break`
dentro de `while`/`for` é o `break` do núcleo e sai do `loop` gerado, como se espera.

## Estilo obrigatório em `mc.mc`

Nunca acessar layout cru (`ld64(n + 16)`) no meio do código: sempre `#define NODE_LHS 16` +
acessoras `node_lhs(n)` / `set_node_lhs(n, v)`. Quando `struct` chegar pela superfície, trocam-se
~20 acessoras, não milhares de call sites. Todo `src/*.mc` segue essa disciplina desde M6
(`docs/specs/M6-M7.md`); o M9 **não** trouxe `struct` — a spec (`docs/specs/M9.md`) tirou-o de
escopo depois que o M6 mostrou que `#define` + acessora resolve, e `struct` de verdade exigiria o
buraco `type $t` e um modelo de layout, que é mais do que `#rule` entrega.

## Programa de exemplo

Compilado e executado de verdade (`build/mc0 exemplo.mc -o out.o && scripts/link.sh out out.o &&
./out` imprime `46368`, exit 0). `write` é declarado direto por `extern` aqui em vez de
`#include "sys.mc"` porque `sys.mc` já traz `putnum` de `lib/io.mc` — o exemplo define o seu
próprio para mostrar array local + `st8`/`ld8`; um programa real normalmente prefere incluir
`sys.mc`/`sys_svc.mc` e usar o `putnum` de lá (ver `docs/surface.md`).

```c
extern i64 write(i64 fd, uptr buf, i64 n);   // extern: so a assinatura, sem #include

#define HEAP_SIZE 1048576         // constante dobrada em compile time

u8  heap[HEAP_SIZE];              // array global = reserva em __bss
i64 hp = 0;                       // global em __data

uptr alloc(i64 n) {
    uptr p = heap + hp;           // uptr e opaco: aritmetica em bytes
    hp = hp + ((n + 7) & ~7);
    return p;
}

i64 fib(i64 n) {                  // parametros, recursao
    if (n < 2) return n;          // if/else
    return fib(n - 1) + fib(n - 2);
}

void putnum(i64 v) {
    u8 buf[24];                   // array local = espaco no frame
    i64 i = 24;
    loop {                        // loop/break
        i = i - 1;
        st8(buf + i, '0' + v % 10);   // acesso a memoria por largura explicita
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);    // write vem de extern
}

i64 main(i64 argc, uptr argv) {
    uptr first = ld64(argv);      // argv[0] sem sigilo: ld64 le 8 bytes
    putnum(fib(24));              // imprime 46368
    write(1, "\n", 1);            // string literal vale um uptr para __cstring
    return 0;
}
```

## Armadilhas de transliteração

Transliterar `stage0/*.c` função a função para `src/*.mc` (M6, `docs/specs/M6-M7.md`) esbarra em
recursos do C que o núcleo do `.mc` não tem. Cada item abaixo é um caso real encontrado no
`stage0`, com o contorno que ficou no `.mc`:

- **`struct`** — não existe. Vira `#define CAMPO off` + acessoras `campo(p)`/`set_campo(p, v)` (ver
  "Estilo obrigatório em mc.mc" acima) — regra desde a primeira linha de `arena.mc`.
- **`?:`** — não existe. Vira `if` explícito atribuindo a mesma variável nos dois ramos:
  `size_t cap = b->cap ? b->cap : 64;` (`stage0/arena.c`) virou
  `i64 cap = buf_cap(b); if (cap == 0) cap = 64;` (`src/arena.mc`).
- **`for`** — não existe, só `loop { }` + `break N`/`continue`. `for (init; cond; step) corpo` vira
  `init; loop { if (!cond) break; corpo; step; }`, com o "passo" escrito à mão no fim do corpo.
- **`static`** (linkage interna + forward declaration) — `.mc` não tem unidades de tradução: tudo
  entra por `#include` num só arquivo, então `static` não tem o que fazer e é descartado. A parte
  que importa — declarar a assinatura antes da definição, para recursão mútua (`parse_expr`/
  `parse_unary` em `stage0/parse.c`, `gen_stmt`/`gen_expr` em `stage0/gen_arm64.c`) — usa o
  protótipo nativo do `.mc` (testado em `tests/042-proto.mc`, M5.5), não o idioma do C.
- **comparação sem sinal** — `.mc` só tem comparação com sinal (ver § Tipos acima). O C usa
  `size_t`/`u64` sem sinal para offset e capacidade o tempo todo; o contorno é a convenção
  "endereços e tamanhos ficam sempre abaixo de 2^63" (documentada, não verificada em runtime), que
  torna `<`/`<=`/etc. assinados equivalentes aos sem sinal do C para todo valor que aparece de
  verdade em `arena.mc`/`gen_arm64.mc`/`macho.mc`.
- **`++`/`--`** — não existem **no núcleo**. Sem o prelúdio, `i++` vira `i = i + 1` e `i--` vira
  `i = i - 1` — mecânico, mas espalhado por todo loop transliterado. Com
  `#include "../lib/prelude.mc"` (M9) `i++`/`i--`/`i += e`/`i -= e` passam a existir como quatro
  `#rule`, e é isso que `src/macho.mc` usa hoje.
- **literais de string adjacentes** — o C concatena `"a" "b"` em compile time; `.mc` não tem essa
  regra. `out_str(2, "uso: mc0 ... " "entrada.mc [-o saida.o]\n");` (`stage0/main.c`) virou um
  único literal em `src/main.mc`.
- **`&arr[i]` (endereço de elemento indexado)** — `&` só aceita um nome direto (`&nome`), não uma
  expressão indexada — `.mc` não tem `p[i]` nem `p->f` (§ Operadores acima). `Node *p =
  &nodes[nnodes]; p->kind = k;` (`stage0/ast.c`, `node_new`) virou passar o **índice** adiante e
  deixar as acessoras calcularem `base + índice*tamanho`: `set_nd_kind(nnodes, kind);`
  (`src/ast.mc`) — nunca se materializa "o endereço do elemento", só o índice.
- **`continue` dentro de `loop{}` sem passo separado** (vale igual para o `for` do prelúdio, § acima) — num `for` do C, `continue` roda o `step` e
  reavalia a condição; `loop{}` não tem cláusula de passo, então um `continue` ingênuo pula
  justamente o avanço que fecharia o laço (`e = nodes[e].next`, `i++`), podendo travar em loop
  infinito. O contorno usado: eliminar o `continue` reescrevendo o `if (cond) { ...; continue; }`
  seguido de mais código como `if (cond) { ... } else { ... }`, com o avanço (`e = nd_next(e);`)
  incondicional no fim do corpo. Exemplo real: o `for` com `continue` de `stage0/gen_arm64.c` (globais
  com ponteiro para string) virou o `if`/`else` com `e = nd_next(e)` ao final em `src/gen_arm64.mc`.
- **`open` variádica → `creat`** — `open(path, flags, ...)` da libSystem é variádica (`...` para o
  `mode`), e no ABI arm64 da Apple os argumentos variádicos viajam pela pilha — que o `.mc` não sabe
  montar (só `x0..x7`). O contorno é usar `creat(path, mode)` para criar arquivo (sem variádico;
  `open` sem `O_CREAT` continua servindo para leitura, com `mode` sempre 0) — ver o comentário em
  `stage0/arena.c` e `src/arena.mc`.
