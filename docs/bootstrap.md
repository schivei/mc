# bootstrap.md — M8: cortar o cordão

Este documento descreve `scripts/bootstrap.sh` (M7, ponto fixo) e o estado de M8 (o compilador
deixa de depender de `clang` para qualquer coisa além do primeiro estágio). Leia `docs/plan.md`
§ Marcos e `docs/specs/M6-M7.md` § M7 antes deste texto — aqui só se documenta o que já está feito.

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
permanece permitido depois (M11 é o marco que eventualmente escreve `MH_EXECUTE` direto e elimina
até essa dependência — fora de escopo aqui).

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
