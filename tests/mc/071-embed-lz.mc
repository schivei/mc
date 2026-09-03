// expect-exit: 42
// The same file embedded twice: raw and with `lz`. The program inflates the
// compressed copy with <lz> and compares it byte for byte against the raw one.
// `#include <lz>` is enough on its own -- src/lz.mc has no dependencies.
#include <sys>
#include <lz>

#embed plain "071-data.txt"
#embed packed "071-data.txt" lz

u8 out[8192];

i64 main() {
    if (plain_size != plain_raw) return 1;          // raw: size == original
    if (packed_raw != plain_raw) return 2;          // lz: _raw is still the original
    if (packed_size >= packed_raw) return 3;        // and it really compressed
    i64 n = lz_inflate(packed, packed_size, out, packed_raw);
    if (n != packed_raw) return 4;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(out + i) != ld8(plain + i)) return 5;
        i = i + 1;
    }
    return 42;
}
