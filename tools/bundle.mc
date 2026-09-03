// bundle.mc — regenerates src/bundle_data.mc from tools/bundle.list (M15).
//
//   make bundle                    # the normal way
//   build/mc1 --exe tools/bundle.mc -o build/bundle
//   build/bundle tools/bundle.list src/bundle_data.mc
//
// The manifest is one `NAME <TAB> PATH` per line, sorted by name; `#` starts a
// comment line. The output is written by bundle_emit, in src/bundle.mc — the
// SAME function the compiler uses to regenerate `mc/bundle_data` on the fly, so
// there is exactly one definition of the format and the two can never drift.
//
// Reproducibility: everything here is a function of the manifest and of the
// bytes of the files it names. lz_deflate is deterministic (see src/lz.mc), the
// blob is laid out in manifest order, and no path, date or address reaches the
// output. `make check` regenerates into a temporary file and `cmp`s it against
// the checked-in one — twice, so a run-to-run difference would show up too.
//
// This tool is compiled against the CHECKED-IN src/bundle_data.mc (it includes
// src/bundle.mc for bundle_emit, and that file reads those arrays). It never
// looks at them: what it writes comes from the manifest alone. That is what
// makes the generator self-hosting after the first bootstrap.
#include "../src/arena.mc"
#include "../src/lz.mc"
#include "../src/bundle_data.mc"
#include "../src/bundle.mc"

// M23 removed every MAX* from src/, including src/bundle.mc's BUNDLE_MAX (the
// cache there is now sized by the generated BUNDLE_COUNT itself). This is a
// build tool, not the compiler: the manifest is a checked-in file with 30 lines,
// so the ceiling stays here, where it is also the error message.
#define BUNDLE_MAX 128

i64  bl_idx[BUNDLE_MAX * BI_N];
uptr bl_name[BUNDLE_MAX];
uptr bl_path[BUNDLE_MAX];
i64  bl_count = 0;

void bl_set(i64 i, i64 field, i64 v) { st64(bl_idx + (i * BI_N + field) * 8, v); }
uptr bl_name_at(i64 i) { return ld64(bl_name + i * 8); }
uptr bl_path_at(i64 i) { return ld64(bl_path + i * 8); }

// a < b as byte strings
i64 bl_lt(uptr a, uptr b) {
    i64 i = 0;
    loop {
        i64 x = ld8(a + i);
        i64 y = ld8(b + i);
        if (x != y) return x < y;
        if (x == 0) return 0;
        i = i + 1;
    }
    return 0;
}

// one manifest line: NAME <TAB> PATH
void bl_line(uptr s, i64 l) {
    i64 t = 0;
    loop {
        if (t >= l) break;
        if (ld8(s + t) == '\t') break;
        t = t + 1;
    }
    if (t >= l || t == 0) die2("manifest line without NAME<TAB>PATH", xstrdup(s, l));
    i64 p = t;
    loop {
        if (p >= l) break;
        if (ld8(s + p) != '\t' && ld8(s + p) != ' ') break;
        p = p + 1;
    }
    if (p >= l) die2("manifest line without a path", xstrdup(s, l));
    if (bl_count == BUNDLE_MAX) die("manifest larger than BUNDLE_MAX");
    st64(bl_name + bl_count * 8, xstrdup(s, t));
    st64(bl_path + bl_count * 8, xstrdup(s + p, l - p));
    bl_count = bl_count + 1;
}

void bl_load(uptr list) {
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
        if (l == 0) continue;
        if (ld8(s + b) == '#') continue;
        bl_line(s + b, l);
    }
    if (bl_count == 0) die2("empty manifest", list);
}

// The three invariants src/bundle.mc depends on: sorted and unique names (so
// the file is a stable, reviewable artifact), no `mc/bundle_data` (the bundle
// cannot contain itself), and no two entries sharing a last component (that is
// what makes bundle_find_base unambiguous).
void bl_verify() {
    i64 i = 0;
    loop {
        if (i >= bl_count) break;
        uptr n = bl_name_at(i);
        if (str_eq(n, "mc/bundle_data")) die("mc/bundle_data cannot be in the manifest");
        if (i > 0 && !bl_lt(bl_name_at(i - 1), n)) die2("manifest not sorted or has a duplicate", n);
        i64 k = 0;
        loop {
            if (k >= i) break;
            if (str_eq(bd_base(bl_name_at(k)), bd_base(n)))
                die2("two entries with the same last component", n);
            k = k + 1;
        }
        i = i + 1;
    }
}

void bl_report(uptr name, i64 raw, i64 c) {
    out_str(1, "  ");
    out_str(1, name);
    i64 pad = 20 - cstrlen(name);
    loop {
        if (pad <= 0) break;
        out_str(1, " ");
        pad = pad - 1;
    }
    out_num(1, raw);
    out_str(1, " -> ");
    out_num(1, c);
    out_str(1, "\n");
}

i64 main(i64 argc, uptr argv) {
    if (argc < 3) {
        out_str(2, "usage: bundle MANIFEST OUT.mc\n");
        return 1;
    }
    uptr list = ld64(argv + 8);
    uptr out = ld64(argv + 16);
    bl_load(list);
    bl_verify();

    u8 blob[BUF_SIZE];
    buf_init(blob);
    i64 i = 0;
    loop {                                     // the names first, NUL-terminated
        if (i >= bl_count) break;
        bl_set(i, BI_NAME, buf_len(blob));
        buf_put(blob, bl_name_at(i), cstrlen(bl_name_at(i)) + 1);
        i = i + 1;
    }
    i64 total_raw = 0;
    i64 total_c = 0;
    i = 0;
    loop {                                     // then each compressed stream
        if (i >= bl_count) break;
        i64 raw = 0;
        uptr data = read_file(bl_path_at(i), &raw);
        uptr enc = xalloc(lz_bound(raw) + 16);
        i64 c = lz_deflate(data, raw, enc);
        bl_set(i, BI_OFF, buf_len(blob));
        buf_put(blob, enc, c);
        bl_set(i, BI_CSIZE, c);
        bl_set(i, BI_RSIZE, raw);
        bl_report(bl_name_at(i), raw, c);
        total_raw = total_raw + raw;
        total_c = total_c + c;
        i = i + 1;
    }

    u8 b[BUF_SIZE];
    buf_init(b);
    bundle_emit(b, buf_p(blob), buf_len(blob), bl_idx, bl_count);
    write_file(out, b);

    out_str(1, "bundle: ");
    out_num(1, bl_count);
    out_str(1, " files, raw ");
    out_num(1, total_raw);
    out_str(1, " -> lz ");
    out_num(1, total_c);
    out_str(1, ", blob ");
    out_num(1, buf_len(blob));
    out_str(1, " bytes, ");
    out_str(1, out);
    out_str(1, " ");
    out_num(1, buf_len(b));
    out_str(1, " bytes\n");
    return 0;
}
