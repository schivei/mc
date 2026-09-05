// toml.mc — the TOML subset `mc build` reads (M14, docs/specs/M14.md).
//
// What it accepts, and nothing else:
//
//   # comment                         to the end of the line
//   [table]                           sets the prefix for the keys that follow
//   [[array.of.tables]]               same, with an occurrence index in the prefix
//   key = value                       bare key (A-Za-z0-9_-), quoted key, or dotted
//   "quoted key" = value              (a key with `*` has to be quoted; a key
//                                     containing `.` is an error -- see tm_key1)
//   value: "string"                   escapes \" \\ \n \t \r only
//           123 / -7 / +7 / 1_000     decimal integer
//           0.25 / -1.5               decimal float, kept as BASIS POINTS: the
//                                     language has no floating point, so the
//                                     text is read as an i64 hundredth of a
//                                     percent (0.25 -> 2500). At most four
//                                     fraction digits (M23).
//           true / false              boolean
//           [v, v, v]                 array of strings or of integers, multi-line,
//                                     trailing comma allowed; no nesting
//
// Anything else is an error `file:line:col: message` and exit 1 — the column is
// what tells `entry = main.mc` (a bare word where a value goes) from a typo in
// the key.
//
// The result is deliberately NOT a tree: it is a flat table of
// (path, value, type, index) in SOURCE ORDER, exactly like every other table in
// this compiler (docs/determinism.md, rule 1: no hashing, no iterating anything
// but an array in insertion order). The path is the table prefix plus the key:
//
//   [project]        name = "api"     -> project.name          idx -1
//   [include]        paths = ["a"]    -> include.paths          idx 0
//   [[srv]]          host = "h"       -> srv.0.host             idx -1
//
// so the driver walks entries by index (toml_path_at/toml_val_at) whenever it
// needs the KEYS of a table — `[libs]` and `[externs]` are exactly that — and
// asks by path when it wants one value.
//
// Depends only on arena.mc (xalloc/xstrdup/cstrlen/mem_copy/read_file/out_*/_exit)
// and on the prelude (`while`, `+=`). Printing the table is NOT here: it lives in
// src/tomldump.mc, the driver that does it, because the compiler carries toml.mc
// in every binary and a dump nobody calls is a dozen string literals on the
// budget the C seed still caps (docs/build.md). `scripts/check-toml.sh` compares
// that driver's output against tests/toml/*.expect.

#include "../lib/prelude.mc"

#define TV_STR  0
#define TV_INT  1
#define TV_BOOL 2
#define TV_FLOAT 3                    // M23: decimal text stored as basis points

// flat entry: { path, value, type, idx, line, col }
#define TM_PATH 0
#define TM_VAL  8
#define TM_TYPE 16
#define TM_IDX  24                    // position in the array literal; -1 = scalar
#define TM_LINE 32
#define TM_COL  40
#define TM_SIZE 48

// M23: both tables are arena blocks that double on demand (arena.mc grow()).
uptr tm_ents;
i64  tm_entcap = 0;
i64  tm_n = 0;

uptr tm_aot_name;                     // [[x]] seen so far, in order
uptr tm_aot_n;                        // how many times each one appeared
i64  tm_aotcap = 0;
i64  tm_naot = 0;

uptr tm_file = 0;                     // path of the file being read, for errors
uptr tm_p = 0;                        // cursor
uptr tm_end = 0;
uptr tm_bol = 0;                      // first byte of the current line, for the column
i64  tm_line = 1;
uptr tm_pfx = 0;                      // current table prefix, ending in '.'

// ---- entry accessors ----
uptr tme_at(i64 i)    { return tm_ents + i * TM_SIZE; }
uptr tme_path(uptr e) { return ld64(e + TM_PATH); }
uptr tme_val(uptr e)  { return ld64(e + TM_VAL); }
i64  tme_type(uptr e) { return ld64(e + TM_TYPE); }
i64  tme_idx(uptr e)  { return ld64(e + TM_IDX); }
i64  tme_line(uptr e) { return ld64(e + TM_LINE); }
i64  tme_col(uptr e)  { return ld64(e + TM_COL); }
void set_tme_path(uptr e, uptr v) { st64(e + TM_PATH, v); }
void set_tme_val(uptr e, uptr v)  { st64(e + TM_VAL, v); }
void set_tme_type(uptr e, i64 v)  { st64(e + TM_TYPE, v); }
void set_tme_idx(uptr e, i64 v)   { st64(e + TM_IDX, v); }
void set_tme_line(uptr e, i64 v)  { st64(e + TM_LINE, v); }
void set_tme_col(uptr e, i64 v)   { st64(e + TM_COL, v); }

// ---- small string helpers (the arena is the only allocator) ----
// tm_cat moved to src/arena.mc at M41: src/cli.mc needs it for --include= and
// cli.mc is <mc/core_min>, which must not depend on <mc/core_build>.

// tm_num_str moved to src/arena.mc at M41 as well: src/backend_coff.mc uses it
// for a long section name, and <mc/core_writers> must not depend on
// <mc/core_build> either.

i64 tm_atoi(uptr s) {
    i64 n = 0;
    i64 neg = 0;
    if (ld8(s) == '-') { neg = 1; s = s + 1; }
    loop {
        i64 c = ld8(s);
        if (c < '0' || c > '9') break;
        n = n * 10 + (c - '0');
        s = s + 1;
    }
    if (neg) return 0 - n;
    return n;
}

// ---- cursor ----
// -1 = end of file; the buffer read_file returns is NUL-terminated, so reading
// one byte past the end is safe but never reached.
i64 tm_cur() {
    if (tm_p >= tm_end) return -1;
    return ld8(tm_p);
}

void tm_adv() {
    if (tm_p >= tm_end) return;
    if (ld8(tm_p) == '\n') {
        tm_line = tm_line + 1;
        tm_bol = tm_p + 1;
    }
    tm_p = tm_p + 1;
}

i64 tm_col(uptr p) { return p - tm_bol + 1; }

// file:line:col: message — the only error shape in this file
void toml_err(uptr p, uptr msg) {
    out_str(2, tm_file);
    out_str(2, ":");
    out_num(2, tm_line);
    out_str(2, ":");
    out_num(2, tm_col(p));
    out_str(2, ": ");
    out_str(2, msg);
    out_str(2, "\n");
    _exit(1);
}

// spaces and tabs, never a newline: the end of a line is significant
void tm_sp() {
    while (tm_cur() == ' ' || tm_cur() == '\t' || tm_cur() == '\r') { tm_adv(); }
}

void tm_comment() {
    while (tm_cur() != -1 && tm_cur() != '\n') { tm_adv(); }
}

// spaces, newlines and comments — used between statements and inside arrays
void tm_ws() {
    loop {
        i64 c = tm_cur();
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { tm_adv(); continue; }
        if (c == '#') { tm_comment(); continue; }
        break;
    }
}

// end of a logical line: an optional comment, then a newline or the end of file
void tm_eol() {
    tm_sp();
    if (tm_cur() == '#') tm_comment();
    i64 c = tm_cur();
    if (c == -1) return;
    if (c == '\n') { tm_adv(); return; }
    toml_err(tm_p, "unexpected text after the value");
}

// ---- lexemes ----
i64 tm_is_bare(i64 c) {
    if (c >= 'A' && c <= 'Z') return 1;
    if (c >= 'a' && c <= 'z') return 1;
    if (c >= '0' && c <= '9') return 1;
    return c == '_' || c == '-';
}

uptr tm_word() {
    uptr s = tm_p;
    i64 n = 0;
    while (tm_is_bare(tm_cur())) { tm_adv(); n = n + 1; }
    return xstrdup(s, n);
}

// "..." with the four escapes; the position of the opening quote is what the
// "unterminated string" error points at
uptr tm_str() {
    uptr q = tm_p;
    i64 qline = tm_line;
    tm_adv();
    u8 b[BUF_SIZE];
    buf_init(b);
    loop {
        i64 c = tm_cur();
        if (c == -1 || c == '\n') {
            tm_line = qline;
            toml_err(q, "unterminated string");
        }
        if (c == '"') { tm_adv(); break; }
        if (c == '\\') {
            tm_adv();
            i64 e = tm_cur();
            if (e == 'n')       buf_u8(b, '\n');
            else if (e == 't')  buf_u8(b, '\t');
            else if (e == 'r')  buf_u8(b, '\r');
            else if (e == '"')  buf_u8(b, '"');
            else if (e == '\\') buf_u8(b, '\\');
            else                toml_err(tm_p, "unknown escape");
            tm_adv();
            continue;
        }
        buf_u8(b, c);
        tm_adv();
    }
    buf_u8(b, 0);
    return buf_p(b);
}

// one key segment: quoted or bare. A quoted segment must NOT contain '.': the
// flat table joins segments with '.', so `"b.c"` under [a] and `c` under [a.b]
// would both land on a.b.c and one of the two would be silently unreachable.
// Quoting is still what a key with `*` in it needs -- `"sqlite3_*"` in
// [externs] -- and that character collides with nothing.
uptr tm_key1() {
    if (tm_cur() == '"') {
        uptr q = tm_p;                 // the opening quote is what the error points at
        uptr k = tm_str();
        i64 i = 0;
        loop {
            i64 c = ld8(k + i);
            if (c == 0) break;
            if (c == '.') toml_err(q, "quoted key must not contain .");
            i = i + 1;
        }
        return k;
    }
    uptr k = tm_word();
    if (ld8(k) == 0) toml_err(tm_p, "key expected");
    return k;
}

// dotted key: a.b.c comes back as the string "a.b.c"
uptr tm_key() {
    uptr k = tm_key1();
    loop {
        tm_sp();
        if (tm_cur() != '.') break;
        tm_adv();
        tm_sp();
        k = tm_cat(tm_cat(k, "."), tm_key1());
    }
    return k;
}

// ---- table ----
void toml_add(uptr path, uptr val, i64 type, i64 idx, i64 line, i64 col) {
    tm_ents = grow(T_TOMLENT, tm_ents, tm_n, &tm_entcap, TM_SIZE);
    uptr e = tme_at(tm_n);
    set_tme_path(e, path);
    set_tme_val(e, val);
    set_tme_type(e, type);
    set_tme_idx(e, idx);
    set_tme_line(e, line);
    set_tme_col(e, col);
    tm_n = tm_n + 1;
}

// occurrence index of [[name]], counting from 0; registers the name on first sight
i64 tm_aot_bump(uptr name) {
    i64 i = 0;
    while (i < tm_naot) {
        if (str_eq(ld64(tm_aot_name + i * 8), name)) {
            i64 n = ld64(tm_aot_n + i * 8);
            st64(tm_aot_n + i * 8, n + 1);
            return n;
        }
        i = i + 1;
    }
    i64 oc = tm_aotcap;
    tm_aot_name = grow(T_TOMLAOT, tm_aot_name, tm_naot, &tm_aotcap, 8);
    if (tm_aotcap != oc) tm_aot_n = grow_to(tm_aot_n, tm_naot, tm_aotcap, 8);
    st64(tm_aot_name + tm_naot * 8, name);
    st64(tm_aot_n + tm_naot * 8, 1);
    tm_naot = tm_naot + 1;
    return 0;
}

// ---- values ----
// one scalar; `idx` is the position in the array literal, or -1 for a plain value
void tm_value(uptr path, i64 idx) {
    i64 line = tm_line;
    i64 col = tm_col(tm_p);
    i64 c = tm_cur();
    if (c == '"') {
        toml_add(path, tm_str(), TV_STR, idx, line, col);
        return;
    }
    if (c == 't' || c == 'f') {
        uptr w = tm_word();
        if (!str_eq(w, "true") && !str_eq(w, "false")) toml_err(tm_p, "value expected");
        toml_add(path, w, TV_BOOL, idx, line, col);
        return;
    }
    if (c == '-' || c == '+' || (c >= '0' && c <= '9')) {
        i64 neg = 0;
        if (c == '-') { neg = 1; tm_adv(); }
        else if (c == '+') tm_adv();
        i64 n = 0;
        i64 d = 0;
        loop {
            i64 k = tm_cur();
            if (k == '_') { tm_adv(); continue; }
            if (k < '0' || k > '9') break;
            n = n * 10 + (k - '0');
            d = d + 1;
            tm_adv();
        }
        if (d == 0) toml_err(tm_p, "value expected");
        if (tm_cur() == '.') {                 // M23: a float, stored as basis points
            tm_adv();
            i64 f = 0;
            i64 fd = 0;
            loop {
                i64 k = tm_cur();
                if (k == '_') { tm_adv(); continue; }
                if (k < '0' || k > '9') break;
                f = f * 10 + (k - '0');
                fd = fd + 1;
                tm_adv();
            }
            if (fd == 0) toml_err(tm_p, "digit expected after .");
            if (fd > 4)  toml_err(tm_p, "float with more than 4 fraction digits");
            loop {                             // 0.5 -> 5000, 0.25 -> 2500
                if (fd >= 4) break;
                f = f * 10;
                fd = fd + 1;
            }
            i64 bp = n * 10000 + f;
            if (neg) bp = 0 - bp;
            toml_add(path, tm_num_str(bp), TV_FLOAT, idx, line, col);
            return;
        }
        if (neg) n = 0 - n;
        toml_add(path, tm_num_str(n), TV_INT, idx, line, col);
        return;
    }
    toml_err(tm_p, "value expected");
}

// [v, v, v] — every element gets its own entry, with the same path and an
// increasing index. An empty array leaves no entry: toml_count() gives 0.
void tm_array(uptr path) {
    tm_adv();
    i64 i = 0;
    loop {
        tm_ws();
        if (tm_cur() == -1) toml_err(tm_p, "unterminated array");
        if (tm_cur() == ']') { tm_adv(); break; }
        tm_value(path, i);
        i = i + 1;
        tm_ws();
        if (tm_cur() == ',') { tm_adv(); continue; }
        if (tm_cur() == ']') { tm_adv(); break; }
        toml_err(tm_p, "expected , or ] in the array");
    }
}

// [table] or [[array of tables]] — sets the prefix for the keys that follow
void tm_header() {
    tm_adv();
    i64 arr = 0;
    if (tm_cur() == '[') { arr = 1; tm_adv(); }
    tm_sp();
    uptr k = tm_key();
    tm_sp();
    if (tm_cur() != ']') toml_err(tm_p, "expected ] in the table header");
    tm_adv();
    if (arr) {
        if (tm_cur() != ']') toml_err(tm_p, "expected ] in the table header");
        tm_adv();
        k = tm_cat(tm_cat(k, "."), tm_num_str(tm_aot_bump(k)));
    }
    tm_pfx = tm_cat(k, ".");
}

// ---- entry point ----
void toml_parse(uptr path) {
    i64 len = 0;
    uptr src = read_file(path, &len);
    tm_file = path;
    tm_p = src;
    tm_end = src + len;
    tm_bol = src;
    tm_line = 1;
    tm_pfx = "";
    tm_n = 0;
    tm_naot = 0;
    loop {
        tm_ws();
        if (tm_cur() == -1) break;
        if (tm_cur() == '[') { tm_header(); tm_eol(); continue; }
        uptr k = tm_key();
        tm_sp();
        if (tm_cur() != '=') toml_err(tm_p, "expected = after the key");
        tm_adv();
        tm_sp();
        uptr full = tm_cat(tm_pfx, k);
        if (tm_cur() == '[') tm_array(full);
        else                 tm_value(full, -1);
        tm_eol();
    }
}

// ---- public API ----
i64  toml_entries()        { return tm_n; }
uptr toml_path_at(i64 i)   { return tme_path(tme_at(i)); }
uptr toml_val_at(i64 i)    { return tme_val(tme_at(i)); }
i64  toml_type_at(i64 i)   { return tme_type(tme_at(i)); }
i64  toml_line_at(i64 i)   { return tme_line(tme_at(i)); }

// index of the first entry with this path, -1 if none
i64 toml_find(uptr path) {
    i64 i = 0;
    while (i < tm_n) {
        if (str_eq(toml_path_at(i), path)) return i;
        i = i + 1;
    }
    return -1;
}

uptr toml_get(uptr path) {
    i64 i = toml_find(path);
    if (i < 0) return 0;
    return toml_val_at(i);
}

i64 toml_count(uptr path) {
    i64 n = 0;
    i64 i = 0;
    while (i < tm_n) {
        if (str_eq(toml_path_at(i), path)) n = n + 1;
        i = i + 1;
    }
    return n;
}

uptr toml_get_array(uptr path, i64 k) {
    i64 n = 0;
    i64 i = 0;
    while (i < tm_n) {
        if (str_eq(toml_path_at(i), path)) {
            if (n == k) return toml_val_at(i);
            n = n + 1;
        }
        i = i + 1;
    }
    return 0;
}

// error over an entry that IS in the file, at the exact position where its value
// was written: file:line:col: msg: path. This is what the driver uses to reject
// `[target] os = "linux"` pointing at the string, not at the file.
void toml_err_at(i64 i, uptr msg) {
    out_str(2, tm_file);
    out_str(2, ":");
    out_num(2, toml_line_at(i));
    out_str(2, ":");
    out_num(2, tme_col(tme_at(i)));
    out_str(2, ": ");
    out_str(2, msg);
    out_str(2, ": ");
    out_str(2, toml_path_at(i));
    out_str(2, "\n");
    _exit(1);
}

// error over a KEY: at its position when it is there, at the file itself when it
// is missing -- a missing key has no line to point at.
void toml_err_key(uptr path, uptr msg) {
    i64 i = toml_find(path);
    if (i >= 0) toml_err_at(i, msg);
    out_str(2, tm_file);
    out_str(2, ": ");
    out_str(2, msg);
    out_str(2, ": ");
    out_str(2, path);
    out_str(2, "\n");
    _exit(1);
}

i64 toml_int(uptr path, i64 dflt) {
    uptr v = toml_get(path);
    if (v == 0) return dflt;
    return tm_atoi(v);
}

// error over an entry that IS in the file, with no key appended: the message
// already names what is wrong (`tolerance must be between 0 and 1`)
void toml_err_val(i64 i, uptr msg) {
    out_str(2, tm_file);
    out_str(2, ":");
    out_num(2, toml_line_at(i));
    out_str(2, ":");
    out_num(2, tme_col(tme_at(i)));
    out_str(2, ": ");
    out_str(2, msg);
    out_str(2, "\n");
    _exit(1);
}

// M23: a float in basis points. An integer is accepted as well (`0` and `1` are
// the two ends of the range the caller wants), and the range is the caller's:
// out of [lo, hi] is an error at the value's own file:line:col.
// ---- M44 § 9: one parser, re-entrant ----
// toml_parse fills ONE global table, and `mc build` now has three kinds of TOML
// to read in one process: the project's mc.toml, the lock beside it, and one
// mc.toml per locked package. A second bespoke reader was the road not to take
// (src/limits.mc's lim_read_usage says so in its own comment), so the eight
// globals that ARE the table are saved into an arena frame and zeroed; the
// caller parses whatever it likes, copies out what it needs, and restores.
//
// Every parse of a foreign file is wrapped in one function that pops before it
// returns or dies -- and dying is `_exit`, where the table no longer matters
// (docs/specs/M44.md § Risks 6).
#define TF_ENTS 0
#define TF_CAP  8
#define TF_N    16
#define TF_ANAM 24
#define TF_ANUM 32
#define TF_ACAP 40
#define TF_NAOT 48
#define TF_FILE 56
#define TF_SIZE 64

uptr toml_push() {
    uptr f = xalloc(TF_SIZE);
    st64(f + TF_ENTS, tm_ents);
    st64(f + TF_CAP,  tm_entcap);
    st64(f + TF_N,    tm_n);
    st64(f + TF_ANAM, tm_aot_name);
    st64(f + TF_ANUM, tm_aot_n);
    st64(f + TF_ACAP, tm_aotcap);
    st64(f + TF_NAOT, tm_naot);
    st64(f + TF_FILE, tm_file);
    tm_ents = 0;
    tm_entcap = 0;
    tm_n = 0;
    tm_aot_name = 0;
    tm_aot_n = 0;
    tm_aotcap = 0;
    tm_naot = 0;
    tm_file = 0;
    return f;
}

void toml_pop(uptr f) {
    tm_ents     = ld64(f + TF_ENTS);
    tm_entcap   = ld64(f + TF_CAP);
    tm_n        = ld64(f + TF_N);
    tm_aot_name = ld64(f + TF_ANAM);
    tm_aot_n    = ld64(f + TF_ANUM);
    tm_aotcap   = ld64(f + TF_ACAP);
    tm_naot     = ld64(f + TF_NAOT);
    tm_file     = ld64(f + TF_FILE);
}

// how many times `[[name]]` appeared: the row count of an array of tables, which
// is what makes `[[package]]` in mc.lock and `[[file]]` in a cache manifest
// readable without scanning for the highest index that happens to exist.
i64 toml_occurrences(uptr name) {
    i64 i = 0;
    while (i < tm_naot) {
        if (str_eq(ld64(tm_aot_name + i * 8), name)) return ld64(tm_aot_n + i * 8);
        i = i + 1;
    }
    return 0;
}

i64 toml_bp(uptr path, i64 dflt, i64 lo, i64 hi, uptr msg) {
    i64 i = toml_find(path);
    if (i < 0) return dflt;
    i64 t = toml_type_at(i);
    if (t != TV_FLOAT && t != TV_INT) toml_err_val(i, msg);
    i64 bp = tm_atoi(toml_val_at(i));
    if (t == TV_INT) bp = bp * 10000;
    if (bp < lo || bp > hi) toml_err_val(i, msg);
    return bp;
}
