// limits.mc — M23: the estimate, the reserve and the `mc limits` report.
//
// Every table of the compiler is an arena block that doubles on demand
// (arena.mc: grow(), and the registry the ids T_* index). This file is the other
// half: it decides how big each block should be BEFORE the first append, so the
// doubling is the exception and not the rule.
//
// Two sources, and the bigger one wins:
//
//   static      a byte-level pre-scan of the entry file plus every include it
//               can reach -- relative ones from disk, `<name>` ones from the
//               bundle (already inflated and cached, so the lexer pays nothing
//               twice). The coefficients are the LIM_* constants below and are
//               documented, with their measured values, in docs/build.md
//               § limits.
//   remembered  build/.mc-usage.toml, written by `mc build` at the end of every
//               build: one section per compiled source, one line per table with
//               the high-water usage. The next build reads its own section and
//               pre-sizes from it. Sections, not one flat list, because a
//               project with a [compiler] compiles TWO sources of very different
//               sizes and neither should pre-size the other.
//
// The reserve is `estimate * (1 + tolerance)`, tolerance being the single knob
// (`[limits] tolerance`, default 0.25, a float in [0, 1] read as basis points).
//
// None of this touches the OUTPUT: a table that had to grow holds exactly the
// same elements, in exactly the same order, as one that did not
// (docs/determinism.md § capacity).
//
// Depends on arena.mc (the registry, xalloc, read_file, write_file, buf_*),
// on lex.mc (path_norm, lex_find_path_from, lex_readable, and bopen_fn --
// the bundle is reached through the lexer's function pointer, so this module
// does not depend on src/bundle.mc either). It is included after bundle.mc, so
// `mc limits` sees the same bundle the lexer will.

#include "../lib/prelude.mc"

// ---- the coefficient table ----
// Measured on src/mc.mc and examples/api; the numbers are in docs/build.md
// § limits, together with what they were calibrated against. `bytes`, `quotes`,
// `parenbrace` and `defines` all come from the pre-scan below.
//
//   nodes    = bytes / 11             functions = occurrences of ") {"
//   ins      = nodes * 9 / 10         globals   = functions / 3
//   strings  = quotes / 3             defines   = occurrences of "#define"
//   symbols  = functions + globals + strings          (exact, by construction)
//   heap     = sum(count * record) * 5 / 3 + 7 * bytes
//
// The token table is NOT byte-derived: it holds DISTINCT lexemes (the core
// keywords plus whatever `#token`/`#rule`/`syntax` register), so its cold-start
// seed covers it and doubling takes any teaching beyond that.
#define LIM_NODE_DIV 11
#define LIM_INS_NUM   9
#define LIM_INS_DEN  10
#define LIM_STR_DIV   3
#define LIM_GLB_DIV   3
#define LIM_HEAP_NUM  5
#define LIM_HEAP_DEN  3
#define LIM_HEAP_MUL  7

// ---- pre-scan state ----
i64 ps_bytes = 0;                 // source bytes reachable from the entry
i64 ps_quotes = 0;                // '"' characters
i64 ps_funcs = 0;                 // occurrences of ") {"
i64 ps_defines = 0;               // occurrences of "#define"
uptr ps_seen;                     // files already scanned, in order
i64 ps_seencap = 0;
i64 ps_seen_n = 0;

i64 lim_sest[T_COUNT];            // the STATIC estimate alone (what --fix-limits reasons about)
i64 lim_rem[T_COUNT];             // what build/.mc-usage.toml remembered
i64 lim_tol = 2500;               // tolerance in basis points; 0.25 by default
uptr lim_label = 0;               // the source, as the TOML names it: the section key

i64 lim_sest_at(i64 i) { return ld64(lim_sest + i * 8); }
i64 lim_rem_at(i64 i)  { return ld64(lim_rem + i * 8); }

// ---- the pre-scan ----
i64 ps_seen_has(uptr key) {
    i64 i = 0;
    while (i < ps_seen_n) {
        if (str_eq(ld64(ps_seen + i * 8), key)) return 1;
        i = i + 1;
    }
    return 0;
}

void ps_seen_add(uptr key) {
    if (ps_seen_n == ps_seencap) {
        i64 nc = ps_seencap * 2;
        if (nc == 0) nc = 64;
        ps_seen = grow_to(ps_seen, ps_seen_n, nc, 8);
        ps_seencap = nc;
    }
    st64(ps_seen + ps_seen_n * 8, key);
    ps_seen_n = ps_seen_n + 1;
}

// the three features the estimate needs, counted on raw bytes: no lexing, no
// comment or string state. Deliberately crude -- this is an estimate.
void ps_count(uptr s, i64 len) {
    ps_bytes = ps_bytes + len;
    i64 i = 0;
    while (i < len) {
        i64 c = ld8(s + i);
        if (c == '"') ps_quotes = ps_quotes + 1;
        if (c == ')' && ld8(s + i + 1) == ' ' && ld8(s + i + 2) == '{')
            ps_funcs = ps_funcs + 1;
        if (c == '#' && mem_eq(s + i, "#define", 7)) ps_defines = ps_defines + 1;
        i = i + 1;
    }
}

// #include "x" from a real file, #include <name> from the bundle. `virt` marks a
// source that came from the bundle: its own relative includes resolve by name,
// exactly as lex_include does.
void ps_scan(uptr file, i64 virt);

i64 ps_bundled(uptr name) {
    u8 canon[8];
    u8 blen[8];
    st64(canon, 0);
    st64(blen, 0);
    // reached through lex.mc's function pointer, not by calling bundle_open
    // directly: a taught compiler assembled without src/bundle.mc (the core
    // list is the module's to choose, docs/surface.md § Tier 3) still links,
    // and simply pre-scans no bundled include. Same reason lex.mc uses it.
    if (bopen_fn == 0) return 0;
    uptr src = callp(bopen_fn, name, 1, canon, blen);
    if (src == 0) return 0;
    uptr key = ld64(canon);
    if (ps_seen_has(key)) return 1;
    ps_seen_add(key);
    ps_count(src, ld64(blen));
    ps_includes(key, src, ld64(blen), 1);
    return 1;
}

// the same resolution lex_include does: inside a bundled file a relative
// include is joined, normalized, stripped of `.mc` and looked up in the bundle;
// only if the bundle does not have it does the filesystem get a turn.
void ps_relative(uptr file, uptr rel, i64 virt) {
    if (virt && ps_bundled(lex_strip_mc(path_join(file, rel)))) return;
    ps_scan(lex_find_path_from(file, rel), 0);
}

// line by line, looking for a `#include` that OPENS the line. Anything else --
// the one inside a `//` comment, the one inside a string literal that
// src/driver.mc writes -- is not a directive, and following it would pull whole
// modules into the estimate that the lexer will never read.
void ps_includes(uptr file, uptr s, i64 len, i64 virt) {
    i64 i = 0;
    while (i < len) {
        i64 e = i;
        while (e < len && ld8(s + e) != '\n') { e = e + 1; }
        i64 k = i;
        while (k < e && (ld8(s + k) == ' ' || ld8(s + k) == '\t')) { k = k + 1; }
        if (e - k > 10 && mem_eq(s + k, "#include", 8)) {
            i64 j = k + 8;
            while (j < e && (ld8(s + j) == ' ' || ld8(s + j) == '\t')) { j = j + 1; }
            i64 c = ld8(s + j);
            i64 close = 0;
            if (c == '"') close = '"';
            if (c == '<') close = '>';
            if (close) {
                i64 q = j + 1;
                while (q < e && ld8(s + q) != close) { q = q + 1; }
                if (q < e && q > j + 1) {
                    uptr rel = xstrdup(s + j + 1, q - j - 1);
                    if (c == '<') ps_bundled(rel);
                    else          ps_relative(file, rel, virt);
                }
            }
        }
        i = e + 1;
    }
}

void ps_scan(uptr file, i64 virt) {
    uptr key = path_norm(file);
    if (ps_seen_has(key)) return;
    if (!lex_readable(key)) return;             // a missing include is the lexer's error, not ours
    ps_seen_add(key);
    i64 len = 0;
    uptr src = read_file(key, &len);
    ps_count(src, len);
    ps_includes(key, src, len, virt);
}

// ---- the estimate ----
void lim_set_static(i64 i, i64 v) { st64(lim_sest + i * 8, v); }

// bytes the tables themselves will take from the arena, plus what the section
// buffers and the strings need (~2 x the source)
i64 lim_heap_estimate(i64 nds, i64 strs2, i64 fns, i64 glbs, i64 defs2, i64 syms, i64 ins) {
    i64 n = nds * ND_SIZE + strs2 * STR_SIZE + fns * FS_SIZE;
    n = n + glbs * GLB_SIZE + defs2 * DE_SIZE + syms * SYM_SIZE + ins * INS_SIZE;
    return n * LIM_HEAP_NUM / LIM_HEAP_DEN + LIM_HEAP_MUL * ps_bytes;
}

// the coefficients, applied once. Only the tables that scale with the program
// get an estimate; the rest keep their cold-start seed (arena.mc lim_seeds).
void lim_estimate() {
    i64 nds = ps_bytes / LIM_NODE_DIV;
    i64 ins = nds * LIM_INS_NUM / LIM_INS_DEN;
    i64 strs2 = ps_quotes / LIM_STR_DIV;
    i64 fns = ps_funcs;
    i64 glbs = fns / LIM_GLB_DIV;
    i64 defs2 = ps_defines;
    i64 syms = fns + glbs + strs2;
    lim_set_static(T_NODES, nds);
    lim_set_static(T_INS, ins);
    lim_set_static(T_STRINGS, strs2);
    lim_set_static(T_FUNCS, fns);
    lim_set_static(T_LOWERED, fns);
    lim_set_static(T_GLOBALS, glbs);
    lim_set_static(T_DEFINES, defs2);
    lim_set_static(T_SYMBOLS, syms);
    lim_set_static(T_INCLUDES, ps_seen_n);
    lim_set_static(T_HEAP, lim_heap_estimate(nds, strs2, fns, glbs, defs2, syms, ins));
}

// ---- remembered usage (build/.mc-usage.toml) ----
i64 lim_id(uptr name) {
    i64 i = 0;
    while (i < T_COUNT) {
        if (str_eq(lim_name_at(i), name)) return i;
        i = i + 1;
    }
    return -1;
}

// the section header for one compiled source
uptr lim_section(uptr label) {
    return tm_cat(tm_cat("[usage.\"", label), "\"]");
}

// 1 if the line that starts at s+k (up to s+e) is exactly `hdr`, ignoring
// trailing blanks
i64 lim_line_is(uptr s, i64 k, i64 e, uptr hdr) {
    while (e > k && (ld8(s + e - 1) == '\n' || ld8(s + e - 1) == '\r' ||
                     ld8(s + e - 1) == ' '  || ld8(s + e - 1) == '\t')) { e = e - 1; }
    i64 n = cstrlen(hdr);
    if (e - k != n) return 0;
    return mem_eq(s + k, hdr, n);
}

// `name = number` lines inside this source's section; `#` comments and every
// other section are skipped. Its own tiny reader on purpose: toml_parse() owns
// one global table and reading this file with it would throw away the project's
// mc.toml.
void lim_read_usage(uptr path, uptr label) {
    if (!lex_readable(path)) return;
    uptr hdr = lim_section(label);
    i64 len = 0;
    uptr s = read_file(path, &len);
    i64 on = 0;
    i64 i = 0;
    while (i < len) {
        i64 c = ld8(s + i);
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { i = i + 1; continue; }
        if (c == '#') {
            while (i < len && ld8(s + i) != '\n') { i = i + 1; }
            continue;
        }
        if (c == '[') {
            i64 e = i;
            while (e < len && ld8(s + e) != '\n') { e = e + 1; }
            on = lim_line_is(s, i, e, hdr);
            i = e;
            continue;
        }
        if (!on) {
            while (i < len && ld8(s + i) != '\n') { i = i + 1; }
            continue;
        }
        i64 j = i;
        while (j < len && ld8(s + j) != '=' && ld8(s + j) != '\n') { j = j + 1; }
        if (j >= len || ld8(s + j) != '=') { i = j; continue; }
        i64 e = j;
        while (e > i && (ld8(s + e - 1) == ' ' || ld8(s + e - 1) == '\t')) { e = e - 1; }
        uptr nm = xstrdup(s + i, e - i);
        i64 k = j + 1;
        while (k < len && (ld8(s + k) == ' ' || ld8(s + k) == '\t')) { k = k + 1; }
        i64 v = 0;
        while (k < len && ld8(s + k) >= '0' && ld8(s + k) <= '9') {
            v = v * 10 + (ld8(s + k) - '0');
            k = k + 1;
        }
        i64 t = lim_id(nm);
        if (t >= 0) st64(lim_rem + t * 8, v);
        i = k;
    }
}

void lim_put(uptr b, uptr s) { buf_put(b, s, cstrlen(s)); }

void lim_putnum(uptr b, i64 v) {
    u8 t[24];
    i64 i = 24;
    u64 u = v;
    loop {
        i = i - 1;
        st8(t + i, '0' + u % 10);
        u = u / 10;
        if (u == 0) break;
    }
    buf_put(b, t + i, 24 - i);
}

// rewrites this source's section with what this build actually used and copies
// every other section through untouched -- that is how the compiler's section
// and the entry's coexist in one file. The value REPLACES the old one instead of
// taking the maximum: a project that shrinks has to be able to shrink back.
void lim_write_usage(uptr path, uptr label) {
    uptr hdr = lim_section(label);
    u8 b[BUF_SIZE];
    buf_init(b);
    lim_put(b, "# written by `mc build`: high-water usage per table (M23).\n");
    lim_put(b, "# One section per compiled source. Safe to delete.\n");
    if (lex_readable(path)) {
        i64 len = 0;
        uptr s = read_file(path, &len);
        i64 skip = 0;
        i64 i = 0;
        while (i < len) {
            i64 e = i;
            while (e < len && ld8(s + e) != '\n') { e = e + 1; }
            if (e < len) e = e + 1;
            i64 k = i;
            while (k < e && (ld8(s + k) == ' ' || ld8(s + k) == '\t')) { k = k + 1; }
            if (ld8(s + k) == '#') { i = e; continue; }
            if (ld8(s + k) == '[') skip = lim_line_is(s, k, e, hdr);
            if (!skip) buf_put(b, s + i, e - i);
            i = e;
        }
    }
    lim_put(b, hdr);
    lim_put(b, "\n");
    i64 i = 0;
    while (i < T_COUNT) {
        lim_put(b, lim_name_at(i));
        lim_put(b, " = ");
        lim_putnum(b, lim_used_at(i));
        lim_put(b, "\n");
        i = i + 1;
    }
    drv_mkdirs(path);
    write_file(path, b);
}

// ---- the plan ----
// pre-scan, combine with the remembered usage, apply the tolerance and reserve.
// Runs before tok_init(): every table is still empty, so every first allocation
// lands on the reserve.
void lim_plan(uptr entry, i64 tol, uptr usage, uptr label) {
    lim_tol = tol;
    lim_label = label;
    if (usage != 0) lim_read_usage(usage, label);
    ps_scan(entry, 0);
    lim_estimate();
    i64 i = 0;
    while (i < T_COUNT) {
        i64 e = lim_sest_at(i);
        if (lim_rem_at(i) > e) e = lim_rem_at(i);
        set_lim_est(i, e);
        set_lim_res(i, e + e * tol / 10000);
        i = i + 1;
    }
    arena_reserve(lim_reserve(T_HEAP));
}

// ---- the report ----
#define V_OK    0
#define V_TIGHT 1
#define V_GREW  2

uptr lim_vnames[] = { "ok", "tight", "grew" };

uptr lim_vname(i64 v) { return ld64(lim_vnames + v * 8); }

// what the plan set aside before the first append. A table that grew ended up
// with more than this -- that is what the `grow` column is for. The heap is the
// exception: what it has is the chunks actually mapped, the static 32 MiB
// included.
i64 lim_reserved(i64 i) {
    if (i == T_HEAP) return heap_res;
    return lim_reserve(i);
}

i64 lim_row_verdict(i64 i) {
    if (lim_grew_at(i) > 0) return V_GREW;
    i64 r = lim_reserved(i);
    if (r > 0 && lim_used_at(i) * 10 > r * 9) return V_TIGHT;
    return V_OK;
}

i64 lim_verdict() {
    i64 w = V_OK;
    i64 i = 0;
    while (i < T_COUNT) {
        i64 v = lim_row_verdict(i);
        if (v > w) w = v;
        i = i + 1;
    }
    return w;
}

i64 lim_exit_code() {
    if (lim_verdict() == V_OK) return 0;
    return 3;
}

void lim_padnum(i64 v, i64 w) {
    i64 n = 1;
    i64 t = v;
    while (t >= 10) { t = t / 10; n = n + 1; }
    while (n < w) { out_str(1, " "); n = n + 1; }
    out_num(1, v);
}

void lim_padstr(uptr s, i64 w) {
    out_str(1, s);
    i64 n = cstrlen(s);
    while (n < w) { out_str(1, " "); n = n + 1; }
}

// One line per table, in the fixed order of the T_* ids: estimate, reserved,
// used, growth events, verdict. Deterministic text for CI.
void lim_report(uptr what) {
    out_str(1, "limits ");
    out_str(1, what);
    out_str(1, "\n");
    out_str(1, "table         estimate   reserved       used  grow  verdict\n");
    i64 i = 0;
    while (i < T_COUNT) {
        lim_padstr(lim_name_at(i), 12);
        lim_padnum(lim_est_at(i), 10);
        lim_padnum(lim_reserved(i), 11);
        lim_padnum(lim_used_at(i), 11);
        lim_padnum(lim_grew_at(i), 6);
        out_str(1, "  ");
        out_str(1, lim_vname(lim_row_verdict(i)));
        out_str(1, "\n");
        i = i + 1;
    }
    out_str(1, "tolerance ");
    lim_tol_str(1, lim_tol);
    out_str(1, ", verdict ");
    out_str(1, lim_vname(lim_verdict()));
    out_str(1, " (heap in bytes, every other table in elements)\n");
}

// ---- --fix-limits ----
// `D.DD` from basis points; the tolerance is always a multiple of 0.05, so two
// decimals say everything.
void lim_tol_str(i64 fd, i64 t) {
    out_num(fd, t / 10000);
    out_str(fd, ".");
    i64 f = (t % 10000) / 100;
    if (f < 10) out_str(fd, "0");
    out_num(fd, f);
}

// would tolerance `t` have kept every table off `grew` AND off `tight`, using
// the STATIC estimate alone? The static estimate is what a clean checkout has,
// so that is what the number written into mc.toml has to cover.
i64 lim_fits(i64 t) {
    i64 i = 0;
    while (i < T_COUNT) {
        i64 need = lim_used_at(i) * 10 / 9 + 1;
        i64 e = lim_sest_at(i);
        i64 res = e + e * t / 10000;
        i64 fl = lim_seed_at(i);
        if (i == T_HEAP) fl = HEAP_SIZE;       // the static heap is always there
        if (res < fl) res = fl;
        if (res < need) return 0;
        i = i + 1;
    }
    return 1;
}

// smallest multiple of 0.05 in [0, 1] that fits; -1 when even 1.0 does not
i64 lim_fix_tolerance() {
    i64 t = 0;
    while (t <= 10000) {
        if (lim_fits(t)) return t;
        t = t + 500;
    }
    return -1;
}

void lim_tol_line(uptr b, i64 t) {
    lim_put(b, "tolerance = ");
    lim_putnum(b, t / 10000);
    lim_put(b, ".");
    i64 f = (t % 10000) / 100;
    if (f < 10) lim_put(b, "0");
    lim_putnum(b, f);
    lim_put(b, "\n");
}

// 1 if the trimmed line at s+k starts with `w` used as a key (`w` then spaces
// then '=' or ']')
i64 lim_line_key(uptr s, i64 k, uptr w) {
    i64 n = cstrlen(w);
    if (!mem_eq(s + k, w, n)) return 0;
    i64 j = k + n;
    while (ld8(s + j) == ' ' || ld8(s + j) == '\t') { j = j + 1; }
    return ld8(s + j) == '=';
}

// Rewrites ONLY the `[limits]` section of `cfg`: every other byte of the file
// comes out exactly as it went in. Never called without --fix-limits.
void lim_fix_write(uptr cfg, i64 t) {
    i64 len = 0;
    uptr s = read_file(cfg, &len);
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 inlim = 0;
    i64 done = 0;
    i64 i = 0;
    while (i < len) {
        i64 e = i;
        while (e < len && ld8(s + e) != '\n') { e = e + 1; }
        if (e < len) e = e + 1;                    // the newline belongs to the line
        i64 k = i;
        while (k < e && (ld8(s + k) == ' ' || ld8(s + k) == '\t')) { k = k + 1; }
        if (ld8(s + k) == '[') {
            if (inlim && !done) { lim_tol_line(b, t); done = 1; }
            inlim = mem_eq(s + k, "[limits]", 8);
        }
        if (inlim && !done && lim_line_key(s, k, "tolerance")) {
            lim_tol_line(b, t);
            done = 1;
            i = e;
            continue;
        }
        buf_put(b, s + i, e - i);
        i = e;
    }
    if (!done) {
        if (len > 0 && ld8(s + len - 1) != '\n') lim_put(b, "\n");
        if (!inlim) lim_put(b, "[limits]\n");
        lim_tol_line(b, t);
    }
    write_file(cfg, b);
}

// with the developer's consent (the flag): raises the tolerance to the smallest
// value that would have avoided growth, or says the static estimate is what has
// to be remembered instead.
i64 lim_fix(uptr cfg) {
    if (lim_verdict() == V_OK) {
        out_str(1, "fix-limits: nothing to do\n");
        return 0;
    }
    i64 t = lim_fix_tolerance();
    if (t < 0) {
        out_str(1, "fix-limits: no tolerance in [0, 1] is enough -- the static ");
        out_str(1, "estimate is short; the remembered usage covers it instead\n");
        return 0;
    }
    if (t <= lim_tol) {
        out_str(1, "fix-limits: tolerance already covers it\n");
        return 0;
    }
    lim_fix_write(cfg, t);
    out_str(1, "fix-limits: tolerance ");
    lim_tol_str(1, lim_tol);
    out_str(1, " -> ");
    lim_tol_str(1, t);
    out_str(1, " in ");
    out_str(1, cfg);
    out_str(1, "\n");
    return 1;
}

// ---- `mc limits FILE.mc` ----
// The same pipeline the single-file CLI runs, minus writing the object: every
// table is filled exactly as in a real build, and nothing is left behind.
void lim_compile_file(uptr in) {
    lim_plan(in, lim_tol, 0, in);
    tok_init();
    lex_init(in);
    core_types_init();                            // M45: `i32`, before user_init
    user_init();
    i64 unit = parse_unit();
    unit = run_passes(unit);
    unit = fold(unit);
    gen_lower(unit);
    gen_encode_all();
}
