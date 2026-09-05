// pkg.mc — the WRITE and network side of packages (M44 § 3-§ 8, D12, D21):
// `mc pkg sync|add|list|vendor|verify|hash|check` and the top-level
// `mc update`.
//
// It lives in <mc/core_pkg> and not in <mc/core_build> for the reason M41 gave
// the parts: a compiler that will never RESOLVE a dependency -- the CI and
// consumer shape -- still has to build a project from its lock and its `deps/`
// tree, and that half is src/deps.mc's. Leave this part out and the `pkg` and
// `update` usage lines disappear with it, because the usage IS the subcommand
// table (src/hooks.mc).
//
// What is here and nowhere else:
//
//   1. the registry index reader (§ 5): `<registry>/index/<name>.toml`, one
//      file per package, read in place from a DIR and fetched into an offline
//      snapshot from a URL;
//   2. MVS (§ 3): minimal version selection, Go's algorithm -- the LOWEST
//      version that satisfies every minimum, never "the latest" -- with two
//      majors of one name refused rather than solved;
//   3. the lock WRITER: rows sorted by name, `lib`/`deps` read out of the
//      archive's own mc.toml and `sha256` the tree hash src/deps.mc computes;
//   4. the archive fetch, in M25's order of operations: download, extract,
//      HASH AND COMPARE BEFORE ANYTHING ELSE, and only then the manifest --
//      which is the claim that the directory holds what the lock says;
//   5. `vendor`, `add`, `list`, `verify`, `hash` and the registry-side gate
//      `check`.
//
// Nothing in `mc build` reaches this file. `mc pkg` is the only thing that
// writes `mc.lock`, the only thing that writes under `<libs>`, and the only
// thing that spawns a downloader (through src/fetch.mc).
//
// Depends on arena.mc, sha256.mc, toml.mc, deps.mc (the name rule, semver, the
// tree hash, `<libs>`), driver.mc (drv_path, drv_mkdirs, cfg_file), fetch.mc
// and the host layer.

// ---- the default registry (§ 5) ----
// A package SERVER at minicompiler.dev produces exactly the layout § 5
// describes -- `index/<name>.toml`, one file per package, immutable rows -- out
// of the git repositories registered with it. The compiler's side of that is
// this constant and the reader below: there is no API client here, no JSON and
// no search. A private registry is a directory or any URL with the same layout,
// which is why `--registry` and `[registry].url` take either.
uptr pkg_default_registry() { return "https://minicompiler.dev/registry"; }

// ---- the state: one arena record, so this file costs one global ----
#define PKS_REG      0                 // the registry, URL or directory
#define PKS_YES      8                 // --yes: may download
#define PKS_NIX      16                // index files loaded
#define PKS_IXCAP    24
#define PKS_IX       32                // IX_SIZE records
#define PKS_NVR      40                // version rows, all packages
#define PKS_VRCAP    48
#define PKS_VR       56                // VR_SIZE records
#define PKS_NSEL     64                // the MVS build list
#define PKS_SELCAP   72
#define PKS_SEL      80                // SL_SIZE records
#define PKS_NPLAN    88                // what a fetch would download
#define PKS_PLANCAP  96
#define PKS_PLAN     104               // PL_SIZE records
#define PKS_SIZE     112

#define IX_NAME 0                     // the package this index file is about
#define IX_REPO 8
#define IX_SIZE 16

#define VR_NAME  0                    // the package
#define VR_VER   8
#define VR_URL   16
#define VR_STRIP 24
#define VR_SHA   32                   // the TREE hash, never the archive's
#define VR_YANK  40
#define VR_DEPN  48                   // requirements, as written: "mathx 1.1.0"
#define VR_DEPP  56
#define VR_SIZE  64

#define SL_NAME 0
#define SL_VER  8                     // the maximum minimum: what MVS selects
#define SL_LOW  16                    // the smallest minimum seen, for majors
#define SL_DONE 24                    // 1 once its requirements were expanded
#define SL_SIZE 32

#define PL_WHAT 0                     // "index geo" / "geo 1.2.0"
#define PL_URL  8
#define PL_SHA  16                    // 0 for an index file: it is not pinned
#define PL_DEST 24
#define PL_SIZE 32

uptr pk = 0;

uptr pk_state() {
    if (pk == 0) {
        pk = xalloc(PKS_SIZE);
        st64(pk + PKS_REG, pkg_default_registry());
    }
    return pk;
}

// One doubling table helper for all four tables here: `off_*` are the field
// offsets of the (pointer, count, capacity) triple inside the state record.
// None of these scales with the program -- they scale with the dependency
// graph, which the developer wrote -- so they double here instead of going
// through arena.mc's grow() and `mc limits` gains no row (the M17 argument for
// MAXTARGETS, and src/deps.mc's for its file table).
uptr pk_add(i64 off_p, i64 off_n, i64 off_cap, i64 esz) {
    uptr s = pk_state();
    i64 n = ld64(s + off_n);
    i64 cap = ld64(s + off_cap);
    if (n >= cap) {
        i64 nc = cap * 2;
        if (nc < 8) nc = 8;
        uptr np = xalloc(nc * esz);
        mem_copy(np, ld64(s + off_p), n * esz);
        st64(s + off_p, np);
        st64(s + off_cap, nc);
    }
    uptr e = ld64(s + off_p) + n * esz;
    mem_zero(e, esz);
    st64(s + off_n, n + 1);
    return e;
}

uptr pk_registry()     { return ld64(pk_state() + PKS_REG); }
i64  pk_yes()          { return ld64(pk_state() + PKS_YES); }
i64  pk_nvr()          { return ld64(pk_state() + PKS_NVR); }
uptr pk_vr(i64 i)      { return ld64(pk_state() + PKS_VR) + i * VR_SIZE; }
i64  pk_nsel()         { return ld64(pk_state() + PKS_NSEL); }
uptr pk_sel(i64 i)     { return ld64(pk_state() + PKS_SEL) + i * SL_SIZE; }
i64  pk_nplan()        { return ld64(pk_state() + PKS_NPLAN); }
uptr pk_plan_at(i64 i) { return ld64(pk_state() + PKS_PLAN) + i * PL_SIZE; }

void pk_set_registry(uptr r) { st64(pk_state() + PKS_REG, r); }
void pk_set_yes(i64 v)       { st64(pk_state() + PKS_YES, v); }

// ---- messages ----
// Exit 1 is "what you wrote is wrong" (a name, a version nobody registered, an
// index row that contradicts its own archive); exit 2 is M25's "the environment
// is not ready" (a download that failed, a checksum that did not match, a tree
// that is not there). dep_die() is src/deps.mc's and carries the `run:` line.
void pkg_die1(uptr msg, uptr det) {
    out_str(2, "mc: ");
    out_str(2, msg);
    if (det != 0) {
        out_str(2, ": ");
        out_str(2, det);
    }
    out_str(2, "\n");
    _exit(1);
}

// `geo 1.2.0`
uptr pkg_what(uptr name, uptr ver) { return tm_cat(tm_cat(name, " "), ver); }

// what fetch_get's answer means, in words: the one place a non-zero code
// becomes a reason a message can carry (post-M44 review, finding 4).
uptr pkg_fetch_reason(i64 rc) {
    if (rc < 0) return "no downloader on this PATH";
    if (rc == FETCH_TOOBIG) return "larger than the cap";
    return tm_cat("exit status ", tm_num_str(rc));
}

// ---- getting a file, with the message the caller owes ----
// fetch_get answers with a code and prints nothing (src/fetch.mc); this is the
// one place `mc pkg` turns that code into words. A local path that does not
// open is `cannot open`, a URL is M25's `the download failed`.
void pkg_get(uptr src, uptr file, i64 cap) {
    i64 rc = fetch_get(src, file, cap);
    if (rc == 0) return;
    // post-M44 review, finding 6: a body over the ceiling is a refusal of its
    // own, before the shape of the source is even discussed
    if (rc == FETCH_TOOBIG) {
        out_str(2, "mc: larger than the cap of ");
        out_str(2, tm_num_str(cap));
        out_str(2, " bytes: ");
        out_str(2, src);
        out_str(2, "\n");
        _exit(2);
    }
    if (!fetch_is_url(src)) {
        out_str(2, "mc: cannot open: ");
        out_str(2, src);
        out_str(2, "\n");
        _exit(2);
    }
    if (rc < 0) {
        out_str(2, "mc: no downloader on this PATH (tried ");
        out_str(2, host_downloader());
        if (host_downloader_alt() != 0) {
            out_str(2, ", ");
            out_str(2, host_downloader_alt());
        }
        out_str(2, ")\n");
        _exit(2);
    }
    out_str(2, "mc: the download failed (exit ");
    out_str(2, tm_num_str(rc));
    out_str(2, "): ");
    out_str(2, src);
    out_str(2, "\n");
    _exit(2);
}

// ---- the plan (D13) ----
// Every verb that can download prints what it WOULD download before it is
// allowed to: the source, its expected tree hash where there is one, and the
// destination. Without --yes that is all it does -- `mc` has no isatty and
// therefore no prompt (M25 D10).
void pkg_plan(uptr what, uptr url, uptr sha, uptr dest) {
    uptr e = pk_add(PKS_PLAN, PKS_NPLAN, PKS_PLANCAP, PL_SIZE);
    st64(e + PL_WHAT, what);
    st64(e + PL_URL, url);
    st64(e + PL_SHA, sha);
    st64(e + PL_DEST, dest);
}

void pkg_print_plan() {
    i64 i = 0;
    while (i < pk_nplan()) {
        uptr e = pk_plan_at(i);
        out_str(1, "fetch  ");
        out_str(1, ld64(e + PL_WHAT));
        out_str(1, "\nurl    ");
        out_str(1, ld64(e + PL_URL));
        if (ld64(e + PL_SHA) != 0) {
            out_str(1, "\nsha256 ");
            out_str(1, ld64(e + PL_SHA));
        }
        out_str(1, "\ninto   ");
        out_str(1, ld64(e + PL_DEST));
        out_str(1, "\n");
        i = i + 1;
    }
}

// ---- the index (§ 5) ----
// One file per package. A DIR registry is read in place -- which is what makes
// a private registry a `git clone` and a directory, at zero lines -- and a URL
// registry is fetched into `<libs>/index/<name>.toml`, the offline snapshot
// every later `mc pkg` in this project reads.
uptr pkg_index_url(uptr name) {
    return tm_cat(tm_cat(pk_registry(), "/index/"), tm_cat(name, ".toml"));
}

uptr pkg_index_snapshot(uptr name) {
    uptr root = deps_libs_root();
    if (root == 0)
        dep_die("nowhere to put the registry index", "no --libs-dir and no HOME", 0);
    return tm_cat(tm_cat(root, "/index/"), tm_cat(name, ".toml"));
}

// where the index file for `name` is on this disk, or 0 when it would have to
// be downloaded first and --yes was not given (the plan records it).
uptr pkg_index_file(uptr name) {
    uptr url = pkg_index_url(name);
    if (!fetch_is_url(url)) {
        if (!lex_readable(url))
            pkg_die1("no such package in the registry", name);
        return url;
    }
    uptr snap = pkg_index_snapshot(name);
    if (lex_readable(snap)) return snap;
    if (!pk_yes()) {
        pkg_plan(tm_cat("index ", name), url, 0, snap);
        return 0;
    }
    drv_mkdirs(snap);
    pkg_get(url, snap, FETCH_MAXINDEX);
    return snap;
}

i64 pkg_index_loaded(uptr name) {
    uptr s = pk_state();
    i64 n = ld64(s + PKS_NIX);
    i64 i = 0;
    while (i < n) {
        if (str_eq(ld64(ld64(s + PKS_IX) + i * IX_SIZE + IX_NAME), name)) return 1;
        i = i + 1;
    }
    return 0;
}

// Reads ONE index file into the version table. The parse happens inside a
// push/pop: the project's own table is the one every other reader here expects
// to find (M44 § 9), and everything is copied out before the pop.
//
// It takes the file and not the name because `mc pkg check` is handed the
// candidate file directly -- what the registry CI validates is a file in a pull
// request, which is not (yet) the file the registry serves.
void pkg_index_read(uptr name, uptr file) {
    uptr frame = toml_push();
    toml_parse(file);
    uptr pname = toml_get("package.name");
    if (pname == 0) toml_err_key("package.name", "missing key");
    if (!str_eq(pname, name)) toml_err_key("package.name", "the index file is about another package");
    uptr repo = toml_get("package.repo");
    i64 nv = toml_occurrences("versions");
    // Everything is copied out BEFORE the pop: what the tables below hold is
    // strings this process owns, not pointers into a table that is about to be
    // swapped back (rule 1 of docs/determinism.md -- flat, in source order).
    i64 i = 0;
    while (i < nv) {
        uptr key = tm_cat(tm_cat("versions.", tm_num_str(i)), ".");
        uptr ver = toml_get(tm_cat(key, "version"));
        if (ver == 0) toml_err_key(tm_cat(key, "version"), "missing key");
        uptr dk = tm_cat(key, "deps");
        i64 nd = toml_count(dk);
        uptr dp8 = xalloc(nd * 8 + 8);
        i64 j = 0;
        while (j < nd) {
            st64(dp8 + j * 8, toml_get_array(dk, j));
            j = j + 1;
        }
        uptr e = pk_add(PKS_VR, PKS_NVR, PKS_VRCAP, VR_SIZE);
        st64(e + VR_NAME, name);
        st64(e + VR_VER, ver);
        st64(e + VR_URL, toml_get(tm_cat(key, "url")));
        st64(e + VR_STRIP, toml_int(tm_cat(key, "strip"), 1));
        st64(e + VR_SHA, toml_get(tm_cat(key, "sha256")));
        uptr yk = toml_get(tm_cat(key, "yanked"));
        st64(e + VR_YANK, yk != 0 && str_eq(yk, "true"));
        st64(e + VR_DEPN, nd);
        st64(e + VR_DEPP, dp8);
        i = i + 1;
    }
    toml_pop(frame);
    uptr ix = pk_add(PKS_IX, PKS_NIX, PKS_IXCAP, IX_SIZE);
    st64(ix + IX_NAME, name);
    st64(ix + IX_REPO, repo);
}

// The same, for a package named rather than a file handed over: the registry
// answers, in place from a directory and through a snapshot from a URL. 0 when
// the file is not on this disk yet and --yes was not given (the plan has it).
i64 pkg_index_load(uptr name) {
    if (pkg_index_loaded(name)) return 1;
    uptr file = pkg_index_file(name);
    if (file == 0) return 0;
    pkg_index_read(name, file);
    return 1;
}

// the row for exactly this version, or -1
i64 pkg_row(uptr name, uptr ver) {
    i64 i = 0;
    while (i < pk_nvr()) {
        uptr e = pk_vr(i);
        if (str_eq(ld64(e + VR_NAME), name) && str_eq(ld64(e + VR_VER), ver)) return i;
        i = i + 1;
    }
    return -1;
}

// the newest version of `name` that is not yanked, or 0. Yanked is Go's
// retract: `add` and `update` skip such a row, and a lock that already pins one
// keeps working, so a published build never breaks retroactively.
//
// `major` is -1 for "any", which is what `mc pkg add NAME` asks: a name nothing
// requires yet has no major to stay inside of. `mc update` passes the major of
// the minimum already written down, because raising a minimum across a major is
// not an update -- it is the case D6 refuses to solve, and `go get -u` does not
// cross a major either.
uptr pkg_newest(uptr name, i64 major) {
    uptr best = 0;
    i64 i = 0;
    while (i < pk_nvr()) {
        uptr e = pk_vr(i);
        if (str_eq(ld64(e + VR_NAME), name) && !ld64(e + VR_YANK)
            && (major < 0 || ver_major(ld64(e + VR_VER)) == major)) {
            if (best == 0 || ver_cmp(ld64(e + VR_VER), best) > 0) best = ld64(e + VR_VER);
        }
        i = i + 1;
    }
    return best;
}

// ---- MVS (§ 3, D6) ----
// Go's algorithm, exactly: the build list starts from the project's [deps]; for
// every selected (name, version) the requirements of THAT version are added; a
// name's selected version is the MAXIMUM over every minimum that mentions it;
// repeat to a fixed point. No search, no SAT, no "latest" -- the answer is a
// function of the index alone, and the lock then freezes it so the index can
// move afterwards without moving the build.
i64 pkg_sel_find(uptr name) {
    i64 i = 0;
    while (i < pk_nsel()) {
        if (str_eq(ld64(pk_sel(i) + SL_NAME), name)) return i;
        i = i + 1;
    }
    return -1;
}

// Two majors of one name in one build is the case MVS is not designed for, and
// semantic import versioning (`/v2` in the path) is out of scope: refused,
// naming both minimums in ascending order so the message is the same whichever
// order the requirements arrived in.
void pkg_majors(uptr name, uptr a, uptr b) {
    uptr lo = a;
    uptr hi = b;
    if (ver_cmp(a, b) > 0) {
        lo = b;
        hi = a;
    }
    pkg_die1(tm_cat(tm_cat(name, ": "), tm_cat(tm_cat(lo, " and "), hi)),
             "different majors: no solver");
}

void pkg_require(uptr name, uptr ver) {
    i64 i = pkg_sel_find(name);
    if (i < 0) {
        uptr e = pk_add(PKS_SEL, PKS_NSEL, PKS_SELCAP, SL_SIZE);
        st64(e + SL_NAME, name);
        st64(e + SL_VER, ver);
        st64(e + SL_LOW, ver);
        st64(e + SL_DONE, 0);
        return;
    }
    uptr e = pk_sel(i);
    if (ver_major(ver) != ver_major(ld64(e + SL_VER)))
        pkg_majors(name, ld64(e + SL_LOW), ver);
    if (ver_cmp(ver, ld64(e + SL_LOW)) < 0) st64(e + SL_LOW, ver);
    if (ver_cmp(ver, ld64(e + SL_VER)) > 0) {
        st64(e + SL_VER, ver);
        st64(e + SL_DONE, 0);           // a raised version has other requirements
    }
}

// `mathx 1.1.0` -> the name, and the version after the space
uptr pkg_req_name(uptr s) {
    i64 n = 0;
    loop {
        i64 c = ld8(s + n);
        if (c == 0 || c == ' ') break;
        n = n + 1;
    }
    return xstrdup(s, n);
}

uptr pkg_req_ver(uptr s) {
    i64 n = 0;
    loop {
        i64 c = ld8(s + n);
        if (c == 0) return 0;
        if (c == ' ') break;
        n = n + 1;
    }
    while (ld8(s + n) == ' ') { n = n + 1; }
    return s + n;
}

// Expands one selected package: its index row's `deps` become requirements.
// Returns 0 when the index could not be read (plan mode with a URL registry and
// no snapshot) -- the caller then has a plan and nothing else to say.
i64 pkg_expand(i64 i) {
    uptr e = pk_sel(i);
    st64(e + SL_DONE, 1);
    uptr name = ld64(e + SL_NAME);
    uptr ver = ld64(e + SL_VER);
    if (!pkg_index_load(name)) return 0;
    i64 r = pkg_row(name, ver);
    if (r < 0)
        pkg_die1(tm_cat(tm_cat(name, " "), ver), "no such version in the registry");
    uptr row = pk_vr(r);
    i64 nd = ld64(row + VR_DEPN);
    i64 j = 0;
    while (j < nd) {
        uptr d = ld64(ld64(row + VR_DEPP) + j * 8);
        uptr dn = pkg_req_name(d);
        uptr dv = pkg_req_ver(d);
        if (dv == 0) pkg_die1("a [[versions]].deps entry needs a version", d);
        if (dep_reserved(dn) || !dep_name_ok(dn)) pkg_die1("invalid package name", dn);
        pkg_require(dn, dv);
        j = j + 1;
    }
    return 1;
}

// to the fixed point; 0 when something was missing from the disk
i64 pkg_resolve() {
    i64 ok = 1;
    loop {
        i64 i = 0;
        i64 more = 0;
        while (i < pk_nsel()) {
            if (!ld64(pk_sel(i) + SL_DONE)) {
                if (!pkg_expand(i)) ok = 0;
                more = 1;
            }
            i = i + 1;
        }
        if (!more) break;
    }
    return ok;
}

// the project's [deps], validated at their own file:line:col and turned into
// the first requirements
i64 pkg_read_deps() {
    i64 n = 0;
    i64 i = 0;
    while (i < toml_entries()) {
        uptr k = opt_val(toml_path_at(i), "deps.");
        if (k != 0) {
            dep_check_name("deps.", k);
            pkg_require(k, toml_val_at(i));
            n = n + 1;
        }
        k = opt_val(toml_path_at(i), "replace.");
        if (k != 0) dep_check_name("replace.", k);
        i = i + 1;
    }
    return n;
}

// ---- where a tree is, and whether it is already there ----
uptr pkg_vendor_dir(uptr name) {
    return tm_cat(drv_path(tm_cat("deps/", name)), "/");
}

uptr pkg_libs_dir(uptr name, uptr ver) {
    uptr root = deps_libs_root();
    if (root == 0)
        dep_die("nowhere to put a package", "no --libs-dir and no HOME", 0);
    return tm_cat(tm_cat(tm_cat(root, "/"), name), tm_cat(tm_cat("/v", ver), "/"));
}

uptr pkg_libs_manifest(uptr name, uptr ver) {
    uptr root = deps_libs_root();
    if (root == 0)
        dep_die("nowhere to put a package", "no --libs-dir and no HOME", 0);
    return tm_cat(tm_cat(tm_cat(root, "/"), name), tm_cat(tm_cat("/v", ver), ".toml"));
}

uptr pkg_replace_path(uptr name) { return toml_get(tm_cat("replace.", name)); }

// 1 when the tree is on this disk already: vendored, replaced, or installed
// WITH ITS MANIFEST -- a half-extracted directory has no manifest and is not a
// tree (§ 4).
i64 pkg_present(uptr name, uptr ver) {
    if (pkg_replace_path(name) != 0) return 1;
    if (lex_readable(tm_cat(pkg_vendor_dir(name), "mc.toml"))) return 1;
    return lex_readable(pkg_libs_manifest(name, ver));
}

// the directory to READ this package from, in D10's order: deps/ first (a
// choice the developer made by checking the tree in), then <libs>.
uptr pkg_tree_dir(uptr name, uptr ver) {
    uptr rep = pkg_replace_path(name);
    if (rep != 0) return tm_cat(path_norm(drv_path(rep)), "/");
    uptr v = pkg_vendor_dir(name);
    if (lex_readable(tm_cat(v, "mc.toml"))) return v;
    return pkg_libs_dir(name, ver);
}

// ---- the cache manifest ----
// <libs>/<pack>/v<version>.toml, beside the tree and not inside it, so a
// package file called manifest.toml cannot collide. Written LAST, after the
// tree is complete and hashed: it is the claim src/deps.mc reads. No date in
// it (docs/determinism.md).
void pkg_write_manifest(uptr name, uptr ver, uptr url, uptr sha, uptr dir) {
    u8 b[BUF_SIZE];
    buf_init(b);
    drv_put(b, "# written by `mc pkg sync` -- do not edit\n[source]\nname    = \"");
    drv_put(b, name);
    drv_put(b, "\"\nversion = \"");
    drv_put(b, ver);
    drv_put(b, "\"\n");
    if (url != 0) {
        drv_put(b, "url     = \"");
        drv_put(b, url);
        drv_put(b, "\"\n");
    }
    drv_put(b, "sha256  = \"");
    drv_put(b, sha);
    drv_put(b, "\"\n");
    // one [[file]] per hashed file, in manifest order: this is what lets a
    // mismatch name the FILE that moved, since the lock pins one hash per
    // package (src/deps.mc, dep_manifest_bad)
    uptr names = 0;
    i64 n = dep_read_files(dir, pkg_what(name, ver), &names);
    i64 i = -1;
    while (i < n) {
        uptr rel = "mc.toml";
        if (i >= 0) rel = ld64(names + i * 8);
        drv_put(b, "\n[[file]]\npath   = \"");
        drv_put(b, rel);
        drv_put(b, "\"\nsha256 = \"");
        drv_put(b, sha256_file(path_join(dir, rel)));
        drv_put(b, "\"\n");
        i = i + 1;
    }
    write_file(pkg_libs_manifest(name, ver), b);
}

// A refused tree must not go on looking like a package: every file it listed is
// unlinked and no manifest is written, so the next `mc build` says `is not
// fetched` instead of reading debris (§ 4, sysroot_unbless's idea).
// Post-M44 review, finding 1: this used to re-read the just-extracted mc.toml
// -- a file the registry wrote and mc has just REFUSED -- and unlink everything
// it listed, which made a wrong `sha256` in an index row an arbitrary delete on
// the developer's machine. It never needed that list: what is on the disk is
// what the extraction put there, and src/fetch.mc now knows exactly what that
// was. mc has no rmdir, so directories stay; a directory with no mc.toml is
// `is not fetched`, which is the point.
void pkg_unbless(uptr dir) {
    uptr base = tm_cat(path_norm(dir), "/");
    i64 i = 0;
    while (i < fetch_member_count()) {
        if (!fetch_member_dir(i)) unlink(path_join(base, fetch_member_at(i)));
        i = i + 1;
    }
    unlink(tm_cat(base, "mc.toml"));
}

// ---- the fetch (§ 4) ----
// download -> extract -> hash and compare -> manifest. The archive itself is
// NOT checksummed (§ 3 says why: GitHub regenerated its tag tarballs in 2023
// and a content hash did not move), so unlike `mc sysroot fetch` the refusal
// comes after the bytes are on disk -- but still before any manifest exists and
// before any build can consume the tree.
void pkg_fetch_one(uptr name, uptr ver, uptr url, i64 strip, uptr want) {
    uptr dir = pkg_libs_dir(name, ver);
    uptr archive = tm_cat(tm_cat(tm_cat(deps_libs_root(), "/"), name),
                          tm_cat(tm_cat("/v", ver), ".tar.gz"));
    drv_mkdirs(archive);
    drv_mkdirs(tm_cat(dir, "x"));
    pkg_get(url, archive, FETCH_MAXARCHIVE);
    if (fetch_extract(archive, dir, strip, 0) != 0) {
        unlink(archive);
        pkg_unbless(dir);
        out_str(2, "mc: tar could not extract ");
        out_str(2, fetch_basename(url));
        out_str(2, "\n");
        _exit(2);
    }
    unlink(archive);
    // Post-M44 review, finding 5: soft mode. A files entry that escapes, or one
    // that names a file the archive does not carry, used to leave through
    // _exit() from inside the hash with the extracted tree still on the disk.
    // The hash answers 0 and hands the reason back instead, so the tree is
    // unblessed first and the message is the same one either way.
    dep_hash_soft(1);
    dep_hash_label(pkg_what(name, ver));
    uptr got = dep_hash_tree(dir, -1);
    uptr err = dep_hash_err();
    uptr det = dep_hash_errdet();
    dep_hash_soft(0);
    if (err != 0) {
        pkg_unbless(dir);
        dep_die(err, det, 0);
    }
    if (got == 0) {
        pkg_unbless(dir);
        dep_die(pkg_what(name, ver), "the archive carries no mc.toml at its root", 0);
    }
    if (want != 0 && !str_eq(got, want)) {
        pkg_unbless(dir);
        out_str(2, "mc: checksum mismatch for ");
        out_str(2, pkg_what(name, ver));
        out_str(2, "\n  expected ");
        out_str(2, want);
        out_str(2, "\n  got      ");
        out_str(2, got);
        out_str(2, "\n");
        _exit(2);
    }
    pkg_write_manifest(name, ver, url, got, dir);
    out_str(1, "package ");
    out_str(1, pkg_what(name, ver));
    out_str(1, " -> ");
    out_str(1, dir);
    out_str(1, "\n");
}

// ---- the lock writer (D4) ----
// Rows sorted by name -- an insertion sort over unique keys, so there is no
// tie to break (rule 2 of docs/determinism.md forbids qsort's tie-breaking, not
// ordering). `lib` and `deps` come out of the archive's OWN mc.toml, and
// `sha256` is the tree hash: what the lock records is the tree that is here,
// never what the index claimed about it.
// bytewise `a < b`, the total order the lock's rows are sorted by
i64 pkg_name_lt(uptr a, uptr b) {
    i64 i = 0;
    loop {
        i64 x = ld8(a + i);
        i64 y = ld8(b + i);
        if (x != y) return x < y;
        if (x == 0) return 0;
        i = i + 1;
    }
}

void pkg_sort_sel(uptr order) {
    i64 n = pk_nsel();
    i64 i = 0;
    while (i < n) {
        i64 j = i;
        st64(order + i * 8, i);
        while (j > 0) {
            i64 a = ld64(order + (j - 1) * 8);
            i64 b = ld64(order + j * 8);
            if (pkg_name_lt(ld64(pk_sel(b) + SL_NAME), ld64(pk_sel(a) + SL_NAME))) {
                st64(order + (j - 1) * 8, b);
                st64(order + j * 8, a);
                j = j - 1;
            } else {
                j = 0;
            }
        }
        i = i + 1;
    }
}

void pkg_write_lock(uptr path) {
    u8 b[BUF_SIZE];
    buf_init(b);
    drv_put(b, "# written by `mc pkg sync` -- do not edit (docs/reference/packages.md)\n");
    i64 n = pk_nsel();
    uptr order = xalloc(n * 8 + 8);
    pkg_sort_sel(order);
    i64 k = 0;
    while (k < n) {
        uptr e = pk_sel(ld64(order + k * 8));
        uptr name = ld64(e + SL_NAME);
        uptr ver = ld64(e + SL_VER);
        uptr dir = pkg_tree_dir(name, ver);
        uptr rep = pkg_replace_path(name);
        // the tree's own manifest is the truth about `lib` and about the edges
        uptr lib = 0;
        i64 nd = 0;
        uptr dnames = 0;
        uptr frame = toml_push();
        toml_parse(tm_cat(dir, "mc.toml"));
        lib = toml_get("package.lib");
        dnames = xalloc(toml_entries() * 8 + 8);
        i64 i = 0;
        while (i < toml_entries()) {
            uptr dk = opt_val(toml_path_at(i), "deps.");
            if (dk != 0) {
                st64(dnames + nd * 8, dk);
                nd = nd + 1;
            }
            i = i + 1;
        }
        toml_pop(frame);
        drv_put(b, "\n[[package]]\nname    = \"");
        drv_put(b, name);
        drv_put(b, "\"\nversion = \"");
        drv_put(b, ver);
        drv_put(b, "\"\n");
        if (lib != 0) {
            drv_put(b, "lib     = \"");
            drv_put(b, lib);
            drv_put(b, "\"\n");
        }
        if (rep != 0) {
            // D11: a replaced package is not pinned and not hashed, exactly as
            // go.sum omits a path-replaced module
            drv_put(b, "path    = \"");
            drv_put(b, rep);
            drv_put(b, "\"\n");
        } else {
            drv_put(b, "sha256  = \"");
            drv_put(b, dep_hash_tree(dir, -1));
            drv_put(b, "\"\n");
        }
        drv_put(b, "deps    = [");
        i = 0;
        while (i < nd) {
            if (i > 0) drv_put(b, ", ");
            drv_put(b, "\"");
            drv_put(b, ld64(dnames + i * 8));
            drv_put(b, "\"");
            i = i + 1;
        }
        drv_put(b, "]\n");
        k = k + 1;
    }
    write_file(path, b);
}

// ---- sync ----
// `go mod tidy` + `go mod download`: read [deps], read the index rows it needs,
// run MVS, fetch what is missing, write the lock. Rows nothing requires are
// dropped, because the lock is written from the build list and from nothing
// else.
i64 pkg_sync() {
    i64 nd = pkg_read_deps();
    uptr lock = drv_path("mc.lock");
    if (nd == 0) {
        pkg_write_lock(lock);
        out_str(1, "sync: no dependencies\n");
        return 0;
    }
    i64 complete = pkg_resolve();
    if (!complete) {
        // a URL registry with no snapshot and no --yes: the plan is the index
        // files it would fetch, and there is nothing more that can be said
        // without them
        pkg_print_plan();
        out_str(1, "nothing was downloaded: re-run with --yes\n");
        return 0;
    }
    // what is not on the disk yet
    i64 i = 0;
    while (i < pk_nsel()) {
        uptr e = pk_sel(i);
        uptr name = ld64(e + SL_NAME);
        uptr ver = ld64(e + SL_VER);
        if (!pkg_present(name, ver)) {
            i64 r = pkg_row(name, ver);
            uptr row = pk_vr(r);
            if (ld64(row + VR_URL) == 0)
                pkg_die1(pkg_what(name, ver), "the index row has no url");
            pkg_plan(pkg_what(name, ver), ld64(row + VR_URL), ld64(row + VR_SHA),
                     pkg_libs_dir(name, ver));
        }
        i = i + 1;
    }
    if (pk_nplan() > 0) {
        pkg_print_plan();
        if (!pk_yes()) {
            out_str(1, "nothing was downloaded: re-run with --yes\n");
            return 0;
        }
        i = 0;
        while (i < pk_nsel()) {
            uptr e = pk_sel(i);
            uptr name = ld64(e + SL_NAME);
            uptr ver = ld64(e + SL_VER);
            if (!pkg_present(name, ver)) {
                i64 r = pkg_row(name, ver);
                uptr row = pk_vr(r);
                pkg_fetch_one(name, ver, ld64(row + VR_URL), ld64(row + VR_STRIP),
                              ld64(row + VR_SHA));
            }
            i = i + 1;
        }
    }
    // the trees are here: check each one against the index before it is locked,
    // so a vendored or replaced tree that does not match what was published is
    // refused now and not at the next consumer
    i = 0;
    while (i < pk_nsel()) {
        uptr e = pk_sel(i);
        uptr name = ld64(e + SL_NAME);
        uptr ver = ld64(e + SL_VER);
        if (pkg_replace_path(name) != 0) {
            out_str(1, "replaced ");
            out_str(1, name);
            out_str(1, ": ");
            out_str(1, pkg_replace_path(name));
            out_str(1, " -- not pinned by mc.lock\n");
        } else {
            uptr dir = pkg_tree_dir(name, ver);
            uptr got = dep_hash_tree(dir, -1);
            if (got == 0) dep_die(pkg_what(name, ver), "no mc.toml in the package tree",
                                  "mc pkg sync --yes");
            i64 r = pkg_row(name, ver);
            uptr want = 0;
            if (r >= 0) want = ld64(pk_vr(r) + VR_SHA);
            if (want != 0 && !str_eq(got, want)) {
                out_str(2, "mc: checksum mismatch for ");
                out_str(2, pkg_what(name, ver));
                out_str(2, "\n  expected ");
                out_str(2, want);
                out_str(2, "\n  got      ");
                out_str(2, got);
                out_str(2, "\n");
                _exit(2);
            }
        }
        i = i + 1;
    }
    pkg_write_lock(lock);
    out_str(1, "lock   ");
    out_str(1, lock);
    out_str(1, " (");
    out_str(1, tm_num_str(pk_nsel()));
    out_str(1, " packages)\n");
    return 0;
}

// ---- list ----
// One line per lock row: name, version, the first 12 characters of the hash,
// and which road served it. No absolute path anywhere, which is what makes it a
// golden (tests/golden/pkg-list.txt).
void pkg_pad(uptr s, i64 w) {
    out_str(1, s);
    i64 n = w - cstrlen(s);
    while (n > 0) {
        out_str(1, " ");
        n = n - 1;
    }
}

i64 pkg_list() {
    deps_apply(cfg_file);
    i64 i = 0;
    while (i < dp_npkg()) {
        pkg_pad(dp_name(i), 12);
        out_str(1, " ");
        pkg_pad(dp_ver(i), 8);
        out_str(1, " ");
        uptr h = dp_hash(i);
        if (h == 0) pkg_pad("-", 12);
        else        pkg_pad(xstrdup(h, 12), 12);
        out_str(1, " ");
        if (pkg_replace_path(dp_name(i)) != 0) out_str(1, "path");
        else if (dp_man(i) != 0)               out_str(1, "cache");
        else                                   out_str(1, "vendored");
        out_str(1, "\n");
        i = i + 1;
    }
    return 0;
}

// ---- verify ----
// deps_apply is the whole of it: it resolves every row, rehashes every tree and
// refuses with the § 8 messages and exit 2. What is added here is the sentence
// that says nothing was wrong.
i64 pkg_verify() {
    deps_apply(cfg_file);
    out_str(1, "verified ");
    out_str(1, tm_num_str(dp_npkg()));
    out_str(1, " packages against mc.lock\n");
    return 0;
}

// ---- vendor ----
// copies each locked tree into deps/<pack>/, then verifies. `mc.toml` plus the
// files the manifest lists, and nothing else: the vendor list IS [package].files
// (D5), which is also the hash's input and the build-time boundary.
void pkg_copy_file(uptr src, uptr dst) {
    i64 len = 0;
    uptr p = read_file(src, &len);
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, p, len);
    drv_mkdirs(dst);
    write_file(dst, b);
}

i64 pkg_copy_tree(uptr src, uptr dst, uptr what) {
    uptr names = 0;
    // dep_read_files checks every entry against `src` (post-M44 review): the
    // copy is a WRITE, and `deps/<pack>/../../x` landed outside the project
    i64 n = dep_read_files(src, what, &names);
    i64 i = 0;
    pkg_copy_file(tm_cat(src, "mc.toml"), tm_cat(dst, "mc.toml"));
    i = 0;
    while (i < n) {
        pkg_copy_file(path_join(src, ld64(names + i * 8)),
                      path_join(dst, ld64(names + i * 8)));
        i = i + 1;
    }
    return n + 1;
}

i64 pkg_vendor() {
    deps_apply(cfg_file);
    i64 i = 0;
    while (i < dp_npkg()) {
        uptr name = dp_name(i);
        uptr dst = pkg_vendor_dir(name);
        uptr src = dp_dir(i);
        if (!str_eq(src, dst)) {
            i64 n = pkg_copy_tree(src, dst, pkg_what(name, dp_ver(i)));
            drv_step("vendor", pkg_what(name, dp_ver(i)),
                     tm_cat(tm_cat("deps/", name), tm_cat("/ (", tm_cat(tm_num_str(n), " files)"))));
        }
        i = i + 1;
    }
    out_str(1, "vendored ");
    out_str(1, tm_num_str(dp_npkg()));
    out_str(1, " packages into deps/\n");
    return 0;
}

// ---- editing [deps] (§ 7, risk 9) ----
// lim_fix_write's method (src/limits.mc): ONE key in ONE section is replaced or
// inserted and every other byte of the file comes out exactly as it went in.
// Refused when the file has a [deps] table the scan cannot see -- an unusual
// spelling like `[ deps ]` -- because writing a second one would be worse than
// saying so.
void pkg_dep_line(uptr b, uptr name, uptr ver) {
    drv_put(b, name);
    drv_put(b, " = \"");
    drv_put(b, ver);
    drv_put(b, "\"\n");
}

void pkg_add_write(uptr cfg, uptr name, uptr ver) {
    i64 len = 0;
    uptr s = read_file(cfg, &len);
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 indeps = 0;
    i64 seen = 0;                      // a [deps] header was seen at all
    i64 done = 0;
    i64 i = 0;
    while (i < len) {
        i64 e = i;
        while (e < len && ld8(s + e) != '\n') { e = e + 1; }
        if (e < len) e = e + 1;                    // the newline belongs to the line
        i64 k = i;
        while (k < e && (ld8(s + k) == ' ' || ld8(s + k) == '\t')) { k = k + 1; }
        if (ld8(s + k) == '[') {
            if (indeps && !done) {                 // the section ended: append
                pkg_dep_line(b, name, ver);
                done = 1;
            }
            indeps = mem_eq(s + k, "[deps]", 6);
            if (indeps) seen = 1;
        }
        if (indeps && !done && lim_line_key(s, k, name)) {
            pkg_dep_line(b, name, ver);
            done = 1;
            i = e;
            continue;
        }
        buf_put(b, s + i, e - i);
        i = e;
    }
    if (!done) {
        if (len > 0 && ld8(s + len - 1) != '\n') drv_put(b, "\n");
        if (!indeps) {
            if (seen)
                pkg_die1("mc pkg add cannot edit this file", "[deps] is written more than once");
            drv_put(b, "\n[deps]\n");
        }
        pkg_dep_line(b, name, ver);
    }
    write_file(cfg, b);
}

// `geo@1.2.0` -> the name; 0 when there is no `@`
uptr pkg_at_name(uptr s) {
    i64 n = 0;
    loop {
        i64 c = ld8(s + n);
        if (c == 0 || c == '@') break;
        n = n + 1;
    }
    return xstrdup(s, n);
}

uptr pkg_at_ver(uptr s) {
    i64 n = 0;
    loop {
        i64 c = ld8(s + n);
        if (c == 0) return 0;
        if (c == '@') return s + n + 1;
        n = n + 1;
    }
}

// the version `add`/`update` picks for a name: the one that was asked for, or
// the newest that is not yanked (within `major`, or any major when it is -1)
uptr pkg_pick(uptr name, uptr want, i64 major) {
    if (!pkg_index_load(name)) {
        pkg_print_plan();
        out_str(1, "nothing was downloaded: re-run with --yes\n");
        _exit(0);
    }
    if (want != 0) {
        i64 r = pkg_row(name, want);
        if (r < 0) pkg_die1(tm_cat(tm_cat(name, " "), want), "no such version in the registry");
        if (ld64(pk_vr(r) + VR_YANK))
            pkg_die1(tm_cat(tm_cat(name, " "), want), "is yanked: pick another version");
        return want;
    }
    uptr v = pkg_newest(name, major);
    if (v == 0) pkg_die1(name, "every registered version is yanked");
    return v;
}

// ---- add ----
i64 pkg_add(uptr arg) {
    uptr name = pkg_at_name(arg);
    if (dep_reserved(name)) pkg_die1("reserved package name", name);
    if (!dep_name_ok(name)) pkg_die1("invalid package name", name);
    uptr ver = pkg_pick(name, pkg_at_ver(arg), -1);
    pkg_add_write(cfg_file, name, ver);
    drv_step("add", pkg_what(name, ver), cfg_file);
    // the config changed under the table we parsed: read it again, so that
    // MVS and the lock see the [deps] this command just wrote
    toml_parse(cfg_file);
    return pkg_sync();
}

// ---- update (D21: top-level) ----
// `go get -u`: raise the [deps] minimum(s) to the newest non-yanked index
// version, then sync. With a NAME, that one; without, every one.
i64 pkg_update(uptr only) {
    i64 n = 0;
    uptr names = xalloc(toml_entries() * 8 + 8);
    i64 i = 0;
    while (i < toml_entries()) {
        uptr k = opt_val(toml_path_at(i), "deps.");
        if (k != 0 && (only == 0 || str_eq(k, only))) {
            dep_check_name("deps.", k);
            st64(names + n * 8, k);
            n = n + 1;
        }
        i = i + 1;
    }
    if (only != 0 && n == 0) pkg_die1("not a dependency of this project", only);
    i = 0;
    while (i < n) {
        uptr name = ld64(names + i * 8);
        uptr cur = toml_get(tm_cat("deps.", name));
        uptr v = pkg_pick(name, 0, ver_major(cur));
        if (ver_cmp(v, cur) > 0) {
            pkg_add_write(cfg_file, name, v);
            drv_step("update", name, tm_cat(tm_cat(cur, " -> "), v));
        }
        i = i + 1;
    }
    toml_parse(cfg_file);
    return pkg_sync();
}

// ---- hash ----
// The author's tool, and the registry CI's: the tree hash of a checkout, which
// is what a [[versions]] row's sha256 has to carry. One definition, in
// src/deps.mc -- the same function `mc build` rehashes with, and the same rule
// scripts/pkg-hash.sh implements in shell.
i64 pkg_hash_cmd(uptr dir) {
    uptr d = tm_cat(path_norm(dir), "/");
    uptr h = dep_hash_tree(d, -1);
    if (h == 0) pkg_die1("no mc.toml in", dir);
    out_str(1, h);
    out_str(1, "\n");
    return 0;
}

// ---- check: the registry-side gate (§ 5) ----
// Run by the registry's CI on every changed index file, and by an author before
// the pull request. It refuses:
//
//   * a [package].name outside the name rule, or one of the reserved names
//     (`mc` above all: <mc/core> is the compiler's own source, A5);
//   * a row with no url or no sha256, or a version that is not X.Y.Z;
//   * with --yes, a row whose ARCHIVE disagrees with it -- the tree hash, the
//     package name, or the set of [deps];
//   * an edit to a row the registry already publishes, except adding
//     `yanked = true`. That comparison needs the published copy, which is what
//     --registry names.
i64 pkg_check_same(uptr a, uptr b) {
    if (a == 0 && b == 0) return 1;
    if (a == 0 || b == 0) return 0;
    return str_eq(a, b);
}

// Every row the registry already publishes has to be in the candidate file,
// unchanged. `yanked` is deliberately not compared: adding it is the one edit
// D3 allows.
void pkg_check_immutable(uptr name, uptr file) {
    uptr pub = pkg_index_url(name);
    if (!fetch_is_url(pub)) {
        if (!lex_readable(pub)) return;                 // a new package
        if (str_eq(path_norm(pub), path_norm(file))) return;  // it IS the file
    } else {
        // Post-M44 review, finding 4: this used to `return` -- silently
        // answering "immutable" -- both without --yes and on ANY failed fetch,
        // which turned the one rule the registry has (a published row never
        // changes) into a check that a network hiccup switches off.
        if (!pk_yes())
            dep_die("check needs --yes to compare against the published index", name, 0);
        uptr snap = tm_cat(pkg_index_snapshot(name), ".published");
        drv_mkdirs(snap);
        i64 rc = fetch_get(pub, snap, FETCH_MAXINDEX);
        // 22 is `curl -f` on an HTTP status >= 400 and 8 is wget's; either way
        // the index file is not there, which is exactly "a new package". Any
        // other code is a failure to READ the index and must not pass for one.
        if (rc == 22 || rc == 8) return;
        if (rc != 0)
            dep_die(tm_cat("check: cannot read the published index for ", name),
                    pkg_fetch_reason(rc), 0);
        pub = snap;
    }
    uptr frame = toml_push();
    toml_parse(pub);
    i64 nv = toml_occurrences("versions");
    i64 n = 0;
    uptr vers = xalloc(nv * 8 + 8);
    uptr urls = xalloc(nv * 8 + 8);
    uptr shas = xalloc(nv * 8 + 8);
    i64 i = 0;
    while (i < nv) {
        uptr key = tm_cat(tm_cat("versions.", tm_num_str(i)), ".");
        st64(vers + n * 8, toml_get(tm_cat(key, "version")));
        st64(urls + n * 8, toml_get(tm_cat(key, "url")));
        st64(shas + n * 8, toml_get(tm_cat(key, "sha256")));
        n = n + 1;
        i = i + 1;
    }
    toml_pop(frame);
    i = 0;
    while (i < n) {
        uptr ver = ld64(vers + i * 8);
        i64 r = pkg_row(name, ver);
        if (r < 0)
            pkg_die1(pkg_what(name, ver), "a published version was removed");
        uptr row = pk_vr(r);
        if (!pkg_check_same(ld64(urls + i * 8), ld64(row + VR_URL))
            || !pkg_check_same(ld64(shas + i * 8), ld64(row + VR_SHA)))
            pkg_die1(pkg_what(name, ver),
                     "a published row was edited: only yanked = true may be added");
        i = i + 1;
    }
}

// with --yes: the archive itself, against the row that describes it
void pkg_check_archive(uptr name, uptr row) {
    uptr ver = ld64(row + VR_VER);
    uptr dir = pkg_libs_dir(name, ver);
    if (!lex_readable(pkg_libs_manifest(name, ver)))
        pkg_fetch_one(name, ver, ld64(row + VR_URL), ld64(row + VR_STRIP),
                      ld64(row + VR_SHA));
    uptr frame = toml_push();
    toml_parse(tm_cat(dir, "mc.toml"));
    uptr aname = toml_get("package.name");
    if (aname == 0 || !str_eq(aname, name))
        pkg_die1(pkg_what(name, ver), "the archive's mc.toml names another package");
    i64 nd = 0;
    i64 j = 0;
    while (j < toml_entries()) {
        uptr dk = opt_val(toml_path_at(j), "deps.");
        if (dk != 0) {
            i64 found = 0;
            i64 m = 0;
            while (m < ld64(row + VR_DEPN)) {
                if (str_eq(pkg_req_name(ld64(ld64(row + VR_DEPP) + m * 8)), dk)) found = 1;
                m = m + 1;
            }
            if (!found)
                pkg_die1(pkg_what(name, ver),
                         tm_cat("the archive requires a package the row does not list: ", dk));
            nd = nd + 1;
        }
        j = j + 1;
    }
    toml_pop(frame);
    if (nd != ld64(row + VR_DEPN))
        pkg_die1(pkg_what(name, ver), "the row lists a dependency the archive does not have");
    out_str(1, "ok     ");
    out_str(1, pkg_what(name, ver));
    out_str(1, "\n");
}

i64 pkg_check(uptr file) {
    uptr frame = toml_push();
    toml_parse(file);
    uptr name = toml_get("package.name");
    if (name == 0) toml_err_key("package.name", "missing key");
    if (dep_reserved(name)) toml_err_key("package.name", "reserved package name");
    if (!dep_name_ok(name)) toml_err_key("package.name", "invalid package name");
    if (toml_occurrences("versions") == 0)
        toml_err_key("package.name", "an index file with no [[versions]] row");
    toml_pop(frame);

    pkg_index_read(name, file);
    i64 nv = 0;
    i64 i = 0;
    while (i < pk_nvr()) {
        uptr row = pk_vr(i);
        if (str_eq(ld64(row + VR_NAME), name)) {
            uptr ver = ld64(row + VR_VER);
            if (ver_cmp(ver, "0.0.0") == 0 && !str_eq(ver, "0.0.0"))
                pkg_die1(ver, "not a version");
            if (ld64(row + VR_URL) == 0) pkg_die1(pkg_what(name, ver), "the row has no url");
            if (ld64(row + VR_SHA) == 0) pkg_die1(pkg_what(name, ver), "the row has no sha256");
            if (cstrlen(ld64(row + VR_SHA)) != 64)
                pkg_die1(pkg_what(name, ver), "sha256 is not 64 hex characters");
            if (pk_yes()) pkg_check_archive(name, row);
            else {
                out_str(1, "would check ");
                out_str(1, pkg_what(name, ver));
                out_str(1, "\n");
            }
            nv = nv + 1;
        }
        i = i + 1;
    }
    pkg_check_immutable(name, file);
    out_str(1, "check  ");
    out_str(1, file);
    out_str(1, ": ");
    out_str(1, tm_num_str(nv));
    out_str(1, " rows\n");
    if (!pk_yes()) out_str(1, "nothing was downloaded: re-run with --yes\n");
    return 0;
}

// ---- the config ----
// Same shape as drv_run's first four lines: the config's path is what every
// relative path in this file is resolved against (drv_path), and it is what
// src/deps.mc reads the lock beside.
void pkg_open_config(uptr dir, uptr cfg) {
    if (dir == 0) dir = ".";
    if (cfg == 0) cfg = path_norm(tm_cat(dir, "/mc.toml"));
    cfg_file = cfg;
    toml_parse(cfg);
    uptr r = deps_registry();
    if (r != 0 && str_eq(pk_registry(), pkg_default_registry())) pk_set_registry(r);
}

void pkg_usage() {
    out_str(2, "usage: mc pkg sync|add|list|vendor|verify [DIR] [--config FILE] [--yes] [--registry URL|DIR] [--libs-dir DIR]\n");
    out_str(2, "       mc pkg hash DIR\n");
    out_str(2, "       mc pkg check INDEX.toml [--yes] [--registry URL|DIR] [--libs-dir DIR]\n");
}

// ---- the dispatch ----
i64 pkg_cmd(i64 argc, uptr argv) {
    if (argc < 3) {
        pkg_usage();
        return 1;
    }
    uptr sub = ld64(argv + 2 * 8);
    uptr pos1 = 0;
    uptr pos2 = 0;
    uptr cfg = 0;
    i64 i = 3;
    while (i < argc) {
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--yes")) pk_set_yes(1);
        else if (str_eq(a, "--config")) {
            if (i + 1 >= argc) die("--config requires an argument");
            i = i + 1;
            cfg = ld64(argv + i * 8);
        }
        else if (str_eq(a, "--registry")) {
            if (i + 1 >= argc) die("--registry requires an argument");
            i = i + 1;
            pk_set_registry(ld64(argv + i * 8));
        }
        else if (str_eq(a, "--libs-dir")) {
            if (i + 1 >= argc) die("--libs-dir requires an argument");
            i = i + 1;
            deps_set_libs_dir(ld64(argv + i * 8));
        }
        else if (ld8(a) == '-') { pkg_usage(); return 1; }
        else if (pos1 == 0)      pos1 = a;
        else if (pos2 == 0)      pos2 = a;
        else                     die2("too many arguments", a);
        i = i + 1;
    }
    if (str_eq(sub, "hash")) {
        if (pos1 == 0) { pkg_usage(); return 1; }
        return pkg_hash_cmd(pos1);
    }
    if (str_eq(sub, "check")) {
        if (pos1 == 0) { pkg_usage(); return 1; }
        return pkg_check(pos1);
    }
    if (str_eq(sub, "add")) {
        if (pos1 == 0) { pkg_usage(); return 1; }
        pkg_open_config(pos2, cfg);
        return pkg_add(pos1);
    }
    pkg_open_config(pos1, cfg);
    if (str_eq(sub, "sync"))   return pkg_sync();
    if (str_eq(sub, "list"))   return pkg_list();
    if (str_eq(sub, "vendor")) return pkg_vendor();
    if (str_eq(sub, "verify")) return pkg_verify();
    pkg_usage();
    return 1;
}

// `mc update [NAME] [DIR]`. One positional is a DIRECTORY when it holds an
// mc.toml and a NAME otherwise -- the two are never ambiguous in practice (a
// package name has no `/` and a project directory is not a registered name),
// and the rule is stated rather than guessed.
i64 update_cmd(i64 argc, uptr argv) {
    uptr name = 0;
    uptr dir = 0;
    uptr cfg = 0;
    i64 i = 2;
    while (i < argc) {
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--yes")) pk_set_yes(1);
        else if (str_eq(a, "--config")) {
            if (i + 1 >= argc) die("--config requires an argument");
            i = i + 1;
            cfg = ld64(argv + i * 8);
        }
        else if (str_eq(a, "--registry")) {
            if (i + 1 >= argc) die("--registry requires an argument");
            i = i + 1;
            pk_set_registry(ld64(argv + i * 8));
        }
        else if (str_eq(a, "--libs-dir")) {
            if (i + 1 >= argc) die("--libs-dir requires an argument");
            i = i + 1;
            deps_set_libs_dir(ld64(argv + i * 8));
        }
        else if (ld8(a) == '-') {
            out_str(2, "usage: mc update [NAME] [DIR] [--config FILE] [--yes] [--registry URL|DIR] [--libs-dir DIR]\n");
            return 1;
        }
        else if (name == 0) name = a;
        else if (dir == 0)   dir = a;
        else                 die2("too many arguments", a);
        i = i + 1;
    }
    if (dir == 0 && name != 0 && lex_readable(path_norm(tm_cat(name, "/mc.toml")))) {
        dir = name;
        name = 0;
    }
    pkg_open_config(dir, cfg);
    return pkg_update(name);
}
