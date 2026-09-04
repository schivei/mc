#!/bin/sh
# check-asm.sh [MC0] [MC1] — acceptance criterion for M6 slice 4.
# For each .mc source in the repo, compares `MC0 --dump-asm F` with `MC1 --dump-asm F`.
# Any difference (stdout, stderr, or exit code) is a failure — including the
# files the compilers reject: the error message and the code have to be the
# same. The src/ sources compiled on their own are exactly those cases (the
# functions they call live in another file), and the identical error is the test.
#
# While build/mc1 doesn't exist yet, run with MC1 = MC0: it has to come out
# 100% identical (proves the test itself is deterministic and the script is correct).
mc0="${1:-build/mc0}"
mc1="${2:-build/mc1}"

for mc in "$mc0" "$mc1"; do
    if [ ! -x "$mc" ]; then
        echo "FAIL: compiler '$mc' not found or not executable"
        exit 1
    fi
done


# M38: a source the FROZEN SEED cannot compile has nothing to compare. There is
# exactly one -- lib/sys_windows_host.mc declares CreateProcessA, which takes
# ten parameters, and stage0 keeps MAXPARAMS at 8 (docs/build.md § limits). It
# carries the reason in its own header, the way tests/*.mc carry `// skip-linux:`,
# and it is REPORTED here rather than silently dropped. This is the same reason
# tests/mc/ is a directory of its own (scripts/check-mc.sh).
seed_skip() { sed -n 's|^// seed-skip: *||p' "$1" | head -1; }

tmp="${TMPDIR:-/tmp}/check-asm.$$"
mkdir -p "$tmp"
fails=0
total=0
skipped=0

for f in tests/*.mc tests/lib/*.mc lib/*.mc src/*.mc; do
    [ -f "$f" ] || continue
    why=$(seed_skip "$f")
    if [ -n "$why" ]; then
        echo "skip $f ($why)"
        skipped=$((skipped + 1)); continue
    fi
    total=$((total + 1))

    "$mc0" --dump-asm "$f" > "$tmp/a" 2> "$tmp/ae"; ra=$?
    "$mc1" --dump-asm "$f" > "$tmp/b" 2> "$tmp/be"; rb=$?

    if [ "$ra" != "$rb" ]; then
        echo "FAIL $f (exit $rb with '$mc1', $ra with '$mc0')"
        sed -n '1,3p' "$tmp/ae" "$tmp/be"
        fails=$((fails + 1)); continue
    fi
    if ! diff -u "$tmp/a" "$tmp/b" > "$tmp/d" 2>&1; then
        echo "FAIL $f"
        sed -n '1,20p' "$tmp/d"
        fails=$((fails + 1)); continue
    fi
    if ! diff -u "$tmp/ae" "$tmp/be" > "$tmp/de" 2>&1; then
        echo "FAIL $f (stderr differs)"
        sed -n '1,20p' "$tmp/de"
        fails=$((fails + 1)); continue
    fi
    echo "ok $f"
done

rm -rf "$tmp"
echo "$((total - fails))/$total files identical"
[ "$skipped" -gt 0 ] && echo "$skipped skipped (the frozen seed cannot compile it)"
[ "$fails" -eq 0 ]
