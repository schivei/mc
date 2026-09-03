#!/bin/sh
# check-asm.sh [MC0] [MC1] — criterio da fatia 4 do M6.
# Para cada fonte .mc do repo compara `MC0 --dump-asm F` com `MC1 --dump-asm F`.
# Qualquer diferenca (stdout, stderr ou codigo de saida) e falha — inclusive os
# arquivos que os compiladores rejeitam: a mensagem de erro e o codigo tem de ser
# os mesmos. Os fontes de src/ compilados sozinhos sao justamente esses casos (as
# funcoes que eles chamam moram em outro arquivo), e o erro identico e o teste.
#
# Enquanto build/mc1 nao existe, rode com MC1 = MC0: tem de dar 100% identico
# (prova que o proprio teste e deterministico e que o script esta correto).
mc0="${1:-build/mc0}"
mc1="${2:-build/mc1}"

for mc in "$mc0" "$mc1"; do
    if [ ! -x "$mc" ]; then
        echo "FAIL: compilador '$mc' nao encontrado ou nao executavel"
        exit 1
    fi
done

tmp="${TMPDIR:-/tmp}/check-asm.$$"
mkdir -p "$tmp"
fails=0
total=0

for f in tests/*.mc tests/lib/*.mc lib/*.mc src/*.mc; do
    [ -f "$f" ] || continue
    total=$((total + 1))

    "$mc0" --dump-asm "$f" > "$tmp/a" 2> "$tmp/ae"; ra=$?
    "$mc1" --dump-asm "$f" > "$tmp/b" 2> "$tmp/be"; rb=$?

    if [ "$ra" != "$rb" ]; then
        echo "FAIL $f (exit $rb com '$mc1', $ra com '$mc0')"
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
