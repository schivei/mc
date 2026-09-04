// sysroot.mc — where the files a cross link needs come from (M25,
// docs/specs/M25.md, docs/reference/sysroot.md).
//
// `{sysroot}` in [linker].args used to be one `toml_get` and a path join, with
// no existence check anywhere: a wrong directory was diagnosed by the LINKER,
// halfway through a build, in the linker's own words. This file is the
// resolution chain that replaced it:
//
//   1. [sysroot].path        resolved against the config's directory, and now
//                            CHECKED against the target's marker files. Present
//                            but incomplete stops the chain -- an explicit path
//                            that is wrong is a mistake to report, not a reason
//                            to go looking somewhere else.
//   2. the running system    only when host == target: the probes below. A
//                            cross build never picks up the host's own libc.
//   3. the cache             --sysroot-dir DIR (the directory itself), else
//                            [sysroot].cache/<os>-<arch>, else
//                            host_home()/.mc/sysroots/<os>-<arch>.
//   4. nothing               sysroot_missing(): what was tried, what to run,
//                            and the manual commands -- then exit 2.
//
// "Present" is a marker-file test, not a directory walk: `mc` has no `opendir`,
// it has `open` (src/arena.mc), so path_exists() is open + close and each target
// declares the one or two names that say a directory is populated.
//
// Exit code 2 is new with M25 and belongs to this file alone: 1 is a
// diagnostic, 3 is the limits verdict, 2 is "the environment is not ready"
// (docs/reference/cli.md § Exit codes).
//
// The second half of this file is the `mc sysroot` subcommand -- `list`, `path`,
// `fetch` and `stub` (the last one is the front half of a build, handing the
// program to src/stubs.mc). `fetch` is the ONLY thing that reaches the network, it
// requires `--yes`, and it downloads by spawning `curl`/`wget`/`curl.exe`
// (host_downloader) rather than speaking HTTP: there is no TLS in this language
// and an `http://` fetch of a checksummed file would still be a downgrade
// nobody should ship. The checksum is computed HERE, by src/sha256.mc, so there
// is no dependence on three different checksum CLIs across three hosts.
//
// Depends on arena.mc (open/close, out_str, tm_cat via toml.mc), on toml.mc
// (toml_get for [sysroot], tm_num_str), on sha256.mc (sha256), on sysroots.mc
// (the pinned rows), on hooks.mc (the target registry, for `list`) and on
// driver.mc (drv_path, drv_sdk, drv_spawn_ok, drv_mkdirs). Everything that
// differs between hosts comes from the host layer:
// host_os/host_arch/host_home/host_has_sdk/host_downloader.

// ---- the one primitive: does this path open? ----
// O_RDONLY on a directory succeeds on macOS, Linux and Windows alike, so the
// same call answers for a file and for a directory.
i64 path_exists(uptr p) {
    i64 fd = open(p, O_RDONLY, 0);
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

// ---- the markers ----
// The files whose presence says "this directory is a sysroot for that target".
// Two for Linux because crt1.o alone is a `musl` package without `musl-dev`;
// one for Windows (the import library scripts/sysroot-windows.sh generates) and
// one for macOS (the SDK's libSystem stub).
// A marker may name ALTERNATIVES, separated by `|`: a Windows sysroot is
// `kernel32.lib` when scripts/sysroot-windows.sh generated it and
// `libkernel32.a` when `mc sysroot fetch` unpacked llvm-mingw's import
// libraries, and both are equally a sysroot. The first name is the one the
// message quotes.
uptr sysroot_marker(uptr os, i64 i) {
    if (str_eq(os, "linux")) {
        if (i == 0) return "crt1.o";
        if (i == 1) return "libc.a";
        return 0;
    }
    if (str_eq(os, "windows")) {
        if (i == 0) return "kernel32.lib|libkernel32.a";
        return 0;
    }
    if (str_eq(os, "macos")) {
        if (i == 0) return "usr/lib/libSystem.tbd";
        return 0;
    }
    return 0;
}

// the first alternative of `m`, which is what a diagnostic names
uptr sysroot_marker_name(uptr m) {
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 i = 0;
    loop {
        i64 c = ld8(m + i);
        if (c == 0 || c == '|') break;
        buf_u8(b, c);
        i = i + 1;
    }
    buf_u8(b, 0);
    return buf_p(b);
}

// 1 when `dir` holds ANY alternative of `m`
i64 sysroot_has_marker(uptr dir, uptr m) {
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 i = 0;
    loop {
        i64 c = ld8(m + i);
        if (c == 0 || c == '|') {
            buf_u8(b, 0);
            if (path_exists(tm_cat(tm_cat(dir, "/"), buf_p(b)))) return 1;
            if (c == 0) return 0;
            buf_init(b);
        } else {
            buf_u8(b, c);
        }
        i = i + 1;
    }
}

// the first marker of `os` that `dir` does not have, or 0 when it has them all
uptr sysroot_missing_marker(uptr dir, uptr os) {
    i64 i = 0;
    loop {
        uptr m = sysroot_marker(os, i);
        if (m == 0) return 0;
        if (!sysroot_has_marker(dir, m)) return sysroot_marker_name(m);
        i = i + 1;
    }
}

// ---- the state the chain leaves behind ----
uptr sr_dir_opt   = 0;                // --sysroot-dir DIR, the leaf directory
uptr sr_resolved  = 0;                // what the chain answered, per build
uptr sr_kind      = 0;                // "path" | "system" | "cache"
uptr sr_tried     = 0;                // the lines sysroot_missing() prints

void sr_note(uptr dir, uptr why) {
    uptr line = tm_cat(tm_cat(dir, " ("), tm_cat(why, ")"));
    if (sr_tried == 0) sr_tried = line;
    else               sr_tried = tm_cat(sr_tried, tm_cat("\n         ", line));
}

// one candidate: accepted when every marker is there, remembered with the
// reason it was not otherwise
i64 sr_try(uptr dir, uptr os) {
    if (!path_exists(dir)) { sr_note(dir, "absent"); return 0; }
    uptr m = sysroot_missing_marker(dir, os);
    if (m != 0) { sr_note(dir, tm_cat("no ", m)); return 0; }
    return 1;
}

// `os`-`arch`, the name a target goes by everywhere in this file
uptr sysroot_target(uptr os, uptr arch) { return tm_cat(tm_cat(os, "-"), arch); }

// a path written in mc.toml is relative to the CONFIG's directory; with no
// config -- `mc sysroot list|path` -- it is relative to the working directory
uptr sr_path(uptr rel) {
    if (cfg_file == 0) return rel;
    return drv_path(rel);
}

// ---- step 2: the running system ----
// Skipped entirely when host != target, which is what keeps a cross build from
// linking against the host's own crt1.o.
uptr sysroot_probe(uptr os, uptr arch) {
    if (!str_eq(os, host_os()) || !str_eq(arch, host_arch())) return 0;
    if (str_eq(os, "linux")) {
        // Debian/Ubuntu musl-dev (the layout the CI host legs use), then the
        // two Alpine ones -- `apk add musl-dev` puts all four in /usr/lib.
        uptr d = tm_cat(tm_cat("/usr/lib/", arch), "-linux-musl");
        if (sr_try(d, os)) return d;
        if (sr_try("/usr/lib/musl/lib", os)) return "/usr/lib/musl/lib";
        if (sr_try("/usr/lib", os)) return "/usr/lib";
        return 0;
    }
    if (str_eq(os, "macos")) {
        // the SDK is the macOS sysroot; it is also what {sdk} expands to, and
        // drv_sdk caches it, so asking twice runs `xcrun` once
        if (!host_has_sdk()) return 0;
        uptr t = "build/.mc-sdk";
        if (cfg_file != 0) t = tm_cat(cfg_file, ".sdk");
        uptr d = drv_sdk(t);
        if (sr_try(d, os)) return d;
        return 0;
    }
    if (str_eq(os, "windows")) {
        // `mc` cannot regenerate an import library (that is llvm-dlltool), so
        // the only thing to probe is where scripts/sysroot-windows.sh writes one
        uptr d = tm_cat("build/sysroot/windows-", arch);
        if (sr_try(d, os)) return d;
        return 0;
    }
    return 0;
}

// ---- step 3: the cache ----
// --sysroot-dir names the directory ITSELF (that is what CI passes, one target
// at a time); [sysroot].cache and the default name the ROOT, under which every
// target has its own <os>-<arch>.
uptr sysroot_cache_dir(uptr os, uptr arch) {
    if (sr_dir_opt != 0) return sr_dir_opt;
    uptr root = toml_get("sysroot.cache");
    if (root != 0) return tm_cat(tm_cat(sr_path(root), "/"), sysroot_target(os, arch));
    uptr home = host_home();
    if (home == 0) return 0;
    return tm_cat(tm_cat(home, "/.mc/sysroots/"), sysroot_target(os, arch));
}

// ---- the chain ----
// 0 when nothing answered; sr_kind says how it was found, sr_tried what was
// looked at. Nothing here downloads: `mc build` never reaches the network
// (docs/specs/M25.md, architect's addition (a)).
uptr sysroot_find(uptr os, uptr arch) {
    sr_tried = 0;
    sr_kind = 0;
    uptr p = toml_get("sysroot.path");
    if (p != 0) {
        uptr d = sr_path(p);
        if (sr_try(d, os)) { sr_kind = "path"; return d; }
        return 0;                      // explicit and wrong: do not go looking
    }
    uptr d = sysroot_probe(os, arch);
    if (d != 0) { sr_kind = "system"; return d; }
    d = sysroot_cache_dir(os, arch);
    if (d == 0) {
        sr_note("~/.mc/sysroots", "no HOME, no [sysroot].cache, no --sysroot-dir");
        return 0;
    }
    if (sr_try(d, os)) { sr_kind = "cache"; return d; }
    return 0;
}

// ---- step 4: the message ----
// One text, shared by `mc build` and by `mc sysroot path|fetch`, so there is one
// thing to get right and one thing to document
// (docs/reference/diagnostics.md § no sysroot).
// last path component of a URL or a path
uptr sysroot_basename(uptr p) {
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
i64 sysroot_ends(uptr s, uptr suf) {
    i64 n = cstrlen(s);
    i64 m = cstrlen(suf);
    if (m > n) return 0;
    return mem_eq(s + n - m, suf, m);
}

// which `tar` does this archive need. An Alpine `.apk` is a gzip tar (three
// concatenated gzip members) and `-xzf` reads it on all three hosts; `.zip` is
// only ever a row for a Windows host, whose bundled tar.exe is libarchive.
uptr sysroot_tar_flag(uptr url) {
    if (sysroot_ends(url, ".zip")) return "-xf";
    if (sysroot_ends(url, ".tar.xz")) return "-xJf";
    return "-xzf";
}

// where a fetched sysroot would go, as text, for a message that must print
// something even when there is no HOME
uptr sysroot_dest_text(uptr os, uptr arch) {
    uptr d = sysroot_cache_dir(os, arch);
    if (d != 0) return d;
    return tm_cat("~/.mc/sysroots/", sysroot_target(os, arch));
}

// The `run:`/`or:` half of the message: what would produce this sysroot, both
// as one `mc` command and as the commands to run by hand -- so an offline
// machine, or one behind a proxy `curl` cannot use, still has everything it
// needs. Written from the pinned row (src/sysroots.mc), never from memory.
void sysroot_manual(uptr os, uptr arch) {
    uptr t = sysroot_target(os, arch);
    i64 r = sysroot_src_find(t);
    if (r < 0 || ss_url_at(r) == 0) {
        if (str_eq(os, "macos")) {
            out_str(2, "  run:   nothing: `mc --exe` needs no SDK at all, and `mc sysroot stub`\n");
            out_str(2, "         writes the .tbd stubs the .o + ld road needs\n");
            out_str(2, "         (docs/reference/sysroot.md)\n");
            return;
        }
        out_str(2, "  run:   no pinned source for ");
        out_str(2, t);
        out_str(2, " on this host: point [sysroot].path at a directory\n");
        return;
    }
    uptr url = ss_url_at(r);
    uptr dest = sysroot_dest_text(os, arch);
    out_str(2, "  run:   mc sysroot fetch ");
    out_str(2, t);
    out_str(2, " --yes\n");
    out_str(2, "  or:    curl -fLO ");
    out_str(2, url);
    out_str(2, "\n         sha256  ");
    out_str(2, ss_sha_at(r));
    out_str(2, "\n         tar ");
    out_str(2, sysroot_tar_flag(url));
    out_str(2, " ");
    out_str(2, sysroot_basename(url));
    out_str(2, " -C ");
    out_str(2, dest);
    out_str(2, " --strip-components=");
    out_str(2, tm_num_str(ss_strip_at(r)));
    out_str(2, " \\\n                ");
    out_str(2, ss_member_at(r));
    out_str(2, "\n");
}

void sysroot_missing(uptr os, uptr arch) {
    out_str(2, "mc: no sysroot for ");
    out_str(2, sysroot_target(os, arch));
    out_str(2, "\n");
    if (sr_tried != 0) {
        out_str(2, "  tried: ");
        out_str(2, sr_tried);
        out_str(2, "\n");
    }
    sysroot_manual(os, arch);
    _exit(2);
}

// what drv_ph substitutes for {sysroot}: the chain, run at most once per build
// and only because some [linker].args value asked for it -- exactly the
// laziness {sdk} already had.
uptr sysroot_for(uptr os, uptr arch) {
    if (sr_resolved != 0) return sr_resolved;
    uptr d = sysroot_find(os, arch);
    if (d == 0) sysroot_missing(os, arch);
    sr_resolved = d;
    return d;
}

// =====================================================================
// `mc sysroot` -- list, path, fetch
// =====================================================================
// A third subcommand beside `build` and `limits` (src/main.mc). None of it is
// reachable from a build: `mc build` never downloads (docs/specs/M25.md,
// architect's addition (a)).

void sysroot_usage() {
    out_str(2, "usage: mc sysroot list\n");
    out_str(2, "       mc sysroot path <os>-<arch>\n");
    out_str(2, "       mc sysroot fetch <os>-<arch> [--yes] [--sysroot-dir DIR]\n");
    out_str(2, "       mc sysroot stub [DIR] [--config FILE]\n");
}

// ---- list ----
// A walk of the TARGET registry (src/hooks.mc) crossed with the pinned source
// table, and nothing else: no `open`, no probe, no absolute path. That is what
// makes the output the same on all three hosts and a golden test possible
// (tests/golden/sysroot-list.txt). Where a sysroot actually IS on this machine
// is what `mc sysroot path` answers.
void sysroot_list() {
    out_str(1, "target           source\n");
    i64 i = 0;
    while (i < ntargets) {
        uptr t = sysroot_target(tgt_os_at(i), tgt_arch_at(i));
        out_str(1, t);
        i64 pad = 17 - cstrlen(t);
        while (pad > 0) { out_str(1, " "); pad = pad - 1; }
        out_str(1, sysroot_kind(t));
        out_str(1, "\n");
        i = i + 1;
    }
}

// index in the target registry of the target called "<os>-<arch>", or -1
i64 sysroot_target_index(uptr name) {
    i64 i = 0;
    while (i < ntargets) {
        if (str_eq(sysroot_target(tgt_os_at(i), tgt_arch_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

void sysroot_unknown(uptr name) {
    out_str(2, "mc: unknown target: ");
    out_str(2, name);
    out_str(2, "\nregistered: ");
    i64 i = 0;
    while (i < ntargets) {
        if (i > 0) out_str(2, " ");
        out_str(2, sysroot_target(tgt_os_at(i), tgt_arch_at(i)));
        i = i + 1;
    }
    out_str(2, "\n");
    _exit(1);
}

// ---- path ----
// The chain, and its answer on stdout. Exit 2 with the shared message when
// nothing answered -- the same text `mc build` prints.
i64 sysroot_path_cmd(uptr name) {
    i64 ti = sysroot_target_index(name);
    if (ti < 0) sysroot_unknown(name);
    uptr os = tgt_os_at(ti);
    uptr arch = tgt_arch_at(ti);
    uptr d = sysroot_find(os, arch);
    if (d == 0) sysroot_missing(os, arch);
    out_str(1, d);
    out_str(1, "\n");
    return 0;
}

// ---- fetch ----
// 32 raw bytes of digest as 64 lowercase hex characters
uptr sysroot_hex(uptr d) {
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 i = 0;
    while (i < 32) {
        i64 v = ld8(d + i);
        buf_u8(b, ld8("0123456789abcdef" + ((v >> 4) & 15)));
        buf_u8(b, ld8("0123456789abcdef" + (v & 15)));
        i = i + 1;
    }
    buf_u8(b, 0);
    return buf_p(b);
}

// curl first, then the host's alternative. -1 says neither program is on PATH,
// which is a case with its own message and not a failed spawn.
i64 sysroot_download(uptr file, uptr url) {
    uptr d = host_downloader();
    u8 av[6 * 8];
    st64(av + 0, d);
    st64(av + 8, "-fLsS");
    st64(av + 16, "-o");
    st64(av + 24, file);
    st64(av + 32, url);
    st64(av + 40, 0);
    i64 rc = drv_spawn_ok(d, av, 0);
    if (rc >= 0) return rc;
    uptr a = host_downloader_alt();
    if (a == 0) return -1;
    st64(av + 0, a);
    st64(av + 8, "-q");
    st64(av + 16, "-O");
    return drv_spawn_ok(a, av, 0);
}

// `tar <flag> ARCHIVE -C DEST --strip-components=N MEMBER...`, the members read
// off the row as a space-separated list. One spawn, no shell.
i64 sysroot_extract(i64 r, uptr archive, uptr dest) {
    u8 av[DRV_MAXARG * 8];
    i64 n = 0;
    st64(av + n * 8, "tar");                        n = n + 1;
    st64(av + n * 8, sysroot_tar_flag(ss_url_at(r))); n = n + 1;
    st64(av + n * 8, archive);                      n = n + 1;
    st64(av + n * 8, "-C");                         n = n + 1;
    st64(av + n * 8, dest);                         n = n + 1;
    st64(av + n * 8, tm_cat("--strip-components=", tm_num_str(ss_strip_at(r)))); n = n + 1;
    uptr m = ss_member_at(r);
    u8 b[BUF_SIZE];
    buf_init(b);
    i64 i = 0;
    loop {
        i64 c = ld8(m + i);
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
    st64(av + n * 8, 0);
    return drv_spawn_ok("tar", av, 0);
}

// manifest.toml beside the files: where they came from and what they hashed to,
// with NO date in it (docs/determinism.md). It is what lets a later run say
// where a directory came from, and a human re-verify it by hand.
void sysroot_manifest(i64 r, uptr name, uptr dest) {
    u8 b[BUF_SIZE];
    buf_init(b);
    drv_put(b, "# written by `mc sysroot fetch` -- do not edit\n[source]\ntarget = \"");
    drv_put(b, name);
    drv_put(b, "\"\nkind   = \"");
    drv_put(b, ss_kind_at(r));
    drv_put(b, "\"\nurl    = \"");
    drv_put(b, ss_url_at(r));
    drv_put(b, "\"\nsha256 = \"");
    drv_put(b, ss_sha_at(r));
    drv_put(b, "\"\nsize   = ");
    drv_put(b, tm_num_str(ss_size_at(r)));
    drv_put(b, "\nstrip  = ");
    drv_put(b, tm_num_str(ss_strip_at(r)));
    drv_put(b, "\nfiles  = \"");
    drv_put(b, ss_member_at(r));
    drv_put(b, "\"\n");
    write_file(tm_cat(dest, "/manifest.toml"), b);
}

// the plan, printed before anything is downloaded and again by --yes: the URL,
// its size, its expected digest and where the files will land
void sysroot_plan(i64 r, uptr name, uptr dest) {
    out_str(1, "fetch  ");
    out_str(1, name);
    out_str(1, "\nurl    ");
    out_str(1, ss_url_at(r));
    out_str(1, "\nsize   ");
    out_str(1, tm_num_str(ss_size_at(r)));
    out_str(1, " bytes\nsha256 ");
    out_str(1, ss_sha_at(r));
    out_str(1, "\ninto   ");
    out_str(1, dest);
    out_str(1, "\n");
}

// the shared failure exit: the manual block, then 2
void sysroot_fetch_failed(uptr os, uptr arch) {
    sysroot_manual(os, arch);
    _exit(2);
}

i64 sysroot_fetch(uptr name, i64 yes) {
    i64 ti = sysroot_target_index(name);
    if (ti < 0) sysroot_unknown(name);
    uptr os = tgt_os_at(ti);
    uptr arch = tgt_arch_at(ti);
    i64 r = sysroot_src_find(name);
    if (r < 0 || ss_url_at(r) == 0) {
        out_str(1, "nothing to download for ");
        out_str(1, name);
        out_str(1, ": ");
        out_str(1, sysroot_kind(name));
        out_str(1, "\n");
        return 0;
    }
    uptr dest = sysroot_cache_dir(os, arch);
    if (dest == 0) {
        out_str(2, "mc: nowhere to put ");
        out_str(2, name);
        out_str(2, ": no --sysroot-dir, no [sysroot].cache and no HOME\n");
        _exit(2);
    }
    sysroot_plan(r, name, dest);
    if (!yes) {
        out_str(1, "nothing was downloaded: re-run with --yes\n");
        return 0;
    }
    drv_mkdirs(tm_cat(dest, "/x"));
    uptr file = tm_cat(tm_cat(dest, "/"), sysroot_basename(ss_url_at(r)));
    i64 rc = sysroot_download(file, ss_url_at(r));
    if (rc < 0) {
        out_str(2, "mc: no downloader on this PATH (tried ");
        out_str(2, host_downloader());
        if (host_downloader_alt() != 0) {
            out_str(2, ", ");
            out_str(2, host_downloader_alt());
        }
        out_str(2, ")\n");
        sysroot_fetch_failed(os, arch);
    }
    if (rc != 0) {
        unlink(file);
        out_str(2, "mc: the download failed (exit ");
        out_str(2, tm_num_str(rc));
        out_str(2, ")\n");
        sysroot_fetch_failed(os, arch);
    }
    // the checksum is computed here, by src/sha256.mc: one implementation on
    // three hosts, and part of the compiler rather than part of a script
    i64 len = 0;
    uptr p = read_file(file, &len);
    u8 dg[32];
    sha256(p, len, dg);
    uptr got = sysroot_hex(dg);
    if (!str_eq(got, ss_sha_at(r))) {
        unlink(file);
        out_str(2, "mc: checksum mismatch for ");
        out_str(2, sysroot_basename(ss_url_at(r)));
        out_str(2, "\n  expected ");
        out_str(2, ss_sha_at(r));
        out_str(2, "\n  got      ");
        out_str(2, got);
        out_str(2, "\n");
        sysroot_fetch_failed(os, arch);
    }
    if (len != ss_size_at(r)) {
        unlink(file);
        out_str(2, "mc: wrong size for ");
        out_str(2, sysroot_basename(ss_url_at(r)));
        out_str(2, "\n");
        sysroot_fetch_failed(os, arch);
    }
    if (sysroot_extract(r, file, dest) != 0) {
        unlink(file);
        out_str(2, "mc: tar could not extract ");
        out_str(2, sysroot_basename(ss_url_at(r)));
        out_str(2, "\n");
        sysroot_fetch_failed(os, arch);
    }
    unlink(file);
    sysroot_manifest(r, name, dest);
    uptr miss = sysroot_missing_marker(dest, os);
    if (miss != 0) {
        out_str(2, "mc: the archive did not carry ");
        out_str(2, miss);
        out_str(2, "\n");
        sysroot_fetch_failed(os, arch);
    }
    out_str(1, "sysroot ");
    out_str(1, name);
    out_str(1, " -> ");
    out_str(1, dest);
    out_str(1, "\n");
    return 0;
}

// ---- the dispatch ----
// `stub` is here rather than in src/stubs.mc because it is a subcommand and
// this is where subcommands live; the writing itself is stubs_write().
i64 sysroot_cmd(i64 argc, uptr argv) {
    if (argc < 3) { sysroot_usage(); return 1; }
    uptr sub = ld64(argv + 2 * 8);
    uptr name = 0;
    uptr cfg = 0;
    i64 yes = 0;
    i64 i = 3;
    while (i < argc) {
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--yes")) yes = 1;
        else if (str_eq(a, "--config")) {
            if (i + 1 >= argc) die("--config requires an argument");
            i = i + 1;
            cfg = ld64(argv + i * 8);
        }
        else if (str_eq(a, "--sysroot-dir")) {
            if (i + 1 >= argc) die("--sysroot-dir requires an argument");
            i = i + 1;
            sr_dir_opt = ld64(argv + i * 8);
        }
        else if (ld8(a) == '-') { sysroot_usage(); return 1; }
        else if (name != 0) die2("duplicate target", a);
        else name = a;
        i = i + 1;
    }
    if (str_eq(sub, "list")) {
        if (name != 0) { sysroot_usage(); return 1; }
        sysroot_list();
        return 0;
    }
    if (str_eq(sub, "path")) {
        if (name == 0) { sysroot_usage(); return 1; }
        return sysroot_path_cmd(name);
    }
    if (str_eq(sub, "fetch")) {
        if (name == 0) { sysroot_usage(); return 1; }
        return sysroot_fetch(name, yes);
    }
    // M25: the stub writers (src/stubs.mc). This is the front half of a build
    // -- read mc.toml, parse [project].entry, write one import file per library
    // the program declares `extern`s for -- and nothing else. `--entry-only` is
    // passed because it is the entry's externs that are wanted, never the
    // taught compiler's.
    if (str_eq(sub, "stub")) {
        drv_stub_mode = 1;
        uptr dir = name;
        if (dir == 0) dir = ".";
        if (cfg == 0) cfg = tm_cat(dir, "/mc.toml");
        return drv_run(dir, cfg, 1, 0);
    }
    sysroot_usage();
    return 1;
}
