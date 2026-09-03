#!/bin/sh
# test-exe.sh COMPILER — the whole suite via the path with no `ld`: for each
# tests/*.mc, compiles straight to build/tests-exe/NAME with --exe, runs it,
# and compares against the source's header, exactly like scripts/test.sh does
# via the .o + ld path:
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
# It also checks that the binary is signed ad hoc (codesign --verify).
# Only the .mc compiler has --exe; stage0 in C does not (docs/surface.md § Tier 2).
mc="${1:-build/mc1}"
mkdir -p build/tests-exe
fails=0
total=0

for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    total=$((total + 1))
    exe="build/tests-exe/$name"

    want_exit=$(sed -n 's|^// expect-exit: *||p' "$f" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$f" | head -1)
    has_out=$(grep -c '^// expect-stdout:' "$f")

    if [ -z "$want_exit" ]; then
        echo "FAIL $name (sem cabecalho expect-exit)"; fails=$((fails + 1)); continue
    fi
    rm -f "$exe"
    if ! msg=$("$mc" --exe "$f" -o "$exe" 2>&1); then
        echo "FAIL $name (compilacao: $msg)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$(codesign --verify --verbose=4 "$exe" 2>&1); then
        echo "FAIL $name (assinatura: $msg)"; fails=$((fails + 1)); continue
    fi

    got_out=$("$exe" 2>/dev/null)
    got_exit=$?
    if [ "$got_exit" != "$want_exit" ]; then
        echo "FAIL $name (exit $got_exit, esperado $want_exit)"; fails=$((fails + 1)); continue
    fi
    if [ "$has_out" != "0" ] && [ "$got_out" != "$want_out" ]; then
        echo "FAIL $name (stdout '$got_out', esperado '$want_out')"; fails=$((fails + 1)); continue
    fi
    echo "ok $name"
done

echo "$((total - fails))/$total testes passaram via --exe"
[ "$fails" -eq 0 ]
