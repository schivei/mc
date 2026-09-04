// expect-exit: 0
// expect-stdout: 15360 15362 15361 1065353216 15360
// f16 -- half precision as a STORAGE type, taught by lib/f16.mc on top of
// <float>, with nothing in src/.
//
// The first three columns are the case where round-to-nearest-TIES-TO-EVEN
// bites. 1 + 2^-11 (the f32 bits 0x3f801000) is exactly halfway between the
// halves 0x3c00 = 15360 and 0x3c01 = 15361, and goes to the EVEN one; 1 + 3*2^-12
// (0x3f803000) is halfway between 0x3c01 and 0x3c02 = 15362 and goes to 15362;
// 1 + 2^-10 (0x3f802000) is exact and stays 15361. A round-half-UP conversion
// would answer 15361 to the first, so the number itself is the assertion.
//
// The fourth is the round trip back to f32 (1.0 = 0x3f800000 = 1065353216) and
// the fifth reads a half back out of the eighth element of a global array --
// which is only at offset 14 because type_new said the width is 2.
#include <sys>
#include <float_rt>

f16 tbl[8];

f32 bits32(u64 b) { u64 r[1]; st64(r, b); return ldf32(r); }
u64 half(f16 h)   { u64 r[1]; st64(r, 0); stf16(r, h); return ld64(r); }

i64 main() {
    putnum(half(f32_to_f16(bits32(0x3f801000)))); puts(" ");
    putnum(half(f32_to_f16(bits32(0x3f803000)))); puts(" ");
    putnum(half(f32_to_f16(bits32(0x3f802000)))); puts(" ");
    u64 r[1];
    st64(r, 0);
    stf32(r, f16_to_f32(f32_to_f16(bits32(0x3f800000))));
    putnum(ld64(r)); puts(" ");
    stf16(tbl + 14, f32_to_f16(bits32(0x3f800000)));
    putnum(half(ldf16(tbl + 14))); puts("\n");
    return 0;
}
