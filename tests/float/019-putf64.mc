// expect-exit: 0
// expect-stdout: 3.500 -1.25 0 0.333 3.14159 inf -inf nan
// putf64 is a FIXED-PRECISION formatter, half-up at the requested number of
// digits, and says so: it is not Ryu and makes no shortest-representation claim.
// nan and the two infinities are recognised by bit pattern before any arithmetic
// happens. It is pushed into the program as a second source by the module
// (p_push_source), so it is not a core function and not a library the program
// links against.
#include <sys>
#include <float_rt>

i64 main() {
    putf64(3.5, 3);          puts(" ");
    putf64(-1.25, 2);        puts(" ");
    putf64(0.4, 0);          puts(" ");
    putf64(1.0 / 3.0, 3);    puts(" ");
    putf64(3.14159265358979, 5); puts(" ");
    putf64((f64) (f64raw) 0x7ff0000000000000, 1); puts(" ");
    putf64((f64) (f64raw) 0xfff0000000000000, 1); puts(" ");
    putf64((f64) (f64raw) 0x7ff8000000000000, 1); puts("\n");
    return 0;
}
