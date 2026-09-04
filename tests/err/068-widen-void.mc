// M31 (2.1): decl_ret answers TY_VOID and the module refuses to bind the
// result. This is exactly the case docs/specs/M31.md § 2.1 names: a naive
// version that does not read the declared return type dies with the core's
// `value of type void` instead, far from the declaration that caused it.
// Expected:
//
//   tests/err/068-widen-void.mc:11: widen: cannot bind the result of a void function: nothing
void nothing(i64 x) { }

i64 main() {
    widen v = nothing(1);
    return v;
}
