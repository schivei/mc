// CASO DE ERRO — nao entra em scripts/test.sh (por isso mora em tests/err/).
// R_UNSIGNED e uma relocacao de 8 bytes (length 3): grudada numa palavra crua de
// 4 bytes ela passaria por cima da instrucao seguinte. O lugar certo para um
// endereco de 8 bytes e o inicializador de array global (ver tests/060-callp.mc).
//
// esperado: tests/err/062-reloc-unsigned.mc:10: reloc UNSIGNED exige 8 bytes: use inicializador de array global (exit 1)
extern i64 alvo();

i64 f() {
    reloc(UNSIGNED, "_alvo");
    emit(0x00000000);
}

i64 main() {
    return 0;
}
