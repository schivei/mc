// deps.mc — the READ side of packages (M44 § A1-A6, D12): `[deps]`, `mc.lock`,
// the tree hash, and what answers `#include <pack/file.mc>`.
//
// It lives in <mc/core_build> and not in <mc/core_pkg> on purpose: a compiler
// that will never fetch anything still has to BUILD a project from its lock and
// its `deps/` tree. That is the CI and consumer shape, and it is what makes
// "`mc build` never downloads" a property of the code and not of a promise --
// there is no downloader in this file.
//
// The three things it owns:
//
//   1. the name rule and the reserved names (`mc`, `deps`, `build`);
//   2. `mc.lock`: rows of (name, version, lib, sha256, deps), read, resolved to
//      a directory, and REHASHED on every build (D7, "checked, not trusted");
//   3. `libs_open`, the function pointer src/lex.mc calls for `<name>` -- stage
//      0 the lock road, stage 1 the installed `mc` package.
//
// Everything a package tree can say about itself is read through toml_push /
// toml_pop (M44 § 9): the project's own table is swapped out, the foreign file
// is parsed, what is needed is copied into the flat tables below -- name,
// version, hash, files, in source order, rule 1 of docs/determinism.md -- and
// the project's table comes back.
//
// Depends on arena.mc, sha256.mc, toml.mc, lex.mc and the host layer
// (host_home, host_include). Nothing here writes to <libs>: that is `mc pkg`.

// ---- exit codes ----
// 2 is "the environment is not ready" in the M25 sense: a lock that does not
// describe this tree, a package that was never fetched, a byte that moved. A
// script has to be able to tell it from "your program does not compile", which
// is 1 (docs/reference/cli.md § Exit codes).
void dep_die(uptr msg, uptr det, uptr run) {
    out_str(2, "mc: ");
    out_str(2, msg);
    if (det != 0) {
        out_str(2, ": ");
        out_str(2, det);
    }
    out_str(2, "\n");
    if (run != 0) {
        out_str(2, "  run:   ");
        out_str(2, run);
        out_str(2, "\n");
    }
    _exit(2);
}

// ---- the name rule (§ 1) ----
// [a-z][a-z0-9_]*, at most 32 bytes: a bare TOML key, a valid path component on
// all three hosts, and a valid identifier prefix (`geo_init`). Upper case and
// `-` are out so that one spelling is the only spelling.
#define DEP_NAMEMAX 32

i64 dep_name_ok(uptr s) {
    i64 c = ld8(s);
    if (c < 'a' || c > 'z') return 0;
    i64 i = 1;
    loop {
        c = ld8(s + i);
        if (c == 0) break;
        if (i >= DEP_NAMEMAX) return 0;
        if ((c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_') return 0;
        i = i + 1;
    }
    return 1;
}

// `mc` is the compiler's own package and can never be pinned by a lock: <mc/core>
// is the source of the compiler that is RUNNING, and a taught compiler assembled
// from a foreign one would not be the compiler that built it (A5). `deps` and
// `build` are directories `mc build` writes.
i64 dep_reserved(uptr s) {
    if (str_eq(s, "mc")) return 1;
    if (str_eq(s, "deps")) return 1;
    if (str_eq(s, "build")) return 1;
    return 0;
}

// refuses at the key's own file:line:col, through the project's table
void dep_check_name(uptr section, uptr name) {
    uptr key = tm_cat(section, name);
    if (dep_reserved(name)) toml_err_key(key, "reserved package name");
    if (!dep_name_ok(name)) toml_err_key(key, "invalid package name");
}

// ---- semver (§ 3) ----
// X.Y.Z, and a `-suffix` is ignored for ordering -- `0.0.0-dev` compares as
// 0.0.0, so every release is newer than a dev build (C4). Same arithmetic as
// scripts/next-version.sh --gt.
i64 ver_field(uptr s, uptr pi) {
    i64 i = ld64(pi);
    i64 v = 0;
    loop {
        i64 c = ld8(s + i);
        if (c < '0' || c > '9') break;
        v = v * 10 + (c - '0');
        i = i + 1;
    }
    if (ld8(s + i) == '.') i = i + 1;
    st64(pi, i);
    return v;
}

i64 ver_cmp(uptr a, uptr b) {
    i64 ia = 0;
    i64 ib = 0;
    i64 k = 0;
    while (k < 3) {
        i64 x = ver_field(a, &ia);
        i64 y = ver_field(b, &ib);
        if (x < y) return -1;
        if (x > y) return 1;
        k = k + 1;
    }
    return 0;
}

i64 ver_major(uptr a) {
    i64 i = 0;
    return ver_field(a, &i);
}

// ---- the state: one arena record, so this file costs two globals ----
#define DP_APPLIED  0                 // 1 once deps_apply has run
#define DP_NPKG     8
#define DP_PKG      16                // PK_SIZE records, in lock order
#define DP_NFILE    24
#define DP_FILECAP  32
#define DP_FILE     40                // FL_SIZE records
#define DP_MCTRIED  48                // 1 once bundle.list was looked for
#define DP_MCN      56
#define DP_MCNAME   64                // uptr per entry
#define DP_MCPATH   72                // uptr per entry
#define DP_MCDIR    80                // <libs>/mc/v<version>/
// Post-M44 review, finding 5: a tree that is being FETCHED is refused with the
// directory still on the disk, so the refusal has to come back to pkg_fetch_one
// -- which unblesses first and dies afterwards -- instead of leaving through
// _exit() from inside the hash. In soft mode dep_soft_die records the first
// problem here and the hash answers 0; everywhere else it is dep_die, as it was.
#define DP_SOFT     88
#define DP_ERRMSG   96
#define DP_ERRDET   104
#define DP_LABEL    112               // what to call a tree nobody locked yet
#define DP_SIZE     120

#define PK_NAME 0
#define PK_VER  8
#define PK_HASH 16                    // the lock's tree hash, 0 when replaced
#define PK_LIB  24                    // what a bare `<pack>` means, 0 when none
#define PK_DIR  32                    // resolved, normalised, trailing '/'
#define PK_MAN  40                    // the cache manifest, 0 when vendored
#define PK_SIZE 48

#define FL_PKG  0
#define FL_NAME 8
#define FL_SIZE 16

uptr dp = 0;                          // the record above
uptr dp_libs_opt = 0;                 // --libs-dir DIR

uptr dp_state() {
    if (dp == 0) dp = xalloc(DP_SIZE);
    return dp;
}

i64  dp_npkg()          { return ld64(dp_state() + DP_NPKG); }
uptr dp_at(i64 i)       { return ld64(dp_state() + DP_PKG) + i * PK_SIZE; }
uptr dp_name(i64 i)     { return ld64(dp_at(i) + PK_NAME); }
uptr dp_ver(i64 i)      { return ld64(dp_at(i) + PK_VER); }
uptr dp_hash(i64 i)     { return ld64(dp_at(i) + PK_HASH); }
uptr dp_lib(i64 i)      { return ld64(dp_at(i) + PK_LIB); }
uptr dp_dir(i64 i)      { return ld64(dp_at(i) + PK_DIR); }
uptr dp_man(i64 i)      { return ld64(dp_at(i) + PK_MAN); }

// the package's directory and the lexer's root for it are one value written in
// two places: the record is what libs_open joins against, the root is what
// lex_root_of matches a path against.
void dp_set_dir(i64 i, uptr dir) {
    // NORMALISED, once, here: lex_root_of compares the root against paths that
    // came out of path_join, which normalises. A --libs-dir the caller wrote
    // with a `//` in it (macOS TMPDIR ends in `/`) would otherwise be a prefix
    // of nothing and the closure rule would silently never fire.
    dir = tm_cat(path_norm(dir), "/");
    st64(dp_at(i) + PK_DIR, dir);
    lex_set_root_dir(i, dir);
}

i64 dp_find(uptr name) {
    i64 i = 0;
    while (i < dp_npkg()) {
        if (str_eq(dp_name(i), name)) return i;
        i = i + 1;
    }
    return -1;
}

// `geo` out of `geo/vec.mc`, or the whole name when there is no '/'
uptr dep_first(uptr name) {
    i64 n = 0;
    loop {
        i64 c = ld8(name + n);
        if (c == 0 || c == '/') break;
        n = n + 1;
    }
    return xstrdup(name, n);
}

// The file table doubles inside this file instead of going through arena.mc's
// grow(): it is not a compiler table. Its size is the LOCK's -- the developer
// wrote it -- so a growth event carries no information anybody could act on,
// which is the whole point of a `mc limits` row (M23).
void dp_add_file(i64 pk, uptr name) {
    uptr s = dp_state();
    i64 n = ld64(s + DP_NFILE);
    i64 cap = ld64(s + DP_FILECAP);
    if (n >= cap) {
        i64 nc = cap * 2;
        if (nc < 16) nc = 16;
        uptr np = xalloc(nc * FL_SIZE);
        mem_copy(np, ld64(s + DP_FILE), n * FL_SIZE);
        st64(s + DP_FILE, np);
        st64(s + DP_FILECAP, nc);
    }
    uptr e = ld64(s + DP_FILE) + n * FL_SIZE;
    st64(e + FL_PKG, pk);
    st64(e + FL_NAME, name);
    st64(s + DP_NFILE, n + 1);
}

i64 dp_has_file(i64 pk, uptr name) {
    uptr s = dp_state();
    i64 n = ld64(s + DP_NFILE);
    i64 i = 0;
    while (i < n) {
        uptr e = ld64(s + DP_FILE) + i * FL_SIZE;
        if (ld64(e + FL_PKG) == pk && str_eq(ld64(e + FL_NAME), name)) return 1;
        i = i + 1;
    }
    return 0;
}

// ---- containment: what a package may name (post-M44 review, finding 1) ----
// Every path in [package].files is attacker-controlled: it comes out of the
// mc.toml of a tree that was downloaded from a registry row, and it is then
// opened (the tree hash, on EVERY build), copied (`mc pkg vendor`), hashed into
// a manifest and -- before this batch -- unlinked (`pkg_unbless`). Nothing
// checked it, so `files = ["../../../../.ssh/id_rsa"]` read the developer's key
// and `mc pkg vendor` wrote a payload outside the project.
//
// The rule, stated once and applied at every consumer: a files entry is a
// RELATIVE path made of ordinary components. No leading `/`, no `.` and no `..`
// component, no empty component, no backslash (a Windows separator is not a
// component separator here, and letting one through would make the same name
// mean two things on two hosts), and no byte below 0x20 -- which also removes
// the newline that made the hash lines forgeable (finding 3).
//
// `dirok` allows the ONE extra shape an archive member has and a files entry
// never does: a trailing `/`, which is how tar spells a directory.
i64 dep_rel_ok(uptr rel, i64 dirok) {
    i64 n = cstrlen(rel);
    if (n == 0) return 0;
    if (ld8(rel) == '/') return 0;                // absolute
    i64 i = 0;
    while (i < n) {
        i64 c = ld8(rel + i);
        if (c < 32) return 0;                     // control byte, LF included
        if (c == 92) return 0;                    // backslash
        // the characters Windows reserves in a name: `:` (a drive letter, an
        // NTFS stream), `<`, `>`, `"`, `|`, `?`, `*` -- a tar member `C:/x` is
        // absolute to a Windows extractor, and the rule is one rule for the
        // three hosts (Copilot's review of #27)
        if (c == ':' || c == '<' || c == '>' || c == '"' || c == '|' || c == '?' || c == '*') return 0;
        i = i + 1;
    }
    i64 b = 0;
    i = 0;
    loop {
        if (i > n) break;
        if (i == n || ld8(rel + i) == '/') {
            i64 l = i - b;
            // an empty component is `//` or a trailing `/`; the second is a
            // directory member and only an archive may have one
            if (l == 0 && !(dirok && i == n && b > 0)) return 0;
            if (l == 1 && ld8(rel + b) == '.') return 0;
            if (l == 2 && ld8(rel + b) == '.' && ld8(rel + b + 1) == '.') return 0;
            b = i + 1;
        }
        i = i + 1;
    }
    return 1;
}

// The same question asked of the filesystem's own arithmetic, so that a rule
// the component walk somehow let through still cannot escape: the normalised
// join has to start with the normalised directory plus a separator. Belt and
// braces on purpose -- this is the check that would survive a future path_norm.
i64 dep_under(uptr dir, uptr rel) {
    uptr base = tm_cat(path_norm(dir), "/");
    uptr p = path_join(base, rel);                // path_join normalises
    i64 n = cstrlen(base);
    if (cstrlen(p) <= n) return 0;
    return mem_eq(p, base, n);
}

// `geo 1.2.0` for a locked package, the directory for a tree nobody locked
// (`mc pkg hash DIR`, and every tree `mc pkg sync` unpacks).
uptr dep_pkg_what(i64 pk, uptr dir) {
    if (pk >= 0) return tm_cat(tm_cat(dp_name(pk), " "), dp_ver(pk));
    uptr lab = ld64(dp_state() + DP_LABEL);
    if (lab != 0) return lab;
    return dir;
}

// `mc pkg sync` knows the name and version of the tree it has just unpacked
// before any lock does; without this a refusal would name the cache directory.
void dep_hash_label(uptr w) { st64(dp_state() + DP_LABEL, w); }

// The refusal, or the recorded error in soft mode (finding 5).
void dep_soft_die(uptr msg, uptr det) {
    uptr s = dp_state();
    if (ld64(s + DP_SOFT)) {
        if (ld64(s + DP_ERRMSG) == 0) {
            st64(s + DP_ERRMSG, msg);
            st64(s + DP_ERRDET, det);
        }
        return;
    }
    dep_die(msg, det, 0);
}

void dep_hash_soft(i64 on) {
    uptr s = dp_state();
    st64(s + DP_SOFT, on);
    st64(s + DP_ERRMSG, 0);
    st64(s + DP_ERRDET, 0);
    if (!on) st64(s + DP_LABEL, 0);
}

uptr dep_hash_err()    { return ld64(dp_state() + DP_ERRMSG); }
uptr dep_hash_errdet() { return ld64(dp_state() + DP_ERRDET); }

// `mc: geo 1.2.0: files entry escapes the package: ../../../../.ssh/id_rsa`
void dep_file_check(uptr dir, uptr rel, uptr what) {
    if (dep_rel_ok(rel, 0) && dep_under(dir, rel)) return;
    dep_soft_die(tm_cat(what, ": files entry escapes the package"), rel);
}

// ---- the tree hash (D5) ----
// Go's dirhash.Hash1 in plain hex: for `mc.toml` first and then each entry of
// [package].files IN MANIFEST ORDER, one line
//
//     <64 hex of sha256(file bytes)><space><decimal length><colon><path><LF>
//
// The path is LENGTH-PREFIXED (post-M44 review, finding 3). The original shape
// was `<hex><two spaces><path><LF>`, which is Go's dirhash.Hash1 verbatim and
// is not injective: a path carrying a newline writes two lines and the hash
// cannot tell which file list produced them. Go can afford it because its file
// list comes out of a zip it built; here the list is an attacker-controlled
// array in a downloaded mc.toml. A control byte in a files entry is refused
// outright now (dep_rel_ok), so the primitive is gone either way -- the length
// prefix is what makes the FORMAT unable to represent the ambiguity at all.
// scripts/pkg-hash.sh writes the same lines; check-pkg compares the two.
//
// and the tree hash is sha256 of those lines. Content only: no mtime, no mode,
// no directory listing (mc has no opendir -- the author lists the files, which
// is also the vendor-copy list and the build-time boundary), and the bytes are
// taken exactly as they are on disk, LF or CRLF, so a checkout that translates
// line endings changes the hash and says so (.gitattributes `-text`).
// The hex printer and the per-file digest are src/sha256.mc's since M44 step 3
// (hex64, sha256_file): three files print a digest and one of them is a
// fetcher, so the spelling lives beside the function that produces the bytes.

// `dir` carries its trailing '/', so path_join treats it as a directory
uptr dep_in(uptr dir, uptr rel) { return path_join(dir, rel); }

void dep_line(uptr b, uptr dir, uptr rel) {
    uptr p = dep_in(dir, rel);
    if (!lex_readable(p)) {
        dep_soft_die("a file the package lists is missing", p);
        return;
    }
    uptr ln = tm_num_str(cstrlen(rel));
    buf_put(b, sha256_file(p), 64);
    buf_u8(b, ' ');
    buf_put(b, ln, cstrlen(ln));
    buf_u8(b, ':');
    buf_put(b, rel, cstrlen(rel));
    buf_u8(b, '\n');
}

// ---- reading [package].files, once, with every entry checked ----
// The ONE reader of that array. Before this batch each consumer had its own
// copy of the six lines and none of them checked anything, which is why one
// hole was five holes (the hash, the manifest writer, the vendor copy, the
// unbless and the per-file attribution). `what` names the package in a refusal;
// the array comes back through `pnames` and the count is the answer.
i64 dep_read_files(uptr dir, uptr what, uptr pnames) {
    uptr frame = toml_push();
    toml_parse(dep_in(dir, "mc.toml"));
    i64 n = toml_count("package.files");
    uptr names = xalloc(n * 8 + 8);
    i64 i = 0;
    while (i < n) {
        st64(names + i * 8, toml_get_array("package.files", i));
        i = i + 1;
    }
    toml_pop(frame);
    // after the pop, so a refusal cannot leave the project's own table swapped
    // out (M44 § Risks 6) -- it does not matter to _exit, and it does to a
    // soft-mode caller that carries on to unbless the tree
    i = 0;
    while (i < n) {
        dep_file_check(dir, ld64(names + i * 8), what);
        i = i + 1;
    }
    st64(pnames, names);
    return n;
}

// Reads <dir>/mc.toml inside a push/pop: records the package's [package].files
// into the file table and returns the tree hash. Also the one place that reads
// a package manifest at all, so a package that lists nothing hashes its mc.toml
// and no more -- which is a legitimate (and useless) package, not an error.
// Hashes a package tree: <dir>/mc.toml first, then each entry of
// [package].files IN MANIFEST ORDER, through dep_line above. The manifest is
// read inside a push/pop, and the file names are recorded in the file table
// under `pk` -- which is the package's index for a locked tree and -1 for a
// directory nobody locked (`mc pkg hash DIR`, and every tree `mc pkg sync`
// unpacks). Only the entries THIS call added are hashed, so the same table
// serves both and a second call cannot pick up the first one's names.
//
// It is the ONE definition of D5's rule: src/pkg.mc's `hash`, `sync`, `vendor`
// and `check` all come through here, and scripts/pkg-hash.sh is the second
// implementation `make check-pkg` compares it against on every run.
uptr dep_hash_tree(uptr dir, i64 pk) {
    uptr mt = dep_in(dir, "mc.toml");
    if (!lex_readable(mt)) return 0;
    uptr s = dp_state();
    uptr names = 0;
    i64 n = dep_read_files(dir, dep_pkg_what(pk, dir), &names);
    // soft mode: an entry that escapes is reported by the caller, which
    // unblesses the tree first. Nothing was added to the file table.
    if (dep_hash_err() != 0) return 0;
    i64 start = ld64(s + DP_NFILE);
    i64 i = 0;
    while (i < n) {
        dp_add_file(pk, ld64(names + i * 8));
        i = i + 1;
    }

    u8 b[BUF_SIZE];
    buf_init(b);
    dep_line(b, dir, "mc.toml");
    i64 nf = ld64(s + DP_NFILE);
    i = start;
    while (i < nf) {
        dep_line(b, dir, ld64(ld64(s + DP_FILE) + i * FL_SIZE + FL_NAME));
        i = i + 1;
    }
    if (dep_hash_err() != 0) return 0;          // a listed file was missing
    u8 d[32];
    sha256(buf_p(b), buf_len(b), d);
    return hex64(d);
}

// The locked package's tree, hashed and recorded. A package that lists nothing
// hashes its mc.toml and no more -- which is a legitimate (and useless)
// package, not an error.
uptr dep_scan(i64 pk) {
    uptr h = dep_hash_tree(dp_dir(pk), pk);
    if (h == 0)
        dep_die(tm_cat(tm_cat(dp_name(pk), " "), dp_ver(pk)),
                "no mc.toml in the package tree", "mc pkg sync --yes");
    return h;
}

// ---- per-file attribution ----
// The lock pins ONE hash per package (D4), so a mismatch says "something in this
// tree moved" and no more. What names the file is the cache manifest the fetch
// wrote beside the tree, `<libs>/<pack>/v<version>.toml`, with one [[file]] row
// per hashed file -- the same shape src/sysroot.mc writes for a sysroot. A
// vendored tree has no manifest (it was copied by hand or by `mc pkg vendor`),
// so its refusal names the tree.
uptr dep_manifest_bad(i64 pk) {
    uptr man = dp_man(pk);
    if (man == 0) return 0;
    uptr bad = 0;
    uptr frame = toml_push();
    toml_parse(man);
    i64 n = toml_occurrences("file");
    i64 i = 0;
    while (i < n) {
        uptr key = tm_cat(tm_cat("file.", tm_num_str(i)), ".");
        uptr rel = toml_get(tm_cat(key, "path"));
        uptr want = toml_get(tm_cat(key, "sha256"));
        if (rel != 0 && want != 0) {
            // the manifest is mc's own file, but it lives next to a tree a
            // registry wrote and it is read with the same arithmetic: check it
            // with the same rule rather than trust it (post-M44 review)
            if (!dep_rel_ok(rel, 0) || !dep_under(dp_dir(pk), rel)) {
                bad = rel;
                i = n;
            }
            uptr p = dep_in(dp_dir(pk), rel);
            if (bad == 0 && (!lex_readable(p) || !str_eq(sha256_file(p), want))) {
                bad = rel;
                i = n;
            }
        }
        i = i + 1;
    }
    toml_pop(frame);
    return bad;
}

// `geo 1.2.0: vec.mc does not match mc.lock`
void dep_mismatch(i64 pk) {
    uptr what = dep_manifest_bad(pk);
    if (what == 0 && dp_man(pk) != 0) what = "mc.toml";
    if (what == 0) what = "the tree";
    dep_die(tm_cat(tm_cat(tm_cat(dp_name(pk), " "), dp_ver(pk)),
                   tm_cat(tm_cat(": ", what), " does not match mc.lock")),
            0, "mc pkg verify");
}

// ---- <libs>: where an installed package lives ----
// --libs-dir DIR, else host_home()/.mc/libs. Never the working directory: that
// is the M15 stance one level up -- the answer to `<float>` must be a function
// of (this binary, this lock, the installed packages) and of nothing else.
uptr deps_libs_root() {
    if (dp_libs_opt != 0) return dp_libs_opt;
    uptr home = host_home();
    if (home == 0) return 0;
    return tm_cat(home, "/.mc/libs");
}

void deps_set_libs_dir(uptr d) { dp_libs_opt = d; }

// ---- stage 1: the installed `mc` package (A3, A4) ----
// <libs>/mc/v<mc_version()>/ in the REPOSITORY layout, with bundle.list at its
// root as the NAME<TAB>PATH map. Read once, cached; absent is not an error here
// -- a full binary answers every one of these names from its blob and never
// reaches this step.
void dp_mc_load() {
    uptr s = dp_state();
    if (ld64(s + DP_MCTRIED)) return;
    st64(s + DP_MCTRIED, 1);
    uptr root = deps_libs_root();
    if (root == 0) return;
    uptr dir = tm_cat(tm_cat(tm_cat(root, "/mc/v"), mc_version()), "/");
    uptr list = dep_in(dir, "bundle.list");
    if (!lex_readable(list)) return;
    i64 len = 0;
    uptr src = read_file(list, &len);
    // two passes: count the lines, then fill. The manifest is a file the
    // installer wrote, so its size is known before a byte is stored and there
    // is nothing to grow.
    i64 n = 0;
    i64 i = 0;
    while (i < len) {
        if (ld8(src + i) == '\n') n = n + 1;
        i = i + 1;
    }
    uptr names = xalloc(n * 8 + 8);
    uptr paths = xalloc(n * 8 + 8);
    i64 k = 0;
    i64 b = 0;
    i = 0;
    while (i <= len) {
        if (i == len || ld8(src + i) == '\n') {
            i64 t = b;
            while (t < i && ld8(src + t) != 9) { t = t + 1; }
            if (t < i && k < n) {
                st64(names + k * 8, xstrdup(src + b, t - b));
                st64(paths + k * 8, xstrdup(src + t + 1, i - t - 1));
                k = k + 1;
            }
            b = i + 1;
        }
        i = i + 1;
    }
    st64(s + DP_MCN, k);
    st64(s + DP_MCNAME, names);
    st64(s + DP_MCPATH, paths);
    st64(s + DP_MCDIR, dir);
}

uptr dp_mc_open(uptr name, uptr pcanon, uptr plen) {
    dp_mc_load();
    uptr s = dp_state();
    if (ld64(s + DP_MCDIR) == 0) return 0;
    // M37: `<mc/host>` is not an entry, it is the name of THIS compiler's host
    // file -- the same rewrite src/core_bundle.mc does for the blob, so that a
    // generated taught compiler is portable whichever road served it.
    if (str_eq(name, "mc/host")) name = host_include();
    i64 n = ld64(s + DP_MCN);
    i64 i = 0;
    while (i < n) {
        if (str_eq(ld64(ld64(s + DP_MCNAME) + i * 8), name)) {
            uptr p = dep_in(ld64(s + DP_MCDIR), ld64(ld64(s + DP_MCPATH) + i * 8));
            if (!lex_readable(p)) return 0;
            uptr src = read_file(p, plen);
            st64(pcanon, p);
            return src;
        }
        i = i + 1;
    }
    return 0;
}

// ---- the opener src/lex.mc calls ----
// stage 0 = the lock road, stage 1 = the installed `mc` package. The once-only
// key handed back for either is the file's NORMALISED PATH -- the same key
// lex_include would record for it -- so a package file reached once as
// `<geo/vec.mc>` and once as a relative "vec.mc" from inside the package is one
// inclusion, exactly as `<mc/core>` and "core.mc" are one entry in the blob.
uptr libs_open(uptr name, i64 stage, uptr pcanon, uptr plen) {
    if (stage != 0) return dp_mc_open(name, pcanon, plen);
    if (dp == 0) return 0;
    i64 pk = dp_find(dep_first(name));
    if (pk < 0) return 0;
    uptr rest = 0;
    i64 n = cstrlen(dp_name(pk));
    if (ld8(name + n) == '/') rest = name + n + 1;
    else                      rest = dp_lib(pk);      // a bare <geo>
    if (rest == 0) return 0;
    // The `.mc` src/lex.mc dropped is put back here, and only here: a bundled
    // name never carries one (`mc/lex`, not `mc/lex.mc`) while a file on disk
    // always does. So `<geo/geo.mc>` and `<geo/geo>` are one name and both land
    // on geo.mc, and a payload with another extension -- `<pack/data.txt>` for
    // an #embed -- is found under the name it was written with.
    uptr p = dep_in(dp_dir(pk), rest);
    if (!lex_readable(p)) p = dep_in(dp_dir(pk), tm_cat(rest, ".mc"));
    if (!lex_readable(p)) return 0;
    uptr src = read_file(p, plen);
    st64(pcanon, p);
    return src;
}

// ---- reading mc.lock ----
// The format is docs/reference/packages.md § The lock: one [[package]] per row,
// sorted by name, each with name/version/lib/sha256/deps. Written only by
// `mc pkg`; read here, and checked against the trees on every build.
void dep_read_lock(uptr cfg) {
    uptr lock = path_join(cfg, "mc.lock");
    if (!lex_readable(lock))
        dep_die("mc.lock is stale", 0, "mc pkg sync --yes");
    uptr s = dp_state();
    uptr frame = toml_push();
    toml_parse(lock);
    i64 n = toml_occurrences("package");
    uptr pkgs = xalloc(n * PK_SIZE + PK_SIZE);
    // the edge list, sized exactly: the lock says how many there are
    i64 ne = 0;
    i64 i = 0;
    while (i < n) {
        ne = ne + toml_count(tm_cat(tm_cat("package.", tm_num_str(i)), ".deps"));
        i = i + 1;
    }
    uptr efrom = xalloc(ne * 8 + 8);
    uptr ename = xalloc(ne * 8 + 8);
    i64 k = 0;
    i = 0;
    while (i < n) {
        uptr key = tm_cat(tm_cat("package.", tm_num_str(i)), ".");
        uptr nm = toml_get(tm_cat(key, "name"));
        uptr vr = toml_get(tm_cat(key, "version"));
        if (nm == 0) toml_err_key(tm_cat(key, "name"), "missing key");
        if (vr == 0) toml_err_key(tm_cat(key, "version"), "missing key");
        uptr e = pkgs + i * PK_SIZE;
        st64(e + PK_NAME, nm);
        st64(e + PK_VER, vr);
        st64(e + PK_HASH, toml_get(tm_cat(key, "sha256")));
        st64(e + PK_LIB, toml_get(tm_cat(key, "lib")));
        uptr dk = tm_cat(key, "deps");
        i64 nd = toml_count(dk);
        i64 j = 0;
        while (j < nd) {
            st64(efrom + k * 8, i);
            st64(ename + k * 8, toml_get_array(dk, j));
            k = k + 1;
            j = j + 1;
        }
        i = i + 1;
    }
    toml_pop(frame);
    st64(s + DP_NPKG, n);
    st64(s + DP_PKG, pkgs);
    // the roots and the edges are sized once, from the lock, and never grow
    lex_pkg_reserve(n, ne);
    i = 0;
    while (i < n) {
        lex_add_root(dp_name(i), 0);        // the directory is filled in below
        i = i + 1;
    }
    i = 0;
    while (i < ne) {
        i64 to = dp_find(ld64(ename + i * 8));
        if (to < 0)
            dep_die("mc.lock is stale", ld64(ename + i * 8), "mc pkg sync --yes");
        lex_add_edge(ld64(efrom + i * 8), to);
        i = i + 1;
    }
}

// ---- where a locked package's tree is (D10') ----
// deps/<pack>/ wins when it is there -- that is the fully offline project, and
// it is a choice the developer made by checking the tree in. Otherwise
// <libs>/<pack>/v<version>/, and ONLY that version: a directory no lock names is
// never opened, so `v1.0.0/` sitting beside `v1.2.0/` cannot change a byte.
void dep_resolve(i64 pk, uptr cfg) {
    uptr e = dp_at(pk);                        // PK_MAN is written straight
    uptr vend = path_join(cfg, tm_cat(tm_cat("deps/", dp_name(pk)), "/mc.toml"));
    if (lex_readable(vend)) {
        // the trailing '/' is re-attached AFTER path_join: path_norm drops it,
        // and a directory without it is a file name to the next join
        dp_set_dir(pk, tm_cat(path_join(cfg, tm_cat("deps/", dp_name(pk))), "/"));
        return;
    }
    uptr root = deps_libs_root();
    if (root != 0) {
        uptr base = tm_cat(tm_cat(tm_cat(root, "/"), dp_name(pk)), tm_cat("/v", dp_ver(pk)));
        // the manifest, beside the tree, is the CLAIM that the directory holds
        // what the lock says -- it is written last by the fetch, so a half
        // extracted tree is "not fetched" and not "does not match"
        uptr man = tm_cat(base, ".toml");
        if (lex_readable(man)) {
            dp_set_dir(pk, tm_cat(base, "/"));
            st64(e + PK_MAN, man);
            return;
        }
    }
    dep_die(tm_cat(tm_cat(dp_name(pk), " "), tm_cat(dp_ver(pk), " is not fetched")),
            0, "mc pkg sync --yes");
}

// ---- [replace] (D11) ----
// A local tree, for development: not pinned, not hashed, and announced, exactly
// as Go's replace directive is and as go.sum omits it.
void dep_replace(i64 pk, uptr cfg) {
    uptr p = toml_get(tm_cat("replace.", dp_name(pk)));
    if (p == 0) return;
    uptr e = dp_at(pk);
    dp_set_dir(pk, tm_cat(path_join(cfg, p), "/"));
    st64(e + PK_HASH, 0);
    st64(e + PK_MAN, 0);
    out_str(1, "replaced ");
    out_str(1, dp_name(pk));
    out_str(1, ": ");
    out_str(1, p);
    out_str(1, " -- not pinned by mc.lock\n");
}

// ---- the entry point the driver calls ----
// Runs for BOTH halves of `mc build` (the taught compiler and the entry), which
// is why it is in drv_parse and not in drv_apply_config: a compiler-module
// package has to reach the first compilation and a library package the second.
// With no [deps] it returns before reading anything, and the lexer's root table
// stays empty -- so a project without dependencies is byte for byte what it was
// (D24).
void deps_apply(uptr cfg) {
    uptr s = dp_state();
    if (ld64(s + DP_APPLIED)) return;
    st64(s + DP_APPLIED, 1);
    // 1. the names, validated at their own position, before anything is read
    i64 nd = 0;
    i64 i = 0;
    while (i < toml_entries()) {
        uptr k = opt_val(toml_path_at(i), "deps.");
        if (k != 0) {
            dep_check_name("deps.", k);
            nd = nd + 1;
        }
        k = opt_val(toml_path_at(i), "replace.");
        if (k != 0) dep_check_name("replace.", k);
        i = i + 1;
    }
    if (nd == 0) return;
    // 2. the lock, and the roots it names
    dep_read_lock(cfg);
    // 3. every [deps] minimum has to be met by a row: the lock is the answer to
    //    the manifest, so a manifest that moved makes the lock stale
    i = 0;
    while (i < toml_entries()) {
        uptr k = opt_val(toml_path_at(i), "deps.");
        if (k != 0) {
            i64 pk = dp_find(k);
            if (pk < 0 || ver_cmp(dp_ver(pk), toml_val_at(i)) < 0)
                dep_die("mc.lock is stale", k, "mc pkg sync --yes");
        }
        i = i + 1;
    }
    // 4. each tree resolved, then REHASHED (D7): checked, not trusted
    i = 0;
    while (i < dp_npkg()) {
        dep_resolve(i, cfg);
        dep_replace(i, cfg);
        uptr got = dep_scan(i);
        uptr want = dp_hash(i);
        if (want != 0 && !str_eq(got, want)) dep_mismatch(i);
        i = i + 1;
    }
}

// ---- the post-parse boundary (§ 3, last row) ----
// A file the build actually READ under a package root has to be one the package
// declared. That is what makes [package].files a boundary rather than
// documentation: an author who forgets a file ships one that fails loudly at
// the first consumer, and a planted file inside a fetched tree is refused even
// though its bytes are inside the hashed set of none of them.
void deps_check_files() {
    if (dp == 0) return;
    if (lex_root_count() == 0) return;
    i64 i = 0;
    while (i < lex_inc_count()) {
        uptr key = lex_inc_at(i);
        i64 r = lex_root_of(key);
        if (r >= 0) {
            uptr rel = key + cstrlen(lex_root_dir(r));
            if (!str_eq(rel, "mc.toml") && !dp_has_file(r, rel))
                err_at(tm_cat(tm_cat(lex_root_name(r), "/"), rel), 1,
                       tm_cat(tm_cat("not declared in ", lex_root_name(r)),
                              "'s [package].files"));
        }
        i = i + 1;
    }
}

// [registry].url, the index `mc pkg` reads. Nothing in <mc/core_build> fetches,
// so this is only the value; the default lives in src/pkg.mc with the code that
// uses it (M44 § 5).
uptr deps_registry() { return toml_get("registry.url"); }
