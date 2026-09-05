// fetch.mc — getting a file, and unpacking an archive (M44 § 4, D9).
//
// This is `mc sysroot fetch`'s road (M25) with the sysroot taken out of it: one
// source of a file, one archive extractor, one `.sha256` reader. `mc pkg` needs
// exactly the same things about a package tarball that `mc sysroot fetch` needs
// about a sysroot tarball, and a second copy of them would be a second set of
// flags to get right. src/sysroot.mc now calls into here and keeps only what is
// about sysroots: the pinned row, the members, the markers, the manifest.
//
// Two roads, decided by the source's own spelling and by nothing else:
//
//   https://...   spawn the host's downloader (curl, then the alternative) with
//                 the HTTPS-only flags of docs/specs/M25.md § 2. There is no TLS
//                 in this language and there is no HTTP client here.
//   anything else a LOCAL PATH, copied. That is what makes the whole test suite
//                 need no network -- a fixture registry is a directory and a
//                 fixture archive is a file -- and it is what prices a private
//                 registry at zero: a `git clone` of a tap plus
//                 `[registry] url = "/path/to/it"` (M44 § 5).
//
// Nothing here prints anything about a TRANSFER. The caller knows whether it is
// fetching a sysroot, a registry index or a package, and its message says so;
// that is why fetch_get answers with a code and not with an exit.
//
// An ARCHIVE is different, and it is the one thing this file does refuse by
// itself (post-M44 review, finding 2). `tar` used to be trusted: mc handed it a
// file somebody else produced and let it decide what to write. It is listed
// first now, and a member that is absolute, that carries a `..`, that lands
// outside the destination after --strip-components, or that is a symlink or a
// hard link, stops the extraction before a byte is written -- with the archive
// named, at exit 2. That refusal has no caller-specific wording and no useful
// return value, so it is a message and an _exit here.
//
// Depends on arena.mc (buf, read_file/write_file), sha256.mc (hex64, through
// its callers), toml.mc (tm_cat, tm_num_str), lex.mc (lex_readable), driver.mc
// (drv_spawn_ok, DRV_MAXARG) and the host layer (host_downloader/_alt).

// ---- the two spellings ----
// An `https://` source is fetched, anything else is a path. `http://` is not a
// third case: it is a path that will not open, which is the honest answer for a
// toolchain that refuses plaintext transport (M25 § 2).
i64 fetch_is_url(uptr src) {
    return mem_eq(src, "https://", 8);
}

// last path component of a URL or a path
uptr fetch_basename(uptr p) {
    i64 last = -1;
    i64 i = 0;
    loop {
        i64 c = ld8(p + i);
        if (c == 0) break;
        if (c == '/') last = i;
        i = i + 1;
    }
    return p + last + 1;
}

// 1 when `s` ends with `suf`
i64 fetch_ends(uptr s, uptr suf) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(suf);
    if (m > n) return 0;
    return mem_eq(s + n - m, suf, m);
}

// which `tar` flag this archive needs. An Alpine `.apk` is a gzip tar (three
// concatenated gzip members) and `-xzf` reads it on all three hosts; `.zip` is
// only ever a row for a Windows host, whose bundled tar.exe is libarchive.
//
// The compression letter is the same for extracting (`-x`), listing (`-t`) and
// listing verbosely (`-tv`), so the three spellings come out of one function
// and cannot drift apart.
uptr fetch_tar_flag_op(uptr name, uptr op) {
    if (fetch_ends(name, ".zip")) return tm_cat(op, "f");
    if (fetch_ends(name, ".tar.xz")) return tm_cat(op, "Jf");
    return tm_cat(op, "zf");
}

uptr fetch_tar_flag(uptr name) { return fetch_tar_flag_op(name, "-x"); }

// ---- size caps (post-M44 review, finding 6) ----
// A downloader writes what the far end sends and a local path is whatever is on
// the disk; neither had a ceiling, so an index file or a package archive could
// fill the disk (and, once read, the arena) before anything looked at it. The
// two numbers are deliberately far apart: an index file is a handful of TOML
// rows and an archive is a source tree.
#define FETCH_MAXINDEX   1048576              // 1 MiB
#define FETCH_MAXARCHIVE 67108864             // 64 MiB

// 1 when the file is at most `cap` bytes (cap 0 = no ceiling). Counted in
// chunks and stopped at the first byte over, so the arena never holds the file
// this is refusing.
i64 fetch_size_ok(uptr path, i64 cap) {
    if (cap <= 0) return 1;
    i64 fd = c_int(open(path, O_RDONLY, 0));
    if (fd < 0) return 1;                     // not there: not this check's job
    uptr tmp = xalloc(RF_CHUNK);
    i64 n = 0;
    i64 ok = 1;
    loop {
        i64 r = read(fd, tmp, RF_CHUNK);
        if (r <= 0) break;
        n = n + r;
        if (n > cap) { ok = 0; break; }
    }
    close(fd);
    return ok;
}

// ---- get ----
// 0 on success, -1 when no downloader is on PATH, FETCH_TOOBIG when the body is
// larger than `cap` (and then the file is unlinked), the tool's exit status (or
// 1 for an unreadable local path) otherwise. `cap` of 0 means no ceiling.
//
// `--proto =https --proto-redir =https` is the HTTPS-only rule stated to the
// program that does the transfer and not only to the table: every URL is an
// `https://` one, but `-L` follows redirects and without those two flags a 3xx
// to an `http://` mirror would be followed silently. The `wget` fallback keeps
// its two flags: busybox's `wget` is what an Alpine host has and it knows
// neither `--https-only` nor `--proto`, so refusing plaintext there would cost
// the fallback itself (docs/reference/sysroot.md § 7).
#define FETCH_TOOBIG (-2)

i64 fetch_get(uptr src, uptr file, i64 cap) {
    if (!fetch_is_url(src)) {
        if (!lex_readable(src)) return 1;
        if (!fetch_size_ok(src, cap)) return FETCH_TOOBIG;
        i64 len = 0;
        uptr p = read_file(src, &len);
        u8 b[BUF_SIZE];
        buf_init(b);
        buf_put(b, p, len);
        write_file(file, b);
        return 0;
    }
    uptr d = host_downloader();
    u8 av[10 * 8];
    st64(av + 0, d);
    st64(av + 8, "--proto");
    st64(av + 16, "=https");
    st64(av + 24, "--proto-redir");
    st64(av + 32, "=https");
    st64(av + 40, "-fLsS");
    st64(av + 48, "-o");
    st64(av + 56, file);
    st64(av + 64, src);
    st64(av + 72, 0);
    i64 rc = drv_spawn_ok(d, av, 0);
    if (rc < 0) {
        uptr a = host_downloader_alt();
        if (a == 0) return -1;
        st64(av + 0, a);
        st64(av + 8, "-q");
        st64(av + 16, "-O");
        st64(av + 24, file);
        st64(av + 32, src);
        st64(av + 40, 0);
        rc = drv_spawn_ok(a, av, 0);
        if (rc < 0) return -1;
    }
    if (rc != 0) return rc;
    // the ceiling is applied to what actually landed: a downloader has no
    // --max-filesize we can rely on across curl and busybox wget
    if (!fetch_size_ok(file, cap)) {
        unlink(file);
        return FETCH_TOOBIG;
    }
    return 0;
}

// ---- the member table (post-M44 review, finding 2) ----
// What the last fetch_extract listed, as paths RELATIVE to the destination --
// --strip-components already applied. Two consumers: the post-extraction check
// below, and src/pkg.mc's pkg_unbless, which used to re-read the untrusted tree
// mc.toml to decide what to DELETE and now deletes exactly what the extraction
// wrote.
#define FX_N   0
#define FX_CAP 8
#define FX_P   16                              // uptr per member
#define FX_D   24                              // 1 per member when it is a directory
#define FX_SIZE 32

uptr fx = 0;

uptr fx_state() {
    if (fx == 0) fx = xalloc(FX_SIZE);
    return fx;
}

i64  fetch_member_count()   { return ld64(fx_state() + FX_N); }
uptr fetch_member_at(i64 i) { return ld64(ld64(fx_state() + FX_P) + i * 8); }
i64  fetch_member_dir(i64 i) { return ld64(ld64(fx_state() + FX_D) + i * 8); }

void fx_reset() { st64(fx_state() + FX_N, 0); }

void fx_add(uptr rel, i64 isdir) {
    uptr s = fx_state();
    i64 n = ld64(s + FX_N);
    i64 cap = ld64(s + FX_CAP);
    if (n >= cap) {
        i64 nc = cap * 2;
        if (nc < 64) nc = 64;
        uptr np = xalloc(nc * 8);
        uptr nd = xalloc(nc * 8);
        mem_copy(np, ld64(s + FX_P), n * 8);
        mem_copy(nd, ld64(s + FX_D), n * 8);
        st64(s + FX_P, np);
        st64(s + FX_D, nd);
        st64(s + FX_CAP, nc);
    }
    st64(ld64(s + FX_P) + n * 8, rel);
    st64(ld64(s + FX_D) + n * 8, isdir);
    st64(s + FX_N, n + 1);
}

// `<archive>: member escapes the archive: <member>`, exit 2. The archive is
// named by its last component: the whole path is a cache location nobody wrote
// down, and the name is what the registry row points at.
void fetch_refuse(uptr archive, uptr why, uptr member) {
    unlink(archive);                           // a refused archive is poison
    out_str(2, "mc: ");
    out_str(2, fetch_basename(archive));
    out_str(2, ": ");
    out_str(2, why);
    out_str(2, ": ");
    out_str(2, member);
    out_str(2, "\n");
    _exit(2);
}

// runs a program with stdout redirected into `outfile` -- drv_sdk's file-action
// trick, which is the only way this language captures output (no pipes)
i64 fetch_spawn_to(uptr prog, uptr av, uptr outfile) {
    u8 fa[8];
    st64(fa, 0);
    if (posix_spawn_file_actions_init(fa) != 0) die("posix_spawn_file_actions_init failed");
    drv_mkdirs(outfile);
    if (posix_spawn_file_actions_addopen(fa, 1, outfile, O_WRONLY | O_CREAT | O_TRUNC, MODE_644) != 0)
        die2("cannot create", outfile);
    i64 rc = drv_spawn_ok(prog, av, fa);
    posix_spawn_file_actions_destroy(fa);
    return rc;
}

// `tar -t[v]<z>f ARCHIVE` into `outfile`
i64 fetch_tar_list(uptr archive, uptr outfile, uptr op) {
    u8 av[6 * 8];
    st64(av + 0, "tar");
    st64(av + 8, fetch_tar_flag_op(archive, op));
    st64(av + 16, archive);
    st64(av + 24, 0);
    return fetch_spawn_to("tar", av, outfile);
}

// the start of line `k` of `s` (0-based), and its end through `pend`; -1 when
// there is no such line. A trailing newline does not make an extra line.
i64 fx_line(uptr s, i64 len, i64 from, uptr pend) {
    if (from >= len) return -1;
    i64 e = from;
    while (e < len && ld8(s + e) != '\n') { e = e + 1; }
    i64 t = e;
    if (t > from && ld8(s + t - 1) == '\r') t = t - 1;   // a Windows tar
    st64(pend, t);
    return e + 1;
}

// drops the first `strip` components, the way --strip-components does; 0 when
// the member has no more components than that (tar skips it silently)
uptr fx_strip(uptr name, i64 strip) {
    i64 i = 0;
    i64 k = 0;
    while (k < strip) {
        i64 n = cstrlen(name + i);
        i64 j = 0;
        while (j < n && ld8(name + i + j) != '/') { j = j + 1; }
        if (j >= n) return 0;
        i = i + j + 1;
        k = k + 1;
    }
    if (ld8(name + i) == 0) return 0;
    return name + i;
}

// ---- extract ----
// `tar <flag> ARCHIVE -C DEST --strip-components=N [MEMBER...]`, the members a
// space-separated list or 0 for "everything in the archive". One spawn, no
// shell. The flag comes from the ARCHIVE's own name, which is the URL's last
// component wherever a URL was involved.
//
// Before that spawn the archive is LISTED and every member checked. Two
// listings and not one: `-tf` gives the names one per line and nothing else,
// which is the only way to read a name that contains a space, and `-tvf` gives
// the ls-style type character in column 1 -- `l` for a symbolic link, `h` for a
// hard link, `d` for a directory -- which is the only way to see that a member
// is a link at all. They come out in the same order, so the k-th line of one
// describes the k-th line of the other; a disagreement in the number of lines
// is itself a refusal.
//
// What is NOT done, on record: the extraction still names no members when the
// caller named none. Passing the validated list back to tar would mean writing
// it into a space-separated argument string, which no member whose name
// contains a space can survive, and the archive between the listing and the
// extraction is a file mc has just written and does not re-fetch.
void fetch_check_members(uptr archive, uptr dest, i64 strip) {
    fx_reset();
    uptr lf = tm_cat(archive, ".list");
    uptr vf = tm_cat(archive, ".listv");
    if (fetch_tar_list(archive, lf, "-t") != 0) {
        unlink(lf);
        fetch_refuse(archive, "cannot be listed", "tar -t failed");
    }
    if (fetch_tar_list(archive, vf, "-tv") != 0) {
        unlink(lf);
        unlink(vf);
        fetch_refuse(archive, "cannot be listed", "tar -tv failed");
    }
    if (!fetch_size_ok(lf, FETCH_MAXINDEX) || !fetch_size_ok(vf, FETCH_MAXINDEX)) {
        unlink(lf);
        unlink(vf);
        fetch_refuse(archive, "has too many members to list", "over 1 MiB of names");
    }
    i64 ll = 0;
    i64 vl = 0;
    uptr ls = read_file(lf, &ll);
    uptr vs = read_file(vf, &vl);
    unlink(lf);
    unlink(vf);
    i64 li = 0;
    i64 vi = 0;
    loop {
        i64 le = 0;
        i64 ve = 0;
        i64 lnext = fx_line(ls, ll, li, &le);
        i64 vnext = fx_line(vs, vl, vi, &ve);
        if (lnext < 0) {
            if (vnext >= 0) fetch_refuse(archive, "lists differently twice", "tar -t and tar -tv disagree");
            break;
        }
        if (vnext < 0) fetch_refuse(archive, "lists differently twice", "tar -t and tar -tv disagree");
        uptr name = xstrdup(ls + li, le - li);
        i64 type = ld8(vs + vi);
        li = lnext;
        vi = vnext;
        if (cstrlen(name) == 0) continue;
        if (type == 'l' || type == 'h')
            fetch_refuse(archive, "archive member is a link", name);
        i64 isdir = ld8(name + cstrlen(name) - 1) == '/';
        // an absolute member, or one with a `..`, is refused BEFORE the strip:
        // what tar would do with it differs between implementations, and mc
        // does not want any of them
        if (!dep_rel_ok(name, 1)) fetch_refuse(archive, "member escapes the archive", name);
        uptr rel = fx_strip(name, strip);
        if (rel == 0) continue;                 // tar skips it: too few components
        if (!dep_rel_ok(rel, 1) || !dep_under(dest, rel))
            fetch_refuse(archive, "member escapes the archive", name);
        fx_add(rel, isdir);
    }
}

i64 fetch_extract(uptr archive, uptr dest, i64 strip, uptr members) {
    fetch_check_members(archive, dest, strip);
    u8 av[DRV_MAXARG * 8];
    i64 n = 0;
    st64(av + n * 8, "tar");                    n = n + 1;
    st64(av + n * 8, fetch_tar_flag(archive));  n = n + 1;
    st64(av + n * 8, archive);                  n = n + 1;
    st64(av + n * 8, "-C");                     n = n + 1;
    st64(av + n * 8, dest);                     n = n + 1;
    st64(av + n * 8, tm_cat("--strip-components=", tm_num_str(strip))); n = n + 1;
    if (members != 0) {
        u8 b[BUF_SIZE];
        buf_init(b);
        i64 i = 0;
        loop {
            i64 c = ld8(members + i);
            if (c == 0 || c == ' ') {
                if (buf_len(b) > 0) {
                    buf_u8(b, 0);
                    if (n >= DRV_MAXARG - 1) die("too many archive members");
                    st64(av + n * 8, buf_p(b));
                    n = n + 1;
                    buf_init(b);
                }
                if (c == 0) break;
            } else {
                buf_u8(b, c);
            }
            i = i + 1;
        }
    }
    st64(av + n * 8, 0);
    i64 rc = drv_spawn_ok("tar", av, 0);
    if (rc != 0) return rc;
    // Every member the listing promised has to be there, as something `open`
    // can read: a symlink was refused above, so nothing under `dest` can be one
    // -- this is the check that says tar wrote what tar said it would. Only
    // when the caller took the whole archive: with an explicit member list, tar
    // deliberately writes a subset (src/sysroot.mc's rows).
    if (members == 0) {
        i64 k = 0;
        while (k < fetch_member_count()) {
            if (!fetch_member_dir(k)) {
                uptr q = path_join(tm_cat(path_norm(dest), "/"), fetch_member_at(k));
                if (!lex_readable(q))
                    fetch_refuse(archive, "member missing after extraction", fetch_member_at(k));
            }
            k = k + 1;
        }
    }
    return 0;
}

// ---- a `.sha256` file ----
// `sha256sum -c` writes `<64 hex>  <name>`, and that is what
// scripts/release-assets.sh writes. Only the digest is read, and only when it
// IS 64 hex characters -- an HTML error page saved under the name of a checksum
// file must not come out of here as a digest that merely fails to match.
uptr fetch_sha256_line(uptr path) {
    i64 len = 0;
    uptr s = read_file(path, &len);
    if (len < 64) return 0;
    i64 i = 0;
    while (i < 64) {
        i64 c = ld8(s + i);
        if ((c < '0' || c > '9') && (c < 'a' || c > 'f')) return 0;
        i = i + 1;
    }
    return xstrdup(s, 64);
}
