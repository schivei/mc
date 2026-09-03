// lz_test.mc — round-trip test for src/lz.mc, outside the compiler (M15).
//
//   build/mc1 --exe tools/lz_test.mc -o build/lz_test
//   build/lz_test tools/bundle.list
//
// Two batteries:
//   1. synthetic buffers built by a deterministic LCG — pure random bytes (the
//      worst case for LZ, where the output has to grow by at most 1/128), runs
//      of a single byte, a small alphabet, and a repeating pattern;
//   2. every file named by the manifest given in argv[1], read from disk.
//
// For each buffer: deflate, inflate, compare byte by byte against the original
// and check the returned size. Any divergence prints the case and exits 1.
// Exit 0 means every case round-tripped.
#include "../src/arena.mc"
#include "../src/lz.mc"

#define LT_MAX (1 << 20)              // largest synthetic buffer

u8 lt_src[LT_MAX];
u8 lt_out[LT_MAX];
i64 lt_cases = 0;

// the core has no local array initializer: the sizes live in a global
i64 lt_sizes[6] = {0, 1, 2, 511, 65537, 262144};

u64 lt_seed = 0;

// LCG: the same constants as the classic PCG, taken modulo 2^64 by the i64
// multiply. Deterministic, which is the point — a failure is reproducible.
i64 lt_rand() {
    lt_seed = lt_seed * 6364136223846793005 + 1442695040888963407;
    return (lt_seed >> 33) & 255;
}

void lt_fail(uptr what, i64 n, i64 at) {
    out_str(2, "FAIL ");
    out_str(2, what);
    out_str(2, " n=");
    out_num(2, n);
    out_str(2, " at=");
    out_num(2, at);
    out_str(2, "\n");
    _exit(1);
}

// deflate + inflate + compare; prints one line per case
void lt_check(uptr what, uptr src, i64 n) {
    uptr enc = xalloc(lz_bound(n) + 16);
    i64 c = lz_deflate(src, n, enc);
    if (c > lz_bound(n)) lt_fail(what, n, c);
    i64 r = lz_inflate(enc, c, lt_out, n);
    if (r != n) lt_fail(what, n, r);
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(lt_out + i) != ld8(src + i)) lt_fail(what, n, i);
        i = i + 1;
    }
    lt_cases = lt_cases + 1;
    out_str(1, "ok ");
    out_str(1, what);
    out_str(1, " raw=");
    out_num(1, n);
    out_str(1, " lz=");
    out_num(1, c);
    out_str(1, "\n");
}

// fills lt_src with n bytes; kind 0 = random, 1 = constant, 2 = 4-letter
// alphabet, 3 = 37-byte repeating pattern
void lt_fill(i64 kind, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 v = 0;
        if (kind == 0)      v = lt_rand();
        else if (kind == 1) v = 65;
        else if (kind == 2) v = 97 + (lt_rand() & 3);
        else                v = 32 + i % 37;
        st8(lt_src + i, v);
        i = i + 1;
    }
}

uptr lt_kind_name(i64 kind) {
    if (kind == 0) return "random";
    if (kind == 1) return "constant";
    if (kind == 2) return "alphabet4";
    return "pattern37";
}

// one line of the manifest: NAME <TAB> PATH. Returns the path, in the arena.
uptr lt_path(uptr line, i64 len) {
    i64 i = 0;
    loop {
        if (i >= len) break;
        if (ld8(line + i) == '\t') break;
        i = i + 1;
    }
    loop {
        if (i >= len) break;
        if (ld8(line + i) != '\t' && ld8(line + i) != ' ') break;
        i = i + 1;
    }
    return xstrdup(line + i, len - i);
}

// every file of the manifest, read from disk and round-tripped
void lt_manifest(uptr list) {
    i64 len = 0;
    uptr s = read_file(list, &len);
    i64 i = 0;
    loop {
        if (i >= len) break;
        i64 b = i;
        loop {
            if (i >= len) break;
            if (ld8(s + i) == '\n') break;
            i = i + 1;
        }
        i64 l = i - b;
        i = i + 1;
        if (l == 0 || ld8(s + b) == '#') continue;
        uptr path = lt_path(s + b, l);
        i64 flen = 0;
        uptr data = read_file(path, &flen);
        lt_check(path, data, flen);
    }
}

i64 main(i64 argc, uptr argv) {
    i64 kind = 0;
    loop {
        if (kind > 3) break;
        i64 k = 0;
        loop {
            if (k >= 6) break;
            i64 n = ld64(lt_sizes + k * 8);
            lt_fill(kind, n);
            lt_check(lt_kind_name(kind), lt_src, n);
            k = k + 1;
        }
        kind = kind + 1;
    }
    if (argc >= 2) lt_manifest(ld64(argv + 8));
    out_str(1, "lz round trip: ");
    out_num(1, lt_cases);
    out_str(1, " cases ok\n");
    return 0;
}
