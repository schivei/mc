// md.mc - the Markdown subset of docs/specs/M27.md, turned into HTML.
//
// Deliberately small and line-oriented: ATX headings with ids and an anchor,
// paragraphs, emphasis, inline code, links, images, ordered and unordered lists,
// blockquotes, pipe tables, thematic breaks and fenced code. A fence tagged `mc`
// goes through hl.mc (the bundled lexer); every other fence is emitted with the
// same frame and no spans.
//
// What it deliberately does NOT do, because docs/ does not need it and every
// feature here is one more thing to get wrong: reference links ([x][1]), setext
// headings (=== / --- under a line: a --- line is always a thematic break here),
// indented (4-space) code blocks, raw HTML passthrough (it is escaped), footnotes
// and nested blockquotes deeper than the recursion guard.
//
// The output shape is fixed by site/README.md § "The shape of {{content}}":
// headings carry an id and an anchor, tables are wrapped in .table-wrap, code
// blocks are <pre class="code" tabindex="0">, images always have an alt.

#define MD_MAXDEPTH 8                 // blockquote / list nesting: an error, not a table

// ---- state of the page being rendered ----
uptr md_ids;                          // every id emitted, for uniqueness and for --check
uptr md_hlvl;                         // heading levels (2 or 3), parallel to the two below
uptr md_hid;
uptr md_htext;
uptr md_title = 0;                    // text of the first h1
uptr md_desc = 0;                     // text of the first paragraph
i64  md_h1n = 0;                      // how many h1 the page has (exactly one is the rule)
i64  md_no_h1 = 0;                    // the template already has one: demote every `# `
i64  md_depth = 0;
uptr md_file = 0;                     // source path, for diagnostics

// resolved by site.mc: a Markdown link target -> the URL to write in the HTML
uptr sg_resolve_link(uptr href);
// resolved by hl.mc: one fenced block, with its info string
void hl_block(uptr b, uptr code, i64 n, uptr info);

void md_blocks(uptr b, uptr s, i64 n);
void md_inline(uptr b, uptr s, i64 n);
void md_plain_into(uptr b, uptr s, i64 n);

void md_reset(uptr file) {
    md_ids = sl_new();
    md_hlvl = sl_new();
    md_hid = sl_new();
    md_htext = sl_new();
    md_title = 0;
    md_desc = 0;
    md_h1n = 0;
    md_no_h1 = 0;
    md_depth = 0;
    md_file = file;
}

// ---- line helpers ----
i64 md_eol(uptr s, i64 n, i64 i) {
    i64 e = i;
    loop {
        if (e >= n) break;
        if (ld8(s + e) == '\n') break;
        e = e + 1;
    }
    return e;
}

i64 md_is_blank(uptr s, i64 i, i64 e) {
    loop {
        if (i >= e) break;
        if (!u_is_space(ld8(s + i))) return 0;
        i = i + 1;
    }
    return 1;
}

// leading blanks, a tab counting as four columns
i64 md_ind(uptr s, i64 i, i64 e) {
    i64 k = 0;
    loop {
        if (i >= e) break;
        i64 c = ld8(s + i);
        if (c == ' ') k = k + 1;
        else if (c == '\t') k = k + 4;
        else break;
        i = i + 1;
    }
    return k;
}

// index of the first non-blank byte of the line
i64 md_first(uptr s, i64 i, i64 e) {
    loop {
        if (i >= e) break;
        i64 c = ld8(s + i);
        if (c != ' ' && c != '\t') break;
        i = i + 1;
    }
    return i;
}

i64 md_fence_ch = 0;

// length of the fence run at j, or 0
i64 md_fence_len(uptr s, i64 j, i64 e) {
    i64 c = ld8(s + j);
    if (c != '`' && c != '~') return 0;
    i64 k = 0;
    loop {
        if (j + k >= e) break;
        if (ld8(s + j + k) != c) break;
        k = k + 1;
    }
    if (k < 3) return 0;
    md_fence_ch = c;
    return k;
}

// --- *** ___ alone on the line
i64 md_is_hr(uptr s, i64 j, i64 e) {
    i64 c = ld8(s + j);
    if (c != '-' && c != '*' && c != '_') return 0;
    i64 k = 0;
    i64 i = j;
    loop {
        if (i >= e) break;
        i64 d = ld8(s + i);
        if (d == c) k = k + 1;
        else if (d != ' ' && d != '\t') return 0;
        i = i + 1;
    }
    return k >= 3;
}

i64 md_ord = 0;                       // set by md_marker: 1 = ordered list

// width of the list marker at j (including the blank after it), or 0
i64 md_marker(uptr s, i64 j, i64 e) {
    i64 c = ld8(s + j);
    md_ord = 0;
    if (c == '-' || c == '*' || c == '+') {
        if (j + 1 < e && (ld8(s + j + 1) == ' ' || ld8(s + j + 1) == '\t')) return 2;
        return 0;
    }
    if (!is_digit(c)) return 0;
    i64 k = 0;
    loop {
        if (j + k >= e) break;
        if (!is_digit(ld8(s + j + k))) break;
        k = k + 1;
    }
    if (j + k >= e) return 0;
    i64 d = ld8(s + j + k);
    if (d != '.' && d != ')') return 0;
    if (j + k + 1 >= e) return 0;
    i64 sp = ld8(s + j + k + 1);
    if (sp != ' ' && sp != '\t') return 0;
    md_ord = 1;
    return k + 2;
}

// a table delimiter row: only | - : and blanks, with at least one -
i64 md_is_delim(uptr s, i64 i, i64 e) {
    i64 dash = 0;
    i64 bar = 0;
    loop {
        if (i >= e) break;
        i64 c = ld8(s + i);
        if (c == '-') dash = 1;
        else if (c == '|') bar = 1;
        else if (c != ':' && c != ' ' && c != '\t') return 0;
        i = i + 1;
    }
    return dash && bar;
}

// ---- inline ----
// the matching close of a run of `k` backticks, or -1
i64 md_code_close(uptr s, i64 n, i64 from, i64 k) {
    i64 i = from;
    loop {
        if (i >= n) break;
        if (ld8(s + i) == '`') {
            i64 r = 0;
            loop {
                if (i + r >= n) break;
                if (ld8(s + i + r) != '`') break;
                r = r + 1;
            }
            if (r == k) return i;
            i = i + r;
        } else i = i + 1;
    }
    return 0 - 1;
}

// index of the closing bracket that matches the '[' at `from`, or -1
i64 md_close_br(uptr s, i64 n, i64 from, i64 open, i64 close) {
    i64 d = 0;
    i64 i = from;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c == '\\') { i = i + 2; continue; }
        if (c == '`') {                                  // a code span hides brackets
            i64 k = 0;
            loop {
                if (i + k >= n) break;
                if (ld8(s + i + k) != '`') break;
                k = k + 1;
            }
            i64 cl = md_code_close(s, n, i + k, k);
            if (cl < 0) i = i + k;
            else i = cl + k;
            continue;
        }
        if (c == open) d = d + 1;
        else if (c == close) {
            d = d - 1;
            if (d == 0) return i;
        }
        i = i + 1;
    }
    return 0 - 1;
}

// `&name;` / `&#123;` written by hand goes through untouched; every other & is escaped
i64 md_entity_len(uptr s, i64 n, i64 i) {
    i64 k = i + 1;
    if (k < n && ld8(s + k) == '#') k = k + 1;
    i64 start = k;
    loop {
        if (k >= n) break;
        if (!is_alnum(ld8(s + k))) break;
        k = k + 1;
    }
    if (k == start) return 0;
    if (k >= n || ld8(s + k) != ';') return 0;
    return k + 1 - i;
}

// an autolink is <scheme:...> with no blank inside
i64 md_autolink_len(uptr s, i64 n, i64 i) {
    i64 k = i + 1;
    i64 colon = 0;
    loop {
        if (k >= n) break;
        i64 c = ld8(s + k);
        if (c == '>') break;
        if (u_is_space(c)) return 0;
        if (c == ':') colon = 1;
        k = k + 1;
    }
    if (k >= n || !colon) return 0;
    return k + 1 - i;
}

// emphasis: the closing run of the same delimiter, or -1
i64 md_emph_close(uptr s, i64 n, i64 from, i64 c, i64 run) {
    i64 i = from;
    loop {
        if (i + run > n) break;
        if (ld8(s + i) == '\\') { i = i + 2; continue; }
        if (ld8(s + i) == '`') {
            i64 k = 0;
            loop {
                if (i + k >= n) break;
                if (ld8(s + i + k) != '`') break;
                k = k + 1;
            }
            i64 cl = md_code_close(s, n, i + k, k);
            if (cl < 0) i = i + k;
            else i = cl + k;
            continue;
        }
        if (ld8(s + i) == c) {
            i64 r = 0;
            loop {
                if (i + r < n && ld8(s + i + r) == c) r = r + 1;
                else break;
            }
            if (r >= run && i > from) return i;
            i = i + r;
            continue;
        }
        i = i + 1;
    }
    return 0 - 1;
}

// the page a refused link was written on, so the author knows where to look
void md_bad_url(uptr url) {
    out_str(2, "mcsite: link scheme refused in ");
    out_str(2, md_file);
    out_str(2, ": ");
    out_str(2, url);
    out_str(2, "\n");
}

// a link destination and its optional "title", resolved. 0 = the scheme is not
// one a documentation page may link to (`javascript:`, `data:`, ...); the source
// is then not a link at all and the caller writes it as literal text.
uptr md_dest(uptr s, i64 n) {
    uptr raw = u_trim(xstrdup(s, n));
    i64 sp = u_chr(raw, cstrlen(raw), 0, ' ');
    if (sp > 0) raw = u_slice(raw, 0, sp);
    uptr r = sg_resolve_link(raw);
    if (r == 0) md_bad_url(raw);
    return r;
}

void md_inline(uptr b, uptr s, i64 n) {
    if (md_depth > MD_MAXDEPTH) { u_esc_text_n(b, s, n); return; }
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c == '\\' && i + 1 < n && !is_alnum(ld8(s + i + 1)) && !u_is_space(ld8(s + i + 1))) {
            u_esc_text_n(b, s + i + 1, 1);
            i = i + 2;
            continue;
        }
        if (c == '`') {
            i64 k = 0;
            loop {
                if (i + k < n && ld8(s + i + k) == '`') k = k + 1;
                else break;
            }
            i64 cl = md_code_close(s, n, i + k, k);
            if (cl < 0) {
                // CommonMark: an opening run with no closing run of the same
                // length is literal, all k of it. Emitting one backtick and
                // retrying at i+1 shrank the run by one on every attempt until
                // its last backtick paired with an unrelated single one later
                // in the line. md_plain_into, md_close_br and md_emph_close all
                // already skip the whole run; this is the odd one out.
                i64 q = 0;
                loop {
                    if (q >= k) break;
                    u_put(b, "&#96;");
                    q = q + 1;
                }
                i = i + k;
                continue;
            }
            i64 from = i + k;
            i64 len = cl - from;
            if (len > 1 && ld8(s + from) == ' ' && ld8(s + from + len - 1) == ' ') {
                from = from + 1;
                len = len - 2;
            }
            u_put(b, "<code>");
            u_esc_text_n(b, s + from, len);
            u_put(b, "</code>");
            i = cl + k;
            continue;
        }
        if (c == '!' && i + 1 < n && ld8(s + i + 1) == '[') {
            i64 rb = md_close_br(s, n, i + 1, '[', ']');
            if (rb > 0 && rb + 1 < n && ld8(s + rb + 1) == '(') {
                i64 rp = md_close_br(s, n, rb + 1, '(', ')');
                if (rp > 0) {
                    uptr dst = md_dest(s + rb + 2, rp - rb - 2);
                    if (dst == 0) { u_esc_text_n(b, s + i, rp + 1 - i); i = rp + 1; continue; }
                    u_put(b, "<img src=\"");
                    u_esc(b, dst);
                    u_put(b, "\" alt=\"");
                    u8 alt[BUF_SIZE];
                    buf_init(alt);
                    md_plain_into(alt, s + i + 2, rb - i - 2);
                    u_esc_n(b, buf_p(alt), buf_len(alt));
                    u_put(b, "\">");
                    i = rp + 1;
                    continue;
                }
            }
        }
        if (c == '[') {
            i64 rb = md_close_br(s, n, i, '[', ']');
            if (rb > 0 && rb + 1 < n && ld8(s + rb + 1) == '(') {
                i64 rp = md_close_br(s, n, rb + 1, '(', ')');
                if (rp > 0) {
                    uptr dst = md_dest(s + rb + 2, rp - rb - 2);
                    if (dst == 0) { u_esc_text_n(b, s + i, rp + 1 - i); i = rp + 1; continue; }
                    u_put(b, "<a href=\"");
                    u_esc(b, dst);
                    u_put(b, "\">");
                    md_depth = md_depth + 1;
                    md_inline(b, s + i + 1, rb - i - 1);
                    md_depth = md_depth - 1;
                    u_put(b, "</a>");
                    i = rp + 1;
                    continue;
                }
            }
        }
        if (c == '<') {
            i64 al = md_autolink_len(s, n, i);
            if (al > 0) {
                uptr url = xstrdup(s + i + 1, al - 2);
                if (u_scheme(url) == U_SCHEME_ABS) {
                    u_put(b, "<a href=\"");
                    u_esc(b, url);
                    u_put(b, "\">");
                    u_esc_text(b, url);
                    u_put(b, "</a>");
                    i = i + al;
                    continue;
                }
                md_bad_url(url);
            }
            u_put(b, "&lt;");
            i = i + 1;
            continue;
        }
        if (c == '&') {
            i64 el = md_entity_len(s, n, i);
            if (el > 0) { u_putn(b, s + i, el); i = i + el; continue; }
            u_put(b, "&amp;");
            i = i + 1;
            continue;
        }
        if (c == '*' || c == '_') {
            i64 run = 1;
            if (i + 1 < n && ld8(s + i + 1) == c) run = 2;
            i64 ok = 1;
            // `_` only opens at a word boundary, so snake_case_names survive
            if (c == '_') {
                if (i > 0 && is_alnum(ld8(s + i - 1))) ok = 0;
            }
            if (i + run >= n || u_is_space(ld8(s + i + run))) ok = 0;
            if (ok) {
                i64 cl = md_emph_close(s, n, i + run, c, run);
                if (cl > 0) {
                    if (run == 2) u_put(b, "<strong>");
                    else          u_put(b, "<em>");
                    md_depth = md_depth + 1;
                    md_inline(b, s + i + run, cl - i - run);
                    md_depth = md_depth - 1;
                    if (run == 2) u_put(b, "</strong>");
                    else          u_put(b, "</em>");
                    i = cl + run;
                    continue;
                }
            }
            u_esc_text_n(b, s + i, 1);
            i = i + 1;
            continue;
        }
        u_esc_text_n(b, s + i, 1);
        i = i + 1;
    }
}

// the same walk, emitting text only: what a title, an id, a description and the
// search index are built from
void md_plain_into(uptr b, uptr s, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c == '\\' && i + 1 < n && !is_alnum(ld8(s + i + 1)) && !u_is_space(ld8(s + i + 1))) {
            buf_u8(b, ld8(s + i + 1));
            i = i + 2;
            continue;
        }
        if (c == '`') {
            i64 k = 0;
            loop {
                if (i + k < n && ld8(s + i + k) == '`') k = k + 1;
                else break;
            }
            i64 cl = md_code_close(s, n, i + k, k);
            if (cl < 0) { i = i + k; continue; }
            i64 from = i + k;
            i64 len = cl - from;
            if (len > 1 && ld8(s + from) == ' ' && ld8(s + from + len - 1) == ' ') {
                from = from + 1;
                len = len - 2;
            }
            u_putn(b, s + from, len);
            i = cl + k;
            continue;
        }
        if (c == '!' && i + 1 < n && ld8(s + i + 1) == '[') { i = i + 1; continue; }
        if (c == '[') {
            i64 rb = md_close_br(s, n, i, '[', ']');
            if (rb > 0 && rb + 1 < n && ld8(s + rb + 1) == '(') {
                i64 rp = md_close_br(s, n, rb + 1, '(', ')');
                if (rp > 0) {
                    md_plain_into(b, s + i + 1, rb - i - 1);
                    i = rp + 1;
                    continue;
                }
            }
        }
        if (c == '<') {
            i64 al = md_autolink_len(s, n, i);
            if (al > 0) { u_putn(b, s + i + 1, al - 2); i = i + al; continue; }
        }
        if (c == '*') { i = i + 1; continue; }
        if (c == '_' && (i == 0 || !is_alnum(ld8(s + i - 1)))) { i = i + 1; continue; }
        if (c == '\n') { buf_u8(b, ' '); i = i + 1; continue; }
        buf_u8(b, c);
        i = i + 1;
    }
}

uptr md_plain(uptr s, i64 n) {
    u8 b[BUF_SIZE];
    buf_init(b);
    md_plain_into(b, s, n);
    return u_trim(u_take(b));
}

// ---- headings ----
uptr md_unique_id(uptr base) {
    if (!sl_has(md_ids, base)) { sl_add(md_ids, base); return base; }
    i64 k = 2;
    loop {
        u8 t[BUF_SIZE];
        buf_init(t);
        u_put(t, base);
        buf_u8(t, '-');
        u_putnum(t, k);
        uptr cand = u_take(t);
        if (!sl_has(md_ids, cand)) { sl_add(md_ids, cand); return cand; }
        k = k + 1;
    }
    return base;
}

void md_heading(uptr b, i64 lvl, uptr s, i64 n) {
    uptr text = md_plain(s, n);
    if (lvl == 1) {
        md_h1n = md_h1n + 1;
        // A page has exactly one <h1>. A document with a second `# ` (docs/plan.md
        // opens a phase that way) gets it demoted to an <h2> rather than emitting
        // an invalid page; the count above is what --check reports.
        if (md_h1n > 1 || md_no_h1) lvl = 2;
        else {
            if (md_title == 0) md_title = text;
            // The h1 carries an id but no visible anchor: the design does not put
            // a '#' next to the page title, and a link written as
            // `[x](page.md#the-title)` still has to land somewhere.
            u_put(b, "<h1 id=\"");
            u_esc(b, md_unique_id(u_slug(text)));
            u_put(b, "\">");
            md_inline(b, s, n);
            u_put(b, "</h1>\n");
            return;
        }
    }
    uptr id = md_unique_id(u_slug(text));
    u_put(b, "<h");
    u_putnum(b, lvl);
    u_put(b, " id=\"");
    u_esc(b, id);
    u_put(b, "\">");
    md_inline(b, s, n);
    u_put(b, " <a class=\"anchor\" href=\"#");
    u_esc(b, id);
    u_put(b, "\" aria-label=\"Link to this section\">#</a></h");
    u_putnum(b, lvl);
    u_put(b, ">\n");
    if (lvl == 2 || lvl == 3) {
        il_add(md_hlvl, lvl);
        sl_add(md_hid, id);
        sl_add(md_htext, text);
    }
}

// the {{toc}} of the page just rendered: h2 at the top level, h3 one deeper
uptr md_toc_html() {
    i64 n = sl_n(md_hid);
    if (n == 0) return u_dup("");
    u8 b[BUF_SIZE];
    buf_init(b);
    u_put(b, "<ul class=\"toc-list\">\n");
    i64 i = 0;
    i64 open2 = 0;                    // an <li> of an h2 is still open
    i64 open3 = 0;                    // the nested <ul> is still open
    loop {
        if (i >= n) break;
        i64 lvl = il_at(md_hlvl, i);
        if (lvl == 3 && open2) {
            if (!open3) { u_put(b, "\n<ul class=\"toc-list\">\n"); open3 = 1; }
            u_put(b, "<li><a href=\"#");
            u_esc(b, sl_at(md_hid, i));
            u_put(b, "\">");
            u_esc_text(b, sl_at(md_htext, i));
            u_put(b, "</a></li>\n");
        } else {
            if (open3) { u_put(b, "</ul>\n"); open3 = 0; }
            if (open2) { u_put(b, "</li>\n"); open2 = 0; }
            u_put(b, "<li><a href=\"#");
            u_esc(b, sl_at(md_hid, i));
            u_put(b, "\">");
            u_esc_text(b, sl_at(md_htext, i));
            u_put(b, "</a>");
            open2 = 1;
        }
        i = i + 1;
    }
    if (open3) u_put(b, "</ul>\n");
    if (open2) u_put(b, "</li>\n");
    u_put(b, "</ul>\n");
    return u_take(b);
}

// ---- blocks ----
// fenced code: returns the index of the line after the closing fence
i64 md_code_block(uptr b, uptr s, i64 n, i64 i) {
    i64 e = md_eol(s, n, i);
    i64 ind = md_ind(s, i, e);
    i64 j = md_first(s, i, e);
    i64 k = md_fence_len(s, j, e);
    i64 ch = md_fence_ch;
    uptr info = u_trim(xstrdup(s + j + k, e - j - k));
    u8 body[BUF_SIZE];
    buf_init(body);
    i64 p = e + 1;
    loop {
        if (p >= n) break;
        i64 pe = md_eol(s, n, p);
        i64 pj = md_first(s, p, pe);
        i64 pk = md_fence_len(s, pj, pe);
        if (pk >= k && md_fence_ch == ch && md_is_blank(s, pj + pk, pe)) {
            p = pe + 1;
            break;
        }
        i64 cut = md_ind(s, p, pe);
        if (cut > ind) cut = ind;
        i64 q = p;
        i64 dropped = 0;
        loop {
            if (dropped >= cut) break;
            if (q >= pe) break;
            if (ld8(s + q) != ' ') break;
            q = q + 1;
            dropped = dropped + 1;
        }
        u_putn(body, s + q, pe - q);
        buf_u8(body, '\n');
        p = pe + 1;
    }
    hl_block(b, buf_p(body), buf_len(body), info);
    return p;
}

// paragraph: everything up to a blank line or the start of another block
i64 md_para(uptr b, uptr s, i64 n, i64 i) {
    u8 t[BUF_SIZE];
    buf_init(t);
    loop {
        if (i >= n) break;
        i64 e = md_eol(s, n, i);
        if (md_is_blank(s, i, e)) break;
        i64 j = md_first(s, i, e);
        if (buf_len(t) != 0) {
            if (ld8(s + j) == '#' && ld8(s + j + 1) != 0) break;
            if (md_fence_len(s, j, e)) break;
            if (md_is_hr(s, j, e)) break;
            if (ld8(s + j) == '>') break;
            if (md_marker(s, j, e)) break;
        }
        if (buf_len(t) != 0) buf_u8(t, '\n');
        u_putn(t, s + j, e - j);
        i = e + 1;
    }
    uptr text = u_take(t);
    i64 tn = cstrlen(text);
    if (md_desc == 0) md_desc = md_plain(text, tn);
    u_put(b, "<p>");
    md_inline(b, text, tn);
    u_put(b, "</p>\n");
    return i;
}

// Past MD_MAXDEPTH the recursion stops -- but the text must not vanish with it.
// It goes out escaped, in one paragraph, and the page is named on stderr: a
// truncated document that says nothing is worse than an ugly paragraph.
void md_too_deep(uptr b, uptr s, i64 n) {
    out_str(2, "mcsite: nesting past ");
    out_num(2, MD_MAXDEPTH);
    out_str(2, " levels, the rest is plain text in ");
    out_str(2, md_file);
    out_str(2, "\n");
    u_put(b, "<p>");
    u_esc_text_n(b, s, n);
    u_put(b, "</p>\n");
}

i64 md_quote(uptr b, uptr s, i64 n, i64 i) {
    u8 t[BUF_SIZE];
    buf_init(t);
    loop {
        if (i >= n) break;
        i64 e = md_eol(s, n, i);
        i64 j = md_first(s, i, e);
        if (j >= e || ld8(s + j) != '>') break;
        j = j + 1;
        if (j < e && ld8(s + j) == ' ') j = j + 1;
        u_putn(t, s + j, e - j);
        buf_u8(t, '\n');
        i = e + 1;
    }
    u_put(b, "<blockquote>\n");
    md_depth = md_depth + 1;
    if (md_depth <= MD_MAXDEPTH) md_blocks(b, buf_p(t), buf_len(t));
    else                         md_too_deep(b, buf_p(t), buf_len(t));
    md_depth = md_depth - 1;
    u_put(b, "</blockquote>\n");
    return i;
}

// one <li>: a single paragraph is emitted without the <p> wrapper (a tight list),
// anything longer goes through md_blocks
void md_item(uptr b, uptr s, i64 n) {
    i64 multi = 0;
    i64 k = 0;
    loop {
        if (k >= n) break;
        if (ld8(s + k) == '\n' && k + 1 < n) {
            i64 e2 = md_eol(s, n, k + 1);
            if (!md_is_blank(s, k + 1, e2)) {
                i64 j2 = md_first(s, k + 1, e2);
                if (md_marker(s, j2, e2) || md_fence_len(s, j2, e2) || ld8(s + j2) == '>') multi = 1;
            } else multi = 1;
        }
        k = k + 1;
    }
    u_put(b, "<li>");
    if (multi) {
        u_put(b, "\n");
        md_depth = md_depth + 1;
        if (md_depth <= MD_MAXDEPTH) md_blocks(b, s, n);
        else                         md_too_deep(b, s, n);
        md_depth = md_depth - 1;
    } else {
        md_inline(b, s, n);
    }
    u_put(b, "</li>\n");
}

i64 md_list(uptr b, uptr s, i64 n, i64 i) {
    i64 e = md_eol(s, n, i);
    i64 base = md_ind(s, i, e);
    i64 j = md_first(s, i, e);
    md_marker(s, j, e);
    i64 ordered = md_ord;
    if (ordered) u_put(b, "<ol>\n");
    else         u_put(b, "<ul>\n");
    loop {
        if (i >= n) break;
        e = md_eol(s, n, i);
        if (md_is_blank(s, i, e)) break;
        i64 ind = md_ind(s, i, e);
        if (ind < base) break;
        j = md_first(s, i, e);
        i64 mw = md_marker(s, j, e);
        if (mw == 0 || md_ord != ordered) break;
        if (ind > base) break;
        // the item's own text, dedented by the marker's width
        u8 t[BUF_SIZE];
        buf_init(t);
        u_putn(t, s + j + mw, e - j - mw);
        buf_u8(t, '\n');
        i = e + 1;
        i64 cont = base + mw;
        loop {
            if (i >= n) break;
            i64 pe = md_eol(s, n, i);
            if (md_is_blank(s, i, pe)) {
                // a blank line only continues the item if what follows is indented
                if (i + 1 >= n) break;
                i64 ne = md_eol(s, n, pe + 1);
                if (md_is_blank(s, pe + 1, ne)) break;
                if (md_ind(s, pe + 1, ne) < cont) break;
                buf_u8(t, '\n');
                i = pe + 1;
                continue;
            }
            i64 pind = md_ind(s, i, pe);
            i64 pj = md_first(s, i, pe);
            if (pind >= cont) {
                i64 q = i;
                i64 dropped = 0;
                loop {
                    if (dropped >= cont) break;
                    if (q >= pe) break;
                    if (ld8(s + q) != ' ') break;
                    q = q + 1;
                    dropped = dropped + 1;
                }
                u_putn(t, s + q, pe - q);
                buf_u8(t, '\n');
                i = pe + 1;
                continue;
            }
            if (pind > base && md_marker(s, pj, pe)) {   // a nested list, less indented
                u_putn(t, s + pj, pe - pj);
                buf_u8(t, '\n');
                i = pe + 1;
                continue;
            }
            if (pind == base && md_marker(s, pj, pe) == 0 && !md_fence_len(s, pj, pe)
                && ld8(s + pj) != '>' && ld8(s + pj) != '#') {
                u_putn(t, s + pj, pe - pj);            // lazy continuation
                buf_u8(t, '\n');
                i = pe + 1;
                continue;
            }
            break;
        }
        md_item(b, buf_p(t), buf_len(t));
    }
    if (ordered) u_put(b, "</ol>\n");
    else         u_put(b, "</ul>\n");
    return i;
}

// one row of a pipe table into <th>/<td> cells
void md_row(uptr b, uptr s, i64 i, i64 e, uptr tag) {
    i64 j = md_first(s, i, e);
    i64 end = e;
    loop {
        if (end <= j) break;
        i64 c = ld8(s + end - 1);
        if (c != ' ' && c != '\t') break;
        end = end - 1;
    }
    if (j < end && ld8(s + j) == '|') j = j + 1;
    if (end > j && ld8(s + end - 1) == '|') end = end - 1;
    u_put(b, "<tr>");
    i64 cell = j;
    loop {
        if (cell > end) break;
        i64 k = cell;
        i64 stop = end;
        loop {
            if (k >= end) { stop = end; break; }
            i64 c = ld8(s + k);
            if (c == '\\') { k = k + 2; continue; }
            if (c == '`') {
                i64 r = 0;
                loop {
                    if (k + r < end && ld8(s + k + r) == '`') r = r + 1;
                    else break;
                }
                i64 cl = md_code_close(s, end, k + r, r);
                if (cl < 0) k = k + r;
                else k = cl + r;
                continue;
            }
            if (c == '|') { stop = k; break; }
            k = k + 1;
        }
        // `\|` inside a cell is a literal bar, as GitHub renders it
        u8 t[BUF_SIZE];
        buf_init(t);
        i64 p = cell;
        loop {
            if (p >= stop) break;
            if (ld8(s + p) == '\\' && p + 1 < stop && ld8(s + p + 1) == '|') {
                buf_u8(t, '|');
                p = p + 2;
                continue;
            }
            buf_u8(t, ld8(s + p));
            p = p + 1;
        }
        uptr text = u_trim(u_take(t));
        u_put(b, "<");
        u_put(b, tag);
        u_put(b, ">");
        md_inline(b, text, cstrlen(text));
        u_put(b, "</");
        u_put(b, tag);
        u_put(b, ">");
        cell = stop + 1;
    }
    u_put(b, "</tr>\n");
}

i64 md_table(uptr b, uptr s, i64 n, i64 i) {
    i64 e = md_eol(s, n, i);
    u_put(b, "<div class=\"table-wrap\">\n<table>\n<thead>\n");
    md_row(b, s, i, e, "th");
    u_put(b, "</thead>\n<tbody>\n");
    i = md_eol(s, n, e + 1) + 1;                    // skip the delimiter row
    loop {
        if (i >= n) break;
        i64 pe = md_eol(s, n, i);
        if (md_is_blank(s, i, pe)) break;
        if (u_chr(s, pe, i, '|') < 0) break;
        md_row(b, s, i, pe, "td");
        i = pe + 1;
    }
    u_put(b, "</tbody>\n</table>\n</div>\n");
    return i;
}

void md_blocks(uptr b, uptr s, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 e = md_eol(s, n, i);
        if (md_is_blank(s, i, e)) { i = e + 1; continue; }
        i64 j = md_first(s, i, e);
        if (md_fence_len(s, j, e)) { i = md_code_block(b, s, n, i); continue; }
        if (ld8(s + j) == '#') {
            i64 lvl = 0;
            loop {
                if (j + lvl >= e) break;
                if (ld8(s + j + lvl) != '#') break;
                lvl = lvl + 1;
            }
            if (lvl >= 1 && lvl <= 6 && j + lvl < e && ld8(s + j + lvl) == ' ') {
                i64 tend = e;
                loop {                                  // a trailing run of # is decoration
                    if (tend <= j + lvl) break;
                    i64 c = ld8(s + tend - 1);
                    if (c != '#' && c != ' ') break;
                    tend = tend - 1;
                }
                md_heading(b, lvl, s + j + lvl + 1, tend - j - lvl - 1);
                i = e + 1;
                continue;
            }
        }
        if (md_is_hr(s, j, e)) { u_put(b, "<hr>\n"); i = e + 1; continue; }
        if (ld8(s + j) == '>') { i = md_quote(b, s, n, i); continue; }
        if (md_marker(s, j, e)) { i = md_list(b, s, n, i); continue; }
        if (u_chr(s, e, j, '|') >= 0 && e + 1 < n) {
            i64 de = md_eol(s, n, e + 1);
            if (md_is_delim(s, e + 1, de)) { i = md_table(b, s, n, i); continue; }
        }
        i = md_para(b, s, n, i);
    }
}

// the page body, as HTML
uptr md_render(uptr s, i64 n) {
    u8 b[BUF_SIZE];
    buf_init(b);
    md_blocks(b, s, n);
    return u_take(b);
}
