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
        echo "FAIL: compilador '$mc' nao encontrado ou nao executavel"
        exit 1
    fi
done

tmp="${TMPDIR:-/tmp}/check-obj.$$"
mkdir -p "$tmp/a" "$tmp/b"
fails=0
total=0

for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    total=$((total + 1))
    a="$tmp/a/$name.o"
    b="$tmp/b/$name.o"

    "$mc0" "$f" -o "$a" > "$tmp/ao" 2> "$tmp/ae"; ra=$?
    "$mc1" "$f" -o "$b" > "$tmp/bo" 2> "$tmp/be"; rb=$?

    if [ "$ra" != "$rb" ]; then
        echo "FAIL $name (exit $rb com '$mc1', $ra com '$mc0')"
        sed -n '1,3p' "$tmp/ae" "$tmp/be"
        fails=$((fails + 1)); continue
    fi
    if [ "$ra" != "0" ]; then
        echo "FAIL $name (os dois recusaram o fonte: $(sed -n 1p "$tmp/ae"))"
        fails=$((fails + 1)); continue
    fi
    if ! diff -u "$tmp/ae" "$tmp/be" > "$tmp/de" 2>&1; then
        echo "FAIL $name (stderr difere)"
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
echo "$((total - fails))/$total objetos identicos"
[ "$fails" -eq 0 ]
