#!/bin/sh
# pkg-hash.sh DIR — the tree hash of a package checkout (M44 D5), in shell.
#
# `mc pkg hash` is step 3 of the milestone; until it exists this script is the
# only implementation, and it is the one scripts/check-pkg.sh uses to build the
# fixture locks and manifests. It is deliberately a SECOND implementation of the
# rule src/deps.mc's dep_scan() implements: check-pkg.sh compares the two on
# every run, so a divergence between the compiler and the specification is a red
# `make check` and not a surprise at a consumer.
#
# The rule, from docs/reference/packages.md § The tree hash:
#
#   for `mc.toml` first and then each entry of [package].files in the order the
#   manifest writes them, one line
#
#       <64 hex of sha256(file bytes)><space><byte length><colon><path><LF>
#
#   and the tree hash is the sha256 of those lines, in plain hex. The path is
#   length-prefixed (post-M44 review, finding 3): the two-space form Go's
#   dirhash.Hash1 uses is not injective once a path may carry a newline, and
#   here the path list comes out of a downloaded mc.toml. Content only:
#   no mtime, no mode, no directory listing, and the bytes exactly as they are on
#   disk (which is why tests/pkg carries `-text` in .gitattributes).
#
# With --files it prints `<hex> <path>` pairs instead of the tree hash, which is
# what the fixture cache manifests are made of; with --lines it prints the
# canonical hash lines themselves, which is how check-pkg reads the format.
set -e

sha() {
    if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else sha256sum "$1" | cut -d' ' -f1
    fi
}

sha_stdin() {
    if command -v shasum > /dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
    else sha256sum | cut -d' ' -f1
    fi
}

files_of() {
    # [package].files, in manifest order. The fixture manifests write the array
    # on one line; a multi-line array would need a TOML reader, and the point of
    # this script is not to be one.
    sed -n 's/^files *= *\[\(.*\)\].*/\1/p' "$1/mc.toml" | head -1 \
        | tr ',' '\n' | sed 's/^ *"//; s/" *$//; s/^ *//; s/ *$//' | grep -v '^$' || true
}

mode=tree
if [ "$1" = "--files" ]; then mode=files; shift; fi
if [ "$1" = "--lines" ]; then mode=lines; shift; fi
dir="${1:?usage: pkg-hash.sh [--files] DIR}"

mctoml=mc.toml

# the canonical hash lines
lines() {
    printf '%s %s:%s\n' "$(sha "$dir/mc.toml")" "${#mctoml}" "$mctoml"
    files_of "$dir" | while IFS= read -r f; do
        [ -f "$dir/$f" ] || { echo "pkg-hash: missing $dir/$f" >&2; exit 1; }
        printf '%s %s:%s\n' "$(sha "$dir/$f")" "${#f}" "$f"
    done
}

# `<hex> <path>` pairs, which is what a [[file]] row of a cache manifest is made
# of -- deliberately NOT the hash lines: those carry a length prefix now and
# nothing but the hash reads them.
pairs() {
    printf '%s %s\n' "$(sha "$dir/mc.toml")" "mc.toml"
    files_of "$dir" | while IFS= read -r f; do
        printf '%s %s\n' "$(sha "$dir/$f")" "$f"
    done
}

if [ "$mode" = files ]; then pairs
elif [ "$mode" = lines ]; then lines
else lines | sha_stdin
fi
