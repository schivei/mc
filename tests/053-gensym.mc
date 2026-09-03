// expect-exit: 42
// expect-stdout: 3,7,7,3,
// Gensym: `$$t` in the template becomes a new local (__g1, __g2, ...) on
// each expansion. The rule below is used TWICE in the same block: if the
// name were fixed, the second declaration would collide with the first.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

#rule stmt: swap ( ident $a , ident $b ) ;
    => { i64 $$t = $a; $a = $b; $b = $$t; }

i64 main() {
    i64 p = 7;
    i64 q = 3;
    swap(p, q);
    putnum(p);  write(1, ",", 1);     // 3
    putnum(q);  write(1, ",", 1);     // 7

    swap(p, q);                       // second expansion in the same block
    putnum(p);  write(1, ",", 1);     // 7
    putnum(q);  write(1, ",", 1);     // 3

    return p * 6;                     // 42
}
