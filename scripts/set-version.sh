#!/bin/sh
# set-version.sh VERSION — bake VERSION into the binary about to be built.
#
# M44 (docs/specs/M44.md § C, decision D20). `src/version.mc` carries one string
# literal and the working tree always carries the SENTINEL `0.0.0-dev`. A
# release runner calls this after `make mc1` and before every binary it builds:
#
#   scripts/set-version.sh "${TAG#v}"      # .github/workflows/release.yml
#
# It rewrites that one literal and regenerates the bundle, because
# `src/version.mc` is bundled as `mc/version` and a taught compiler built by a
# release binary out of its own blob must report the same version as the binary
# that built it.
#
# It NEVER commits. `scripts/check-bundle.sh` fails `make check` on a tree whose
# sentinel has been rewritten, so a release build cannot reach `main` by
# accident (docs/ci.md § Versioning). To undo it in a working tree:
#
#   scripts/set-version.sh 0.0.0-dev
#
# VERSION is `X.Y.Z` with an optional `-suffix`. The `X.Y.Z` is validated by
# scripts/next-version.sh, which is the one definition of what a version is; the
# suffix is `[0-9A-Za-z.-]+` and exists for the sentinel and for a hand-pushed
# pre-release tag (docs/ci.md § Versioning: the automation never makes one). A
# leading `v` belongs to a tag name, not to a version, and is stripped.
set -eu

usage() {
    echo "usage: set-version.sh VERSION      (X.Y.Z, optionally -suffix; no leading v)" >&2
    exit 2
}

[ $# -eq 1 ] || usage
version="${1#v}"
core="${version%%-*}"
suffix=""
case "$version" in
    *-*) suffix="${version#*-}" ;;
esac

# the X.Y.Z half goes through the one definition of a version
if ! scripts/next-version.sh "$core" patch > /dev/null 2>&1; then
    echo "set-version: '$1' is not X.Y.Z[-suffix]" >&2
    exit 2
fi
case "$suffix" in
    '') : ;;
    *[!0-9A-Za-z.-]*) echo "set-version: bad suffix '-$suffix' in '$1'" >&2; exit 2 ;;
esac

file=src/version.mc
n=$(grep -c '^uptr mc_version() { return "' "$file" || :)
[ "$n" = "1" ] || { echo "set-version: $file must hold exactly one mc_version() line (found $n)" >&2; exit 1; }

tmp="$file.tmp.$$"
trap 'rm -f "$tmp"' EXIT INT TERM
awk -v v="$version" '
    /^uptr mc_version\(\) \{ return "/ { printf "uptr mc_version() { return \"%s\"; }\n", v; next }
    { print }
' "$file" > "$tmp"
mv "$tmp" "$file"

echo "set-version: $file now reports $version"
grep '^uptr mc_version' "$file"

# mc/version inside the blob has to agree with mc_version() -- see the header.
make bundle
