#!/bin/sh
# test.sh — acceptance test for the API in examples/api/main.mc.
#
# Brings the server up on a free port with a temporary database, hits every
# route with `curl`, compares body and status against the expected values,
# checks the database's final state with the system's `sqlite3`, and kills
# the server. Exits 0 if everything passed.
#
# Depends only on: ../../build/mc1 (builds it if missing), build/mc-api, curl,
# sqlite3. The default compiler will not do — `class`/`interface`/`#dylib`
# come from mc-api.mc + oop.mc.

root=$(cd "$(dirname "$0")/../.." && pwd)
dir="$root/examples/api"
mc="$root/build/mc1"
mcapi="$dir/build/mc-api"
api="$dir/build/api"
db="/tmp/mc_api_test_$$.db"
log="/tmp/mc_api_test_$$.log"
pid=""
fails=0

cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$db" "$db-journal" "$log"
    return 0
}
trap cleanup EXIT INT TERM

# name, expected, obtained
check() {
    if [ "$2" = "$3" ]; then
        echo "  ok    $1"
        echo "        $3"
    else
        echo "  FAIL $1"
        echo "        expected: $2"
        echo "        got:      $3"
        fails=$((fails + 1))
    fi
}

echo "== compiling =="
if [ ! -x "$mc" ]; then
    make -C "$root" mc1 || { echo "FAIL: make mc1"; exit 1; }
fi
mkdir -p "$dir/build"
# rm before each output: overwriting a signed executable on the same inode
# makes the kernel kill its next execution with SIGKILL (cached signature)
rm -f "$mcapi" "$api"
"$mc" --exe "$dir/mc-api.mc" -o "$mcapi" || { echo "FAIL: mc-api"; exit 1; }
"$mcapi" --exe "$dir/main.mc" -o "$api" || { echo "FAIL: main.mc"; exit 1; }
echo "  ok    $api ($(wc -c < "$api" | tr -d ' ') bytes)"

echo "== signature and dylibs =="
codesign --verify --verbose=2 "$api" || { echo "FAIL: codesign"; exit 1; }
otool -L "$api" | sed 's|^|  |'
otool -L "$api" | grep -q libsqlite3 || { echo "FAIL: libsqlite3 missing"; exit 1; }

echo "== starting the server =="
rm -f "$db"
port=$((19000 + $$ % 1000))
attempt=0
ready=""
while [ "$attempt" -lt 20 ]; do
    "$api" "$port" "$db" > "$log" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 100 ]; do
        kill -0 "$pid" 2>/dev/null || break            # died: port taken
        ready=$(curl -s -m 5 "http://127.0.0.1:$port/health" 2>/dev/null)
        [ -n "$ready" ] && break
        i=$((i + 1))
        sleep 0.05
    done
    [ -n "$ready" ] && break
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=""
    port=$((port + 1))
    attempt=$((attempt + 1))
done

if [ -z "$ready" ]; then
    echo "FAIL: the server did not come up on any port"
    [ -f "$log" ] && cat "$log"
    exit 1
fi
echo "  ok    port $port, db $db"

base="http://127.0.0.1:$port"

echo "== routes =="

check "GET /health" '{"ok":true}' "$ready"

body=$(curl -s -X POST --data-binary 'buy bread' "$base/todos")
check "POST /todos (buy bread)" \
    '{"id":1,"title":"buy bread","done":false}' "$body"

st=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary 'pay bill' "$base/todos")
check "POST /todos status" '201' "$st"

body=$(curl -s "$base/todos")
check "GET /todos (two)" \
    '[{"id":1,"title":"buy bread","done":false},{"id":2,"title":"pay bill","done":false}]' \
    "$body"

body=$(curl -s -X DELETE "$base/todos/1")
check "DELETE /todos/1" '{"deleted":1}' "$body"

body=$(curl -s "$base/todos")
check "GET /todos (one)" \
    '[{"id":2,"title":"pay bill","done":false}]' "$body"

body=$(curl -s -X DELETE "$base/todos/99")
check "DELETE /todos/99 (nonexistent)" '{"error":"not found"}' "$body"

st=$(curl -s -o /dev/null -w '%{http_code}' "$base/nada")
body=$(curl -s "$base/nada")
check "GET /nada status" '404' "$st"
check "GET /nada body" '{"error":"not found"}' "$body"

echo "== database (system sqlite3) =="
lines=$(sqlite3 "$db" 'select id || "|" || title || "|" || done from todos order by id;')
check "SELECT * FROM todos" '2|pay bill|0' "$lines"

echo "== server log =="
sed 's|^|  |' "$log"

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
pid=""

if [ "$fails" -ne 0 ]; then
    echo "== FAILED: $fails check(s) =="
    exit 1
fi
echo "== ok: all routes responded as expected =="
exit 0
