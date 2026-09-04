// M31 (2.1): `widen` asks the core for the callee's declaration through
// decl_find, so a name the parser has not seen declared is refused by the
// MODULE, with its own message and position, instead of failing much later at
// lowering with `unknown function`. Expected:
//
//   tests/err/067-widen-unknown.mc:8: widen: unknown function: nosuch
i64 main() {
    widen v = nosuch(1);
    return v;
}
