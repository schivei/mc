// expect-exit: 42
// reloc(TYPE, "symbol") hangs the relocation on the next word emitted; here the
// word is a raw bl. The bl lives alone in an emit-only function: that way the x30
// it clobbers is already saved in its frame and the caller sees no difference at all.

i64 helper() {
    return 42;
}

i64 call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);
}

i64 main() {
    return call_helper();
}
