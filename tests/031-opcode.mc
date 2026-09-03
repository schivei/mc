// expect-exit: 42
// #opcode ensina uma instrucao: os argumentos constantes entram no template,
// que e dobrado e vira uma palavra crua. A funcao nao tem return — o epilogo
// nao toca x0, entao o valor de retorno e o que o encoder deixou la.

#opcode movz(rd, imm) 0xD2800000 | (imm << 5) | rd
#opcode addi(rd, rn, imm) 0x91000000 | (imm << 10) | (rn << 5) | rd

#define ANSWER 40

i64 answer() {
    movz(0, ANSWER);        // movz x0, #40
    addi(0, 0, 2);          // add  x0, x0, #2
}

i64 main() {
    return answer();
}
