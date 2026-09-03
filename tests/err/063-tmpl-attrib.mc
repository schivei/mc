// M21: error attribution through the name of the pushed source. The body of
// `slot` is recorded, not parsed, so `N` only reaches parse_dim at the
// instantiation — and there it is 0. The error is reported inside the frame
// the module named, which is what puts "instantiated from" in front of it:
//
//   slot__i64__0 instantiated from tests/err/063-tmpl-attrib.mc:15:2: array size must be a positive constant
//
// Compiled by build/mc-syntax-demo (lib/user_syntax_demo.mc), never by the
// default compiler. Out of scripts/test.sh, like 055 and 062.
tmpl slot<T, N> {
    T cells[N];
    return N;
}

make slot<i64, 0>;

i64 main() { return 0; }
