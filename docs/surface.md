# surface.md — superfície de ensino

Fonte: `docs/plan.md` § "Superfície de ensino" e
`docs/specs/M1.md`/`M5.md`/`M5.5.md`/`M9.md`/`M10.md`.
Estado neste marco (**M11 fechado**): `#token`, `#infix`/`#prefix`, `#rule`, `#section`, `#opcode`,
`emit()`/`reloc()` implementados e testados de verdade com `build/mc0` **e** com o compilador
auto-hospedado `build/mc1` (o mecanismo existe nos dois lados: `stage0/parse.c` e `src/parse.mc`).
O Tier 2 programático (`pass()`/`backend()`) também está **implementado**, mas só no compilador
em `.mc` — o stage0 em C é a semente e não é ensinável por Tier 2. Ver a seção no fim, que também
descreve os dois backends embutidos: `macho` (o `.o`, default) e `macho-exe` (o executável direto
do M11, apelido `--exe`).

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

**Higiene: só gensym.** `$$nome` no template vira um local novo por expansão, `$g1`, `$g2`, ...
(contador global, determinístico). O `$` no nome não é decoração: o lexer nunca forma um
identificador com `$`, então **nenhum nome escrito pelo usuário pode colidir com um gensym** — a
captura é impossível por construção, não apenas improvável. (Até o M9 o prefixo era `__g`, que é um
identificador legal: `i64 __g1 = 42; mk(1); return __g1;` devolvia o valor do gensym. É o caso de
`tests/056-gensym-nocapture.mc`.) Duas expansões da mesma regra no mesmo bloco também não colidem —
`tests/053-gensym.mc`:

```c
#rule stmt: swap ( ident $a , ident $b ) ;
    => { i64 $$t = $a; $a = $b; $b = $$t; }
```

**O literal de despacho não pode ser palavra-chave do núcleo.** Os tipos (`u8`..`void`) e as
palavras de controle (`if`, `else`, `loop`, `break`, `continue`, `return`, `extern`) são recusadas
com `nao pode redefinir palavra-chave do nucleo`: uma regra aberta por `if` sequestraria o parser de
statements do próprio núcleo, e nada mais no arquivo voltaria a compilar. Pontuação continua livre
— `#rule stmt: ident $x [ expr $i ] = expr $e ;` é legítimo, e um `#token` novo também.

```
$ build/mc0 hijack.mc -o x.o          # #rule stmt: if ( expr $c ) block $b => ...
hijack.mc:1: nao pode redefinir palavra-chave do nucleo
```

**Dois modos de falha que valem conhecer.**

1. *O literal composto precisa de `#token` antes.* Um padrão que abre (ou continua) com `+=` sem
   um `#token "+="` anterior não vê `+=` coisa nenhuma: o lexer entrega `+` e `=`, o `+` já é
   infixo, e o Pratt consome `a +` procurando o operando da direita antes de qualquer despacho.
   O erro sai longe da causa:

   ```
   $ build/mc0 noplus.mc -o x.o       # #rule stmt: ident $x += expr $e ;  (sem #token)
   noplus.mc:3: expressao esperada
   ```

   Com `#token "+="` na frente, a mesma regra funciona (é o que `lib/prelude.mc` faz).

2. *A palavra de abertura vira palavra-chave para o resto da unidade — inclusive sobre nomes já
   declarados.* `tok_add` registra o identificador na tabela do lexer; dali em diante ele nunca
   mais é um `T_IDENT`. Uma função `repeat` declarada **antes** de `#rule stmt: repeat ...`
   continua no `.o` (o símbolo `_repeat` existe), mas ninguém consegue mais chamá-la: a chamada
   deixa de ser uma expressão.

   ```
   $ build/mc0 kw2.mc -o x.o          # i64 repeat(...) ...; #rule stmt: repeat ...
   kw2.mc:3: expressao esperada      #  ... i64 x = repeat(7);
   ```

   É a mesma regra de `tests/err/055-keyword.mc`, vista do outro lado: lá o nome é declarado
   depois da regra, aqui antes. Escolha palavras de abertura que você não pretende usar como nome.

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
PAGEOFF12=4 UNSIGNED=0`). Símbolo desconhecido vira indefinido externo.

`UNSIGNED` é aceito como constante mas **recusado nesta posição**: é uma relocação de 8 bytes
(`length 3`) e a palavra que `emit()`/`#opcode` põem no fluxo tem 4, então ela passaria por cima da
instrução seguinte. O erro é `reloc UNSIGNED exige 8 bytes: use inicializador de array global`, nos
dois lados (`stage0/gen_arm64.c` e `src/gen_arm64.mc`) — caso em `tests/err/062-reloc-unsigned.mc`.
Endereço de 8 bytes se escreve como inicializador de array global, que gera o `R_UNSIGNED` no lugar
certo (`tests/040-arrinit.mc`, `tests/060-callp.mc`).

Testado
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

## Tier 2 — programático (`pass()` / `backend()`) — implementado (M10)

Do M6 em diante o compilador é escrito em `.mc`. Um pass de AST ou um backend novo é, por isso,
**só um módulo `.mc` compilado junto com o compilador**: sem interpretador, sem dylib, sem ABI de
plugin. Ensinar o compilador é editar um arquivo e rodar `make mc1`.

### O passo a passo real

1. **Escreva o módulo** em `lib/` (ou onde quiser). Ele define suas funções e um `user_init` que as
   registra:

   ```c
   // lib/user_demo.mc
   #include "backend_arm64.mc"
   #include "pass_demo.mc"

   void user_init() {
       backend("arm64-surface", &sur_backend);   // --backend=arm64-surface
       pass(&pass_mul1);                          // roda sobre a AST de todo fonte
   }
   ```

2. **Ligue o módulo** trocando o `#include` de `src/user.mc` — é a única costura entre o compilador
   e quem o ensina:

   ```c
   // src/user.mc
   #include "../lib/user_demo.mc"      // no default: ../lib/user_default.mc
   ```

3. **Recompile o compilador**: `make mc1`. O `build/mc1` que sai já tem o pass e o backend dentro.

4. **Use**: `build/mc1 --backend=arm64-surface prog.mc -o prog.o`. Sem `--backend=`, o default é o
   backend embutido `macho`. Um nome desconhecido é erro e lista o que existe:

   ```
   $ build/mc1 --backend=xyz tests/001-return42.mc -o x.o
   backend desconhecido: xyz
   registrados: macho arm64-surface
   ```

`make check-surface` faz os passos 2–4 sozinho (liga o demo, recompila em `build/mc1s`, compara os
objetos, e devolve `src/user.mc` como estava). O default do repositório é `lib/user_default.mc`,
com `void user_init() { }`: a demonstração é **opt-in**.

### As duas assinaturas

| registro | assinatura do que você escreve | quando roda |
|---|---|---|
| `pass(&f)` | `i64 f(i64 root)` — devolve a raiz (a mesma ou outra) | logo depois de `parse_unit`, antes de `fold` e de `--dump-ast` |
| `backend("nome", &f)` | `void f(i64 root, uptr out)` | no lugar do `macho`, quando `--backend=nome` |

As duas entram como `uptr` (o que `&nome` produz) e são chamadas com `callp` — ver
`docs/core-language.md` § `&funcao` e `callp`. As tabelas em `src/hooks.mc` são lineares e
percorridas na ordem de registro: os passes rodam na ordem em que foram registrados; para backends
de mesmo nome, o último registro vence.

O pass roda **antes** de `fold` (e portanto antes de `--dump-ast`): assim o pass vê a árvore com a
forma do fonte, e a dobra de constantes limpa o que o pass produzir. É por isso que
`--dump-ast tests/061-pass.mc` muda quando o demo está ligado.

### O gen em duas metades

O backend embutido `macho` é literalmente `gen_lower` + `gen_encode_all` + `macho_write`:

- **`gen_lower(root)`** baixa a AST para um buffer `Ins` por função (o mesmo que `--dump-asm`
  imprime), cria seções, aloca globais, emite as strings em `__cstring` e cria os símbolos — mas
  **não encoda nada**. O `__text` continua vazio.
- **`gen_encode_all()`** percorre as funções, alinha cada uma a 4, fixa o valor do símbolo, resolve
  os labels e escreve as palavras de 32 bits com as relocações.

Um backend da superfície chama `gen_lower` e substitui a segunda metade. Para isso ele lê o buffer
pelas acessoras públicas de `src/gen_arm64.mc`:

```
gen_func_count()            quantas funcoes foram baixadas
gen_func_name(f)            nome do simbolo (_nome)
gen_func_sec(f)             secao de destino
gen_func_sym(f)             indice do simbolo (para sym_set_value)
gen_func_labels(f)          quantos labels a funcao usou
gen_ins_count(f)            instrucoes da funcao
gen_ins_at(f, i)            a instrucao i -> ins_op/ins_rd/ins_rn/ins_rm/ins_imm/ins_label/ins_sym
gen_prel_count(f)           relocacoes cruas de reloc() na funcao
gen_prel_ins/sym/type(f,k)  cada uma delas
gen_global_count()/gen_global_sym(g)   globais ja alocadas
gen_str_count()/gen_str_sym(s)         literais ja emitidas em __cstring
```

e escreve com os primitivos de `src/macho.mc`, que são funções comuns: `sec_new`, `sec_at`,
`sec_data`, `sym_new`, `sym_ref`, `sym_set_value`, `reloc_add`, `buf_u32`, `buf_pad`, `buf_len`,
`macho_write`.

### A prova: `lib/backend_arm64.mc`

`lib/backend_arm64.mc` registra o backend `arm64-surface`. Ele chama `gen_lower` e depois
**reimplementa o encoder inteiro em `.mc`**, com tabelas de opcode próprias (`sur_rrr_base`,
`sur_mem_base`, ...), resolução de labels própria e as chamadas de `reloc_add`/`buf_u32` — tudo por
cima da API acima, nada de `static` do núcleo. As fórmulas de encoding são as mesmas de `encode`
(copiadas de propósito: o ponto é que dá para chegar nelas de fora, não que sejam diferentes).

Critério de aceite, rodado por `make check-surface`: para **todo** `tests/*.mc`,

```
build/mc1s --backend=arm64-surface X -o a.o
build/mc1s                         X -o b.o
cmp a.o b.o        # byte a byte identicos, 32/32
```

`lib/pass_demo.mc` é o par do backend do lado da AST: um pass que varre `1..nnodes-1` e troca
`x * 1` por `x`, reescrevendo o nó no lugar (preservando `next`, que pertence à lista de irmãos).
O núcleo não faz isso — `fold` só dobra constante com constante — e `tests/061-pass.mc` mostra a
diferença em `--dump-ast`.

### Os dois backends embutidos: `macho` e `macho-exe`

`src/main.mc` registra dois backends antes de chamar `user_init()`:

| nome | escreve | apelido |
|---|---|---|
| `macho` (default) | `MH_OBJECT` — o `.o` que `scripts/link.sh` liga com `ld` | — |
| `macho-exe` (M11) | `MH_EXECUTE` arm64 assinado ad-hoc, sem `ld` | `--exe` |

```
$ build/mc1 --exe tests/001-return42.mc -o tmp/t1 && tmp/t1; echo $?
42
$ build/mc1 --backend=macho-exe tests/001-return42.mc -o tmp/t1    # a mesma coisa
$ build/mc1 --backend=xyz tests/001-return42.mc -o x.o
backend desconhecido: xyz
registrados: macho macho-exe
```

`macho-exe` mora em `src/backend_exe.mc` e é **parte do compilador**, não um módulo de usuário: ele
é a resposta do M11, não uma demonstração de Tier 2. Mas é escrito exatamente como um backend da
superfície seria — chama `gen_lower(root)` e `gen_encode_all()` (as duas metades públicas do gen) e
depois só usa a API pública de `src/macho.mc` para ler seções, símbolos e relocações. O que ele
acrescenta é o que o `ld` fazia: escolher endereços, resolver as quatro relocações, criar
`__TEXT,__stubs` + `__DATA,__got` para os símbolos importados, emitir os bind/rebase opcodes do
`dyld` e assinar ad-hoc (SHA-256 próprio, em `src/sha256.mc`). Os campos, com os valores conferidos,
estão em `docs/macho-notes.md` § M11; a cadeia sem `ld`, em `docs/bootstrap.md`.

Duas coisas que o `--exe` faz e o `.o` + `ld` não:

- **`&nome` de um `extern` de dylib funciona.** No `.o` o `ld` recusa (um símbolo importado só tem
  endereço via `__got` e o núcleo não emite `GOT_LOAD_PAGE21` — o limite conhecido do M10 em
  `docs/core-language.md`). No `--exe` quem resolve é o próprio `mc`, e ele aponta o `adrp`/`add`
  para o stub do símbolo, que é um endereço chamável.
- **O binário sai executável (`0755`) e assinado**, pronto para rodar; não há passo de link nem de
  `codesign`.

Uma coisa que ele **não** faz: `#section` num segmento que não seja `__TEXT` ganha um segmento
`rw-` próprio, e um ponteiro relocado (`R_UNSIGNED`) dentro de `__TEXT` é recusado com
`ponteiro relocado em __TEXT: o segmento e r-x e o dyld nao o rebasa`.

`scripts/test-exe.sh` (alvo `make test-exe`, dentro de `make check`) roda `tests/*.mc` inteiro por
esse caminho — compila com `--exe`, verifica a assinatura com `codesign --verify` e compara exit
code e stdout com o cabeçalho de cada fonte: **32/32**.

### O stage0 não é ensinável

`pass()`/`backend()` só existem no compilador em `.mc`. O stage0 em C é a semente: o driver aceita
`--backend=macho` (para que a linha de comando seja a mesma) e nada mais — `--backend=arm64-surface`
com `build/mc0` é `opcao desconhecida`. **`--exe` também não existe no stage0**: o executável direto
do M11 (`src/backend_exe.mc` + `src/sha256.mc`, 1035 linhas de `.mc`) não caberia no orçamento de
3000 linhas de C, e não precisa caber — a semente só tem de produzir o `mc1`. Isso é deliberado: o Tier 2 custa **zero** linhas de
mecanismo em C justamente porque o compilador que se ensina é o que está escrito na própria
linguagem. O que o C precisou ganhar no M10 foi só o que a linguagem precisa para expressar um
hook: `&funcao`, `callp` e a divisão do gen em duas metades.
