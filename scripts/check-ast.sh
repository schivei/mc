#!/bin/sh
# check-ast.sh [MC0] [ASTDUMP] — cross-check for M6 slice 3.
# Compiles src/astdump.mc (which includes arena.mc, macho.mc, lex.mc, ast.mc
# and parse.mc) with MC0, links it into ASTDUMP and, for each .mc source in
# the repo, compares `MC0 --dump-ast F` with `ASTDUMP F`. Any difference
# (stdout, stderr, or exit code) is a failure — including the files MC0
# rejects: the error message and the code have to be the same.
mc="${1:-build/mc0}"
astdump="${2:-build/astdump}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

mkdir -p build
obj="build/astdump.o"
if ! msg=$("$mc" src/astdump.mc -o "$obj" 2>&1); then
    echo "FAIL: compiling src/astdump.mc: $msg"
    exit 1
fi
if ! msg=$(scripts/link-host.sh "$astdump" "$obj" 2>&1); then
    echo "FAIL: linking $astdump: $msg"
    exit 1
fi

tmp="${TMPDIR:-/tmp}/check-ast.$$"
mkdir -p "$tmp"
fails=0
total=0

for f in tests/*.mc tests/lib/*.mc lib/*.mc src/*.mc; do
    [ -f "$f" ] || continue
    total=$((total + 1))

    "$mc" --dump-ast "$f" > "$tmp/a" 2> "$tmp/ae"; ra=$?
    "$astdump" "$f"       > "$tmp/b" 2> "$tmp/be"; rb=$?

    if [ "$ra" != "$rb" ]; then
        echo "FAIL $f (exit $rb, expected $ra)"
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
[ "$fails" -eq 0 ]
