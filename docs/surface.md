# surface.md — superfície de ensino

Fonte: `docs/plan.md` § "Superfície de ensino" e `docs/specs/M1.md`/`M5.md`/`M5.5.md`/`M9.md`.
Estado neste marco (**M9 fechado**): `#token`, `#infix`/`#prefix`, `#rule`, `#section`, `#opcode`,
`emit()`/`reloc()` implementados e testados de verdade com `build/mc0` **e** com o compilador
auto-hospedado `build/mc1` (o mecanismo existe nos dois lados: `stage0/parse.c` e `src/parse.mc`).
Só o Tier 2 programático (`pass()`/`backend()`) continua **planejado** — ver a seção marcada no fim.

## Tier 1 — diretivas `#...`

Processadas em tempo de compilação, em ordem de aparição, mutando as tabelas do núcleo.

### `#token` — implementado
Registra um novo lexema. Casamento de pontuação/operador é por maior prefixo, varrendo a tabela
linearmente (determinístico, regra 1 de `docs/determinism.md`).

```c
#token "<+>"
```

### `#infix` / `#prefix` — implementado
Estendem a tabela Pratt de expressões. `$1`/`$2` são os operandos; o template é parseado na hora
pelo parser já existente e vira AST com "buracos" (`N_HOLE`) — nunca substituição textual. Testado
(`tests/003-infix.mc`, roda e retorna 42):

```c
#token "<+>"
#infix "<+>" 9 left ($1 + $2) * 2
i64 main() { return 10 <+> 11; }   // (10 + 11) * 2 = 42
```

### `#rule` — implementado (M9)
Parser de statements: casa um padrão plano contra um template. O padrão é uma sequência de itens,
cada item ou um **token literal** (qualquer lexema, inclusive os criados por `#token`) ou
`nt $nome`, com `nt ∈ { expr, stmt, block, ident }`. O template é **um statement**, parseado pelo
parser normal no momento da definição — os `$nome` viram buracos ali, então a expansão é cópia de
árvore (`node_copy_subst`), nunca substituição textual.

```c
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }
```

**Despacho por token, sem backtracking.** A tabela de regras é linear e indexada pelo token que
abre o statement; a última regra definida para o mesmo token vence. Escolhida a regra, cada item
tem de casar — não há volta atrás. Se o item literal for um identificador (`while`, `for`,
`repeat`), ele é registrado no lexer (`tok_add`, entrada *word*) e **vira palavra reservada** dali
em diante: `i64 while = 1;` depois do `#include` é erro (`tests/err/055-keyword.mc`).

**`ident $x` antes do token de despacho.** É a única forma em que o primeiro item do padrão não é
um literal, e serve aos compostos:

```c
#rule stmt: ident $x += expr $e ;   => $x = $x + $e;
#rule stmt: ident $x ++ ;           => $x = $x + 1;
```

O zero-backtracking continua valendo: quando `+=` aparece, o nome à esquerda **já foi lido** como
expressão pelo caminho normal de `parse_stmt`, e o despacho acontece no token literal (`+=`, `++`).
Depois do `ident $x` de abertura, o próximo item tem de ser um literal.

**Dois tipos de buraco.** `expr`/`stmt`/`block` viram `N_HOLE` e viajam pela cópia de árvore.
`ident $x` e o gensym `$$t` viram **nomes**: no template são um `N_IDENT` com um marcador único, e
a expansão troca o marcador pelo nome real. É o que permite `$x` aparecer onde a AST guarda um
nome e não um nó — esquerda de atribuição (`$x = ...`) e declaração de local (`i64 $$t = ...`).

**Higiene: só gensym.** `$$nome` no template vira um local novo por expansão, `__g1`, `__g2`, ...
(contador global, determinístico). Duas expansões da mesma regra no mesmo bloco não colidem —
`tests/053-gensym.mc`:

```c
#rule stmt: swap ( ident $a , ident $b ) ;
    => { i64 $$t = $a; $a = $b; $b = $$t; }
```

**Regra que usa regra.** O template é parseado com o parser que já conhece as regras anteriores,
então `#rule` sobre `while` funciona naturalmente e a expansão acontece **na definição**
(`tests/054-rule-in-rule.mc`). Não há reexpansão textual do resultado: recursão infinita é
impossível por construção. O aninhamento na definição tem teto de 64 níveis.

**Fora do escopo do M9** (decisão registrada em `docs/specs/M9.md`): a categoria `#rule expr:`
(reservada — usá-la é erro claro) e o buraco `type $t` (usar `type` no padrão é erro
`nt \`type\` fora do escopo do M9`). `type $t` só serviria para declarações genéricas
(`type $t ident $x = expr $e;`) e exigiria um `N_TYPE` novo mais o buraco de tipo em `parse_var` e
no codegen — mais do que os "20 linhas" que a spec autorizava. Sem `type $t` não há `struct`, que
por isso também ficou fora do M9.

### `--dump-rules` — implementado (M9)
Lista as regras registradas por um fonte, na ordem de definição: token de abertura, itens e
tamanho do template em nós. Saída real de `build/mc0 --dump-rules tests/053-gensym.mc` (as seis
primeiras vêm de `lib/prelude.mc`, a última do próprio teste):

```
regra 0: stmt: while ( expr $1 ) block $2 => 7 nos
regra 1: stmt: for ( stmt $1 expr $2 ; ident $0 = expr $3 ) block $4 => 11 nos
regra 2: stmt: ident $0 += expr $1 ; => 4 nos
regra 3: stmt: ident $0 -= expr $1 ; => 4 nos
regra 4: stmt: ident $0 ++ ; => 4 nos
regra 5: stmt: ident $0 -- ; => 4 nos
regra 6: stmt: swap ( ident $0 , ident $1 ) ; => 7 nos
```

`ident $N` no dump é o N-ésimo buraco de **nome**; `expr/stmt/block $N` é o N-ésimo buraco de
**nó**. As regras 2–5 são as de `ident $x` na abertura: o `ident $0` mostrado antes do literal é o
nome já lido. `build/mc1 --dump-rules` dá byte a byte a mesma saída.

### `--dump-ast` mostra a AST expandida
A expansão acontece no parser, então `--dump-ast` já é pós-`#rule`. `while (i < 3) { s += i; i++; }`
com o prelúdio (saída real de `build/mc0 --dump-ast`, recortada):

```
    LOOP
      BLOCK
        IF
          UNARY op=!
            BINARY op=<
              IDENT type=i64 name=i
              INT val=3 type=i64
          BREAK val=1
        BLOCK
          ASSIGN name=s
            BINARY op=+
              IDENT type=i64 name=s
              IDENT type=i64 name=i
          ASSIGN name=i
            BINARY op=+
              IDENT type=i64 name=i
              INT val=1 type=i64
```

É esse `!` que faz o `while` do prelúdio custar duas instruções a mais por teste de laço do que o
`loop { if (i >= 3) break; ... }` escrito à mão: o núcleo não simplifica `!(a < b)` para `a >= b`
(não há peephole de AST no M9), e a regra do prelúdio é literalmente
`loop { if (!$c) break; $b }`. Ver `docs/core-language.md` § Prelúdio.

### `lib/prelude.mc` — a biblioteca de superfície
`while`, `for`, `+=`, `-=`, `++`, `--`: seis `#rule` e quatro `#token`, 36 linhas, entrando só por
`#include` explícito. `src/macho.mc` é o primeiro módulo do próprio compilador a usá-la (M9);
`docs/core-language.md` § Prelúdio documenta a sintaxe, o `continue` que pula o passo do `for` e
por que o passo é `ident $x = expr $step`.

### `#section` — implementado
Placement: define a seção de destino dos bytes emitidos depois (funções e globais), até o próximo
`#section`. `#section` sem argumentos volta ao default (`__TEXT,__text` para código,
`__DATA,__data`/`__DATA,__bss` para globais). `ALIGN` é log2 e vale 3 (8 bytes) quando omitido.
Testado (`tests/030-section.mc`, roda e retorna 42; `otool -l` confirma as seções):

```c
#section __DATA __tbl 0 3
u64 tbl[4];                       // __DATA,__tbl, S_REGULAR — ocupa bytes reais no arquivo

#section __DATA __zt 1 4          // flags=1 = S_ZEROFILL: so conta zsize, sem espaco em arquivo
u64 zt[2];

#section __TEXT __hot 0x80000400 2
i64 hot(i64 x) { return x + 2; }  // funcao vai para __TEXT,__hot

#section                          // sem argumentos: volta ao default
i64 base = 30;                    // __DATA,__data
```

### `#opcode` — implementado
Ensina uma instrução. Chamada com argumentos constantes (senão erro "argumento de #opcode nao
constante") dobra o template com os parâmetros substituídos e emite a palavra de 32 bits direto no
fluxo de código da função atual (`I_RAW`, `.word` no `--dump-asm`) — não é um símbolo. É assim que
`lib/sys_svc.mc` implementa as cinco syscalls do núcleo (`open/read/write/close/exit`) sem depender
da libSystem, testado de ponta a ponta em `tests/032-svc.mc` (`write(1, "hi\n", 3)` via `svc`,
stdout `hi`, exit 0):

```c
// lib/sys_svc.mc
#opcode mov16(rd, imm) 0xD2800000 | (imm << 5) | rd
#opcode svc(imm)       0xD4000001 | (imm << 5)

#define SYS_WRITE 4

i64 write(i64 fd, uptr buf, i64 n) {
    mov16(16, SYS_WRITE);   // x16 = numero da syscall; x0..x2 ja tem fd/buf/n
    svc(0x80);              // entra no kernel; resultado fica em x0 = valor de retorno
}
```

`--dump-asm` do corpo de `write` acima (rodado de verdade):
```
_write:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #32
  str x0, [sp, #24]
  str x1, [sp, #16]
  str x2, [sp, #8]
  .word 0xd2800090
  .word 0xd4001001
L1:
  add sp, sp, #32
  ldp x29, x30, [sp], #16
  ret
```
O epílogo não toca `x0`: como a função não tem `return`, o valor de retorno é o `x0` que a `svc`
deixou — a mesma promessa vale para o prólogo (grava os parâmetros no frame sem alterar `x0..x7`).

### `emit()` / `reloc()` — implementado
Bytes e relocações crus, para o que `#opcode` não cobre. `emit(CONST)` grava a palavra de 32 bits
(mesmo `I_RAW` de `#opcode`); `reloc(TIPO, "simbolo")` registra uma relocação para a **próxima**
palavra emitida na função. `TIPO` ∈ `BRANCH26 PAGE21 PAGEOFF12 UNSIGNED`, constantes pré-definidas
internamente na tabela de `#define` (mesmos valores de `docs/macho-notes.md`: `BRANCH26=2 PAGE21=3
PAGEOFF12=4 UNSIGNED=0`). Símbolo desconhecido vira indefinido externo. Testado
(`tests/033-reloc.mc`, roda e retorna 42; `otool -r` mostra a relocação `R_BRANCH26` gerada por
`reloc()` ao lado da que o `bl` do compilador gera para a chamada em `main`):

```c
i64 helper() {
    return 42;
}

i64 call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);          // bl cru (offset preenchido pela relocacao acima)
}

i64 main() {
    return call_helper();      // 42
}
```

## As 7 regras que mantêm o mecanismo pequeno

1. Padrão de `#rule` é sequência plana — sem alternação, opcional ou recursão no padrão.
2. Primeiro item é token literal → indexação por token, sem backtracking.
3. Template é parseado pelo parser existente no momento da definição (`$nome` vira `Hole(i)`);
   expansão é cópia de árvore — nunca substituição textual, logo sem bugs de precedência.
4. Higiene: só gensym — `$$tmp` no template vira local fresco a cada expansão. Nada mais.
5. Reexpansão no resultado com teto de 64 níveis.
6. Tamanho do frame é calculado depois da expansão (os gensyms são locais).
7. `#define` é constante dobrada, não macro textual — implementado. `#opcode` só aceita argumentos
   constantes, senão é erro — implementado.

Estado das sete depois do M9: **1, 2, 3, 4, 6 e 7 estão implementadas e testadas**. A regra 5
("reexpansão no resultado com teto de 64 níveis") foi cumprida de forma mais forte do que o texto:
**não há reexpansão do resultado**. O template é parseado — e portanto já expandido — na definição,
então uma regra que usa outra regra fica resolvida ali; o teto de 64 níveis vale para o
aninhamento *na definição*. Isso torna a recursão infinita impossível por construção, em vez de
apenas limitada.

A regra 2 ganhou uma exceção declarada: o padrão pode começar por um único `ident $nome` antes do
token literal de despacho (é o que `+=`/`++` exigem, e é a forma que o próprio `docs/plan.md`
usa nos exemplos). O despacho continua sendo por token literal e continua sem backtracking — o
nome já foi lido como expressão quando o token aparece.

## Tier 2 — programático (stage1+, custo zero em C) — planejado

A partir de M6 o compilador é escrito em `.mc`; um pass de AST ou um backend novo passa a ser só um
módulo `.mc` incluído via `#include` que chama `pass(fn)` / `backend("nome", fn)` na inicialização.
Recompilar `mc` com esse módulo **é** ensinar o compilador — sem interpretador, sem dylib, sem ABI
de plugin.

A AST é dado plano em arena com offsets `#define`; os primitivos de saída são funções comuns:
`sec_new(seg, sect, flags)`, `sym_def(name, sec, off, global)`, `reloc_add(sec, off, sym, type,
pcrel, len)`, `emit_u32(sec, w)`. Um backend na superfície é só código `.mc` que os chama.

Estado hoje: os primitivos já existem em C e são usados internamente pelo próprio stage0 desde M0 —
`sec_new`, `sym_new`, `reloc_add` em `stage0/macho.c` (`sym_def`/`emit_u32` do plano correspondem a
`sym_new`/`buf_u32` na implementação atual), e desde M5 também por `#section`/`#opcode`/`emit`/
`reloc` do lado da superfície (mesmas funções, chamadas pelo parser em vez de só internamente). A
versão `.mc` desses primitivos e `pass()`/`backend()` como conceito da superfície continuam
planejados para stage1+ (M6 em diante); `backend("asm", fn)` concreto, comparado byte a byte com o
`__text` embutido, é o critério de aceite do **M10**.
