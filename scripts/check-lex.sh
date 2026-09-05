#!/bin/sh
# check-lex.sh [MC0] [LEXDUMP] — cross-check for M4.
# Compiles src/lexdump.mc (which includes src/arena.mc and src/lex.mc) with MC0,
# links it into LEXDUMP and, for each .mc source in the repo, compares
# `MC0 --dump-tokens F` with `LEXDUMP F`. Any difference (output or exit code) is a failure.
mc="${1:-build/mc0}"
lexdump="${2:-build/lexdump}"

# M38: on Windows a program that is not called *.exe cannot be launched, so the
# name is written with the suffix here, where it is chosen (docs/guide/95-windows-host.md).
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) lexdump="$lexdump.exe" ;; esac

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

mkdir -p build
obj="build/lexdump.o"
if ! msg=$("$mc" src/lexdump.mc -o "$obj" 2>&1); then
    echo "FAIL: compiling src/lexdump.mc: $msg"
    exit 1
fi
if ! msg=$(scripts/link-host.sh "$lexdump" "$obj" 2>&1); then
    echo "FAIL: linking $lexdump: $msg"
    exit 1
fi

# M24 (risk 6 / decision D6): a source the FROZEN SEED cannot LEX has nothing to
# compare, the same escape scripts/check-asm.sh and scripts/check-ast.sh have
# carried since M38. It exists here as insurance for the modules Tier 4 puts
# under lib/: the seed's lex_number stops a literal at the `.`, so a file that
# spells one out is not comparable. No file uses it today -- lib/float.mc and
# every other bundled module write bit patterns for exactly this reason -- and
# a skip is REPORTED here rather than silently dropped.
seed_skip() { sed -n 's|^// seed-skip: *||p' "$1" | head -1; }

# M44 (risk 17): a source whose TOKENS the two lexers cannot agree on, while
# both still COMPILE it identically -- which is a strictly narrower escape than
# seed-skip and therefore a header of its own, so that check-asm.sh and
# check-ast.sh keep the file. There is exactly one class: `.` became a lexeme in
# src/lex.mc (it is what lets `#include <geo/geo.mc>` be spelled) and is not one
# in the frozen stage0/lex.c. --dump-tokens does not process directives, so a
# file that registers an operator BEGINNING with a dot -- `#infix ".+"` -- is
# lexed as `.` `+` by the new lexer and refused with `unexpected character` by
# the seed. Under a real compile the #infix has registered `.+` and the longest
# match takes it on both sides, which is why check-asm still compares this file
# byte for byte.
lex_skip() { sed -n 's|^// lex-skip: *||p' "$1" | head -1; }

tmp="${TMPDIR:-/tmp}/check-lex.$$"
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
    [ -n "$why" ] || why=$(lex_skip "$f")
    if [ -n "$why" ]; then
        echo "skip $f ($why)"
        skipped=$((skipped + 1))
        continue
    fi
    total=$((total + 1))

    "$mc" --dump-tokens "$f" > "$tmp/a" 2> "$tmp/ae"; ra=$?
    "$lexdump" "$f"          > "$tmp/b" 2> "$tmp/be"; rb=$?

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
if [ "$skipped" -gt 0 ]; then
    echo "$((total - fails))/$total files identical ($skipped skipped)"
else
    echo "$((total - fails))/$total files identical"
fi
[ "$fails" -eq 0 ]
