// expect-exit: 42
// Ensina um lexema novo e um operador infixo com template.
#token "<+>"
#infix "<+>" 9 left ($1 + $2) * 2
i64 main() { return 10 <+> 11; }
