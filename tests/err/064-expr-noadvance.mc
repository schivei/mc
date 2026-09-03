// M21: the guard around a syntax_expr handler. `nop` is registered by
// lib/user_syntax_demo.mc with a handler that returns without consuming the
// word; without the guard parse_primary would call it again on the same token,
// forever. Expected:
//
//   tests/err/064-expr-noadvance.mc:7: syntax_expr handler consumed no tokens: nop
i64 main() { return nop; }
