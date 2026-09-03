// expect-exit: 42
// expect-stdout: 3,7,7,3,
// Gensym: `$$t` no template vira um local novo (__g1, __g2, ...) a cada
// expansao. A regra abaixo e usada DUAS vezes no mesmo bloco: se o nome fosse
// fixo, a segunda declaracao colidiria com a primeira.
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

    swap(p, q);                       // segunda expansao no mesmo bloco
    putnum(p);  write(1, ",", 1);     // 7
    putnum(q);  write(1, ",", 1);     // 3

    return p * 6;                     // 42
}
