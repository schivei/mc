// bundle.mc — the standard library carried inside the binary (M15,
// docs/specs/M15.md, docs/build.md § The bundle).
//
// `src/bundle_data.mc` is generated source (tools/bundle.mc): one blob with
// everything, plus one flat index with four values per entry. This file reads it:
//
//   bundle_find(name)                  exact name -> index, or -1
//   bundle_find_base(name)             last path component -> index, or -1
//   bundle_open(name, base, pc, pl)    the hook src/lex.mc calls
//   bundle_emit(...)                   writes a bundle_data.mc, byte for byte
//
// The blob is laid out as the NUL-terminated names first, in manifest order,
// and then each compressed stream. So a name is `bundle_blob + BI_NAME` and no
// string literal is needed for it — which matters: the frozen
// stage0/gen_arm64.c has MAXSTRS 512 and src/mc.mc was already at 489 before
// M15, so the bundle had to cost as close to zero literals as possible. The
// index is one array and not four for the same reason: every array header in
// the emitter below is one more literal in every compiler binary.
//
// `mc/bundle_data` is the one name that is not in the blob: the bundle cannot
// contain itself (its own bytes would change the bytes it contains). It gets
// index BUNDLE_COUNT and is REGENERATED on demand by bundle_emit from the
// arrays already in memory — which is why a compiler built from `<mc/core>`,
// whose core.mc does `#include "bundle_data.mc"`, comes out complete and
// byte-identical to one built from src/. scripts/check-standalone.sh proves it.
//
// Depends on arena.mc (xalloc, str_eq, cstrlen, buf_*, mem_copy), on lz.mc
// (lz_inflate) and on the arrays in bundle_data.mc. It does NOT depend on
// lex.mc: the lexer reaches this file only through the function pointer that
// main.mc registers, so src/lexdump.mc and src/astdump.mc stay bundle-free.

#define BUNDLE_MAX 128                // ceiling on BUNDLE_COUNT; tools/bundle.mc checks it

// bundle_idx: four i64 per entry, in this order
#define BI_NAME  0                    // offset of the name inside bundle_blob
#define BI_OFF   1                    // offset of the LZ stream inside bundle_blob
#define BI_CSIZE 2                    // bytes of the stream
#define BI_RSIZE 3                    // bytes of the file it expands to
#define BI_N     4

uptr bundle_cache[BUNDLE_MAX];        // inflated source, per index (0 = not yet)
i64  bundle_clen[BUNDLE_MAX];         // its length, without the NUL

i64  bd_at(uptr a, i64 i) { return ld64(a + i * 8); }
void bd_put(uptr b, uptr s) { buf_put(b, s, cstrlen(s)); }

i64 bundle_at(i64 i, i64 field) { return bd_at(bundle_idx, i * BI_N + field); }

// canonical name of an index; BUNDLE_COUNT is the regenerated bundle_data.mc
uptr bundle_cname(i64 i) {
    if (i == BUNDLE_COUNT) return "mc/bundle_data";
    return bundle_blob + bundle_at(i, BI_NAME);
}

// last path component (the bundle has no directories: `mc/lex` is one name)
uptr bd_base(uptr p) {
    i64 cut = 0;
    i64 i = 0;
    loop {
        if (ld8(p + i) == 0) break;
        if (ld8(p + i) == '/') cut = i + 1;
        i = i + 1;
    }
    return p + cut;
}

i64 bundle_find(uptr name) {
    i64 i = 0;
    loop {
        if (i > BUNDLE_COUNT) break;
        if (str_eq(bundle_cname(i), name)) return i;
        i = i + 1;
    }
    return -1;
}

// Fallback used only by a relative `#include "x"` INSIDE a bundled file: the
// bundle is flat, so `#include "../lib/prelude.mc"` written in mc/driver
// normalizes to `lib/prelude`, which is nobody's name. Comparing the last
// component finds `prelude`; the same rule sends `../src/core.mc` to `mc/core`.
// The manifest has no two entries with the same last component, and the scan
// is in manifest order, so the answer is deterministic.
i64 bundle_find_base(uptr name) {
    uptr b = bd_base(name);
    i64 i = 0;
    loop {
        if (i > BUNDLE_COUNT) break;
        if (str_eq(bd_base(bundle_cname(i)), b)) return i;
        i = i + 1;
    }
    return -1;
}

// ---- writing a bundle_data.mc ----
// Deliberately free of any dependency on the arrays above: tools/bundle.mc
// calls it with the arrays it has just built from the manifest, and
// bundle_gen_data() below calls it with the ones already compiled in. One
// emitter, one output — that is what makes `make bundle` reproducible and the
// regenerated `mc/bundle_data` identical to the checked-in file.
void bd_num(uptr b, i64 v) {
    u8 t[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(t + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    buf_put(b, t + i, 24 - i);
}

// n i64 values starting at p, `per` per line, each with its comma
void bd_list(uptr b, uptr p, i64 n, i64 per) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        bd_num(b, ld64(p + i * 8));
        buf_u8(b, ',');
        if (i % per == per - 1) buf_u8(b, '\n');
        i = i + 1;
    }
    if (n % per != 0) buf_u8(b, '\n');
}

// 0x + 16 hex digits. Hexadecimal, not decimal: an element with the high bit
// set is >= 2^63 and out_num-style decimal would need an unsigned divide, which
// the codegen does not emit (see the NOTE in arena.mc). Fixed width also keeps
// the generated file diffable.
void bd_hex(uptr b, i64 v) {
    buf_u8(b, '0');
    buf_u8(b, 'x');
    i64 i = 60;
    loop {
        buf_u8(b, ld8("0123456789abcdef" + ((v >> i) & 15)));
        if (i == 0) break;
        i = i - 4;
    }
}

// The blob as u64 elements, 8 bytes each in little-endian order -- which is
// exactly how glob_place writes them, so the array reads back byte for byte as
// the original sequence. The reason it is not `u8 x[] = {1,2,3,...}`: the
// parser makes ONE AST node per initializer element, and the frozen stage0 has
// a 32 MiB arena with 72-byte nodes. A 133 KB blob as bytes needs ~133k nodes
// and blows it; as u64 it needs ~17k. Trailing bytes of the last element are
// zero and nobody reads them: the sizes come from bundle_idx.
void bd_blob(uptr b, uptr p, i64 n) {
    i64 nel = (n + 7) / 8;
    i64 i = 0;
    loop {
        if (i >= nel) break;
        i64 v = 0;
        i64 k = 0;
        loop {
            if (k >= 8) break;
            i64 o = i * 8 + k;
            if (o < n) v = v | (ld8(p + o) << (k * 8));
            k = k + 1;
        }
        bd_hex(b, v);
        buf_u8(b, ',');
        if (i % 6 == 5) buf_u8(b, '\n');
        i = i + 1;
    }
    if (nel % 6 != 0) buf_u8(b, '\n');
}

void bundle_emit(uptr b, uptr blob, i64 blen, uptr idx, i64 count) {
    bd_put(b, "// generated by tools/bundle.mc from tools/bundle.list -- do not edit.\n// bundle_blob: the NUL-terminated names, then the LZ streams; 8 bytes per u64.\n// bundle_idx: four values per entry -- name offset, stream offset, csize, rsize.\nu64 bundle_blob[] = {\n");
    bd_blob(b, blob, blen);
    bd_put(b, "};\ni64 bundle_idx[] = {\n");
    bd_list(b, idx, count * BI_N, BI_N);
    bd_put(b, "};\n#define BUNDLE_COUNT ");
    bd_num(b, count);
    buf_u8(b, '\n');
}

// the blob ends where the last stream ends: no extra #define is needed
i64 bundle_blob_size() {
    if (BUNDLE_COUNT == 0) return 0;
    return bundle_at(BUNDLE_COUNT - 1, BI_OFF) + bundle_at(BUNDLE_COUNT - 1, BI_CSIZE);
}

uptr bundle_gen_data(uptr plen) {
    u8 b[BUF_SIZE];
    buf_init(b);
    bundle_emit(b, bundle_blob, bundle_blob_size(), bundle_idx, BUNDLE_COUNT);
    buf_u8(b, 0);                              // sentinel; the length excludes it
    st64(plen, buf_len(b) - 1);
    return buf_p(b);
}

// ---- reading ----
// inflated once and kept: a taught compiler includes mc/arena once, but a
// second `#include` of the same name must not pay for the inflate again.
uptr bundle_read(i64 i, uptr plen) {
    uptr c = ld64(bundle_cache + i * 8);
    if (c != 0) {
        st64(plen, ld64(bundle_clen + i * 8));
        return c;
    }
    i64 len = 0;
    uptr d = 0;
    if (i == BUNDLE_COUNT) {
        d = bundle_gen_data(&len);
    } else {
        len = bundle_at(i, BI_RSIZE);
        d = xalloc(len + 1);
        if (lz_inflate(bundle_blob + bundle_at(i, BI_OFF), bundle_at(i, BI_CSIZE), d, len) != len)
            die2("read error", bundle_cname(i));   // only if the binary itself is damaged
        st8(d + len, 0);
    }
    st64(bundle_cache + i * 8, d);
    st64(bundle_clen + i * 8, len);
    st64(plen, len);
    return d;
}

// The hook src/lex.mc holds a pointer to. `base` = 1 allows the last-component
// fallback (a relative include inside a bundled file); `pcanon` receives the
// canonical name, which is what goes into the once-only list and into error
// messages. Returns 0 when the name is not in the bundle.
uptr bundle_open(uptr name, i64 base, uptr pcanon, uptr plen) {
    i64 i = bundle_find(name);
    if (i < 0 && base) i = bundle_find_base(name);
    if (i < 0) return 0;
    st64(pcanon, bundle_cname(i));
    return bundle_read(i, plen);
}
