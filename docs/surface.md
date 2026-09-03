# surface.md — superfície de ensino

Fonte: `docs/plan.md` § "Superfície de ensino" e `docs/specs/M1.md`/`M5.md`/`M5.5.md`. Estado neste
marco (**M5.5 fechado**): `#token`, `#infix`/`#prefix`, `#section`, `#opcode`, `emit()`/`reloc()`
implementados e testados de verdade com `build/mc0`. `#rule` (parser de statements) e o Tier 2
programático (`pass()`/`backend()`) continuam **planejados** — ver as seções marcadas abaixo.

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

### `#rule` — planejado (M9)
Parser de statements: casa um padrão plano (tokens literais e `nt $nome`, onde `nt` é
`expr | stmt | block | ident | type`) contra um template. O primeiro item do padrão é sempre um
token literal — regras são indexadas por ele, zero backtracking. Ainda não existe no lexer/parser
atuais (`stage0/parse.c`); sintaxe planejada:

```c
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }

#rule stmt: for ( stmt $init expr $cond ; expr $step ) block $b
    => { $init loop { if (!$cond) break; $b $step; } }

#rule stmt: ident $x += expr $e ;
    => $x = $x + $e;
```

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
   constantes, senão é erro — implementado. As regras 1-6 descrevem `#rule`, que continua
   planejado (M9).

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
