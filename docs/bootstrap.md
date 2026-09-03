# bootstrap.md — M8: cortar o cordão (e M11: cortar o `ld`)

Este documento descreve `scripts/bootstrap.sh` (M7, ponto fixo), o estado de M8 (o compilador deixa
de depender de `clang` para qualquer coisa além do primeiro estágio) e a cadeia sem `ld` que o M11
acrescentou. Leia `docs/plan.md` § Marcos, `docs/specs/M6-M7.md` § M7 e `docs/specs/M11.md` antes
deste texto — aqui só se documenta o que já está feito.

## A cadeia

```
build/mc0 src/mc.mc -o build/mc1.o   # mc0 = clang compilando stage0/*.c
scripts/link.sh build/mc1 build/mc1.o

build/mc1 src/mc.mc -o build/mc2.o   # mc1 = o .mc compilado por mc0
scripts/link.sh build/mc2 build/mc2.o

build/mc2 src/mc.mc -o build/mc3.o   # mc2 = o .mc compilado por mc1

cmp build/mc2.o build/mc3.o          # o criterio do ponto fixo
```

`scripts/bootstrap.sh` roda essa cadeia inteira, imprime tempo e tamanho de cada `.o`, confere o
SHA-256 de `build/mc2.o` contra `tests/golden/mc2.sha256` e por fim roda `scripts/test.sh build/mc2`
e `scripts/check-obj.sh build/mc1 build/mc2`. `make bootstrap` (depende de `stage0`, i.e. de
`build/mc0` existir) chama o script; `make check` roda `bootstrap` depois de todos os outros alvos.

## O critério é `mc2.o == mc3.o`, não `mc1.o` vs `mc2.o`

`mc1.o` é produzido por `mc0` (clang) compilando `src/mc.mc`; `mc2.o` é produzido por `mc1` (o
próprio `.mc` já rodando) compilando o mesmo fonte. São dois compiladores diferentes — mesmo que o
resultado costume bater byte a byte (e bate, neste projeto: é uma coincidência favorável, não uma
garantia), **não é isso que prova o ponto fixo**.

O que prova é `mc2.o == mc3.o`: `mc2` e `mc3` são o **mesmo binário mc1** compilando o **mesmo
fonte** — a única diferença entre gerar `mc2.o` e gerar `mc3.o` é que a segunda vez quem compila já
é ele próprio, uma geração adiante. Se `mc2.o == mc3.o`, o compilador se reproduz sem deriva: rodar
mais uma geração (`mc3` compilando de novo) não mudaria nada. Isso é o ponto fixo — o efeito líquido
de ter cortado o clang da cadeia.

## `clang` é usado exatamente uma vez

`clang` só compila **stage0** — o C que produz `build/mc0`. A partir daí, tudo é `mc0`/`mc1`/`mc2`
compilando `.mc`. Confirmação:

```
$ grep -rn clang scripts/ Makefile
Makefile:1:CC      = clang
scripts/link.sh:3:# ld nao e gcc/cc/clang: continua permitido apos o corte do cordao (M8).
scripts/bootstrap.sh:9:#     ... diferentes — clang vs mc1)
```

`CC = clang` só é referenciado pelas regras `build/mc0` e `build/mc0-san` (esta última só para os
sanitizers, nunca faz parte da cadeia de bootstrap). Os outros dois acertos são comentários que
citam a palavra, não invocações. Nenhum script em `scripts/` chama `clang`/`cc`/`gcc` diretamente.

## `ld` continua sendo usado

`ld` (o linker da Apple) não é um compilador C — não interpreta `.mc` nem `.c`, só liga objetos
Mach-O já prontos. `scripts/link.sh` continua chamando `ld -arch arm64 -platform_version macos ...
-lSystem` para transformar `mc1.o`/`mc2.o` em executáveis rodáveis; isso é permitido em M8 e
permanece permitido depois. **Desde o M11 ele deixou de ser necessário**: o backend `macho-exe`
(`mc --exe`) escreve o `MH_EXECUTE` assinado direto — ver a seção seguinte.

## M11 — a cadeia sem `ld`

Do M11 em diante o compilador escreve o executável sozinho (`--exe`, apelido de
`--backend=macho-exe`, ver `docs/surface.md` § Tier 2 e `docs/macho-notes.md` § M11). A cadeia
inteira, do fonte ao compilador rodável, sem nenhum linker:

```
build/mc1 --exe src/mc.mc -o build/mc-exe       # o unico passo que ainda usa mc1 (que veio de ld)
build/mc-exe src/mc.mc -o x.o                   # ... e daqui em diante nada mais usa ld
build/mc-exe --exe src/mc.mc -o build/fix/mc-exe
```

Provas rodadas (saídas reais):

```
$ build/mc1 --exe src/mc.mc -o build/mc-exe && ls -la build/mc-exe
-rwxr-xr-x  1 schivei  staff  210835 build/mc-exe

$ build/mc-exe src/mc.mc -o tmp/x.o && cmp tmp/x.o build/mc2.o && echo identicos
identicos                       # o compilador sem ld gera o MESMO .o que o compilador com ld

$ build/mc-exe --exe src/mc.mc -o build/fix/mc-exe && cmp build/mc-exe build/fix/mc-exe
                                # sem saida: ponto fixo do executavel, byte a byte

$ scripts/test.sh build/mc-exe        # 32/32 (mc-exe compilando .o + ld)
$ scripts/test-exe.sh build/mc-exe    # 32/32 (mc-exe compilando executaveis, ld em lugar nenhum)
$ scripts/check-obj.sh build/mc1 build/mc-exe   # 32/32 objetos identicos
```

**O identificador da assinatura é o nome do arquivo de saída.** Por isso
`build/mc-exe --exe src/mc.mc -o build/mc-exe2` **não** produz bytes idênticos a `build/mc-exe`: o
identificador `mc-exe2` tem um caractere a mais que `mc-exe`, o que muda o tamanho do
`CS_CodeDirectory` e, por tabela, o `datasize` do `LC_CODE_SIGNATURE`, o `filesize` do
`__LINKEDIT`, o `LC_UUID` (que é hash do conteúdo) e os hashes de página. São exatamente 5 campos, e
`cmp -l` confirma que nenhum outro byte muda. Com o mesmo *basename* em outro diretório
(`-o build/fix/mc-exe`) o resultado é idêntico byte a byte — é essa a forma correta de testar o
ponto fixo do executável, e é o que o texto acima faz. A alternativa (identificador fixo) foi
descartada de propósito: `codesign -dvvv` mostrando `Identifier=mc-exe` é a mesma convenção do
`codesign` da Apple.

`scripts/test-exe.sh` (alvo `make test-exe`, incluído em `make check`) roda `tests/*.mc` inteiro por
esse caminho: compila com `--exe`, confere `codesign --verify` e compara exit code e stdout com o
cabeçalho de cada fonte — 32/32.

### Trade-off do `--exe`: símbolo indefinido só aparece no `dyld`

Os dois caminhos de saída falham em momentos diferentes quando um `extern` não existe em lugar
nenhum. Fonte usado nas duas execuções abaixo:

```
// faltante.mc
extern i64 nao_existe_mesmo(i64 x);

i64 main() {
    return nao_existe_mesmo(1);
}
```

O caminho `.o` + `ld` recusa **no link** — o `ld` resolve contra a `libSystem` e sabe dizer não:

```
$ build/mc1 faltante.mc -o faltante.o
$ echo $?
0
$ scripts/link.sh faltante faltante.o
Undefined symbols for architecture arm64:
  "_nao_existe_mesmo", referenced from:
      _main in faltante.o
ld: symbol(s) not found for architecture arm64
$ echo $?
1
```

O `--exe` **não tem como validar** isso: o backend `macho-exe` emite um stub `__TEXT,__stubs` +
uma entrada `__DATA,__got` com bind opcode para cada símbolo importado, e conferir se o nome existe
de verdade exigiria ler os `.tbd` do SDK (ou o próprio `/usr/lib/libSystem.B.dylib`) — dependência
externa que o M11 recusa por definição, já que o ponto do marco é não depender de mais nada além do
`dyld` em tempo de execução. O binário sai bem-formado e assinado; quem recusa é o `dyld`, no
carregamento:

```
$ build/mc1 --exe faltante.mc -o faltante-exe
$ echo $?
0
$ ls -l faltante-exe
-rwxr-xr-x  1 schivei  wheel  33289 faltante-exe
$ codesign --verify --verbose=4 faltante-exe
faltante-exe: valid on disk
faltante-exe: satisfies its Designated Requirement
$ ./faltante-exe
dyld[84421]: Symbol not found: _nao_existe_mesmo
  Referenced from: <CCEFFEF5-D25D-5C49-8593-D99D8433E7BA> .../faltante-exe
  Expected in:     <4FED5EE2-5D3E-35B1-A170-9859C4B683BB> /usr/lib/libSystem.B.dylib
$ echo $?
134
```

O exit 134 é o `SIGABRT` (128 + 6) com que o `dyld` mata o processo. Note que a assinatura ad-hoc
está correta e `codesign --verify` passa: assinatura e resolução de símbolos são coisas
independentes, e o `--exe` acerta a primeira sem opinar sobre a segunda.

**Decisão:** não há lista de símbolos conhecidos embutida no compilador. Uma tabela heurística de
nomes da `libSystem` daria falso negativo (símbolo que existe e não está na lista) e falso positivo
(símbolo na lista ausente na versão do SO em uso), e envelheceria a cada release do macOS — trocaria
um erro tardio e exato por um erro precoce e errado. Quem quiser a checagem em tempo de build tem o
caminho do `.o` + `ld`, que continua sendo o default (`--exe` é opt-in) e é o que `make test` e
`scripts/bootstrap.sh` usam.

**O `ld` continua sendo o caminho do bootstrap.** `scripts/bootstrap.sh` não mudou: o critério do
ponto fixo do M7 é sobre `.o`, e o `.o` continua sendo o formato de saída padrão. O `--exe` é uma
segunda saída, provada por `make test-exe` e pela cadeia acima, não uma substituição.

## Binários não são versionados

`.gitignore` já ignora `build/` (e `*.o`, `*.dSYM`) — `mc0`, `mc1`, `mc2`, `mc3` e todos os `.o`
intermediários são artefatos de build, nunca commitados. O único artefato do ponto fixo que é
versionado é o hash: `tests/golden/mc2.sha256` (ver `tests/golden/README.md`).

## Diagnóstico de divergência

Se `cmp build/mc2.o build/mc3.o` falhar (ou o SHA-256 divergir do golden sem que a mudança em
`src/*.mc` tenha sido proposital), o primeiro passo é comparar a saída textual determinística do
codegen em vez dos bytes do objeto:

```
diff <(build/mc1 --dump-asm src/mc.mc) <(build/mc2 --dump-asm src/mc.mc)
```

Isso localiza a primeira instrução/label onde os dois compiladores discordam. Dali, bissecte por
arquivo e depois por função:

1. Rode o mesmo `diff --dump-asm` isolando um `#include` por vez (`arena.mc`, depois `macho.mc`,
   `lex.mc`, `ast.mc`, `parse.mc`, `gen_arm64.mc`, `main.mc`) até achar qual arquivo diverge —
   compilar cada um sozinho reproduz o erro idêntico nos dois lados quando o arquivo em si é
   idêntico (é o que `scripts/check-asm.sh` já verifica para todo `src/*.mc`), então o arquivo que
   quebra ao ser incluído em `mc.mc` mas não sozinho aponta a interação certa.
2. Dentro do arquivo, comente/isole funções (ou rode `--dump-asm` num arquivo reduzido só com a
   função suspeita e suas dependências diretas) até isolar a função exata.
3. Causas usuais de divergência num ponto fixo autoral (não vistas aqui, mas é a lista de suspeitos
   de `docs/specs/M6-M7.md` § Determinismo): ordem de tabela/símbolo não estável, padding não
   zerado, leitura curta de arquivo, alguma dependência de estado não inicializado na arena.
