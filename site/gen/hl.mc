// hl.mc - fenced code blocks, and the highlighting of the ```mc ones with the
// BUNDLED lexer (`#include <mc/lex>`): the same tok_init table, the same
// lex_next, the same token ids the compiler itself uses. Nothing here
// re-implements a scanner for the language; what it adds around the lexer is
//
//   * the gap between two tokens -- blanks and `//` / `/* */` comments, which
//     the lexer skips and a listing has to show (tok-comment);
//   * the raw span of a token, because T_STR's tok_start points at the DECODED
//     string in the arena and the page has to show what was typed;
//   * `#include <name>`, which the lexer hands over as three tokens (`<`, name,
//     `>`) and the contract renders as one tok-str;
//   * the taught vocabulary, so a word the surface created is marked tok-taught
//     instead of tok-ident.
//
// Token class -> span, exactly the nine classes of site/README.md § Code
// highlighting.
//
// A fence whose content the lexer would refuse (an unterminated string, a
// character no punctuation table knows) is emitted WITHOUT spans and a note goes
// to stderr: the site must render whatever docs/ holds, and half of docs/ is
// about errors. The check that decides it is hl_scan_ok(), which mirrors
// lex_next's error paths one for one.

#define HL_MAXVOCAB 64                // taught lexemes cited by one fence

uptr hl_root = 0;                     // repository root, for `taught=` and `#include <name>`
uptr hl_cache_path;                   // files already scanned for taught words
uptr hl_cache_vocab;                  // their vocabularies, parallel
uptr hl_file = 0;                     // page being rendered, for the notes on stderr
uptr hl_langs;                        // fence languages that go through the lexer
i64  hl_notes = 0;                    // fences that fell back to no highlighting
i64  hl_done = 0;                     // fences that were highlighted

void hl_init(uptr root) {
    hl_root = root;
    hl_cache_path = sl_new();
    hl_cache_vocab = sl_new();
    hl_langs = sl_new();
}

void hl_lang_add(uptr name) { if (!sl_has(hl_langs, name)) sl_add(hl_langs, name); }

// ---- the taught vocabulary ----
// A textual scan, not a parse: what creates a lexeme in this language is always
// one of five spellings, and each of them names its lexeme right after the
// keyword (docs/surface.md).
i64 hl_word_end(uptr s, i64 n, i64 i) {
    loop {
        if (i >= n) break;
        if (!is_alnum(ld8(s + i))) break;
        i = i + 1;
    }
    return i;
}

i64 hl_skip_blank(uptr s, i64 n, i64 i) {
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c != ' ' && c != '\t') break;
        i = i + 1;
    }
    return i;
}

// the lexeme at i: "quoted" or bare. Returns the index after it, or -1.
i64 hl_lexeme(uptr vocab, uptr s, i64 n, i64 i) {
    if (i >= n) return 0 - 1;
    if (ld8(s + i) == '"') {
        i64 k = i + 1;
        loop {
            if (k >= n) break;
            if (ld8(s + k) == '"') break;
            if (ld8(s + k) == '\n') return 0 - 1;
            k = k + 1;
        }
        if (k >= n) return 0 - 1;
        if (k > i + 1 && sl_n(vocab) < HL_MAXVOCAB) sl_add(vocab, xstrdup(s + i + 1, k - i - 1));
        return k + 1;
    }
    i64 e = hl_word_end(s, n, i);
    if (e == i) return 0 - 1;
    if (sl_n(vocab) < HL_MAXVOCAB) sl_add(vocab, xstrdup(s + i, e - i));
    return e;
}

// `#rule stmt: while ( ... )` -> the first item after the colon is the dispatch
// literal, and that is the word the surface created.
void hl_rule_lexeme(uptr vocab, uptr s, i64 n, i64 i) {
    i = hl_skip_blank(s, n, i);
    i64 e = hl_word_end(s, n, i);              // the non-terminal (stmt)
    if (e == i) return;
    i = hl_skip_blank(s, n, e);
    if (i >= n || ld8(s + i) != ':') return;
    i = hl_skip_blank(s, n, i + 1);
    if (i >= n || ld8(s + i) == '\n') return;
    hl_lexeme(vocab, s, n, i);
}

void hl_collect(uptr vocab, uptr s, i64 n);

// the vocabulary of one file on disk, scanned once and remembered
uptr hl_file_vocab(uptr path) {
    i64 k = sl_index(hl_cache_path, path);
    if (k >= 0) return sl_at(hl_cache_vocab, k);
    uptr v = sl_new();
    sl_add(hl_cache_path, u_dup(path));
    sl_add(hl_cache_vocab, v);
    if (!u_file_exists(path)) return v;
    i64 len = 0;
    uptr src = read_file(path, &len);
    hl_collect(v, src, len);
    return v;
}

void hl_merge(uptr vocab, uptr other) {
    i64 i = 0;
    loop {
        if (i >= sl_n(other)) break;
        if (!sl_has(vocab, sl_at(other, i)) && sl_n(vocab) < HL_MAXVOCAB) {
            sl_add(vocab, sl_at(other, i));
        }
        i = i + 1;
    }
}

// `#include <name>` as the fence writes it -> the file of the repository that
// the bundle serves under that name (tools/bundle.list: lib/<name>.mc for a bare
// name, src/<name>.mc under mc/).
uptr hl_bundled_path(uptr name) {
    if (hl_root == 0) return 0;
    if (u_starts(name, "mc/")) {
        uptr p = u_cat3(hl_root, "/src/", u_cat2(name + 3, ".mc"));
        if (u_file_exists(p)) return p;
        return 0;
    }
    uptr a = u_cat3(hl_root, "/lib/", u_cat2(name, ".mc"));
    if (u_file_exists(a)) return a;
    uptr b = u_cat3(hl_root, "/src/", u_cat2(name, ".mc"));
    if (u_file_exists(b)) return b;
    return 0;
}

void hl_collect(uptr vocab, uptr s, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c == '#') {
            i64 e = hl_word_end(s, n, i + 1);
            i64 dl = e - i - 1;
            uptr d = s + i + 1;
            if (dl == 5 && mem_eq(d, "token", 5)) {
                i64 k = hl_lexeme(vocab, s, n, hl_skip_blank(s, n, e));
                if (k > 0) { i = k; continue; }
            } else if (dl == 4 && mem_eq(d, "rule", 4)) {
                hl_rule_lexeme(vocab, s, n, e);
            } else if (dl == 5 && mem_eq(d, "infix", 5)) {
                i64 k = hl_lexeme(vocab, s, n, hl_skip_blank(s, n, e));
                if (k > 0) { i = k; continue; }
            } else if (dl == 6 && mem_eq(d, "prefix", 6)) {
                i64 k = hl_lexeme(vocab, s, n, hl_skip_blank(s, n, e));
                if (k > 0) { i = k; continue; }
            } else if (dl == 7 && mem_eq(d, "include", 7)) {
                i64 k = hl_skip_blank(s, n, e);
                if (k < n && ld8(s + k) == '<') {
                    i64 g = u_chr(s, n, k, '>');
                    i64 nl = u_chr(s, n, k, '\n');
                    if (g > 0 && (nl < 0 || g < nl)) {
                        uptr p = hl_bundled_path(xstrdup(s + k + 1, g - k - 1));
                        if (p) hl_merge(vocab, hl_file_vocab(p));
                        i = g + 1;
                        continue;
                    }
                }
            }
            i = e;
            continue;
        }
        if (c == 's' && i + 7 <= n && mem_eq(s + i, "syntax", 6)
            && (i == 0 || !is_alnum(ld8(s + i - 1)))) {
            i64 k = hl_skip_blank(s, n, i + 6);
            if (k < n && ld8(s + k) == '(') {
                k = hl_skip_blank(s, n, k + 1);
                if (k < n && ld8(s + k) == '"') {
                    i64 e2 = hl_lexeme(vocab, s, n, k);
                    if (e2 > 0) { i = e2; continue; }
                }
            }
            i = i + 6;
            continue;
        }
        i = i + 1;
    }
}

// ---- can the bundled lexer read this fence? ----
// One branch per error path of lex_next / read_char / lex_number / lex_directive
// / lex_hole. Returns 0 at the first byte that would kill the run.
i64 hl_scan_ok(uptr s, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (u_is_space(c)) { i = i + 1; continue; }
        if (c == '/' && i + 1 < n && ld8(s + i + 1) == '/') {
            i64 nl = u_chr(s, n, i, '\n');
            if (nl < 0) return 1;
            i = nl + 1;
            continue;
        }
        if (c == '/' && i + 1 < n && ld8(s + i + 1) == '*') {
            i64 k = i + 2;
            loop {
                if (k + 1 >= n) return 0;                 // unterminated comment
                if (ld8(s + k) == '*' && ld8(s + k + 1) == '/') break;
                k = k + 1;
            }
            i = k + 2;
            continue;
        }
        if (is_digit(c)) {
            if (c == '0' && i + 1 < n && (ld8(s + i + 1) == 'x' || ld8(s + i + 1) == 'X')) {
                if (i + 2 >= n || hex_val(ld8(s + i + 2)) < 0) return 0;
                i = i + 2;
                loop {
                    if (i >= n) break;
                    if (hex_val(ld8(s + i)) < 0) break;
                    i = i + 1;
                }
                continue;
            }
            i = hl_word_end(s, n, i);
            continue;
        }
        if (is_alpha(c)) { i = hl_word_end(s, n, i); continue; }
        if (c == '\'' || c == '"') {
            i64 in_str = c == '"';
            i64 k = i + 1;
            loop {
                if (k >= n) return 0;                     // unterminated literal
                i64 d = ld8(s + k);
                if (in_str && d == '"') break;
                if (!in_str && d == '\'') break;
                if (d == '\\') {
                    if (k + 1 >= n) return 0;
                    i64 esc = ld8(s + k + 1);
                    if (esc == '0' && in_str) return 0;   // \0 is refused in a string
                    if (esc != 'n' && esc != 't' && esc != 'r' && esc != '0'
                        && esc != '\\' && esc != '\'' && esc != '"') return 0;
                    k = k + 2;
                    continue;
                }
                k = k + 1;
            }
            if (!in_str && k != i + 2 && !(k == i + 3 && ld8(s + i + 1) == '\\')) return 0;
            i = k + 1;
            continue;
        }
        if (c == '#') {
            i64 e = hl_word_end(s, n, i + 1);
            if (dir_index(s + i + 1, e - i - 1) < 0) return 0;
            i = e;
            continue;
        }
        if (c == '$') {
            i64 k = i + 1;
            if (k < n && ld8(s + k) == '$') k = k + 1;
            if (k >= n) return 0;
            if (!is_alnum(ld8(s + k))) return 0;
            i = hl_word_end(s, n, k);
            continue;
        }
        i64 plen = 0;
        if (punct_id(s + i, n - i, &plen) < 0) return 0;
        i = i + plen;
    }
    return 1;
}

// ---- the token table, rebuilt per fence ----
// tok_init() appends the 45 core lexemes; resetting the counter first means one
// fence never sees the words another fence taught, whatever order the pages are
// rendered in (docs/determinism.md, rule 1).
void hl_table(uptr vocab) {
    ntok = 0;
    tok_init();
    i64 i = 0;
    loop {
        if (i >= sl_n(vocab)) break;
        uptr w = sl_at(vocab, i);
        if (cstrlen(w) > 0) tok_add(w, cstrlen(w));
        i = i + 1;
    }
}

uptr hl_class(i64 id, uptr text, i64 len, uptr vocab, i64 in_dir) {
    u8 tmp[64];
    if (len > 0 && len < 63) {
        mem_copy(tmp, text, len);
        st8(tmp + len, 0);
        if (sl_has(vocab, tmp)) return "tok-taught";
    }
    if (id == T_DIR)  return "tok-dir";
    if (id == T_HOLE) return "tok-hole";
    if (id == T_INT)  return "tok-num";
    if (id == T_CHAR) return "tok-str";
    if (id == T_STR)  return "tok-str";
    if (id == T_IDENT) {
        if (in_dir) {
            if (len == 4 && mem_eq(text, "stmt", 4))  return "tok-dir";
            if (len == 4 && mem_eq(text, "expr", 4))  return "tok-dir";
            if (len == 5 && mem_eq(text, "block", 5)) return "tok-dir";
            if (len == 5 && mem_eq(text, "ident", 5)) return "tok-dir";
        }
        return "tok-ident";
    }
    if (id >= K_U8 && id <= K_EXTERN) return "tok-keyword";
    if (id >= K_LPAR) return "tok-op";
    return "tok-ident";
}

void hl_span(uptr b, uptr cls, uptr text, i64 len) {
    u_put(b, "<span class=\"");
    u_put(b, cls);
    u_put(b, "\">");
    u_esc_text_n(b, text, len);
    u_put(b, "</span>");
}

// blanks and comments between two tokens, emitted as they were typed
i64 hl_gap(uptr b, uptr s, i64 n, i64 i, uptr pin_dir) {
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (u_is_space(c)) {
            if (c == '\n') st64(pin_dir, 0);
            u_esc_text_n(b, s + i, 1);
            i = i + 1;
            continue;
        }
        if (c == '/' && i + 1 < n && ld8(s + i + 1) == '/') {
            i64 nl = u_chr(s, n, i, '\n');
            if (nl < 0) nl = n;
            hl_span(b, "tok-comment", s + i, nl - i);
            i = nl;
            continue;
        }
        if (c == '/' && i + 1 < n && ld8(s + i + 1) == '*') {
            i64 k = i + 2;
            loop {
                if (k + 1 >= n) break;
                if (ld8(s + k) == '*' && ld8(s + k + 1) == '/') break;
                k = k + 1;
            }
            i64 end = k + 2;
            if (end > n) end = n;
            hl_span(b, "tok-comment", s + i, end - i);
            i = end;
            continue;
        }
        break;
    }
    return i;
}

// the whole fence, token by token
void hl_mc(uptr b, uptr code, i64 n, uptr vocab) {
    nopen = 0;                                   // one fence, one lexer frame
    lex_push_mem("<fence>", code, n, 1, 1);
    u8 t[TOK_SIZE];
    i64 i = 0;
    i64 in_dir = 0;
    loop {
        i = hl_gap(b, code, n, i, &in_dir);
        if (i >= n) break;
        cp = code + i;
        cend = code + n;
        lex_next(t);
        i64 end = cp - code;
        if (end <= i) break;                     // never possible; a guard, not a case
        i64 id = tok_id(t);
        if (id == T_EOF) break;
        hl_span(b, hl_class(id, code + i, end - i, vocab, in_dir), code + i, end - i);
        if (id == T_DIR) in_dir = 1;
        i = end;
        // `#include <name>`: the target is one tok-str, not `<` name `>`
        if (id == T_DIR && tok_val(t) == D_INCLUDE) {
            i64 k = i;
            loop {
                if (k >= n) break;
                i64 sp = ld8(code + k);
                if (sp != ' ' && sp != '\t') break;
                k = k + 1;
            }
            if (k < n && ld8(code + k) == '<') {
                i64 g = u_chr(code, n, k, '>');
                i64 nl = u_chr(code, n, k, '\n');
                if (g > 0 && (nl < 0 || g < nl)) {
                    u_esc_text_n(b, code + i, k - i);
                    hl_span(b, "tok-str", code + k, g - k + 1);
                    i = g + 1;
                }
            }
        }
    }
    nopen = 0;
}

// ---- the block ----
// info string: the language, then optional `key=value` words. Only `taught=PATH`
// is understood, and it names a file of the repository whose taught lexemes the
// fence borrows.
uptr hl_info_word(uptr info, i64 k) {
    i64 n = cstrlen(info);
    i64 i = k;
    loop {
        if (i >= n) break;
        if (u_is_space(ld8(info + i))) break;
        i = i + 1;
    }
    return xstrdup(info + k, i - k);
}

// `taught=PATH` names either one compiler source or a PROJECT DIRECTORY -- the
// two shapes `scripts/check-docs.sh` accepts, because `mc build examples/lang`
// assembles its compiler from modules that live in that directory. For a
// directory every `.mc` at its top level is scanned (the modules are there;
// build/ is not walked). Returns 0 when there is nothing to read.
i64 hl_taught_vocab(uptr vocab, uptr path) {
    if (u_dir_exists(path)) {
        uptr all = u_listdir(path, DT_REG);
        i64 i = 0;
        i64 got = 0;
        loop {
            if (i >= sl_n(all)) break;
            uptr f = sl_at(all, i);
            if (u_ends(f, ".mc")) {
                hl_merge(vocab, hl_file_vocab(u_join(path, f)));
                got = 1;
            }
            i = i + 1;
        }
        return got;
    }
    if (!u_file_exists(path)) return 0;
    hl_merge(vocab, hl_file_vocab(path));
    return 1;
}

void hl_block(uptr b, uptr code, i64 n, uptr info) {
    uptr lang = hl_info_word(info, 0);
    if (cstrlen(lang) == 0) lang = u_dup("text");
    u_put(b, "<pre class=\"code\" tabindex=\"0\"><code class=\"lang-");
    u_esc(b, u_slug(lang));
    u_put(b, "\">");
    if (sl_has(hl_langs, lang)) {
        uptr vocab = sl_new();
        i64 tk = u_find(info, cstrlen(info), 0, "taught=");
        if (tk >= 0) {
            uptr rel = hl_info_word(info, tk + 7);
            uptr path = rel;
            if (hl_root != 0 && ld8(rel) != '/') path = u_join(hl_root, rel);
            if (!hl_taught_vocab(vocab, path)) {
                out_str(2, "mcsite: taught source not readable, core classes only: ");
                out_str(2, path);
                out_str(2, "\n");
                hl_notes = hl_notes + 1;
            }
        }
        hl_collect(vocab, code, n);
        hl_table(vocab);                          // the scan below uses punct_id
        if (hl_scan_ok(code, n)) {
            hl_mc(b, code, n, vocab);
            hl_done = hl_done + 1;
        } else {
            // Not an error: half of docs/ is about diagnostics, and a fence that
            // shows a message the lexer refuses still has to appear on the page.
            hl_notes = hl_notes + 1;
            u_esc_text_n(b, code, n);
        }
    } else {
        u_esc_text_n(b, code, n);
    }
    u_put(b, "</code></pre>\n");
}
