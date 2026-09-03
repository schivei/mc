# golden

`mc2.sha256` e o SHA-256 de referencia de `build/mc2.o` (saida de `build/mc1 src/mc.mc`), gerado por `scripts/bootstrap.sh` — a prova versionada do ponto fixo do M7.
So atualize este arquivo quando `src/*.mc` ou o codegen mudarem **de proposito**.
Antes de regravar, revise o diff de `--dump-asm` entre a versao antiga e a nova para confirmar que a mudanca e a esperada, nao uma regressao.
Para regravar: apague o arquivo e rode `make bootstrap` de novo.
