// ERROR CASE — not part of scripts/test.sh (that is why it lives in tests/err/).
// R_UNSIGNED is an 8-byte relocation (length 3): stuck onto a raw 4-byte word
// it would overrun the next instruction. The right place for an 8-byte
// address is a global array initializer (see tests/060-callp.mc).
//
// expected: tests/err/062-reloc-unsigned.mc:10: reloc UNSIGNED requires 8 bytes: use a global array initializer (exit 1)
extern i64 target();

i64 f() {
    reloc(UNSIGNED, "_target");
    emit(0x00000000);
}

i64 main() {
    return 0;
}
