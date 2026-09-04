// M31 (2.1): decl_nparams gives the arity the parser recorded, so the argument
// count is checked at the use site, at parse time. Expected:
//
//   tests/err/069-widen-arity.mc:8: widen: wrong number of arguments: two
i64 two(i64 a, i64 b) { return a + b; }

i64 main() {
    widen v = two(1);
    return v;
}
