# macho-notes.md — notas verificadas de Mach-O/AArch64

Valores conferidos lendo `stage0/macho.c` (implementado e em uso desde M0) — não é transcrição do
plano, é o que o código realmente escreve.

## Header e constantes

```c
MH_MAGIC_64                 = 0xfeedfacf
CPU_TYPE_ARM64               = 0x0100000C   // subtype 0
MH_OBJECT                    = 1
MH_SUBSECTIONS_VIA_SYMBOLS   = 0x2000
LC_SEGMENT_64                = 0x19
LC_SYMTAB                    = 0x2
LC_DYSYMTAB                  = 0xb
LC_BUILD_VERSION             = 0x32
N_UNDF = 0x00   N_EXT = 0x01   N_SECT = 0x0e
```

Flags de seção usadas hoje: `S_REGULAR=0x0`, `S_ZEROFILL=0x1`, `S_CSTRING_LITERALS=0x2`,
`S_ATTR_PURE_INSTRUCTIONS=0x80000000`, `S_ATTR_SOME_INSTRUCTIONS=0x00000400` (as duas últimas
compostas em `TEXT_FLAGS`, `stage0/mc.h`).

### Coalescing de `S_CSTRING_LITERALS` — por que `\0` embutido é proibido

O `ld` da Apple trata toda seção marcada `S_CSTRING_LITERALS` como um pool de strings C: ele pode
fundir (coalesce) dois literais cujo conteúdo bata **até o primeiro `\0`**, para economizar espaço
— é assim que dois `.o` diferentes com a mesma string literal acabam compartilhando um endereço
depois do link. O `mc0` já faz a sua própria dedup (busca linear por conteúdo completo, byte a
byte, `stage0/gen_arm64.c`) antes de gravar `__cstring`, então strings idênticas de um mesmo módulo
já saem com um símbolo só (confirmado: duas chamadas a `puts("dup")` no mesmo arquivo produzem um
único `l_str0` em `--dump-syms`, seção `__cstring` de 4 bytes). O problema é o caso que a dedup do
`mc0` **não** vê da mesma forma que o `ld`: `mc0` compara os bytes inteiros (`"a\0b"` com 3 bytes
de conteúdo é diferente de `"a"` com 1), mas o coalescing do `ld` só olha até o primeiro `\0` — nos
bytes gravados, `"a\0b\0"` e `"a\0"` têm o mesmo prefixo até o primeiro NUL, e o `ld` os trataria
como o mesmo literal, silenciosamente dando a eles o mesmo endereço. Como o `mc0` não replica essa
regra de fusão do `ld` na sua própria dedup, o resultado divergiria do que o `mc0` "acha" que
compilou. Por isso `\0` dentro de string literal é erro de compilação (M5.5, ver
`docs/core-language.md`) em vez de um caso a mais na dedup.

`macho_write()` sempre emite **4 load commands** (`ncmds=4`): um único `LC_SEGMENT_64` (que carrega
todas as seções do módulo), depois `LC_BUILD_VERSION`, `LC_SYMTAB`, `LC_DYSYMTAB`, nessa ordem.

## Layout de endereços

Duas passadas sobre as seções: primeiro as regulares, na ordem em que foram criadas por `sec_new`
(primeira seção criada = primeiro endereço), depois as `S_ZEROFILL`. Cada seção é alinhada a
`1 << align` antes de somar seu tamanho ao VM acumulado. `filesz` do segmento é o VM logo antes de
entrar nas seções zerofill — zerofill não ocupa espaço em arquivo, só VM.

## Ordem das seções (`gen_sections`, M5.5)

A ordem de **criação** por `sec_new` — que é também a ordem de endereço da seção anterior — segue
sempre esta receita, fixa desde M5.5 (`stage0/gen_arm64.c:gen_sections`, comentário no próprio
código: "`__text`, `__cstring`, `__data` e `__bss` (as que o módulo usa) e só depois as do
`#section`, na ordem de primeira aparição no fonte"):

1. `__TEXT,__text` — sempre criada, mesmo vazia.
2. `__TEXT,__cstring` (`S_CSTRING_LITERALS`) — só se o módulo tem alguma string literal.
3. `__DATA,__data` — só se há global inicializada (escalar ou array) sem seção custom.
4. `__DATA,__bss` (`S_ZEROFILL`) — só se há global sem inicializador sem seção custom.
5. Seções custom declaradas por `#section`, na ordem da **primeira aparição** de cada uma no
   fonte (registradas numa tabela linear própria; `#section` sem argumentos não conta como
   aparição, só devolve ao default).

Confirmado com `--dump-syms` de verdade: `tests/030-section.mc` (que usa `__DATA,__tbl`,
`__DATA,__zt` e `__TEXT,__hot` via `#section`) produz, nessa ordem exata, `__TEXT,__text` →
`__DATA,__data` → `__DATA,__tbl` → `__DATA,__zt` → `__TEXT,__hot`; `tests/040-arrinit.mc` (sem
`#section`, com strings e array inicializado) produz `__TEXT,__text` → `__TEXT,__cstring` →
`__DATA,__data`; `tests/024-arena.mc` (array global sem inicializador) produz `__TEXT,__text` →
`__DATA,__data` → `__DATA,__bss`.

## Relocações — 4 tipos + o modificador `ADDEND`

```c
R_UNSIGNED   = 0   // ponteiro em __data, len=3 (2^3 = 8 bytes)
R_SUBTRACTOR = 1   // reservado no enum, sem uso ainda
R_BRANCH26   = 2   // bl
R_PAGE21     = 3   // adrp — parte alta de endereco de string/global/array
R_PAGEOFF12  = 4   // add/ldr — parte baixa
R_ADDEND     = 10  // precede outra reloc quando ha soma constante (addend)
```

Essas mesmas quatro constantes (`UNSIGNED BRANCH26 PAGE21 PAGEOFF12`) ficam pré-definidas na
tabela de `#define` da superfície para uso em `reloc(TIPO, "simbolo")` (`docs/surface.md`).

### `R_UNSIGNED` em `__data` — inicializador de array global de `uptr`

Desde M5.5, um elemento string literal dentro de `tipo v[] = {...}` grava 8 bytes zero em
`__data` e prende uma relocação `R_UNSIGNED` (len=3, pcrel=0, extern=1) nesse offset, apontando
para o símbolo local `l_strN` daquela string em `__cstring` — é o `ld`, na hora de linkar, que
resolve o ponteiro somando o endereço final de `l_strN`. Confirmado com `otool -r` de
`tests/040-arrinit.mc` (`uptr names[] = {"zero", "um", "dois"};`):

```
Relocation information (__DATA,__data) 3 entries
address  pcrel length extern type    scattered symbolnum/value
00000010 0     3      1      0       0         2
00000008 0     3      1      0       0         1
00000000 0     3      1      0       0         0
```

`type=0` é `R_UNSIGNED`, `length=3` é 8 bytes, `pcrel=0` (endereço absoluto, não relativo ao PC) —
uma reloc por ponteiro do array, em ordem decrescente de endereço (regra geral da seção anterior).

Cada relocação são 8 bytes: offset (u32) + palavra de bits (u32), LE, layout
`symbolnum:24 | pcrel:1 | length:2 | extern:1 | type:4` (bit 0 ao 31), escrita assim em
`macho_write()`:

```c
buf_u32(&o, r->off);
buf_u32(&o, (symnum & 0xffffff) | (pcrel << 24) | (len << 25) | (ext << 27) | (type << 28));
```

`symnum` é o índice do símbolo **na ordem final da symtab**, não o índice de criação — por isso
`macho_write` monta `pos[]` (índice de criação → posição final) antes de emitir relocações.
`ext=0` só quando `type == R_ADDEND` (usa o valor cru do addend em vez de um índice de símbolo).
Relocações são emitidas em **ordem decrescente de endereço** dentro de cada seção — mesmo
comportamento do `clang`/`ld` da Apple, importante para golden-matching (M7).

## Ordem da symtab

Partição estável em 3 classes, sempre nesta ordem: **locais → externos definidos → indefinidos**
(`sym_class`: `sect==0` → indefinido; senão `global` → externo; senão local). `LC_DYSYMTAB` descreve
os índices dessa partição: `ilocalsym=0`, `nlocalsym=count[local]`, `iextdefsym=count[local]`,
`nextdefsym=count[extern]`, `iundefsym=count[local]+count[extern]`, `nundefsym=count[undef]`.
`n_sect` é 1-based (seção 0 = "nenhuma"; símbolos indefinidos usam `n_sect=0`). A string table
começa com um `\0` e é preenchida (`buf_pad`) até múltiplo de 8.

## `LC_BUILD_VERSION` obrigatório

Sem essa load command o `ld` moderno recusa o `.o` (comportamento observado no M0). Valores
hardcoded em `macho.c` (regra de determinismo 4 — nada de ler versão do SDK instalado em runtime):
`platform=1` (macOS), `minos=0x000D0000` (13.0.0), `sdk=0x000D0000` (13.0.0), `ntools=0`.

## Link

`scripts/link.sh OUT IN.o [...]`:
```sh
ld -arch arm64 -platform_version macos 13.0 13.0 -syslibroot "$(xcrun --show-sdk-path)" -lSystem -o "$out" "$@"
```
`ld` continua permitido mesmo depois do corte do cordão (M8) — só `gcc`/`cc`/`clang` ficam de fora
(o stage0 é a única coisa compilada por `clang`, uma única vez).

## Syscalls (`x16` + `svc #0x80`)

Convenção BSD/Darwin arm64: número da syscall em `x16`, argumentos em `x0..x5`, `svc #0x80`,
resultado em `x0`. Números usados hoje (verificados contra `sys/syscall.h` do SDK):

| Syscall | Número |
|---|---|
| `exit`  | 1 |
| `read`  | 3 |
| `write` | 4 |
| `open`  | 5 |
| `close` | 6 |

`m05()` em `stage0/main.c` já usa isso: `mov x16, #4` + `svc #0x80` para `write`, `mov x16, #1` +
`svc #0x80` para `exit`.

## Achado empírico do M0.5: binário estático é morto pelo kernel

Testado: gerar o `.o` de M0.5 e linkar **estático** (`ld -static -e _start ...`), que produz um
executável com `LC_UNIXTHREAD` como ponto de entrada. Resultado: o processo é morto com **SIGKILL**
pelo kernel logo ao iniciar — mesmo depois de `codesign -s - <binário>` (assinatura ad-hoc). O
mesmo `.o`, linkado **dinamicamente** (`ld -e _start -lSystem -syslibroot ... -o out out.o`, o
caminho que `scripts/link.sh` implementa), roda normalmente e o `svc` funciona como esperado.

**Conclusão:** o macOS atual (Xcode 26 / ld-1267, darwin arm64) não aceita mais executáveis Mach-O
totalmente estáticos, mesmo ad-hoc assinados — dyld/`LC_LOAD_DYLINKER` é obrigatório. Usar sempre
`-lSystem`/dyld para linkar (`scripts/link.sh` já faz isso); syscalls crus (`x16` + `svc`) continuam
funcionando normalmente sob dyld — a restrição é sobre o binário ser estático, não sobre emitir
`svc` diretamente. Isso implica que M11 (executável direto, `MH_EXECUTE`) precisa sempre incluir
`LC_LOAD_DYLINKER` + `LC_LOAD_DYLIB libSystem`, como já está no critério de aceite do M11 no plano.
