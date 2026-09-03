// 056-gensym-nocapture.mc — #rule's gensym cannot capture a user name.
// The rule declares `$$t` in the SAME block as its caller (the template does
// not open a `{ }`), so the hidden local shares scope with main's locals.
// Before M10 the gensym was called `__g1` and the expansion would steal the
// user's `__g1`, making this test return 1; today it is called `$g1` and the
// collision is impossible (the lexer never forms an identifier with `$`).
// expect-exit: 42

#rule stmt: mk ( expr $v ) ;
    => i64 $$t = $v;

i64 main() {
    i64 __g1 = 42;
    mk(1);                 // declares a hidden local, with no block of its own
    return __g1;           // must still be 42
}
