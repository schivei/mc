#!/bin/sh
# test.sh COMPILER — for each tests/*.mc: compiles to build/tests/NAME.o,
# links with scripts/link.sh, runs it, and compares against the source's header:
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
mc="${1:-build/mc0}"
mkdir -p build/tests
fails=0
total=0

for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    total=$((total + 1))
    obj="build/tests/$name.o"
    exe="build/tests/$name"

    want_exit=$(sed -n 's|^// expect-exit: *||p' "$f" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$f" | head -1)
    has_out=$(grep -c '^// expect-stdout:' "$f")

    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no expect-exit header)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$("$mc" "$f" -o "$obj" 2>&1); then
        echo "FAIL $name (compilation: $msg)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$(scripts/link.sh "$exe" "$obj" 2>&1); then
        echo "FAIL $name (link: $msg)"; fails=$((fails + 1)); continue
    fi

    got_out=$("$exe" 2>/dev/null)
    got_exit=$?
    if [ "$got_exit" != "$want_exit" ]; then
        echo "FAIL $name (exit $got_exit, expected $want_exit)"; fails=$((fails + 1)); continue
    fi
    if [ "$has_out" != "0" ] && [ "$got_out" != "$want_out" ]; then
        echo "FAIL $name (stdout '$got_out', expected '$want_out')"; fails=$((fails + 1)); continue
    fi
    echo "ok $name"
done

echo "$((total - fails))/$total tests passed"
[ "$fails" -eq 0 ]
