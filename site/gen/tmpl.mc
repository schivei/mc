// tmpl.mc - the template contract of site/README.md, and nothing more.
//
//   {{name}}                        replaced by its value, verbatim, ONE pass,
//                                   never rescanned;
//   <!--if name--> ... <!--endif--> kept without the markers when the value is
//                                   non-empty, dropped whole when it is empty.
//
// Values are a pair of parallel lists (keys, values). An unknown `{{name}}` is a
// bug in the template, so it stops the build with the name in the message; an
// unknown name in an `<!--if-->` counts as empty, which is what makes
// base.html's `<!--if nav-->` work on the pages that never set it.

#define TP_KEYS 0
#define TP_VALS 8
#define TP_SIZE 16

uptr tp_new() {
    uptr c = xalloc(TP_SIZE);
    st64(c + TP_KEYS, sl_new());
    st64(c + TP_VALS, sl_new());
    return c;
}

void tp_set(uptr c, uptr key, uptr val) {
    uptr keys = ld64(c + TP_KEYS);
    i64 k = sl_index(keys, key);
    if (k >= 0) {
        st64(ld64(ld64(c + TP_VALS) + SL_ITEMS) + k * 8, val);
        return;
    }
    sl_add(keys, key);
    sl_add(ld64(c + TP_VALS), val);
}

// 0 = no such key
uptr tp_get(uptr c, uptr key) {
    i64 k = sl_index(ld64(c + TP_KEYS), key);
    if (k < 0) return 0;
    return sl_at(ld64(c + TP_VALS), k);
}

i64 tp_empty(uptr c, uptr key) {
    uptr v = tp_get(c, key);
    if (v == 0) return 1;
    return cstrlen(v) == 0;
}

// <!--if name--> blocks, removed or unwrapped. Pure string work; blocks do not
// nest, so one linear pass is enough.
uptr tp_conds(uptr s, uptr c) {
    i64 n = cstrlen(s);
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 k = u_find(s, n, i, "<!--if ");
        if (k < 0) { u_putn(b, s + i, n - i); break; }
        u_putn(b, s + i, k - i);
        i64 close = u_find(s, n, k, "-->");
        if (close < 0) { u_putn(b, s + k, n - k); break; }
        uptr name = u_trim(xstrdup(s + k + 7, close - k - 7));
        i64 body = close + 3;
        i64 endm = u_find(s, n, body, "<!--endif-->");
        if (endm < 0) die2("template: <!--if--> with no <!--endif-->", name);
        if (!tp_empty(c, name)) u_putn(b, s + body, endm - body);
        i = endm + 12;
    }
    return u_take(b);
}

// {{name}}, one pass, left to right, the result never rescanned
uptr tp_subst(uptr s, uptr c) {
    i64 n = cstrlen(s);
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 k = u_find(s, n, i, "{{");
        if (k < 0) { u_putn(b, s + i, n - i); break; }
        u_putn(b, s + i, k - i);
        i64 close = u_find(s, n, k, "}}");
        if (close < 0) { u_putn(b, s + k, n - k); break; }
        uptr name = xstrdup(s + k + 2, close - k - 2);
        uptr val = tp_get(c, name);
        if (val == 0) die2("template: unknown placeholder", name);
        u_put(b, val);
        i = close + 2;
    }
    return u_take(b);
}

uptr tp_render(uptr tmpl, uptr c) { return tp_subst(tp_conds(tmpl, c), c); }
