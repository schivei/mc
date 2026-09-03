// check.mc - `mcsite --check`: every internal link resolves, and the two Python
// checkers of site/tools run when python3 is on the PATH.
//
// The link check is done in mc, on the files that were actually written: an
// href/src is either external with an allowed scheme (left alone), a fragment
// (its id has to exist on the page), or a URL under base_url (the file it names
// has to exist under site/public, and a fragment on it has to exist in THAT
// file). Any other scheme is a problem, counted like a broken link.
//
// The structural and accessibility checks - tag balance, one h1, landmarks,
// accessible names, alt text, /static/ references - are site/tools/checkhtml.py,
// spawned exactly the way `mc build` spawns the linker (posix_spawnp + waitpid,
// docs/build.md § Spawning tools). Without python3 they are reported as skipped
// and nothing else changes: a machine without Python still gets the link check.

extern i64 posix_spawnp(uptr pid, uptr file, uptr fa, uptr attr, uptr av, uptr envp);
extern i64 waitpid(i64 pid, uptr status, i64 options);
extern uptr _NSGetEnviron();

i64 ck_bad = 0;
uptr ck_files;                        // every html file written, in page order
uptr ck_ids_path;                     // path -> ids, so a file is scanned once
uptr ck_ids_list;

void ck_err(uptr where, uptr msg, uptr detail) {
    out_str(2, where);
    out_str(2, ": ");
    out_str(2, msg);
    if (detail != 0) { out_str(2, ": "); out_str(2, detail); }
    out_str(2, "\n");
    ck_bad = ck_bad + 1;
}

// every id="..." of a file, scanned once and remembered
uptr ck_ids(uptr path) {
    i64 k = sl_index(ck_ids_path, path);
    if (k >= 0) return sl_at(ck_ids_list, k);
    uptr ids = sl_new();
    sl_add(ck_ids_path, u_dup(path));
    sl_add(ck_ids_list, ids);
    if (!u_file_exists(path)) return ids;
    i64 n = 0;
    uptr s = read_file(path, &n);
    i64 i = 0;
    loop {
        i64 j = u_find(s, n, i, "id=\"");
        if (j < 0) break;
        i64 e = u_chr(s, n, j + 4, '"');
        if (e < 0) break;
        sl_add(ids, xstrdup(s + j + 4, e - j - 4));
        i = e + 1;
    }
    return ids;
}

// the file under site/public a site URL names, or 0 when it is not one of ours
uptr ck_target(uptr href) {
    if (!u_starts(href, sg_base)) return 0;
    uptr rest = href + cstrlen(sg_base);
    if (cstrlen(rest) == 0) return u_join(sg_out, "index.html");
    if (u_ends(rest, "/")) return u_join(sg_out, u_cat2(rest, "index.html"));
    return u_join(sg_out, rest);
}

void ck_link(uptr page, uptr href) {
    i64 n = cstrlen(href);
    if (n == 0) { ck_err(page, "empty href", 0); return; }
    // The scheme, not the substring "://": `javascript://x` has that substring
    // and is not an external URL. Nothing mcsite renders can reach here with a
    // refused scheme any more, so a hit means a template or site.toml wrote it.
    i64 sch = u_scheme(href);
    if (sch == U_SCHEME_BAD) { ck_err(page, "refused link scheme", href); return; }
    if (sch == U_SCHEME_ABS) return;
    if (ld8(href) == '#') {
        if (!sl_has(ck_ids(page), href + 1)) ck_err(page, "fragment with no target", href);
        return;
    }
    uptr path = href;
    uptr frag = 0;
    i64 h = u_chr(href, n, 0, '#');
    if (h >= 0) {
        path = u_slice(href, 0, h);
        frag = href + h + 1;
    }
    uptr file = ck_target(path);
    if (file == 0) { ck_err(page, "link outside the site", href); return; }
    if (!u_file_exists(file)) { ck_err(page, "broken link", href); return; }
    if (frag != 0 && cstrlen(frag) != 0 && u_ends(file, ".html")) {
        if (!sl_has(ck_ids(file), frag)) ck_err(page, "fragment with no target", href);
    }
}

void ck_attr(uptr page, uptr s, i64 n, uptr attr) {
    i64 i = 0;
    loop {
        i64 j = u_find(s, n, i, attr);
        if (j < 0) break;
        i64 from = j + cstrlen(attr);
        i64 e = u_chr(s, n, from, '"');
        if (e < 0) break;
        ck_link(page, xstrdup(s + from, e - from));
        i = e + 1;
    }
}

void ck_page(uptr path) {
    if (!u_file_exists(path)) { ck_err(path, "page was not written", 0); return; }
    i64 n = 0;
    uptr s = read_file(path, &n);
    ck_attr(path, s, n, "href=\"");
    ck_attr(path, s, n, "src=\"");
}

// ---- spawning the Python checkers ----
// exit code of the tool, or -1 when it could not be started
i64 ck_spawn(uptr av) {
    u8 pid[8];
    st64(pid, 0);
    if (posix_spawnp(pid, ld64(av), 0, 0, av, ld64(_NSGetEnviron())) != 0) return 0 - 1;
    u8 st[8];
    st64(st, 0);
    waitpid(ld64(pid), st, 0);
    return (ld32(st) >> 8) & 255;
}

i64 ck_python(uptr script, uptr files) {
    uptr tool = u_join(sg_dir, script);
    if (!u_file_exists(tool)) return 0;
    i64 nf = 0;
    if (files != 0) nf = sl_n(files);
    uptr av = xalloc((nf + 3) * 8);
    st64(av, "python3");
    st64(av + 8, tool);
    i64 i = 0;
    loop {
        if (i >= nf) break;
        st64(av + (i + 2) * 8, sl_at(files, i));
        i = i + 1;
    }
    st64(av + (nf + 2) * 8, 0);
    i64 rc = ck_spawn(av);
    if (rc < 0) {
        out_str(1, "mcsite: python3 not found, ");
        out_str(1, script);
        out_str(1, " skipped\n");
        return 0;
    }
    if (rc != 0) {
        out_str(2, "mcsite: ");
        out_str(2, script);
        out_str(2, " reported problems\n");
        ck_bad = ck_bad + 1;
    }
    return rc;
}

i64 ck_run() {
    ck_bad = 0;
    ck_files = sl_new();
    ck_ids_path = sl_new();
    ck_ids_list = sl_new();
    i64 i = 0;
    loop {
        if (i >= sg_np) break;
        uptr path = u_join(sg_out, "404.html");
        if (pg_kind(i) != PK_404) path = u_join(sg_out, u_cat2(pg_url(i), "index.html"));
        sl_add(ck_files, path);
        i = i + 1;
    }
    i = 0;
    loop {
        if (i >= sl_n(ck_files)) break;
        ck_page(sl_at(ck_files, i));
        i = i + 1;
    }
    if (!u_file_exists(u_join(sg_out, "sitemap.xml"))) ck_err(sg_out, "no sitemap.xml", 0);
    if (sg_search && !u_file_exists(u_join(sg_out, "search.json"))) {
        ck_err(sg_out, "search is on but there is no search.json", 0);
    }
    out_str(1, "mcsite --check: ");
    out_num(1, sl_n(ck_files));
    out_str(1, " pages, ");
    out_num(1, ck_bad);
    out_str(1, " link problems\n");
    ck_python("tools/checkhtml.py", ck_files);
    ck_python("tools/contrast.py", 0);
    if (ck_bad != 0) return 1;
    out_str(1, "mcsite --check: ok\n");
    return 0;
}
