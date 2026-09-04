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
// Depends on arena.mc (open/close, out_str, tm_cat via toml.mc), on toml.mc
// (toml_get for [sysroot]), on hooks.mc (the target registry, for `list`) and
// on driver.mc (drv_path, drv_sdk). Everything that differs between hosts comes
// from the host layer: host_os/host_arch/host_home/host_has_sdk.

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
uptr sysroot_marker(uptr os, i64 i) {
    if (str_eq(os, "linux")) {
        if (i == 0) return "crt1.o";
        if (i == 1) return "libc.a";
        return 0;
    }
    if (str_eq(os, "windows")) {
        if (i == 0) return "kernel32.lib";
        return 0;
    }
    if (str_eq(os, "macos")) {
        if (i == 0) return "usr/lib/libSystem.tbd";
        return 0;
    }
    return 0;
}

// the first marker of `os` that `dir` does not have, or 0 when it has them all
uptr sysroot_missing_marker(uptr dir, uptr os) {
    i64 i = 0;
    loop {
        uptr m = sysroot_marker(os, i);
        if (m == 0) return 0;
        if (!path_exists(tm_cat(tm_cat(dir, "/"), m))) return m;
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
void sysroot_manual(uptr os, uptr arch) {
    if (str_eq(os, "linux")) {
        out_str(2, "  run:   sh scripts/sysroot-linux.sh --arch ");
        out_str(2, arch);
        out_str(2, "\n");
        return;
    }
    if (str_eq(os, "windows")) {
        out_str(2, "  run:   sh scripts/sysroot-windows.sh --arch ");
        out_str(2, arch);
        out_str(2, "\n");
        return;
    }
    out_str(2, "  run:   install the Command Line Tools (xcode-select --install),\n");
    out_str(2, "         or drop an SDK at [sysroot].path -- and note that `mc --exe`\n");
    out_str(2, "         needs no SDK at all (docs/reference/sysroot.md)\n");
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
