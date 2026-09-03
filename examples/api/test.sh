#!/bin/sh
# test.sh — aceite da API de examples/api/main.mc.
#
# Sobe o servidor numa porta livre com um banco temporario, bate em cada rota
# com `curl`, compara corpo e status com o esperado, confere o estado final do
# banco com o `sqlite3` do sistema e mata o servidor. Sai 0 se tudo passou.
#
# Depende so de: ../../build/mc1 (constroi se faltar), build/mc-api, curl,
# sqlite3. O compilador padrao nao serve — `class`/`interface`/`#dylib` vem de
# mc-api.mc + oop.mc.

raiz=$(cd "$(dirname "$0")/../.." && pwd)
dir="$raiz/examples/api"
mc="$raiz/build/mc1"
mcapi="$dir/build/mc-api"
api="$dir/build/api"
db="/tmp/mc_api_test_$$.db"
log="/tmp/mc_api_test_$$.log"
pid=""
falhas=0

limpa() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$db" "$db-journal" "$log"
    return 0
}
trap limpa EXIT INT TERM

# nome, esperado, obtido
confere() {
    if [ "$2" = "$3" ]; then
        echo "  ok    $1"
        echo "        $3"
    else
        echo "  FALHA $1"
        echo "        esperado: $2"
        echo "        obtido:   $3"
        falhas=$((falhas + 1))
    fi
}

echo "== compilando =="
if [ ! -x "$mc" ]; then
    make -C "$raiz" mc1 || { echo "FALHA: make mc1"; exit 1; }
fi
mkdir -p "$dir/build"
# rm antes de cada saida: sobrescrever um executavel assinado no mesmo inode faz
# o kernel matar a proxima execucao dele com SIGKILL (assinatura em cache)
rm -f "$mcapi" "$api"
"$mc" --exe "$dir/mc-api.mc" -o "$mcapi" || { echo "FALHA: mc-api"; exit 1; }
"$mcapi" --exe "$dir/main.mc" -o "$api" || { echo "FALHA: main.mc"; exit 1; }
echo "  ok    $api ($(wc -c < "$api" | tr -d ' ') bytes)"

echo "== assinatura e dylibs =="
codesign --verify --verbose=2 "$api" || { echo "FALHA: codesign"; exit 1; }
otool -L "$api" | sed 's|^|  |'
otool -L "$api" | grep -q libsqlite3 || { echo "FALHA: libsqlite3 ausente"; exit 1; }

echo "== subindo o servidor =="
rm -f "$db"
porta=$((19000 + $$ % 1000))
tent=0
pronto=""
while [ "$tent" -lt 20 ]; do
    "$api" "$porta" "$db" > "$log" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 100 ]; do
        kill -0 "$pid" 2>/dev/null || break            # morreu: porta ocupada
        pronto=$(curl -s -m 5 "http://127.0.0.1:$porta/health" 2>/dev/null)
        [ -n "$pronto" ] && break
        i=$((i + 1))
        sleep 0.05
    done
    [ -n "$pronto" ] && break
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=""
    porta=$((porta + 1))
    tent=$((tent + 1))
done

if [ -z "$pronto" ]; then
    echo "FALHA: o servidor nao subiu em nenhuma porta"
    [ -f "$log" ] && cat "$log"
    exit 1
fi
echo "  ok    porta $porta, banco $db"

base="http://127.0.0.1:$porta"

echo "== rotas =="

confere "GET /health" '{"ok":true}' "$pronto"

corpo=$(curl -s -X POST --data-binary 'comprar pao' "$base/todos")
confere "POST /todos (comprar pao)" \
    '{"id":1,"title":"comprar pao","done":false}' "$corpo"

st=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'pagar conta' "$base/todos")
confere "POST /todos status" '201' "$st"

corpo=$(curl -s "$base/todos")
confere "GET /todos (dois)" \
    '[{"id":1,"title":"comprar pao","done":false},{"id":2,"title":"pagar conta","done":false}]' \
    "$corpo"

corpo=$(curl -s -X DELETE "$base/todos/1")
confere "DELETE /todos/1" '{"deleted":1}' "$corpo"

corpo=$(curl -s "$base/todos")
confere "GET /todos (um)" \
    '[{"id":2,"title":"pagar conta","done":false}]' "$corpo"

corpo=$(curl -s -X DELETE "$base/todos/99")
confere "DELETE /todos/99 (inexistente)" '{"error":"not found"}' "$corpo"

st=$(curl -s -o /dev/null -w '%{http_code}' "$base/nada")
corpo=$(curl -s "$base/nada")
confere "GET /nada status" '404' "$st"
confere "GET /nada corpo" '{"error":"not found"}' "$corpo"

echo "== banco (sqlite3 do sistema) =="
linhas=$(sqlite3 "$db" 'select id || "|" || title || "|" || done from todos order by id;')
confere "SELECT * FROM todos" '2|pagar conta|0' "$linhas"

echo "== log do servidor =="
sed 's|^|  |' "$log"

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
pid=""

if [ "$falhas" -ne 0 ]; then
    echo "== FALHOU: $falhas verificacao(oes) =="
    exit 1
fi
echo "== ok: todas as rotas responderam o esperado =="
exit 0
