# surface.md — superfície de ensino

Fonte: `docs/plan.md` § "Superfície de ensino". Ainda não implementado no código (stage0 hoje só tem
`arena.c`/`macho.c`; lexer/parser chegam em M1). Cada diretiva abaixo indica o marco em que passa a
funcionar de verdade.

## Tier 1 — diretivas `#...`

Processadas em tempo de compilação, em ordem de aparição, mutando as tabelas do núcleo.

### `#token` — M1
Registra um novo lexema. Casamento de pontuação/operador é por maior prefixo, varrendo a tabela
linearmente (determinístico, regra 1 de `docs/determinism.md`).

```c
#token "<=>"
#token "+="
```

### `#infix` / `#prefix` — M1
Estendem a tabela Pratt de expressões. `$1`/`$2` são os operandos; o template é parseado na hora
pelo parser já existente e vira AST com "buracos" (`N_HOLE`) — nunca substituição textual.

```c
#infix  "<=>" 6 left   cmp3($1, $2)
#prefix "~~"           bitrev($1)
```

### `#rule` — M9
Parser de statements: casa um padrão plano (tokens literais e `nt $nome`, onde `nt` é
`expr | stmt | block | ident | type`) contra um template. O primeiro item do padrão é sempre um
token literal — regras são indexadas por ele, zero backtracking.

```c
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }

#rule stmt: for ( stmt $init expr $cond ; expr $step ) block $b
    => { $init loop { if (!$cond) break; $b $step; } }

#rule stmt: ident $x += expr $e ;
    => $x = $x + $e;
```

### `#section` — M5
Placement: define a seção de destino dos bytes emitidos depois, até o próximo `#section`. Default:
`__TEXT,__text` para código, `__DATA,__data` para globais inicializados, `__DATA,__bss` para arrays
sem inicializador.

```c
#section __DATA __mytable 0
u64 table[64];

#section __TEXT __text 0x80000400
```

### `#opcode` — M5
Ensina uma instrução. Chamada com argumentos constantes emite a palavra de 32 bits direto no fluxo
de código da função atual.

```c
#opcode mov16(rd, imm)   0xD2800000 | (imm << 5) | rd
#opcode svc(imm)         0xD4000001 | (imm << 5)

i64 sys_write(i64 fd, uptr buf, i64 n) {
    mov16(16, 4);             // x16 = SYS_write; x0..x2 ja carregam os args na entrada
    svc(0x80);                 // resultado fica em x0 e e o valor de retorno
}
```

### `emit()` / `reloc()` — M5
Bytes e relocações crus, para o que `#opcode` não cobre. `emit(u32 constante)` grava a palavra;
`reloc(TIPO, "_simbolo")` amarra uma relocação à próxima palavra emitida.

```c
void call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);
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
7. `#define` é constante dobrada, não macro textual; `#opcode` só aceita argumentos constantes
   (senão é erro).

## Tier 2 — programático (stage1+, custo zero em C)

A partir de M6 o compilador é escrito em `.mc`; um pass de AST ou um backend novo passa a ser só um
módulo `.mc` incluído via `#include` que chama `pass(fn)` / `backend("nome", fn)` na inicialização.
Recompilar `mc` com esse módulo **é** ensinar o compilador — sem interpretador, sem dylib, sem ABI
de plugin.

A AST é dado plano em arena com offsets `#define`; os primitivos de saída são funções comuns:
`sec_new(seg, sect, flags)`, `sym_def(name, sec, off, global)`, `reloc_add(sec, off, sym, type,
pcrel, len)`, `emit_u32(sec, w)`. Um backend na superfície é só código `.mc` que os chama.

Estado hoje: os primitivos já existem em C e são usados internamente pelo próprio stage0 desde M0 —
`sec_new`, `sym_new`, `reloc_add` em `stage0/macho.c` (`sym_def`/`emit_u32` do plano correspondem a
`sym_new`/`buf_u32` na implementação atual). A versão `.mc` desses primitivos e `pass()`/`backend()`
como conceito da superfície são planejados para stage1+; `backend("asm", fn)` concreto, comparado
byte a byte com o `__text` embutido, é o critério de aceite do **M10**.
