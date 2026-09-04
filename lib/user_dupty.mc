// user_dupty.mc — a user_init that tries to register a TYPE named after a core
// keyword. type_new goes through word_add, exactly as type_alias, syntax,
// syntax_stmt, syntax_expr and syntax_infix do, so the refusal is the same one
// and it happens at user_init time, before a single token of the program is
// read. scripts/check-surface.sh wires this file in and checks the message.
void user_init() {
    type_new("if", 8, 8, TK_INT);
}
