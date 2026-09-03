// expect-exit: 42
// expect-stdout: 10,7,8,7,
// Compound operators from the prelude: `+=`, `-=`, `++`, `--`. They are four
// #rule with the pattern `ident $x OP ... ;` — the name was already read as an
// expression by the time the compound token appears, so dispatch is still by
// literal token.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

i64 g = 0;                            // global: += works for it too

i64 main() {
    i64 x = 4;
    x += 6;
    putnum(x);  write(1, ",", 1);     // 10
    x -= 3;
    putnum(x);  write(1, ",", 1);     // 7
    x++;
    putnum(x);  write(1, ",", 1);     // 8
    x--;
    putnum(x);  write(1, ",", 1);     // 7

    g += 5;
    g++;
    // += with a whole expression on the right-hand side, not just a constant
    i64 y = 0;
    y += x * 5 - 1;                   // 34
    return y + g + 2;                 // 34 + 6 + 2 = 42
}
