// expect-exit: 0
// expect-stdout: 0 1 1 0 1 0 42 1 1 0
// i128 -- a 128-bit integer taught to `mc` by lib/i128.mc, with nothing in src/.
//
//   2^64-1 + 1        the carry crosses the halves: lo 0, hi 1
//   2^64 - 1          subtraction the other way (printed as a comparison: <io>'"'"'s
//                     putnum is signed and 2^64-1 is not a number it can print)
//   2^32 * 2^32       a multiply whose product lands entirely in the high half
//   a two-register callee, an ordinary local, a global, and the six comparisons
#include <sys>

// A GLOBAL of the taught type. It is not initialized here on purpose: an
// initializer at top level has to be a constant N_INT, and a 128-bit value is
// not one -- which is exactly why the literal handler puts its bytes in a
// module-private global with an N_BLOB initializer and hands back a load from
// it (docs/specs/M24.md, "two known holes, both with zero-line answers").
i128 g;

i128 add2(i128 x, i128 y) { return x + y; }

i64 main() {
    i128 one = 1i;
    g = 18446744073709551615i;            // 2^64 - 1, through the global
    i128 c = g + one;                     // 2^64
    putnum(i128_lo(c)); puts(" ");
    putnum(i128_hi(c)); puts(" ");
    i128 d = c - one;                     // back to 2^64 - 1
    putnum(i128_lo(d) == 0xffffffffffffffff); puts(" ");
    putnum(i128_hi(d)); puts(" ");
    i128 e = 4294967296i;                 // 2^32
    i128 f = e * e;                       // 2^64: lo 0, hi 1
    putnum(i128_hi(f)); puts(" ");
    putnum(i128_lo(f)); puts(" ");
    i128 s = add2(41i, 1i);               // a two-register callee
    putnum(i128_lo(s)); puts(" ");
    putnum(one < c); puts(" ");
    putnum(c > one); puts(" ");
    putnum(c == one); puts("\n");
    return 0;
}
