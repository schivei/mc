// M21: the second guard. `nil` consumes its word and returns 0 — and an
// expression position has no empty node to fall back on (a syntax_stmt may
// return 0 and get an empty block). Expected:
//
//   tests/err/065-expr-nonode.mc:6: syntax_expr handler produced no expression: nil
i64 main() { return nil; }
