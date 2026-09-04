// sysroots.mc -- the pinned list of downloadable sysroots (M25,
// docs/specs/M25.md § 3 and § 4, docs/reference/sysroot.md § 7).
//
// This is data, not code: one row per (target, host) pair saying where the
// files come from, what they hash to, and which members of the archive to
// unpack. `mc sysroot list` walks it with no I/O at all; `mc sysroot fetch`
// spawns a downloader and a `tar` for the row it selects (src/sysroot.mc).
//
// Why a `.mc` table and not a TOML file: `toml_parse` fills ONE global table
// (src/toml.mc) and there is no `toml_parse_str`, so a second parse during
// `mc build` would destroy the project's own config. A table registered the way
// `target()` and `backend()` are registered costs no parser, is deterministic
// to print, and travels inside the binary like everything else.
//
// Every row is pinned by version AND by sha256. Nothing here is resolved
// through an index file (Alpine's `APKINDEX.tar.gz`, GitHub's `/latest`): those
// move under us, and a build that downloads a different file next week is not
// reproducible. When a pin rots, the row changes in a commit, with the new hash
// in the same diff -- and `docs/reference/sysroot.md` carries the same table, a
// second copy that `scripts/check-sysroots.sh` diffs against this one.
//
// The columns:
//
//   target     "<os>-<arch>", the same name `mc sysroot` takes
//   host       which HOST this row is for: "" matches any, "macos" matches
//              every architecture of that system, "linux:x86_64" one pair. One
//              column and not two because a core function takes at most 8
//              parameters (MAXPARAMS, the ABI). The Windows rows differ per
//              host because llvm-mingw ships one archive per host platform --
//              the import libraries inside are the same files
//   kind       what `mc sysroot list` prints. Byte-stable on every host, which
//              is what makes tests/golden/sysroot-list.txt a golden
//   url        pinned, https only
//   sha        sha256 of the archive, verified by src/sha256.mc after download
//   size       its length in bytes, printed in the plan
//   strip      --strip-components for the extraction
//   member     the archive members to extract, separated by single spaces
//
// A row with `url == 0` is a target that downloads NOTHING: macOS, where the
// direct executable backend needs no SDK at all and the `.o` + `ld` road is
// served by the synthesized stubs of src/stubs.mc.
//
// Depends only on arena.mc (str_eq) and on the host layer (host_os/host_arch).

#include "../lib/prelude.mc"

#define SS_MAX 32                     // fixed on purpose: this table does not
                                      // scale with the program being compiled,
                                      // so M23's growable rule does not apply

uptr ss_target[SS_MAX];
uptr ss_host[SS_MAX];
uptr ss_kind[SS_MAX];
uptr ss_url[SS_MAX];
uptr ss_sha[SS_MAX];
uptr ss_size[SS_MAX];
uptr ss_strip[SS_MAX];
uptr ss_member[SS_MAX];
i64  nsysroot_src = 0;

uptr ss_target_at(i64 i) { return ld64(ss_target + i * 8); }
uptr ss_host_at(i64 i)   { return ld64(ss_host + i * 8); }
uptr ss_kind_at(i64 i)   { return ld64(ss_kind + i * 8); }
uptr ss_url_at(i64 i)    { return ld64(ss_url + i * 8); }
uptr ss_sha_at(i64 i)    { return ld64(ss_sha + i * 8); }
i64  ss_size_at(i64 i)   { return ld64(ss_size + i * 8); }
i64  ss_strip_at(i64 i)  { return ld64(ss_strip + i * 8); }
uptr ss_member_at(i64 i) { return ld64(ss_member + i * 8); }

void sysroot_src(uptr target, uptr host, uptr kind,
                 uptr url, uptr sha, i64 size, i64 strip, uptr member) {
    if (nsysroot_src >= SS_MAX) die2("too many sysroot sources", target);
    st64(ss_target + nsysroot_src * 8, target);
    st64(ss_host + nsysroot_src * 8, host);
    st64(ss_kind + nsysroot_src * 8, kind);
    st64(ss_url + nsysroot_src * 8, url);
    st64(ss_sha + nsysroot_src * 8, sha);
    st64(ss_size + nsysroot_src * 8, size);
    st64(ss_strip + nsysroot_src * 8, strip);
    st64(ss_member + nsysroot_src * 8, member);
    nsysroot_src = nsysroot_src + 1;
}

// does the host column `h` describe the machine this binary runs on?
//   ""              every host
//   "macos"         that operating system, any architecture
//   "linux:x86_64"  that pair
i64 ss_host_match(uptr h) {
    if (ld8(h) == 0) return 1;
    i64 i = 0;
    loop {
        i64 c = ld8(h + i);
        if (c == 0 || c == ':') break;
        i = i + 1;
    }
    if (!mem_eq(h, host_os(), i) || cstrlen(host_os()) != i) return 0;
    if (ld8(h + i) == 0) return 1;
    return str_eq(h + i + 1, host_arch());
}

// the row for `target` on THIS host, or -1. First match wins, and a row with an
// empty host column matches every host.
i64 sysroot_src_find(uptr target) {
    i64 i = 0;
    while (i < nsysroot_src) {
        if (str_eq(ss_target_at(i), target) && ss_host_match(ss_host_at(i))) return i;
        i = i + 1;
    }
    return -1;
}

// the kind column of the FIRST row for `target`, whatever the host -- what
// `mc sysroot list` prints, and the reason `list` is the same text everywhere
uptr sysroot_kind(uptr target) {
    i64 i = 0;
    while (i < nsysroot_src) {
        if (str_eq(ss_target_at(i), target)) return ss_kind_at(i);
        i = i + 1;
    }
    return "-";
}

// ---- the pinned rows ----
// Called by main() beside machine_arm64_init() and the target() registrations.
//
// Alpine v3.22 `musl-dev` carries all four files a static link needs
// (crt1.o crti.o crtn.o libc.a); the `musl` package holds only the dynamic
// loader, which a static link never uses. An `.apk` is a gzip tar, so `tar -xzf`
// reads it on all three hosts.
//
// llvm-mingw's release carries every target triple in one archive, so the same
// download serves windows-aarch64 and windows-x86_64 -- only the member path
// differs. The host picks the archive FORMAT: `.tar.xz` on macOS and Linux
// (both have an xz-capable tar), `.zip` on Windows, whose bundled `tar.exe` is
// libarchive and reads zip but is not to be trusted with xz.
void sysroots_init() {
    sysroot_src("macos-aarch64", "", "stubs (synthesized)", 0, 0, 0, 0, 0);

    sysroot_src("linux-aarch64", "", "musl-dev (alpine v3.22)",
                "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/musl-dev-1.2.5-r12.apk",
                "576f4aabcfa01d10d6baa2d5d87de436b76e58ae76eedf9db7627051365e1fe3",
                2556920, 2,
                "usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o usr/lib/libc.a");
    sysroot_src("linux-x86_64", "", "musl-dev (alpine v3.22)",
                "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/musl-dev-1.2.5-r12.apk",
                "1c2068d910cfdbbcb4eb107a5a478f8b48edf3a6311953c8fa5180c5190efab3",
                3427570, 2,
                "usr/lib/crt1.o usr/lib/crti.o usr/lib/crtn.o usr/lib/libc.a");

    sysroot_src("windows-aarch64", "macos", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-macos-universal.tar.xz",
                "48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f",
                124220620, 3,
                "llvm-mingw-20260826-ucrt-macos-universal/aarch64-w64-mingw32/lib");
    sysroot_src("windows-aarch64", "linux:aarch64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-aarch64.tar.xz",
                "4eb475cccf5e5e37ea3b693a52227e70a86ae70abafceb9ecd83887e67699c9d",
                77875280, 3,
                "llvm-mingw-20260826-ucrt-ubuntu-22.04-aarch64/aarch64-w64-mingw32/lib");
    sysroot_src("windows-aarch64", "linux:x86_64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64.tar.xz",
                "cee8d2ce3da5145ce4dc882e70d0b0719a783d53a99752c60948fc0659975a65",
                83880560, 3,
                "llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64/aarch64-w64-mingw32/lib");
    sysroot_src("windows-aarch64", "windows:aarch64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-aarch64.zip",
                "dbce5a314c44cf44d02ab0d0e6bce948955b46429274df25544f9cfea4986f7b",
                185650782, 3,
                "llvm-mingw-20260826-ucrt-aarch64/aarch64-w64-mingw32/lib");
    sysroot_src("windows-aarch64", "windows:x86_64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-x86_64.zip",
                "ae601f4e0f72bbdf441ad2df8bb16f037e2e9251559ea6b37b4057aef39c06c3",
                190721391, 3,
                "llvm-mingw-20260826-ucrt-x86_64/aarch64-w64-mingw32/lib");

    sysroot_src("windows-x86_64", "macos", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-macos-universal.tar.xz",
                "48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f",
                124220620, 3,
                "llvm-mingw-20260826-ucrt-macos-universal/x86_64-w64-mingw32/lib");
    sysroot_src("windows-x86_64", "linux:aarch64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-aarch64.tar.xz",
                "4eb475cccf5e5e37ea3b693a52227e70a86ae70abafceb9ecd83887e67699c9d",
                77875280, 3,
                "llvm-mingw-20260826-ucrt-ubuntu-22.04-aarch64/x86_64-w64-mingw32/lib");
    sysroot_src("windows-x86_64", "linux:x86_64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64.tar.xz",
                "cee8d2ce3da5145ce4dc882e70d0b0719a783d53a99752c60948fc0659975a65",
                83880560, 3,
                "llvm-mingw-20260826-ucrt-ubuntu-22.04-x86_64/x86_64-w64-mingw32/lib");
    sysroot_src("windows-x86_64", "windows:aarch64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-aarch64.zip",
                "dbce5a314c44cf44d02ab0d0e6bce948955b46429274df25544f9cfea4986f7b",
                185650782, 3,
                "llvm-mingw-20260826-ucrt-aarch64/x86_64-w64-mingw32/lib");
    sysroot_src("windows-x86_64", "windows:x86_64", "import libraries (llvm-mingw 20260826)",
                "https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/llvm-mingw-20260826-ucrt-x86_64.zip",
                "ae601f4e0f72bbdf441ad2df8bb16f037e2e9251559ea6b37b4057aef39c06c3",
                190721391, 3,
                "llvm-mingw-20260826-ucrt-x86_64/x86_64-w64-mingw32/lib");
}
