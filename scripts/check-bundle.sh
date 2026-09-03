#!/bin/sh
# check-bundle.sh [MC1] — M15: src/bundle_data.mc is generated source, and this
# is what keeps it honest.
#
#   1. compile tools/bundle.mc with MC1 (--exe, no ld)
#   2. regenerate the bundle into a temporary file, twice
#   3. the two runs have to be identical  -> the generator is reproducible
#   4. and identical to the checked-in src/bundle_data.mc -> it is up to date
#   5. tools/lz_test.mc: src/lz.mc round-trips random data and every bundled file
#
# It runs BEFORE `make bootstrap` in `make check` on purpose: the bundle carries
# the compressed sources of lib/ and of the core, so a change to src/*.mc or
# lib/*.mc that was not followed by `make bundle` would make the fixed point
# prove something about a compiler whose `<mc/core>` is stale. Failing here
# says exactly what to do; failing in bootstrap would not.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

mkdir -p build
tmp="${TMPDIR:-/tmp}/check-bundle.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

if ! msg=$("$mc" --exe tools/bundle.mc -o build/bundle 2>&1); then
    echo "FAIL: compiling tools/bundle.mc: $msg"
    exit 1
fi

if ! msg=$(build/bundle tools/bundle.list "$tmp/a.mc" 2>&1); then
    echo "FAIL: generating the bundle (run 1): $msg"
    exit 1
fi
if ! msg=$(build/bundle tools/bundle.list "$tmp/b.mc" 2>&1); then
    echo "FAIL: generating the bundle (run 2): $msg"
    exit 1
fi

if ! cmp "$tmp/a.mc" "$tmp/b.mc"; then
    echo "FAIL: tools/bundle.mc is not reproducible (two runs differ)"
    exit 1
fi
echo "ok tools/bundle.mc is reproducible (two runs identical)"

if ! cmp "$tmp/a.mc" src/bundle_data.mc; then
    echo "FAIL: src/bundle_data.mc is STALE." >&2
    echo "  It is generated source: lib/*.mc or the core changed and the bundle" >&2
    echo "  was not regenerated. Run 'make bundle', review the diff, and commit" >&2
    echo "  src/bundle_data.mc with the change (see docs/bootstrap.md § M15)." >&2
    exit 1
fi

echo "ok src/bundle_data.mc matches tools/bundle.list ($(wc -c < src/bundle_data.mc | tr -d ' ') bytes)"

# src/lz.mc on its own: synthetic buffers from a deterministic LCG (pure random
# bytes, runs, a 4-letter alphabet, a repeating pattern; sizes 0 to 256 KiB) and
# every file of the manifest, read from disk. Deflate, inflate, compare.
if ! msg=$("$mc" --exe tools/lz_test.mc -o build/lz_test 2>&1); then
    echo "FAIL: compiling tools/lz_test.mc: $msg"
    exit 1
fi
if ! out=$(build/lz_test tools/bundle.list 2>&1); then
    echo "FAIL: lz round trip"
    printf '%s\n' "$out" | tail -5
    exit 1
fi
printf '%s\n' "$out" | tail -1
