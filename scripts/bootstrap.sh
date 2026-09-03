#!/bin/sh
# bootstrap.sh — M7: fixed point of the self-hosted compiler.
#
#   build/mc0 src/mc.mc -> build/mc1.o  (+ link -> build/mc1)
#   build/mc1 src/mc.mc -> build/mc2.o  (+ link -> build/mc2)
#   build/mc2 src/mc.mc -> build/mc3.o
#   cmp build/mc2.o build/mc3.o         <- the criterion (not mc1.o vs mc2.o:
#                                          those may differ, they are different
#                                          compilers — clang vs mc1)
#   SHA-256 of build/mc2.o compared against the golden checked into
#   tests/golden/mc2.sha256 (recorded the first time the script runs).
#
# No "set -e": each step checks its own exit code and fails with a clear
# message, so a failure in the middle of the chain never passes silently.

mc0="build/mc0"
golden="tests/golden/mc2.sha256"

if [ ! -x "$mc0" ]; then
    echo "FAIL: '$mc0' nao encontrado ou nao executavel (rode 'make stage0')" >&2
    exit 1
fi
if [ ! -f "src/mc.mc" ]; then
    echo "FAIL: src/mc.mc nao encontrado" >&2
    exit 1
fi

# now() prints the clock with millisecond precision. The shell's 'time' can't
# be captured in a format that's portable across 'sh' and reused in the total;
# and GNU coreutils' 'date +%s.%N' doesn't exist in macOS's BSD date (%N isn't
# supported). perl is always installed on macOS and has Time::HiRes: we use it.
now() {
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
}

# dt A B -> "B - A" with 3 decimal places.
dt() {
    perl -e 'printf "%.3f", '"$2"' - '"$1"''
}

fails=0
t_total0=$(now)

# etapa DESCRIPTION CMD... — runs CMD, times it, fails with a clear message if
# the exit code isn't 0. Doesn't use set -e: the 'if' itself captures the status.
etapa() {
    desc="$1"; shift
    t0=$(now)
    if ! "$@" >"$tmp_out" 2>"$tmp_err"; then
        rc=$?
        echo "FAIL: $desc (exit $rc)" >&2
        echo "--- comando: $* ---" >&2
        cat "$tmp_out" "$tmp_err" >&2
        exit 1
    fi
    t1=$(now)
    echo "  $desc: $(dt "$t0" "$t1")s"
    cat "$tmp_out"
}

tmp_out="${TMPDIR:-/tmp}/bootstrap.$$.out"
tmp_err="${TMPDIR:-/tmp}/bootstrap.$$.err"
trap 'rm -f "$tmp_out" "$tmp_err"' EXIT

tamanho() {
    # size in bytes, portable (BSD stat on macOS uses -f%z; GNU uses -c%s).
    wc -c < "$1" | tr -d ' '
}

echo "=== M7 — ponto fixo: mc0 -> mc1 -> mc2 -> mc3 ==="

echo "-- estagio 1: build/mc0 src/mc.mc -> build/mc1.o --"
etapa "mc0 compila mc.mc"      "$mc0" src/mc.mc -o build/mc1.o
echo "  tamanho build/mc1.o: $(tamanho build/mc1.o) bytes"
etapa "link build/mc1"         scripts/link.sh build/mc1 build/mc1.o

echo "-- estagio 2: build/mc1 src/mc.mc -> build/mc2.o --"
etapa "mc1 compila mc.mc"      build/mc1 src/mc.mc -o build/mc2.o
echo "  tamanho build/mc2.o: $(tamanho build/mc2.o) bytes"
etapa "link build/mc2"         scripts/link.sh build/mc2 build/mc2.o

echo "-- estagio 3: build/mc2 src/mc.mc -> build/mc3.o --"
etapa "mc2 compila mc.mc"      build/mc2 src/mc.mc -o build/mc3.o
echo "  tamanho build/mc3.o: $(tamanho build/mc3.o) bytes"

echo "-- criterio do ponto fixo: cmp build/mc2.o build/mc3.o --"
if ! cmp build/mc2.o build/mc3.o; then
    echo "FAIL: build/mc2.o != build/mc3.o — nao ha ponto fixo" >&2
    echo "diagnostico: diff <(build/mc1 --dump-asm src/mc.mc) <(build/mc2 --dump-asm src/mc.mc)" >&2
    echo "depois bissecte por arquivo/funcao (ver docs/bootstrap.md)" >&2
    exit 1
fi
echo "  ok: build/mc2.o == build/mc3.o"

echo "-- golden SHA-256 de build/mc2.o --"
got_line=$(shasum -a 256 build/mc2.o)
got_hash=$(printf '%s\n' "$got_line" | awk '{print $1}')
mkdir -p "$(dirname "$golden")"
if [ ! -f "$golden" ]; then
    printf '%s\n' "$got_line" > "$golden"
    echo "  AVISO: $golden nao existia — gravado agora com o hash atual:"
    echo "  $got_line"
else
    want_hash=$(awk '{print $1}' "$golden")
    if [ "$got_hash" != "$want_hash" ]; then
        echo "FAIL: build/mc2.o diverge do golden $golden" >&2
        echo "  esperado: $want_hash" >&2
        echo "  obtido:   $got_hash" >&2
        echo "  (se a mudanca em src/*.mc ou no codegen foi proposital, revise o" >&2
        echo "  diff de --dump-asm e regrave o golden — ver tests/golden/README.md)" >&2
        exit 1
    fi
    echo "  ok: $got_hash confere com $golden"
fi

t_total1=$(now)
echo "=== tempo total do bootstrap: $(dt "$t_total0" "$t_total1")s ==="

echo ""
echo "=== scripts/test.sh build/mc2 ==="
if ! scripts/test.sh build/mc2; then
    echo "FAIL: scripts/test.sh build/mc2" >&2
    fails=1
fi

echo ""
echo "=== scripts/check-obj.sh build/mc1 build/mc2 ==="
if ! scripts/check-obj.sh build/mc1 build/mc2; then
    echo "FAIL: scripts/check-obj.sh build/mc1 build/mc2" >&2
    fails=1
fi

[ "$fails" -eq 0 ]
