#!/bin/sh
# check-toml.sh [MC] [TOMLDUMP] — acceptance criterion for M14's TOML parser.
#
# Compiles src/tomldump.mc with MC (via --exe: no `ld`), and for each
# tests/toml/*.toml compares the combined output (stdout + stderr) against the
# sibling .expect and checks the exit code: 0 for a well-formed file, 1 for the
# `bad-*.toml` ones, whose .expect holds the exact `file:line:col: message`.
#
# The paths in the error messages are the ones given on the command line, so
# this script has to be run from the repository root -- as `make check-toml`
# does.
mc="${1:-build/mc1}"
tomldump="${2:-build/tomldump}"

# M38: on Windows a program that is not called *.exe cannot be launched, so the
# name is written with the suffix here, where it is chosen (docs/guide/95-windows-host.md).
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tomldump="$tomldump.exe" ;; esac

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

mkdir -p build
# rm before writing: overwriting a signed executable on the same inode makes the
# kernel kill its next execution with SIGKILL (cached signature)
rm -f "$tomldump"
if ! msg=$(scripts/build-exe.sh "$mc" "$tomldump" src/tomldump.mc 2>&1); then
    echo "FAIL: compiling src/tomldump.mc: $msg"
    exit 1
fi

tmp="${TMPDIR:-/tmp}/check-toml.$$"
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
mkdir -p "$tmp"
fails=0
total=0

for f in tests/toml/*.toml; do
    [ -f "$f" ] || continue
    total=$((total + 1))
    exp="${f%.toml}.expect"
    name=$(basename "$f")

    case "$name" in
        bad-*) want_exit=1 ;;
        *)     want_exit=0 ;;
    esac

    "$tomldump" "$f" > "$tmp/o" 2>&1; got_exit=$?

    if [ ! -f "$exp" ]; then
        echo "FAIL $name (no $exp)"
        fails=$((fails + 1)); continue
    fi
    if [ "$got_exit" != "$want_exit" ]; then
        echo "FAIL $name (exit $got_exit, expected $want_exit)"
        sed -n '1,5p' "$tmp/o"
        fails=$((fails + 1)); continue
    fi
    if ! diff -u "$exp" "$tmp/o" > "$tmp/d" 2>&1; then
        echo "FAIL $name"
        sed -n '1,20p' "$tmp/d"
        fails=$((fails + 1)); continue
    fi
    echo "ok $name"
done

rm -rf "$tmp"
echo "$((total - fails))/$total TOML files match"
[ "$fails" -eq 0 ]
