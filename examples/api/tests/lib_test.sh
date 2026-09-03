#!/bin/sh
# lib_test.sh — aceite de examples/api/lib (rt.mc, http.mc, sqlite.mc).
#
# Compila examples/api/tests/lib_test.mc com o mc auto-hospedado pelo caminho
# --exe (o stage0 nao serve: ele nao conhece #dylib) e roda as duas partes:
#
#   1. SQLite — o binario sem argumento cria /tmp/mc_api_libtest.db, faz
#      CREATE TABLE, dois INSERT com bind_text/bind_int e um SELECT com
#      column_text/column_int, e confere o resultado sozinho.
#   2. HTTP   — o binario com uma porta sobe o servidor; o script escolhe uma
#      porta livre, faz `curl -s`, compara o corpo com "ok", confere os
#      cabecalhos e espera o servidor sair. Uma conexao por vez: o servidor
#      responde uma requisicao e termina.
#
# Mostra otool -L (libSystem + libsqlite3, prova do #dylib) e codesign --verify.
# Sai 0 se tudo passou, 1 caso contrario.

raiz=$(cd "$(dirname "$0")/../../.." && pwd)
mc="$raiz/build/mc1"
fonte="$raiz/examples/api/tests/lib_test.mc"
bin="$raiz/build/lib_test"
log=/tmp/mc_api_libtest_srv.log
hdr=/tmp/mc_api_libtest_hdr.txt
pid=""

limpa() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    return 0
}
trap limpa EXIT INT TERM

if [ ! -x "$mc" ]; then
    echo "== build/mc1 ausente, construindo =="
    make -C "$raiz" mc1 || { echo "FALHA: make mc1"; exit 1; }
fi

echo "== compilando (--exe, sem ld) =="
rm -f "$bin"
"$mc" --exe "$fonte" -o "$bin" || { echo "FALHA: compilacao"; exit 1; }
echo "ok: $bin ($(wc -c < "$bin" | tr -d ' ') bytes)"

echo "== otool -L =="
otool -L "$bin" || { echo "FALHA: otool"; exit 1; }
otool -L "$bin" | grep -q libsqlite3 || { echo "FALHA: libsqlite3 ausente em otool -L"; exit 1; }

echo "== codesign --verify =="
codesign --verify --verbose=4 "$bin" || { echo "FALHA: codesign"; exit 1; }

echo "== parte 1: sqlite =="
rm -f /tmp/mc_api_libtest.db
"$bin" || { echo "FALHA: parte sqlite saiu $?"; exit 1; }

echo "== parte 2: http =="
porta=$((18000 + $$ % 1000))
tent=0
corpo=""
while [ "$tent" -lt 20 ]; do
    rm -f "$log" "$hdr"
    "$bin" "$porta" > "$log" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 100 ]; do
        kill -0 "$pid" 2>/dev/null || break        # servidor morreu: porta ocupada
        corpo=$(curl -s -m 5 -D "$hdr" "http://127.0.0.1:$porta/" 2>/dev/null)
        [ -n "$corpo" ] && break
        i=$((i + 1))
        sleep 0.05
    done
    [ -n "$corpo" ] && break
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=""
    porta=$((porta + 1))
    tent=$((tent + 1))
done

if [ -z "$corpo" ]; then
    echo "FALHA: servidor nao respondeu em nenhuma porta de $((18000 + $$ % 1000)) a $porta"
    [ -f "$log" ] && cat "$log"
    exit 1
fi

wait "$pid"
rc=$?
pid=""

echo "porta $porta"
sed 's|^|  |' "$hdr"
sed 's|^|  |' "$log"
echo "  corpo: $corpo"

[ "$corpo" = "ok" ] || { echo "FALHA: corpo '$corpo' != 'ok'"; exit 1; }
grep -q '^HTTP/1.1 200 OK' "$hdr" || { echo "FALHA: linha de status"; exit 1; }
grep -qi '^Content-Length: 2' "$hdr" || { echo "FALHA: Content-Length"; exit 1; }
grep -qi '^Connection: close' "$hdr" || { echo "FALHA: Connection: close"; exit 1; }
[ "$rc" = 0 ] || { echo "FALHA: servidor saiu com $rc"; exit 1; }

echo "== ok: sqlite e http passaram =="
exit 0
