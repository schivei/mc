// expect-exit: 42
// Teaches a new lexeme and an infix operator with a template.
#token "<+>"
#infix "<+>" 9 left ($1 + $2) * 2
i64 main() { return 10 <+> 11; }
