#!/bin/sh
# check-lex.sh [MC0] [LEXDUMP] — cross-check do M4.
# Compila src/lexdump.mc (que inclui src/arena.mc e src/lex.mc) com MC0, linka em
# LEXDUMP e, para cada fonte .mc do repo, compara `MC0 --dump-tokens F` com
# `LEXDUMP F`. Qualquer diferenca (saida ou codigo de saida) e falha.
mc="${1:-build/mc0}"
lexdump="${2:-build/lexdump}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compilador '$mc' nao encontrado ou nao executavel"
    exit 1
fi

mkdir -p build
obj="build/lexdump.o"
if ! msg=$("$mc" src/lexdump.mc -o "$obj" 2>&1); then
    echo "FAIL: compilacao de src/lexdump.mc: $msg"
    exit 1
fi
if ! msg=$(scripts/link.sh "$lexdump" "$obj" 2>&1); then
    echo "FAIL: link de $lexdump: $msg"
    exit 1
fi

tmp="${TMPDIR:-/tmp}/check-lex.$$"
mkdir -p "$tmp"
fails=0
total=0

for f in tests/*.mc tests/lib/*.mc lib/*.mc src/*.mc; do
    [ -f "$f" ] || continue
    total=$((total + 1))

    "$mc" --dump-tokens "$f" > "$tmp/a" 2> "$tmp/ae"; ra=$?
    "$lexdump" "$f"          > "$tmp/b" 2> "$tmp/be"; rb=$?

    if [ "$ra" != "$rb" ]; then
        echo "FAIL $f (exit $rb, esperado $ra)"
        sed -n '1,3p' "$tmp/ae" "$tmp/be"
        fails=$((fails + 1)); continue
    fi
    if ! diff -u "$tmp/a" "$tmp/b" > "$tmp/d" 2>&1; then
        echo "FAIL $f"
        sed -n '1,20p' "$tmp/d"
        fails=$((fails + 1)); continue
    fi
    if ! diff -u "$tmp/ae" "$tmp/be" > "$tmp/de" 2>&1; then
        echo "FAIL $f (stderr difere)"
        sed -n '1,20p' "$tmp/de"
        fails=$((fails + 1)); continue
    fi
    echo "ok $f"
done

rm -rf "$tmp"
echo "$((total - fails))/$total arquivos identicos"
[ "$fails" -eq 0 ]
