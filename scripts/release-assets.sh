#!/bin/sh
# release-assets.sh VERSION TARGET BINARY [OUTDIR]
#
# Packages one release artifact:
#
#   OUTDIR/mc-VERSION-TARGET.tar.gz          the tarball
#   OUTDIR/mc-VERSION-TARGET.tar.gz.sha256   its checksum, `shasum -c`-ready
#
# The tarball holds a single directory, mc-VERSION-TARGET/, containing:
#
#   mc            the binary, mode 755 (mc.exe on a windows-* target: a file
#                 that is not called *.exe cannot be launched there)
#   INSTALL.txt   generated here: where to put it, how to clear the macOS
#                 quarantine flag, how to check the checksum
#   README.md     the repository's README, if there is one (everything before a
#                 `<!-- release-excerpt-end -->` line, or the first 120 lines)
#   LICENSE       the repository's LICENSE, if there is one
#
# OUTDIR defaults to dist/. Run it from the repository root: README.md and
# LICENSE are looked up relative to the working directory.
#
# VERSION comes from the release tag -- there is no VERSION file in the
# repository (docs/ci.md § Versioning). A leading `v` is stripped, so both
# `v0.1.0` and `0.1.0` produce mc-0.1.0-TARGET.tar.gz.
#
# Determinism. Two runs from the same tree must produce the same bytes, so:
#   * the member list is explicit and sorted here, never a directory walk;
#   * every staged file gets mtime 0 (`TZ=UTC touch -t 197001010000`), which is
#     what makes bsdtar -- macOS's tar, which has no --mtime -- reproducible;
#   * owner, group and their names are forced to 0/0/empty;
#   * the format is pinned to `ustar`, so GNU tar and bsdtar agree byte for byte;
#   * gzip runs with -n, so the gzip header carries no name and no timestamp.
#
# GNU tar (`gtar`, or a `tar` that says GNU) takes the documented flags
# `--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner`; bsdtar takes
# `--uid 0 --gid 0 --uname '' --gname '' --numeric-owner` and relies on the
# touch above for the timestamps. Both are pinned to `--format ustar`.
set -e

# the tag name and the bare version are both accepted; `v` never reaches a
# file name
version="${1#v}"
target="$2"
binary="$3"
outdir="${4:-dist}"

if [ -z "$version" ] || [ -z "$target" ] || [ -z "$binary" ]; then
    echo "usage: release-assets.sh VERSION TARGET BINARY [OUTDIR]" >&2
    exit 1
fi
if [ ! -f "$binary" ]; then
    echo "release-assets: binary '$binary' not found" >&2
    exit 1
fi

name="mc-$version-$target"
stage="$outdir/.stage/$name"

rm -rf "$outdir/.stage"
mkdir -p "$stage"

# M38: the name inside the archive is the name the program has to have on the
# target, which on Windows means the suffix. Everything else -- the layout, the
# checksum, the reproducibility rules -- is the same for all five targets.
binname="mc"
case "$target" in
    windows-*) binname="mc.exe" ;;
esac

cp "$binary" "$stage/$binname"
chmod 755 "$stage/$binname"

# INSTALL.txt is generated, never dated: a date would make the tarball differ
# between two builds of the same tag.
{
    echo "mc $version — $target"
    echo
    echo "mc is a self-hosting mini compiler that is teachable through its own surface."
    echo "This archive holds one file that matters: the compiler itself."
    echo
    echo "Install"
    echo "-------"
    case "$target" in
    windows-*)
        # printf '%s\n', not echo: a `\t` in a Windows path is a tab to echo
        printf '%s\n' '  copy mc.exe C:\tools\mc.exe            # or anywhere on your PATH'
        ;;
    *)
        echo "  install -m 755 mc /usr/local/bin/mc      # or anywhere on your PATH"
        ;;
    esac
    echo
    case "$target" in
    macos-*)
        echo "macOS quarantine"
        echo "----------------"
        echo "The binary is signed ad-hoc, not notarized, so a download carries"
        echo "com.apple.quarantine and Gatekeeper refuses to run it. Clear the flag once:"
        echo
        echo "  xattr -d com.apple.quarantine mc"
        echo
        echo "Then check the signature is intact:"
        echo
        echo "  codesign --verify --verbose=4 mc"
        echo
        ;;
    windows-*)
        echo "Windows"
        echo "-------"
        echo "The binary needs nothing but kernel32.dll: no C runtime, no Visual Studio"
        echo "redistributable, no Windows SDK. There is no direct-executable backend on"
        echo "Windows, so a program is an object plus a linker:"
        echo
        echo "  mc hello.mc -o hello.obj"
        echo "  lld-link -subsystem:console -entry:mc_start -nodefaultlib \\"
        echo "           -out:hello.exe hello.obj winstart.obj kernel32.lib"
        echo
        echo "or, the usual way, 'mc build .' with a [linker] section in mc.toml. The"
        echo "import library is generated from a list of names by llvm-dlltool; there is"
        echo "nothing to download."
        echo
        ;;
    linux-*)
        echo "Linux"
        echo "-----"
        echo "The binary is statically linked against musl: it has no shared-library"
        echo "dependencies and runs on any distribution of this architecture. There is no"
        echo "direct-executable backend on Linux, so a program is an object plus a linker:"
        echo
        echo "  mc hello.mc -o hello.o && ld.lld -o hello /usr/lib/crt1.o hello.o -lc"
        echo
        echo "or, the usual way, 'mc build .' with a [linker] section in mc.toml."
        echo
        ;;
    esac
    echo "Verify the download"
    echo "-------------------"
    echo "  shasum -a 256 -c $name.tar.gz.sha256     # macOS"
    echo "  sha256sum -c $name.tar.gz.sha256         # Linux"
    echo
    echo "Use it"
    echo "------"
    echo "  mc hello.mc -o hello.o                                   # an object for this host"
    echo "  mc --exe hello.mc -o hello                               # signed Mach-O, no ld (macOS)"
    echo "  mc build .                                               # a project, from mc.toml"
    echo "  mc --host                                                # what this binary is"
    echo
    echo "The standard library travels inside the binary: #include <sys>, <prelude>, <io>"
    echo "and <mc/core> need no checkout. Documentation: docs/ in the repository."
} > "$stage/INSTALL.txt"

# the README excerpt: everything before the marker, or the first 120 lines
if [ -f README.md ]; then
    if grep -q '^<!-- release-excerpt-end -->' README.md; then
        sed '/^<!-- release-excerpt-end -->/,$d' README.md > "$stage/README.md"
    else
        head -120 README.md > "$stage/README.md"
    fi
fi
if [ -f LICENSE ]; then
    cp LICENSE "$stage/LICENSE"
elif [ -f LICENSE.md ]; then
    cp LICENSE.md "$stage/LICENSE"
fi

# fixed mtime on every staged file, including the directory itself
TZ=UTC find "$outdir/.stage" -exec touch -t 197001010000 {} +

# an explicit, sorted member list -- no directory walk, so no filesystem order
members=$(cd "$outdir/.stage" && find "$name" -type f | LC_ALL=C sort)

tarbin=tar
gnu=0
if command -v gtar >/dev/null 2>&1; then
    tarbin=gtar; gnu=1
elif tar --version 2>/dev/null | head -1 | grep -q GNU; then
    gnu=1
fi

tarball="$outdir/$name.tar.gz"
rm -f "$tarball" "$tarball.sha256"

# $members is deliberately word-split: it is the member list built above, one
# short path per line, never user input.
# shellcheck disable=SC2086  # $members is a member list, deliberately split
make_tar() {
    if [ "$gnu" = 1 ]; then
        $tarbin --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
                --format=ustar -cf - $members
    else
        tar --uid 0 --gid 0 --uname '' --gname '' --numeric-owner \
            --format ustar -cf - $members
    fi
}

(cd "$outdir/.stage" && make_tar) | gzip -n -9 > "$tarball"

rm -rf "$outdir/.stage"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$outdir" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
else
    (cd "$outdir" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
fi

echo "$tarball"
cat "$tarball.sha256"
