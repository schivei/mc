#!/bin/sh
# check-ast.sh [MC0] [ASTDUMP] — cross-check da fatia 3 do M6.
# Compila src/astdump.mc (que inclui arena.mc, macho.mc, lex.mc, ast.mc e
# parse.mc) com MC0, linka em ASTDUMP e, para cada fonte .mc do repo, compara
# `MC0 --dump-ast F` com `ASTDUMP F`. Qualquer diferenca (stdout, stderr ou
# codigo de saida) e falha — inclusive os arquivos que o MC0 rejeita: a mensagem
# de erro e o codigo tem de ser os mesmos.
mc="${1:-build/mc0}"
astdump="${2:-build/astdump}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compilador '$mc' nao encontrado ou nao executavel"
    exit 1
fi

mkdir -p build
obj="build/astdump.o"
if ! msg=$("$mc" src/astdump.mc -o "$obj" 2>&1); then
    echo "FAIL: compilacao de src/astdump.mc: $msg"
    exit 1
fi
if ! msg=$(scripts/link.sh "$astdump" "$obj" 2>&1); then
    echo "FAIL: link de $astdump: $msg"
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
