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

## M11 — executável direto (`MH_EXECUTE`), sem `ld`

Tudo abaixo foi conferido nos binários que `src/backend_exe.mc` realmente escreve (`otool -l`,
`otool -s`, `nm -m`, `xxd`, `codesign -dvvv`), comparado campo a campo com a referência produzida
por `ld` (`build/mc1 tests/001-return42.mc -o t.o && scripts/link.sh t t.o`). O `ld` moderno usa
*chained fixups*; para ter uma referência do formato clássico que o M11 escreve, gere-a com
`ld ... -no_fixup_chains` — ela produz `LC_DYLD_INFO_ONLY` e `__stubs`, e roda normalmente. Isso
prova, de saída, que o `dyld` deste macOS (Darwin 25.6) ainda aceita bind/rebase por opcodes.

### Layout de segmentos

Um `LC_SEGMENT_64` por **nome de segname distinto** entre as seções do módulo, na ordem de primeira
aparição — como `__TEXT,__text` é sempre a primeira seção criada por `gen_sections`, `__TEXT` é
sempre o primeiro. `__DATA` é criado mesmo sem globais quando há símbolo importado (é onde mora o
`__got`). Dentro de cada segmento: seções regulares na ordem de criação, `S_ZEROFILL` no fim — a
mesma regra de `macho_write`.

```
__PAGEZERO   vmaddr 0            vmsize 0x100000000   fileoff 0      filesize 0       prot 0
__TEXT       vmaddr 0x100000000  vmsize 0x4000        fileoff 0      filesize 16384   prot 5 (r-x)
__DATA       vmaddr 0x100004000  vmsize 0x4000        fileoff 16384  filesize 16384   prot 3 (rw-)
__LINKEDIT   vmaddr 0x100008000  vmsize 0x4000        fileoff 32768  filesize 586     prot 1 (r--)
```

(valores reais de `build/mc1 --exe tests/021-strings.mc`). Regras confirmadas:

- **Página de 16 KiB** (`vm_page_size` do arm64): `vmaddr` e `fileoff` de todo segmento são
  múltiplos de 16384. `filesize` é o conteúdo regular arredondado para cima (o arquivo é preenchido
  com zeros até lá); `vmsize` é o conteúdo total, incluindo zerofill, arredondado para cima.
- **VM e arquivo andam separados.** O próximo segmento tem `vmaddr = vmaddr + vmsize` e
  `fileoff = fileoff + filesize` do anterior, calculados independentemente — é o que permite um
  `__bss` de 32 MiB (`heap[]` de `src/arena.mc`) sem 32 MiB de arquivo. Confirmado no `ld`:
  `build/mc1` tem `__DATA` com `vmsize 0x2030000` e `filesize 16384`, e `__LINKEDIT` em
  `vmaddr 0x10205c000` = `0x10002c000 + 0x2030000`.
- **O header mora dentro do `__TEXT`**: `__TEXT` começa em `fileoff 0` e a primeira seção começa em
  `32 + sizeofcmds`, arredondado para o alinhamento dela.
- **`entryoff` do `LC_MAIN` é o offset em arquivo de `_main`.** Como `__TEXT` tem `fileoff 0` e
  `vmaddr = 0x100000000`, é simplesmente `addr(_main) - 0x100000000`. O `dyld`/`libdyld` chama esse
  endereço como `main(argc, argv, envp, apple)` e faz `exit(retorno)` — é por isso que um
  `i64 main()` que devolve 42 dá `$? == 42` sem nenhum `_start` escrito à mão.

Flags do header: `MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE` = `0x200085`. O `ld` põe
`MH_NOUNDEFS` mesmo com símbolos importados (conferido com `otool -hv` na referência) — a flag
significa "nada ficou por resolver no link", não "não há símbolo indefinido na symtab".

### Load commands (13, nesta ordem)

`LC_SEGMENT_64` ×4 · `LC_DYLD_INFO_ONLY` · `LC_SYMTAB` · `LC_DYSYMTAB` · `LC_LOAD_DYLINKER` ·
`LC_UUID` · `LC_BUILD_VERSION` · `LC_MAIN` · `LC_LOAD_DYLIB` · `LC_CODE_SIGNATURE`.

```c
LC_DYLD_INFO_ONLY = 0x80000022   /* 0x22 | LC_REQ_DYLD */   cmdsize 48
LC_LOAD_DYLINKER  = 0x0e   cmdsize 32   name "/usr/lib/dyld" no offset 12
LC_UUID           = 0x1b   cmdsize 24
LC_MAIN           = 0x80000028   cmdsize 24   entryoff u64, stacksize u64 = 0
LC_LOAD_DYLIB     = 0x0c   cmdsize 56   "/usr/lib/libSystem.B.dylib" no offset 24,
                                        timestamp 2, current 1356.0.0, compat 1.0.0
LC_CODE_SIGNATURE = 0x1d   cmdsize 16   dataoff, datasize
```

`LC_LOAD_DYLINKER` + `LC_LOAD_DYLIB` são obrigatórios: o achado empírico do M0.5 (seção anterior) é
que binário estático é morto pelo kernel mesmo assinado. `LC_BUILD_VERSION` sai com `ntools = 0`
(cmdsize 24), ao contrário do `ld`, que anexa uma entrada de ferramenta (cmdsize 32) — o `dyld` não
se importa e `ntools=0` é mais determinístico (nada de versão de linker no arquivo).

### `__stubs` e `__got` — chamada a símbolo importado

Cada símbolo indefinido ganha um stub de 12 bytes em `__TEXT,__stubs` e um slot de 8 bytes em
`__DATA,__got`. Todo `BRANCH26` para um símbolo indefinido é resolvido para o **endereço do stub**;
`PAGE21`/`PAGEOFF12` para um indefinido também apontam para o stub, o que faz `&write` passar a
funcionar no executável direto (no `.o` + `ld` ele ainda é o limite conhecido do M10, ver
`docs/core-language.md`).

```
__TEXT,__stubs   flags 0x80000408 (S_SYMBOL_STUBS|PURE|SOME)  reserved2 = 12 (tamanho do stub)
__DATA,__got     flags 0x00000006 (S_NON_LAZY_SYMBOL_POINTERS)
```

O conteúdo do stub, conferido com `otool -s __TEXT __stubs`:

```
0000000100000000  90000030 f9400210 d61f0200
                  adrp x16, pagina do slot
                           ldr  x16, [x16, #off]
                                    br   x16
```

`reserved1` é o índice na tabela de símbolos indiretos; ela lista os importados **duas vezes**,
primeiro para `__stubs` (`reserved1 = 0`) e depois para `__got` (`reserved1 = nundef`), cada entrada
sendo o índice do símbolo na symtab final. O `dyld` moderno não a usa (quem preenche o `__got` são
os bind opcodes), mas `nm -m`/`otool` sim.

Símbolo indefinido na symtab: `n_type = N_UNDF|N_EXT`, `n_sect = 0`, **`n_desc = 0x0100`** — os bits
8..15 do `n_desc` são o ordinal da dylib no espaço de nomes de dois níveis (`MH_TWOLEVEL`), e 1 é o
único `LC_LOAD_DYLIB` do arquivo. Conferido na referência do `ld` (`xxd` da symtab: `_write` sai com
`n_desc` `00 01` little-endian) e no resultado: `nm -m` mostra `(undefined) external _write (from
libSystem)`.

### Bind e rebase (`LC_DYLD_INFO_ONLY`)

Só `rebase_off/size` e `bind_off/size`; `weak`, `lazy` e `export` ficam zerados (todo bind é
imediato, e um executável não precisa exportar nada). Bytes reais de `tests/021-strings.mc`, que
importa só `_write`:

```
$ xxd -s 32768 -l 14 tmp/e-021-strings
1151 405f 7772 6974 6500 7200 9000
 |  |  |   \_ "_write\0"          |  \_ 0x00 BIND_OPCODE_DONE
 |  |  \_ 0x40 SET_SYMBOL_TRAILING_FLAGS_IMM (flags 0)
 |  \_ 0x51 SET_TYPE_IMM 1 (BIND_TYPE_POINTER)
 \_ 0x11 SET_DYLIB_ORDINAL_IMM 1        0x72 SET_SEGMENT_AND_OFFSET_ULEB seg=2 (__DATA), off=0
                                        0x90 DO_BIND
```

É byte a byte a mesma forma que o `ld` emite (conferido no `-no_fixup_chains`, que produz
`1140 "dyld_stub_binder" 0051 7200 9000` para o binder preguiçoso dele).

Rebase de `tests/040-arrinit.mc` (`uptr names[] = {"zero", "um", "dois"}` — três `R_UNSIGNED` em
`__data`):

```
$ xxd -s 32768 -l 11 tmp/e-040-arrinit
1122 0051 2208 5122 1051 00
 |    \_ 0x22 SET_SEGMENT_AND_OFFSET_ULEB seg=2, off=0 · 0x51 DO_REBASE_IMM_TIMES 1
 \_ 0x11 REBASE_OPCODE_SET_TYPE_IMM 1 (REBASE_TYPE_POINTER)   ... off=8 ... off=16 ... 0x00 DONE
```

O `__data` correspondente guarda o endereço **sem o slide** e o `dyld` soma o slide no rebase:

```
$ otool -s __DATA __data tmp/e-040-arrinit
0000000100004000  000006d8 00000001 000006dd 00000001 000006e0 00000001 ...
```

(`0x1000006d8`, `0x1000006dd`, `0x1000006e0` são os três literais em `__cstring`.) Sem a entrada de
rebase o ponteiro apontaria para o lugar errado assim que o ASLR desse um slide — testado rodando o
binário três vezes seguidas, com stdout igual nas três.

Um `R_UNSIGNED` numa seção de segmento **não gravável** é recusado com
`ponteiro relocado em __TEXT: o segmento e r-x e o dyld nao o rebasa` — não há como o `dyld`
escrever ali, e um erro claro é melhor que um SIGKILL.

### Resolução das quatro relocações

Feita pelo próprio `mc`, patchando a palavra já encodada na seção:

| tipo | conta |
|---|---|
| `BRANCH26` | `imm26 = (alvo - pc) / 4`, ±128 MiB; grava nos 26 bits baixos do `bl` |
| `PAGE21` | `imm = (pagina(alvo) - pagina(pc)) / 4096`; `immlo` nos bits 29:30, `immhi` nos bits 5:23 do `adrp` |
| `PAGEOFF12` | `imm12 = alvo & 0xfff` para `add`; para `ldr`/`str` com deslocamento sem sinal (`(w & 0x3b000000) == 0x39000000`), dividido pela largura do acesso (bits 31:30) |
| `UNSIGNED` | 8 bytes com o endereço absoluto sem slide + entrada de rebase (ou bind, se o símbolo for importado) |

`R_ADDEND` e `R_SUBTRACTOR` são recusados: o núcleo nunca os emite (ver a seção de relocações
acima) e a superfície só predefine `UNSIGNED BRANCH26 PAGE21 PAGEOFF12`.

### Assinatura ad-hoc (`LC_CODE_SIGNATURE`)

Sem assinatura o kernel mata o processo. O blob fica no fim do `__LINKEDIT`, alinhado a 16, e é a
última coisa do arquivo. Todo campo é **big-endian** — ao contrário de todo o resto do Mach-O.

```
CS_SuperBlob   magic 0xfade0cc0, length, count = 1
  CS_BlobIndex type 0 (CSSLOT_CODEDIRECTORY), offset 20
CS_CodeDirectory (em +20)   magic 0xfade0c02
  version       0x20400        <- versao que tem execSeg*
  flags         0x2 (CS_ADHOC)
  hashOffset    88 + len(identificador)+1
  identOffset   88             <- tamanho fixo do cabecalho da v0x20400
  nSpecialSlots 0
  nCodeSlots    ceil(codeLimit / 4096)
  codeLimit     offset do proprio blob no arquivo
  hashSize 32 · hashType 2 (SHA-256) · platform 0 · pageSize 12 (1<<12 = 4 KiB)
  spare2, scatterOffset, teamOffset, spare3, codeLimit64 = 0
  execSegBase   fileoff do __TEXT (0)
  execSegLimit  filesize do __TEXT
  execSegFlags  1 (CS_EXECSEG_MAIN_BINARY)
  identificador NUL-terminado, depois nCodeSlots hashes de 32 bytes
```

Os offsets `identOffset = 88` e `hashOffset = 90` (identificador `"t\0"`) foram lidos byte a byte de
uma assinatura do `ld` com `xxd`, e o `execSegLimit = filesize do __TEXT` de uma assinatura do
`codesign -f -s -` (o `ld`, na assinatura *linker-signed*, escreve ali o tamanho do `__text`, não do
segmento — funciona, mas o `codesign` é a referência melhor). Cada slot é o SHA-256 de uma página de
4 KiB **do arquivo**, com a última página parcial (o hash cobre só até `codeLimit`).

Resultado:

```
$ codesign -dvvv tmp/t1
CodeDirectory v=20400 size=251 flags=0x2(adhoc) hashes=5+0 location=embedded
Executable Segment base=0
Executable Segment limit=16384
Executable Segment flags=0x1
Page size=4096
$ codesign --verify --verbose=4 tmp/t1
tmp/t1: valid on disk
tmp/t1: satisfies its Designated Requirement
```

O identificador é o **basename do arquivo de saída** (`-o tmp/t1` → `t1`), a mesma convenção do
`codesign`.

### `LC_UUID` determinístico

Os 16 bytes são os primeiros 16 do SHA-256 do arquivo inteiro **com o campo do UUID zerado e sem a
assinatura** (isto é, dos bytes `[0, codeLimit)`), com os bits de versão (`byte[6] = (b & 0x0f) |
0x50`) e de variante (`byte[8] = (b & 0x3f) | 0x80`) forçados como manda a RFC 4122. Nada de data,
caminho ou versão de SDK entra ali — dois builds do mesmo fonte para o mesmo nome de saída dão o
mesmo UUID, e portanto o mesmo binário byte a byte.

### Permissão de execução

`write_file` do `arena.mc` usa `creat(path, 0644)`. O executável usa `creat(path, 0755)` **e** um
`chmod(path, 0755)` depois de fechar: `creat` só aplica o modo quando *cria* o arquivo, então
regravar um `-o` que já existia com outra permissão manteria a antiga. `chmod` é o único `extern`
que o M11 acrescentou.
