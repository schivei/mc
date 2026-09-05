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
// Nothing here prints anything. The caller knows whether it is fetching a
// sysroot, a registry index or a package, and its message says so; that is why
// fetch_get answers with a code and not with an exit.
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
uptr fetch_tar_flag(uptr name) {
    if (fetch_ends(name, ".zip")) return "-xf";
    if (fetch_ends(name, ".tar.xz")) return "-xJf";
    return "-xzf";
}

// ---- get ----
// 0 on success, -1 when no downloader is on PATH, the tool's exit status (or 1
// for an unreadable local path) otherwise.
//
// `--proto =https --proto-redir =https` is the HTTPS-only rule stated to the
// program that does the transfer and not only to the table: every URL is an
// `https://` one, but `-L` follows redirects and without those two flags a 3xx
// to an `http://` mirror would be followed silently. The `wget` fallback keeps
// its two flags: busybox's `wget` is what an Alpine host has and it knows
// neither `--https-only` nor `--proto`, so refusing plaintext there would cost
// the fallback itself (docs/reference/sysroot.md § 7).
i64 fetch_get(uptr src, uptr file) {
    if (!fetch_is_url(src)) {
        if (!lex_readable(src)) return 1;
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
    if (rc >= 0) return rc;
    uptr a = host_downloader_alt();
    if (a == 0) return -1;
    st64(av + 0, a);
    st64(av + 8, "-q");
    st64(av + 16, "-O");
    st64(av + 24, file);
    st64(av + 32, src);
    st64(av + 40, 0);
    return drv_spawn_ok(a, av, 0);
}

// ---- extract ----
// `tar <flag> ARCHIVE -C DEST --strip-components=N [MEMBER...]`, the members a
// space-separated list or 0 for "everything in the archive". One spawn, no
// shell. The flag comes from the ARCHIVE's own name, which is the URL's last
// component wherever a URL was involved.
i64 fetch_extract(uptr archive, uptr dest, i64 strip, uptr members) {
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
    return drv_spawn_ok("tar", av, 0);
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
