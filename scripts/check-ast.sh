#!/bin/sh
# check-ast.sh [MC0] [ASTDUMP] — cross-check for M6 slice 3.
# Compiles src/astdump.mc (which includes arena.mc, macho.mc, lex.mc, ast.mc
# and parse.mc) with MC0, links it into ASTDUMP and, for each .mc source in
# the repo, compares `MC0 --dump-ast F` with `ASTDUMP F`. Any difference
# (stdout, stderr, or exit code) is a failure — including the files MC0
# rejects: the error message and the code have to be the same.
mc="${1:-build/mc0}"
astdump="${2:-build/astdump}"

# M38: on Windows a program that is not called *.exe cannot be launched, so the
# name is written with the suffix here, where it is chosen (docs/guide/95-windows-host.md).
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) astdump="$astdump.exe" ;; esac

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


# M38: a source the FROZEN SEED cannot compile has nothing to compare. There is
# exactly one -- lib/sys_windows_host.mc declares CreateProcessA, which takes
# ten parameters, and stage0 keeps MAXPARAMS at 8 (docs/build.md § limits). It
# carries the reason in its own header, the way tests/*.mc carry `// skip-linux:`,
# and it is REPORTED here rather than silently dropped. This is the same reason
# tests/mc/ is a directory of its own (scripts/check-mc.sh).
seed_skip() { sed -n 's|^// seed-skip: *||p' "$1" | head -1; }

tmp="${TMPDIR:-/tmp}/check-ast.$$"
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
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
[ "$skipped" -gt 0 ] && echo "$skipped skipped (the frozen seed cannot compile it)"
[ "$fails" -eq 0 ]
