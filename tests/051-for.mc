// expect-exit: 30
// expect-stdout: 45,20,
// for from the prelude: `{ init loop { if (!cond) break; body step; } }`.
// The step sits at the END of the body, so `continue` skips the step — same
// as would happen writing the loop by hand. That is the price of not having
// a step label; the second loop below shows the consequence and the workaround.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

i64 main() {
    i64 s = 0;
    for (i64 i = 0; i < 10; i = i + 1) {
        s = s + i;
    }
    putnum(s);                        // 45
    write(1, ",", 1);

    // continue skips the step: whoever exits via continue has to touch the
    // counter beforehand, or the loop does not advance. Here the continue comes
    // after the manual increment, so the loop still progresses and the sum skips
    // the odd numbers.
    i64 t = 0;
    i64 k = 0;
    for (k = 0; k < 10; k = k + 1) {
        if (k % 2) { k = k + 1; continue; }   // skips the step: k advances by hand
        t = t + k;
    }
    putnum(t);                        // 0+2+4+6+8 = 20
    write(1, ",", 1);

    // nested for: each expansion generates its own loop, with no interference
    i64 n = 0;
    for (i64 a = 0; a < 3; a = a + 1) {
        for (i64 b = 0; b < 4; b = b + 1) {
            n = n + 1;
        }
    }
    return n + 18;                    // 12 + 18 = 30
}
