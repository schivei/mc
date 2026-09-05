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
#       <64 hex of sha256(file bytes)><two spaces><path><LF>
#
#   and the tree hash is the sha256 of those lines, in plain hex. Content only:
#   no mtime, no mode, no directory listing, and the bytes exactly as they are on
#   disk (which is why tests/pkg carries `-text` in .gitattributes).
#
# With --files it prints the per-file lines instead of the tree hash, which is
# what the fixture cache manifests are made of.
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
dir="${1:?usage: pkg-hash.sh [--files] DIR}"

lines() {
    printf '%s  %s\n' "$(sha "$dir/mc.toml")" "mc.toml"
    files_of "$dir" | while IFS= read -r f; do
        [ -f "$dir/$f" ] || { echo "pkg-hash: missing $dir/$f" >&2; exit 1; }
        printf '%s  %s\n' "$(sha "$dir/$f")" "$f"
    done
}

if [ "$mode" = files ]; then lines; else lines | sha_stdin; fi
