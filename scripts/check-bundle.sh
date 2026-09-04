#!/bin/sh
# check-bundle.sh [MC1] — M15: src/bundle_data.mc is generated source, and this
# is what keeps it honest.
#
#   1. compile tools/bundle.mc with MC1 (--exe, no ld)
#   2. regenerate the bundle into a temporary file, twice
#   3. the two runs have to be identical  -> the generator is reproducible
#   4. and identical to the checked-in src/bundle_data.mc -> it is up to date
#   5. `<mc/bundle_data>`, the copy the binary regenerates, is the `#embed` form
#      (M21.5): one N_BLOB node for the blob instead of one per element
#   6. tools/lz_test.mc: src/lz.mc round-trips random data and every bundled file
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

# M38: on Windows a program that is not called *.exe cannot be launched, so the
# two helper binaries below carry the suffix (docs/guide/95-windows-host.md).
hostexe=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) hostexe=".exe" ;; esac

if ! msg=$(scripts/build-exe.sh "$mc" "build/bundle$hostexe" tools/bundle.mc 2>&1); then
    echo "FAIL: compiling tools/bundle.mc: $msg"
    exit 1
fi

if ! msg=$("build/bundle$hostexe" tools/bundle.list "$tmp/a.mc" 2>&1); then
    echo "FAIL: generating the bundle (run 1): $msg"
    exit 1
fi
if ! msg=$("build/bundle$hostexe" tools/bundle.list "$tmp/b.mc" 2>&1); then
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

# M21.5: the copy the BINARY regenerates is not the file on disk. `mc/bundle_data`
# carries the blob as `#embed bundle_blob "bundle.bin"` -- one N_BLOB node --
# while the file keeps the `u64 ... = { ... }` form, because the frozen stage0
# has no `#embed` and `build/mc0 src/mc.mc` has to keep working. What the two
# forms share is the object they produce, and scripts/check-standalone.sh is
# what compares that. Here we only guard the shape: exactly one BLOB node, and
# an INT count that is the index array alone (four values per bundled file).
# A revert to the array form would put ~22 000 INT nodes here instead.
printf '#include <mc/bundle_data>\ni64 main() { return 0; }\n' > "$tmp/bd.mc"
if ! "$mc" --dump-ast "$tmp/bd.mc" > "$tmp/bd.ast" 2>&1; then
    echo "FAIL: <mc/bundle_data> does not compile"
    sed -n '1,5p' "$tmp/bd.ast"
    exit 1
fi
blobs=$(grep -c '^  BLOB ' "$tmp/bd.ast")
ints=$(grep -c '^  INT '  "$tmp/bd.ast")
want=$(( $(grep -c '^[a-z]' tools/bundle.list) * 4 ))
if [ "$blobs" != "1" ] || [ "$ints" != "$want" ]; then
    echo "FAIL: <mc/bundle_data> is not the #embed form ($blobs BLOB, $ints INT, expected 1 and $want)"
    exit 1
fi
echo "ok <mc/bundle_data> is one #embed node plus the $want-value index"

# src/lz.mc on its own: synthetic buffers from a deterministic LCG (pure random
# bytes, runs, a 4-letter alphabet, a repeating pattern; sizes 0 to 256 KiB) and
# every file of the manifest, read from disk. Deflate, inflate, compare.
if ! msg=$(scripts/build-exe.sh "$mc" "build/lz_test$hostexe" tools/lz_test.mc 2>&1); then
    echo "FAIL: compiling tools/lz_test.mc: $msg"
    exit 1
fi
if ! out=$("build/lz_test$hostexe" tools/bundle.list 2>&1); then
    echo "FAIL: lz round trip"
    printf '%s\n' "$out" | tail -5
    exit 1
fi
printf '%s\n' "$out" | tail -1
