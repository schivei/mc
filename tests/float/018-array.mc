// expect-exit: 0
// expect-stdout: 0x3ff8000000000000 0x4004000000000000 0x4010000000000000 0x4014000000000000
// An array of f64, global and initialized. Nothing in any object writer knows
// what a float is: the literal is an ordinary N_INT carrying the bit pattern, so
// parse_initlist accepts it and glob_place writes type_width bytes of it into
// __data -- which is the whole reason docs/specs/M24.md insisted the taught
// literal be an N_INT and not a node kind of its own.
//
// Element access is ldf64/stf64, two of the eight intrinsics <float> registers:
// `a[i]` is not part of what type_new gives, and the module says so plainly.
#include <sys>
#include <float_rt>

f64 tbl[] = { 1.5, 2.5 };
f64 out[2];

i64 main() {
    puthexf(ldf64(tbl));          puts(" ");
    puthexf(ldf64(tbl + 8));      puts(" ");
    stf64(out, ldf64(tbl) + ldf64(tbl + 8));
    stf64(out + 8, ldf64(out) + 1.0);
    puthexf(ldf64(out));          puts(" ");
    puthexf(ldf64(out + 8));      puts("\n");
    return 0;
}
