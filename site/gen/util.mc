// util.mc - strings, growable tables, paths, directories and files for mcsite.
//
// Everything here sits on top of <mc/arena> (xalloc, Buf, read_file, write_file,
// out_*, die) and <mc/lex> (path_join, path_norm, lex_readable). No struct: every
// record is a flat block of 8-byte fields reached through accessors, the same
// discipline src/*.mc has followed since M6.
//
// The only externs this file adds are the directory ones: opendir/readdir/closedir
// (macOS arm64 has no $INODE64 suffix, so `readdir` already is the 64-bit-inode
// entry point) and mkdir. The dirent fields used are the two the layout of
// <sys/dirent.h> puts right after d_ino/d_seekoff/d_reclen:
//
//   0  d_ino (u64)   8  d_seekoff (u64)   16 d_reclen (u16)
//   18 d_namlen (u16)  20 d_type (u8)     21 d_name (bytes, d_namlen long)
//
// Directory order is whatever the filesystem hands back, so every listing is
// sorted before it is used (docs/determinism.md, rule 1: nothing iterated but an
// array in a fixed order).

extern uptr opendir(uptr path);
extern uptr readdir(uptr dirp);
extern i64  closedir(uptr dirp);
extern i64  mkdir(uptr path, i64 mode);
extern i64  rmdir(uptr path);
extern i64  unlink(uptr path);

#define DIRENT_NAMLEN 18
#define DIRENT_TYPE   20
#define DIRENT_NAME   21
#define DT_DIR   4
#define DT_REG   8
#define DT_LNK  10

// MODE_755 (0755 in decimal: the core has no octal literal) comes from
// <mc/arena>, which this file already has through site/gen/main.mc. It was
// defined here until M41 moved it into the arena, and a second #define of the
// same name is an error.

// ---- growable block (the shape of arena.mc's grow(), without the registry) ----
// The registry ids in arena.mc name the compiler's own tables; mcsite is not the
// compiler, so it keeps its own doubling helper instead of borrowing them.
uptr u_grow(uptr p, i64 n, uptr pcap, i64 esz) {
    i64 cap = ld64(pcap);
    if (n < cap) return p;
    i64 nc = cap * 2;
    if (nc == 0) nc = 32;
    if (nc <= n) nc = n + 1;
    uptr np = xalloc(nc * esz);
    mem_copy(np, p, n * esz);
    st64(pcap, nc);
    return np;
}

// ---- strings ----
// Every string mcsite hands around is NUL-terminated and lives in the arena, so
// it is enough to keep one pointer. Buf is used only while a string is being
// built; u_take() freezes it.

void u_put(uptr b, uptr s)            { buf_put(b, s, cstrlen(s)); }
void u_putn(uptr b, uptr s, i64 n)    { buf_put(b, s, n); }

void u_putnum(uptr b, i64 v) {
    u8 tmp[24];
    i64 i = 24;
    i64 neg = v < 0;
    if (neg) v = 0 - v;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    if (neg) { i = i - 1; st8(tmp + i, '-'); }
    buf_put(b, tmp + i, 24 - i);
}

// the buffer's bytes as a NUL-terminated string (the arena hands out zeroed
// memory, so xstrdup's extra byte is already the terminator)
uptr u_take(uptr b) { return xstrdup(buf_p(b), buf_len(b)); }

uptr u_dup(uptr s) { return xstrdup(s, cstrlen(s)); }

uptr u_cat2(uptr a, uptr b) {
    u8 t[BUF_SIZE];
    buf_init(t);
    u_put(t, a);
    u_put(t, b);
    return u_take(t);
}

uptr u_cat3(uptr a, uptr b, uptr c) {
    u8 t[BUF_SIZE];
    buf_init(t);
    u_put(t, a);
    u_put(t, b);
    u_put(t, c);
    return u_take(t);
}

uptr u_cat4(uptr a, uptr b, uptr c, uptr d) {
    u8 t[BUF_SIZE];
    buf_init(t);
    u_put(t, a);
    u_put(t, b);
    u_put(t, c);
    u_put(t, d);
    return u_take(t);
}

uptr u_slice(uptr s, i64 from, i64 len) { return xstrdup(s + from, len); }

// byte order, like strcmp: <0, 0 or >0. Only the sign is ever used.
i64 u_cmp(uptr a, uptr b) {
    i64 i = 0;
    loop {
        i64 ca = ld8(a + i);
        i64 cb = ld8(b + i);
        if (ca != cb) return ca - cb;
        if (ca == 0) return 0;
        i = i + 1;
    }
    return 0;
}

i64 u_starts(uptr s, uptr pre) {
    i64 i = 0;
    loop {
        i64 c = ld8(pre + i);
        if (c == 0) return 1;
        if (ld8(s + i) != c) return 0;
        i = i + 1;
    }
    return 1;
}

i64 u_ends(uptr s, uptr suf) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(suf);
    if (m > n) return 0;
    return mem_eq(s + n - m, suf, m);
}

// first occurrence of pat in s[from..n), or -1
i64 u_find(uptr s, i64 n, i64 from, uptr pat) {
    i64 m = cstrlen(pat);
    if (m == 0) return from;
    i64 i = from;
    loop {
        if (i + m > n) break;
        if (mem_eq(s + i, pat, m)) return i;
        i = i + 1;
    }
    return 0 - 1;
}

i64 u_chr(uptr s, i64 n, i64 from, i64 c) {
    i64 i = from;
    loop {
        if (i >= n) break;
        if (ld8(s + i) == c) return i;
        i = i + 1;
    }
    return 0 - 1;
}

i64 u_is_space(i64 c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
i64 u_lower(i64 c) {
    if (c >= 'A' && c <= 'Z') return c + 32;
    return c;
}

// ---- URL schemes ----
// What ends up inside an href= or a src= decides whether the page can run
// script, so what is tested is the SCHEME, never the substring "://" --
// `javascript://%0aalert(1)//` carries that substring exactly like an ordinary
// absolute URL does, and used to pass for one both here and in --check.
//
//   U_SCHEME_NONE  no scheme: a fragment, an absolute path, a relative file,
//                  resolved by the caller the way it always was
//   U_SCHEME_ABS   one of the three schemes a documentation page may link to
//   U_SCHEME_BAD   anything else -- `javascript:`, `data:`, `vbscript:`,
//                  `file:` -- refused when rendering and reported by --check
#define U_SCHEME_NONE 0
#define U_SCHEME_ABS  1
#define U_SCHEME_BAD  2
#define U_SCHEME_MAX  32              // longest scheme name kept, NUL included

// RFC 3986: a letter, then letters/digits/`+`/`-`/`.`, then `:`. The bytes a
// browser strips before it parses a URL (tab, newline, every control byte) are
// skipped here too, so `java<tab>script:` cannot hide a scheme from the test.
i64 u_scheme(uptr s) {
    u8 name[U_SCHEME_MAX];
    i64 k = 0;
    i64 i = 0;
    loop {
        i64 c = ld8(s + i);
        if (c == 0) return U_SCHEME_NONE;             // ran out with no colon
        i = i + 1;
        if (c <= ' ' || c == 127) continue;           // stripped by the browser
        if (c == ':') break;
        c = u_lower(c);
        i64 ok = 0;
        if (c >= 'a' && c <= 'z') ok = 1;
        if (k != 0 && (is_digit(c) || c == '+' || c == '-' || c == '.')) ok = 1;
        if (!ok) return U_SCHEME_NONE;                // not a scheme byte
        if (k >= U_SCHEME_MAX - 1) return U_SCHEME_BAD;
        st8(name + k, c);
        k = k + 1;
    }
    if (k == 0) return U_SCHEME_BAD;                  // a bare `:` opens nothing
    st8(name + k, 0);
    if (str_eq(name, "http"))   return U_SCHEME_ABS;
    if (str_eq(name, "https"))  return U_SCHEME_ABS;
    if (str_eq(name, "mailto")) return U_SCHEME_ABS;
    return U_SCHEME_BAD;
}

// s without leading and trailing blanks, as a fresh string
uptr u_trim(uptr s) {
    i64 n = cstrlen(s);
    i64 a = 0;
    loop {
        if (a >= n) break;
        if (!u_is_space(ld8(s + a))) break;
        a = a + 1;
    }
    i64 b = n;
    loop {
        if (b <= a) break;
        if (!u_is_space(ld8(s + b - 1))) break;
        b = b - 1;
    }
    return u_slice(s, a, b - a);
}

// the first n bytes at most, cut at a blank and with an ellipsis when something
// was left out: a <meta name=description> is read by machines that stop around
// 160 characters, and a page's first paragraph is often much longer
uptr u_clip(uptr s, i64 n) {
    i64 len = cstrlen(s);
    if (len <= n) return s;
    i64 cut = n;
    loop {
        if (cut <= 0) break;
        if (ld8(s + cut) == ' ') break;
        cut = cut - 1;
    }
    if (cut == 0) {
        cut = n;
        loop {                        // never cut a UTF-8 sequence in half
            if (cut <= 0) break;
            if ((ld8(s + cut) & 0xc0) != 0x80) break;
            cut = cut - 1;
        }
    }
    return u_cat2(u_slice(s, 0, cut), "...");
}

// ---- string list: a growable array of string pointers ----
#define SL_ITEMS 0
#define SL_N     8
#define SL_CAP   16
#define SL_SIZE  24

uptr sl_new() {
    uptr l = xalloc(SL_SIZE);
    st64(l + SL_ITEMS, 0);
    st64(l + SL_N, 0);
    st64(l + SL_CAP, 0);
    return l;
}

i64  sl_n(uptr l)          { return ld64(l + SL_N); }
uptr sl_at(uptr l, i64 i)  { return ld64(ld64(l + SL_ITEMS) + i * 8); }

void sl_add(uptr l, uptr s) {
    i64 n = ld64(l + SL_N);
    st64(l + SL_ITEMS, u_grow(ld64(l + SL_ITEMS), n, l + SL_CAP, 8));
    st64(ld64(l + SL_ITEMS) + n * 8, s);
    st64(l + SL_N, n + 1);
}

i64 sl_has(uptr l, uptr s) {
    i64 i = 0;
    loop {
        if (i >= sl_n(l)) break;
        if (str_eq(sl_at(l, i), s)) return 1;
        i = i + 1;
    }
    return 0;
}

i64 sl_index(uptr l, uptr s) {
    i64 i = 0;
    loop {
        if (i >= sl_n(l)) break;
        if (str_eq(sl_at(l, i), s)) return i;
        i = i + 1;
    }
    return 0 - 1;
}

// the same list holding plain integers: a slot is 8 bytes either way, and a
// heading level or a page index needs no second table type
void il_add(uptr l, i64 v) { sl_add(l, v); }
i64  il_at(uptr l, i64 i)  { return sl_at(l, i); }
i64  il_n(uptr l)          { return sl_n(l); }

// insertion sort by byte order: stable, in place, no libc, deterministic
void sl_sort(uptr l) {
    uptr it = ld64(l + SL_ITEMS);
    i64 n = sl_n(l);
    i64 i = 1;
    loop {
        if (i >= n) break;
        uptr v = ld64(it + i * 8);
        i64 j = i - 1;
        loop {
            if (j < 0) break;
            if (u_cmp(ld64(it + j * 8), v) <= 0) break;
            st64(it + (j + 1) * 8, ld64(it + j * 8));
            j = j - 1;
        }
        st64(it + (j + 1) * 8, v);
        i = i + 1;
    }
}

// ---- filesystem ----
// A FILE, not merely a readable path: `open()` succeeds on a directory too, and
// every caller here goes on to `read_file` it, which would die with `read
// error`. `docs/` links to directories (`../examples/api`) and a fence may name
// one, so the distinction is not theoretical.
i64 u_file_exists(uptr path) {
    if (!lex_readable(path)) return 0;
    if (u_dir_exists(path)) return 0;
    return 1;
}

i64 u_dir_exists(uptr path) {
    uptr d = opendir(path);
    if (d == 0) return 0;
    closedir(d);
    return 1;
}

// every parent directory of `path`, then `path` itself if it names a directory
void u_mkdirs(uptr path) {
    i64 i = 0;
    loop {
        i64 c = ld8(path + i);
        if (c == 0) break;
        if (c == '/' && i > 0) {
            st8(path + i, 0);
            mkdir(path, MODE_755);
            st8(path + i, '/');
        }
        i = i + 1;
    }
}

void u_mkdir(uptr path) {
    uptr p = u_dup(path);
    u_mkdirs(p);
    mkdir(p, MODE_755);
}

// names in `dir`, sorted, without "." and ".."; want == DT_DIR keeps only
// directories, want == DT_REG only regular files, want == 0 keeps both.
uptr u_listdir(uptr dir, i64 want) {
    uptr l = sl_new();
    uptr d = opendir(dir);
    if (d == 0) return l;
    loop {
        uptr e = readdir(d);
        if (e == 0) break;
        i64 nl = ld16(e + DIRENT_NAMLEN);
        i64 ty = ld8(e + DIRENT_TYPE);
        if (nl == 0) continue;
        if (ld8(e + DIRENT_NAME) == '.') continue;       // "." ".." and dotfiles
        if (want != 0) {
            // a symlink is followed by asking the filesystem, which mcsite does
            // not need: the tree it renders has none.
            if (ty != want) continue;
        }
        sl_add(l, xstrdup(e + DIRENT_NAME, nl));
    }
    closedir(d);
    sl_sort(l);
    return l;
}

// dir + "/" + name
uptr u_join(uptr dir, uptr name) {
    if (cstrlen(dir) == 0) return u_dup(name);
    if (u_ends(dir, "/")) return u_cat2(dir, name);
    return u_cat3(dir, "/", name);
}

// path without its last component ("a/b/c.md" -> "a/b", "x.md" -> ".")
uptr u_dirname(uptr path) {
    i64 n = cstrlen(path);
    i64 cut = 0 - 1;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(path + i) == '/') cut = i;
        i = i + 1;
    }
    if (cut < 0) return u_dup(".");
    if (cut == 0) return u_dup("/");
    return u_slice(path, 0, cut);
}

uptr u_basename(uptr path) {
    i64 n = cstrlen(path);
    i64 cut = 0 - 1;
    i64 i = 0;
    loop {
        if (i >= n) break;
        if (ld8(path + i) == '/') cut = i;
        i = i + 1;
    }
    return u_slice(path, cut + 1, n - cut - 1);
}

// deletes a directory tree. Only ever called on the output directory, which is
// rebuilt from scratch on every run so that a page deleted from docs/ cannot
// survive in site/public. Refuses the paths that would be a disaster to walk.
void u_rmtree(uptr path, i64 depth) {
    if (depth > 6) return;
    i64 n = cstrlen(path);
    if (n == 0) return;
    if (str_eq(path, "/") || str_eq(path, ".") || str_eq(path, "..")) {
        die2("refusing to delete", path);
    }
    if (!u_dir_exists(path)) return;
    uptr files = u_listdir(path, DT_REG);
    i64 i = 0;
    loop {
        if (i >= sl_n(files)) break;
        unlink(u_join(path, sl_at(files, i)));
        i = i + 1;
    }
    uptr dirs = u_listdir(path, DT_DIR);
    i = 0;
    loop {
        if (i >= sl_n(dirs)) break;
        u_rmtree(u_join(path, sl_at(dirs, i)), depth + 1);
        i = i + 1;
    }
    rmdir(path);
}

// writes the buffer, creating the parent directories first
void u_write(uptr path, uptr b) {
    uptr p = u_dup(path);
    u_mkdirs(p);
    write_file(p, b);
}

// copies one file byte for byte
void u_copy_file(uptr src, uptr dst) {
    i64 len = 0;
    uptr data = read_file(src, &len);
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, data, len);
    u_write(dst, b);
}

// ---- HTML and URL escaping ----
// Every value that is not already markup goes through u_esc; the two URL forms
// also escape the quote, because they land inside href="..." (site/README.md
// § Substitution).
void u_esc_n(uptr b, uptr s, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c == '&')      u_put(b, "&amp;");
        else if (c == '<') u_put(b, "&lt;");
        else if (c == '>') u_put(b, "&gt;");
        else if (c == '"') u_put(b, "&quot;");
        else               buf_u8(b, c);
        i = i + 1;
    }
}

void u_esc(uptr b, uptr s) { u_esc_n(b, s, cstrlen(s)); }

// the same for text that lands between tags and never inside an attribute: a
// quote is a quote there, and a code listing full of &quot; helps nobody
void u_esc_text_n(uptr b, uptr s, i64 n) {
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c == '&')      u_put(b, "&amp;");
        else if (c == '<') u_put(b, "&lt;");
        else if (c == '>') u_put(b, "&gt;");
        else               buf_u8(b, c);
        i = i + 1;
    }
}

void u_esc_text(uptr b, uptr s) { u_esc_text_n(b, s, cstrlen(s)); }

uptr u_escaped(uptr s) {
    u8 b[BUF_SIZE];
    buf_init(b);
    u_esc(b, s);
    return u_take(b);
}

// ---- slugs ----
// lowercase, runs of anything that is not a letter or a digit collapsed into a
// single '-', no leading or trailing '-'. Deterministic and stable: the same
// heading always gets the same id.
uptr u_slug(uptr s) {
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 n = cstrlen(s);
    i64 i = 0;
    i64 dash = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (is_digit(c) || (c >= 'a' && c <= 'z')) { buf_u8(b, c); dash = 0; }
        else if (c >= 'A' && c <= 'Z')             { buf_u8(b, c + 32); dash = 0; }
        else if (c == '_')                         { buf_u8(b, c); dash = 0; }
        else {
            if (buf_len(b) != 0 && !dash) { buf_u8(b, '-'); dash = 1; }
        }
        i = i + 1;
    }
    loop {
        if (buf_len(b) == 0) break;
        if (ld8(buf_p(b) + buf_len(b) - 1) != '-') break;
        set_buf_len(b, buf_len(b) - 1);
    }
    if (buf_len(b) == 0) u_put(b, "section");
    return u_take(b);
}

// "getting-started" -> "Getting started": the fallback title of a page whose
// Markdown has no h1.
uptr u_title_from_slug(uptr s) {
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 n = cstrlen(s);
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 c = ld8(s + i);
        if (c == '-' || c == '_') c = ' ';
        if (i == 0 && c >= 'a' && c <= 'z') c = c - 32;
        buf_u8(b, c);
        i = i + 1;
    }
    return u_take(b);
}
