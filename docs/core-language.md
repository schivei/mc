# core-language.md — linguagem núcleo `.mc`

Referência da linguagem núcleo especificada em `docs/plan.md` e detalhada em `docs/specs/M1.md`.
Estado atual do código (`stage0/`): só `arena.c` (arena + I/O) e `macho.c` (escritor de objeto
Mach-O) existem. Não há lexer/parser/AST/codegen de `.mc` ainda — `stage0/main.c` apenas escreve
bytes de máquina à mão para M0/M0.5. Por isso todo item abaixo está marcado com o marco em que passa
a existir; nada aqui é comportamento já implementado hoje, exceto onde dito o contrário.

## Tipos

7 palavras. Os tokens entram na tabela do núcleo na inicialização do lexer (M1); declarar variáveis
desses tipos segue o marco de cada construção (locais M2, globais M3).

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

- Inteiro decimal e hex (`0x...`) — lexer, **M1**.
- Char `'a'`, escapes `\n \t \r \0 \\ \' \"` — lexer decodifica em **M1**; dobra direto para
  `N_INT` (não existe kind de AST separado para char).
- String `"..."` — lexer decodifica escapes e guarda os bytes em arena desde **M1**; emitir em
  `__TEXT,__cstring` com NUL final é do codegen, que só cobre strings a partir de **M3**.
  `\0` dentro de string é **erro** (**M5.5**): `__cstring` é `S_CSTRING_LITERALS` e o `ld` funde
  literais pelo primeiro NUL, o que faria `"a\0b"` e `"a"` virarem o mesmo endereço.

## Operadores e precedência

Tabela Pratt do núcleo (`docs/specs/M1.md`), maior prec liga mais forte. Tabela inteira e
short-circuit de `&&`/`||` (com labels) são escopo de **M1**.

| Prec | Operadores | Nota |
|---|---|---|
| 11 | `f(a, b)` (chamada) | parse em M1; codegen de chamada real (args em x0..x7) é M2 |
| 10 | `* / %` | `%` via `msub` |
| 9 | `+ -` | |
| 8 | `<< >>` | `>>` aritmético (`asr`) só se o operando esquerdo é `i64`; senão lógico (`lsr`) |
| 7 | `< <= > >=` | resultado 0/1 via `cset` |
| 6 | `== !=` | idem |
| 5 | `&` | bitwise |
| 4 | `^` | bitwise |
| 3 | `\|` | bitwise |
| 2 | `&&` | curto-circuito obrigatório |
| 1 | `\|\|` | curto-circuito obrigatório |

Unários prefixos `- ~ !` — **M1**. `&x` (endereço de local/global) — **M3**. Cast C `(u32) x`
(inequívoco: depois de `(` vem palavra-chave de tipo) — parse e codegen (`and`/`mov wd,wn` para
mascarar u8/u16/u32) já estão no escopo de **M1**. Atribuição `x = e` (só `=`, sem `+=` nativo) —
**M2**.

## Intrinsics de memória

`ld8 ld16 ld32 ld64` (leitura, zero-extend) e `st8 st16 st32 st64(p, v)` (escrita) — **M2**, junto
com arrays locais. Não existe `*p` nem `p->f`: acesso é sempre por largura explícita. Nome de array
decai para `uptr` automaticamente. `&x` — **M3**.

## Arrays

- Array local (`u8 buf[24];` dentro de função) — espaço no frame — **M2**.
- Array global (`u8 heap[HEAP_SIZE];` no top-level) — reserva em `__bss` sem inicializador ou
  `__data` com inicializador — **M3**.

## Controle

- `if (c) stmt [else stmt]` — **M2**.
- `loop { }` — **M2**. Não há `while`/`for` no núcleo; vêm do prelúdio via `#rule` (**M9**,
  `lib/prelude.mc`).
- `break;` / `break N;` (sai N níveis, sem precisar de labels) — **M2**.
- `continue;` — **M2**.
- `return [e];` — parcial em **M1** (`return expr;` dentro de `i64 main() { return 40 + 2; }` é o
  aceite do M1); uso combinado com `if`/`loop` acompanha **M2**.

## Funções

`tipo nome(tipo a, ...) { }` — máximo 8 parâmetros (nunca argumento pela pilha; exceder é erro; sem
variádicas). Função de 0 parâmetros com corpo `{ return expr; }` é o que M1 compila; múltiplos
parâmetros, múltiplas funções com chamada/recursão (`fib`) e a convenção `x0..x7` são **M2**. Duas
passadas no top-level permitem recursão mútua sem forward declaration — efetivo a partir de M2,
quando existe mais de uma função.

## `extern`

`extern tipo nome(tipo a, ...);` declara símbolo indefinido (`_nome` sem corpo — é como
`write`/`open` da libSystem entram). **M3**. O kind de AST `N_EXTERN` já está reservado no enum
desde M1, sem implementação.

## `#include` e `#define`

- `#include "arquivo.mc"` — inclusão textual, once-only. **M3**.
- `#define NOME expr` — constante dobrada em tempo de compilação (via `fold()`), não é macro
  textual. Uso na linguagem é **M3**; o dobrador de constantes em si (`fold`) já é parte de **M1**
  (usado internamente por cast/binário/unário constantes).

## Estilo obrigatório em `mc.mc`

Nunca acessar layout cru (`ld64(n + 16)`) no meio do código: sempre `#define NODE_LHS 16` +
acessoras `node_lhs(n)` / `set_node_lhs(n, v)`. Quando `struct` chegar pela superfície (M9),
trocam-se ~20 acessoras, não milhares de call sites. Disciplina que vale a partir de quando
`src/mc.mc` começa a ser escrito (**M6**).

## Programa de exemplo (do plano)

Usa recursos até M3 (array global, `heap+hp` sem `&`, `#include`, string literal, `ld64` sobre
`argv`). Comentários indicam o marco de cada trecho.

```c
#include "sys.mc"                 // include textual, once-only            (M3)

#define HEAP_SIZE 1048576         // constante dobrada em compile time     (M3)

u8  heap[HEAP_SIZE];              // array global = reserva em __bss       (M3)
i64 hp = 0;                       // global em __data                     (M3)

uptr alloc(i64 n) {
    uptr p = heap + hp;           // uptr e opaco: aritmetica em bytes     (M2/M3)
    hp = hp + ((n + 7) & ~7);
    return p;
}

i64 fib(i64 n) {                  // parametros, recursao                 (M2)
    if (n < 2) return n;          // if/else                              (M2)
    return fib(n - 1) + fib(n - 2);
}

void putnum(i64 v) {
    u8 buf[24];                   // array local = espaco no frame        (M2)
    i64 i = 24;
    loop {                        // loop/break                           (M2)
        i = i - 1;
        st8(buf + i, '0' + v % 10);   // acesso a memoria por largura explicita (M2)
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);    // write vem de sys.mc (extern)         (M3)
}

i64 main(i64 argc, uptr argv) {
    uptr first = ld64(argv);      // argv[0] sem sigilo: ld64 le 8 bytes  (M2)
    putnum(fib(24));              // imprime 46368
    write(1, "\n", 1);            // string literal vale um uptr para __cstring (M3)
    return 0;
}
```
