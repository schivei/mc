// user_param_nop.mc — a module whose only registration is syntax_param, and
// whose handler answers 0 for every parameter: "not mine, the core reads this
// one".
//
// It is the M41.5 inertness fixture, the same shape lib/user_lit_nop.mc is for
// syntax_lit and lib/user_tokadd.mc is for tok_add: a compiler that consults
// the hook at every parameter of every function of every program has to produce
// exactly the tree, and exactly the object, that a compiler without the hook
// produces. 0 is not "no handler registered" -- the callp happens -- it is the
// handler declining.
i64 pn_param() { return 0; }

void user_init() {
    syntax_param(&pn_param);
}
