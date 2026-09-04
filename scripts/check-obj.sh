#!/bin/sh
# check-obj.sh [MC0] [MC1] — acceptance criterion for M6 slice 5.
# For each tests/*.mc, compiles the SAME source with both compilers and does a
# `cmp` of the two .o files. Byte-for-byte identity is the criterion; any
# difference (exit code, error message, or bytes) is a failure.
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

# M37/M38: on a Linux or a Windows host the object being compared is an ELF or a
# COFF object for THIS machine, so a test that is not portable to it has nothing
# to compare. The headers are the ones scripts/test-linux.sh and
# scripts/test-windows.sh already read -- `// skip-linux:` / `// skip-windows:`
# for the whole system, `// skip-<arch>:` for one instruction set -- and a
# skipped test is reported, not counted as a failure. On macOS nothing is
# skipped: the Mach-O objects are what the frozen seed writes for every test.
host_skip() {
    case "$(uname -s)" in
        Linux)                sys=linux ;;
        MINGW*|MSYS*|CYGWIN*) sys=windows ;;
        *)                    return 1 ;;
    esac
    r=$(sed -n "s|^// skip-$sys: *||p" "$1" | head -1)
    [ -n "$r" ] && { echo "$r"; return 0; }
    case "$(uname -m)" in
        aarch64|arm64) a=aarch64 ;;
        x86_64|amd64)  a=x86_64 ;;
        *)             a=none ;;
    esac
    r=$(sed -n "s|^// skip-$a: *||p" "$1" | head -1)
    [ -n "$r" ] && { echo "$r"; return 0; }
    return 1
}

tmp="${TMPDIR:-/tmp}/check-obj.$$"
mkdir -p "$tmp/a" "$tmp/b"
fails=0
total=0
skipped=0

for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    if why=$(host_skip "$f"); then
        echo "skip $name ($why)"
        skipped=$((skipped + 1)); continue
    fi
    total=$((total + 1))
    a="$tmp/a/$name.o"
    b="$tmp/b/$name.o"

    "$mc0" "$f" -o "$a" > "$tmp/ao" 2> "$tmp/ae"; ra=$?
    "$mc1" "$f" -o "$b" > "$tmp/bo" 2> "$tmp/be"; rb=$?

    if [ "$ra" != "$rb" ]; then
        echo "FAIL $name (exit $rb with '$mc1', $ra with '$mc0')"
        sed -n '1,3p' "$tmp/ae" "$tmp/be"
        fails=$((fails + 1)); continue
    fi
    if [ "$ra" != "0" ]; then
        echo "FAIL $name (both rejected the source: $(sed -n 1p "$tmp/ae"))"
        fails=$((fails + 1)); continue
    fi
    if ! diff -u "$tmp/ae" "$tmp/be" > "$tmp/de" 2>&1; then
        echo "FAIL $name (stderr differs)"
        sed -n '1,20p' "$tmp/de"
        fails=$((fails + 1)); continue
    fi
    if ! cmp "$a" "$b" > "$tmp/dc" 2>&1; then
        echo "FAIL $name ($(cat "$tmp/dc"))"
        # first divergences and xxd side by side around the first one
        cmp -l "$a" "$b" 2>/dev/null | head -8
        off=$(cmp -l "$a" "$b" 2>/dev/null | head -1 | awk '{print $1 - 1}')
        if [ -n "$off" ]; then
            start=$(( (off / 16) * 16 - 16 ))
            [ "$start" -lt 0 ] && start=0
            diff -u \
                "$(xxd -s "$start" -l 96 "$a" > "$tmp/xa"; echo "$tmp/xa")" \
                "$(xxd -s "$start" -l 96 "$b" > "$tmp/xb"; echo "$tmp/xb")" \
                | sed -n '1,30p'
        fi
        fails=$((fails + 1)); continue
    fi
    echo "ok $name"
done

rm -rf "$tmp"
echo "$((total - fails))/$total objects identical"
[ "$skipped" -gt 0 ] && echo "$skipped skipped (not portable to this host)"
[ "$fails" -eq 0 ]
