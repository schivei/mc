#!/bin/sh
# lib_test.sh — acceptance test for examples/api/lib (rt.mc, http.mc, sqlite.mc).
#
# Compiles examples/api/tests/lib_test.mc with the self-hosted mc via the
# --exe path (stage0 will not do: it does not know #dylib) and runs both parts:
#
#   1. SQLite — the binary with no argument creates /tmp/mc_api_libtest.db,
#      does a CREATE TABLE, two INSERT with bind_text/bind_int and a SELECT
#      with column_text/column_int, and checks the result on its own.
#   2. HTTP   — the binary with a port brings the server up; the script picks
#      a free port, does `curl -s`, compares the body with "ok", checks the
#      headers and waits for the server to exit. One connection at a time:
#      the server answers one request and terminates.
#
# Shows otool -L (libSystem + libsqlite3, proof of #dylib) and codesign --verify.
# Exits 0 if everything passed, 1 otherwise.

root=$(cd "$(dirname "$0")/../../.." && pwd)
mc="$root/build/mc1"
source="$root/examples/api/tests/lib_test.mc"
bin="$root/build/lib_test"
log=/tmp/mc_api_libtest_srv.log
hdr=/tmp/mc_api_libtest_hdr.txt
pid=""

cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

if [ ! -x "$mc" ]; then
    echo "== build/mc1 missing, building =="
    make -C "$root" mc1 || { echo "FAIL: make mc1"; exit 1; }
fi

echo "== compiling (--exe, no ld) =="
rm -f "$bin"
"$mc" --exe "$source" -o "$bin" || { echo "FAIL: compilation"; exit 1; }
echo "ok: $bin ($(wc -c < "$bin" | tr -d ' ') bytes)"

echo "== otool -L =="
otool -L "$bin" || { echo "FAIL: otool"; exit 1; }
otool -L "$bin" | grep -q libsqlite3 || { echo "FAIL: libsqlite3 missing from otool -L"; exit 1; }

echo "== codesign --verify =="
codesign --verify --verbose=4 "$bin" || { echo "FAIL: codesign"; exit 1; }

echo "== part 1: sqlite =="
rm -f /tmp/mc_api_libtest.db
"$bin" || { echo "FAIL: sqlite part exited $?"; exit 1; }

echo "== part 2: http =="
port=$((18000 + $$ % 1000))
attempt=0
body=""
while [ "$attempt" -lt 20 ]; do
    rm -f "$log" "$hdr"
    "$bin" "$port" > "$log" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 100 ]; do
        kill -0 "$pid" 2>/dev/null || break        # server died: port taken
        body=$(curl -s -m 5 -D "$hdr" "http://127.0.0.1:$port/" 2>/dev/null)
        [ -n "$body" ] && break
        i=$((i + 1))
        sleep 0.05
    done
    [ -n "$body" ] && break
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=""
    port=$((port + 1))
    attempt=$((attempt + 1))
done

if [ -z "$body" ]; then
    echo "FAIL: server did not respond on any port from $((18000 + $$ % 1000)) to $port"
    [ -f "$log" ] && cat "$log"
    exit 1
fi

wait "$pid"
rc=$?
pid=""

echo "port $port"
sed 's|^|  |' "$hdr"
sed 's|^|  |' "$log"
echo "  body: $body"

[ "$body" = "ok" ] || { echo "FAIL: body '$body' != 'ok'"; exit 1; }
grep -q '^HTTP/1.1 200 OK' "$hdr" || { echo "FAIL: status line"; exit 1; }
grep -qi '^Content-Length: 2' "$hdr" || { echo "FAIL: Content-Length"; exit 1; }
grep -qi '^Connection: close' "$hdr" || { echo "FAIL: Connection: close"; exit 1; }
[ "$rc" = 0 ] || { echo "FAIL: server exited with $rc"; exit 1; }

echo "== ok: sqlite and http passed =="
exit 0
