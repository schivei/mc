// conc.mc -- concurrency taught to `lx` from outside the compiler.
//
// This file is not compiled as a program: it is linked INSIDE a compiler
// (`mc build` writes `build/mc-conc.mc` = `#include <mc/core>` +
// `examples/lang/lang.mc` + this file) and runs during the parse of a `.lx`
// source. It stacks on the `lx` module of examples/lang, which stays exactly as
// it is except for one line -- `lg_more()`, the chain point at the end of its
// `user_init`, because a compiler may hold only one `user_init` and the stacked
// module needs somewhere to register from.
//
// What it teaches, all through public hooks:
//
//   spawn f(a);                  syntax_stmt   fire and forget, over the pool
//   intent x = f(a);             syntax_stmt   submitted eagerly, at the call
//   await x;  await r = x;       syntax_stmt   waits, or steals and runs inline
//   await r = f(a);              syntax_stmt   the intent is a temporary
//   lock (m) { ... }             syntax_stmt   + on_jump on every exit edge
//   chan                         type_alias    an alias of uptr
//   chan_recv(c)                 syntax_expr   marks the result already owned
//   {                            syntax_stmt   chained over the host's handler
//   conc_boot() at the top of main   pass       the LSE check
//
// Nothing about threads, channels, await or intents is in src/. The core gaps
// this milestone did need -- decl_find, on_jump and a written ABI contract --
// are generic mechanisms with no idea that concurrency exists
// (docs/specs/M31.md section 2).
//
// Read README.md for the language additions and the ownership convention.

#include "conc_tab.mc"
#include "conc_stmt.mc"

// The chain point examples/lang's user_init calls last. A compiler holds one
// user_init and examples/lang's is it; this is what a module stacked on top
// registers from, and examples/lang/lang_solo.mc is the empty default that
// keeps the `lx` example itself working with no module on top.
void lg_more() {
    cc_make_intent_class();

    // examples/lang owns `{` -- that is what makes its release happen per scope
    // -- so this registration REPLACES it in the lookup and calls it through
    // callp. syntax_stmt_find / syntax_stmt_fn_at are public exactly for this
    // (docs/specs/M31.md section 2.4, row 1).
    i64 k = syntax_stmt_find(K_LBRACE);
    if (k < 0) die2("conc: the host module must own", "{");
    cc_lang_block = syntax_stmt_fn_at(k);
    syntax_stmt("{", &cc_block);

    syntax_stmt("spawn",  &cc_spawn);
    syntax_stmt("intent", &cc_intent);
    syntax_stmt("await",  &cc_await);
    syntax_stmt("lock",   &cc_lock);

    // `chan` is a type; `intent` deliberately is NOT. Registering a word with
    // syntax_stmt and never with type_alias means it is not a type in any
    // grammar position, so a return type, a parameter, a field and a generic
    // argument reject it BY CONSTRUCTION rather than by a check that could be
    // forgotten (docs/surface.md, "Registration reserves the word for the whole
    // program").
    type_alias("chan", TY_UPTR);
    syntax_expr("chan_recv", &cc_recv);

    on_jump(&cc_on_jump);
    pass(&cc_pass_boot);
}
