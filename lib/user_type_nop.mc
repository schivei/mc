// user_type_nop.mc — a module whose only registration is syntax_type, and whose
// handler answers 0 for every type word of every declaration: "not mine, the
// core keeps the type it read".
//
// It is the inertness fixture for the type position, the same shape
// lib/user_param_nop.mc is for syntax_param and lib/user_lit_nop.mc is for
// syntax_lit: a compiler that consults the hook at every one of the six places
// the core reads a type -- p_type(), a local, a cast, a parameter, an `extern`
// and a top-level declaration -- has to produce exactly the tree, and exactly
// the object, that a compiler without the hook produces. 0 is not "no handler
// registered" (the callp happens); it is the handler declining.
i64 tn_type(i64 ty) { return 0; }

void user_init() {
    syntax_type(&tn_type);
}
