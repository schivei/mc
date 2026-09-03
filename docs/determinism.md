# determinism.md — as 8 regras de determinismo

Fonte: `docs/plan.md` § Determinismo. Objetivo final: `mc1 mc.mc → mc2.o` e `mc2 mc.mc → mc3.o`
produzem `.o` byte a byte idênticos (ponto fixo, **M7**). Cada regra abaixo tem um exemplo de
violação (o que não fazer) e a forma correta — a forma correta, quando já existe código, é citada
de `stage0/arena.c`/`stage0/macho.c`, que já seguem essas regras desde M0.

## 1. Nunca hashear ponteiros; nunca iterar hash table para gerar saída

Violação:
```c
for (int i = 0; i < table.cap; i++)      // ordem = layout interno da hash table,
    if (table.slot[i].used)              // depende de endereco/hash: nao deterministico
        emit_symbol(table.slot[i]);
```
Correto: array paralelo em ordem de inserção — `sym_new()` em `stage0/macho.c` sempre faz `append`
em `symbols[nsymbols++]`, nunca insere por hash.

## 2. Symtab por partição estável; nada de `qsort`

Violação:
```c
qsort(symbols, nsymbols, sizeof(Symbol), cmp_by_addr);  // desempate do qsort nao e estavel
                                                          // (e pode variar entre libc)
```
Correto: partição estável em 3 classes (local, extern definido, indefinido), preservando a ordem de
inserção dentro de cada classe — o laço em `macho_write()`:
`for (c = 0; c < 3; c++) for (i = 0; i < nsymbols; i++) if (sym_class(&symbols[i]) == c) ...`.

## 3. I/O do stage0 em C com a mesma forma da versão `.mc`

Violação:
```c
FILE *f = fopen(path, "rb");             // stdio bufferiza/formata diferente da versao .mc,
fread(buf, 1, n, f);                     // que so tera open/read/write/close (sem stdio)
```
Correto: `open`/`read` em loop até `r == 0`, depois `close` — é literalmente `read_file()` em
`stage0/arena.c`, para transliterar 1:1 depois.

## 4. Sem `__FILE__`, data, caminho absoluto, `N_OSO`/stabs, `ar`

Violação:
```c
buf_u32(&o, LC_BUILD_VERSION); buf_u32(&o, 24);
buf_u32(&o, 1); buf_u32(&o, sdk_version_from_env()); ...   // varia por maquina/SDK instalado
```
Correto: valores hardcoded — `stage0/macho.c` grava sempre `platform=1, minos=0x000D0000,
sdk=0x000D0000, ntools=0`, independente de máquina ou data de build.

## 5. Zerar todo padding/alinhamento explicitamente

Violação:
```c
o.len += pad;   // "pula" bytes sem escrever; conteudo do heap da arena pode nao estar zerado
```
Correto: `buf_pad(Buf *b, size_t align) { while (b->len % align) buf_u8(b, 0); }`
(`stage0/arena.c`) — escreve zero byte a byte até o alinhamento, nunca avança o cursor sem gravar.

## 6. Builds de referência fixos

Referência: `-O1` puro (`make stage0`). CI adicional: `-O0 -fwrapv -fno-strict-aliasing
-fsanitize=undefined,address` (`make stage0-san`). Violação: comparar `.o` gerados por flags
diferentes (ex.: `-O2` local vs `-O1` no CI) e tratar uma divergência de otimização de compilador
como bug de determinismo do `mc` — sempre comparar builds feitos com as mesmas flags.

## 7. `--dump-tokens/--dump-ast/--dump-syms/--dump-asm` com texto determinístico desde o M1

Violação: dump que imprime endereço de ponteiro (`%p`) ou itera uma tabela hash interna do
compilador. Correto: texto fixo por índice/campo, uma linha por item, na ordem de
emissão/inserção — exigido já no aceite de M1 (`docs/specs/M1.md`: rodar `--dump-tokens`,
`--dump-ast`, `--dump-asm` duas vezes e `diff` sem diferença).

## 8. Comparar `.o`, não executáveis linkados

Violação: `diff <(./mc1_linkado) <(./mc2_linkado)`, ou comparar binários pós-`ld` — o linker da
Apple pode introduzir layout/UUID não controlado pelo `mc`. Correto: comparar o `.o` que o
compilador emite antes de `ld` (`cmp mc2.o mc3.o`); golden SHA-256 de `mc2.o` versionado em
`tests/golden/`.

## Diagnóstico do ponto fixo (M7)

Quando `mc1 src/mc.mc` e `mc2 src/mc.mc` divergem:

1. Gerar os dois `.o` normalmente e confirmar a divergência com `cmp mc2.o mc3.o`.
2. Rodar `diff <(mc1 --dump-asm src/mc.mc) <(mc2 --dump-asm src/mc.mc)`. Como o dump é texto
   determinístico (regra 7), a primeira linha diferente já aponta a instrução/símbolo culpado, sem
   precisar comparar bytes crus do `.o`.
3. Bissectar por função: isolar metade das funções de `src/mc.mc` (comentar, ou compilar um
   subconjunto via `#include`) e repetir o diff até restar a função exata que diverge.
4. Checar contra as regras acima antes de corrigir — causas usuais do plano (§ Riscos/§ Marcos):
   ordem de tabelas (regras 1/2), padding não zerado (regra 5), leitura curta de arquivo (regra 3).
5. Corrigir, rebuildar `mc1`/`mc2`/`mc3` e repetir o `cmp` até bater byte a byte.
