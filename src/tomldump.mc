// tomldump.mc — driver for M14: reads the TOML file given in argv[1] with
// src/toml.mc and prints the flat table, one line per entry, in source order:
//
//   str  project.name = "api"
//   int  project.jobs = 4
//   bp   limits.tolerance = 2500       (a float, in basis points)
//   bool project.strict = true
//   str  include.paths[0] = "lib"
//
// A malformed file prints `file:line:col: message` on stderr and exits 1 — that
// is exactly what tests/toml/bad-*.toml pin down. `scripts/check-toml.sh`
// compares the combined output against tests/toml/*.expect.
#include "arena.mc"
#include "toml.mc"

// ---- the dump itself ----
// One line per entry, in source order: `TYPE path[idx] = value`. Strings come
// back quoted and re-escaped, so the dump is a single line per entry no matter
// what the value holds.
void toml_dump_str(uptr s) {
    out_str(1, "\"");
    i64 i = 0;
    loop {
        i64 c = ld8(s + i);
        if (c == 0) break;
        if (c == '\n')      out_str(1, "\\n");
        else if (c == '\t') out_str(1, "\\t");
        else if (c == '\r') out_str(1, "\\r");
        else if (c == '"')  out_str(1, "\\\"");
        else if (c == '\\') out_str(1, "\\\\");
        else                out_bytes(1, s + i, 1);
        i = i + 1;
    }
    out_str(1, "\"");
}

void toml_dump() {
    i64 i = 0;
    while (i < tm_n) {
        uptr e = tme_at(i);
        i64 t = tme_type(e);
        if (t == TV_STR)        out_str(1, "str  ");
        else if (t == TV_INT)   out_str(1, "int  ");
        else if (t == TV_FLOAT) out_str(1, "bp   ");
        else                    out_str(1, "bool ");
        out_str(1, tme_path(e));
        if (tme_idx(e) >= 0) {
            out_str(1, "[");
            out_num(1, tme_idx(e));
            out_str(1, "]");
        }
        out_str(1, " = ");
        if (t == TV_STR) toml_dump_str(tme_val(e));
        else             out_str(1, tme_val(e));
        out_str(1, "\n");
        i = i + 1;
    }
}

i64 main(i64 argc, uptr argv) {
    if (argc < 2) {
        out_str(2, "usage: tomldump file.toml\n");
        return 1;
    }
    toml_parse(ld64(argv + 8));        // argv[1]
    toml_dump();
    return 0;
}
