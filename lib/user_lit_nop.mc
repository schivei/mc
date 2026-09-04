// user_lit_nop.mc — a module whose only registration is syntax_lit, and whose
// handler answers 0 for every literal: "not mine, the core handles this one".
//
// It exists to prove the M24 inertness shape the way lib/user_tokadd.mc proves
// the M11 one: a compiler that consults the hook on every numeric literal of
// every program has to produce exactly the tree, and exactly the object, that a
// compiler without the hook produces. 0 is not "no handler registered" -- the
// callp happens -- it is the handler declining.
i64 ln_lit() { return 0; }

void user_init() {
    syntax_lit(&ln_lit);
}
