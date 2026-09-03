// expect-exit: 42
// #opcode teaches an instruction: the constant arguments go into the
// template, which is folded and becomes a raw word. The function has no
// return — the epilogue does not touch x0, so the return value is whatever
// the encoder left there.

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
