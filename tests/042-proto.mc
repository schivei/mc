// expect-exit: 0
// expect-stdout: 42
// Prototype: `type name(params);` at the top registers the signature; the
// definition comes later and must match the return type and arity. A
// prototype with neither a definition nor extern is an error at the end of
// the unit.
#include "../lib/sys.mc"

i64  sum(i64 a, i64 b);         // used before it is defined
void show(i64 v);
i64  double(i64 x);             // defined after whoever calls it

i64 main() {
    show(sum(double(20), 2));
    return 0;
}

i64 sum(i64 a, i64 b) { return a + b; }

i64 double(i64 x) { return x + x; }

void show(i64 v) {
    putnum(v);
    write(1, "\n", 1);
}
