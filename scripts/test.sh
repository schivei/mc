#!/bin/sh
# test.sh COMPILADOR — para cada tests/*.mc: compila para build/tests/NOME.o,
# linka com scripts/link.sh, executa e compara com o cabecalho do fonte:
#   // expect-exit: N        (obrigatorio)
#   // expect-stdout: TEXTO  (opcional)
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
        echo "FAIL $name (sem cabecalho expect-exit)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$("$mc" "$f" -o "$obj" 2>&1); then
        echo "FAIL $name (compilacao: $msg)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$(scripts/link.sh "$exe" "$obj" 2>&1); then
        echo "FAIL $name (link: $msg)"; fails=$((fails + 1)); continue
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

echo "$((total - fails))/$total testes passaram"
[ "$fails" -eq 0 ]
