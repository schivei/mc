// expect-exit: 42
// reloc(TIPO, "simbolo") pendura a relocacao na proxima palavra emitida; aqui a
// palavra e um bl cru. O bl mora sozinho numa funcao so-emit: assim o x30 que ele
// destroi ja esta salvo no frame dela e o chamador nao ve diferenca nenhuma.

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
