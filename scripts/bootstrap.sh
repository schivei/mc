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
    echo "FAIL: '$mc0' not found or not executable (run 'make stage0')" >&2
    exit 1
fi
if [ ! -f "src/mc.mc" ]; then
    echo "FAIL: src/mc.mc not found" >&2
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

# step DESCRIPTION CMD... — runs CMD, times it, fails with a clear message if
# the exit code isn't 0. Doesn't use set -e: the 'if' itself captures the status.
step() {
    desc="$1"; shift
    t0=$(now)
    if ! "$@" >"$tmp_out" 2>"$tmp_err"; then
        rc=$?
        echo "FAIL: $desc (exit $rc)" >&2
        echo "--- command: $* ---" >&2
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

size_of() {
    # size in bytes, portable (BSD stat on macOS uses -f%z; GNU uses -c%s).
    wc -c < "$1" | tr -d ' '
}

echo "=== M7 -- fixed point: mc0 -> mc1 -> mc2 -> mc3 ==="

echo "-- stage 1: build/mc0 src/mc.mc -> build/mc1.o --"
step "mc0 compiles mc.mc"      "$mc0" src/mc.mc -o build/mc1.o
echo "  size build/mc1.o: $(size_of build/mc1.o) bytes"
step "link build/mc1"         scripts/link.sh build/mc1 build/mc1.o

echo "-- stage 2: build/mc1 src/mc.mc -> build/mc2.o --"
step "mc1 compiles mc.mc"      build/mc1 src/mc.mc -o build/mc2.o
echo "  size build/mc2.o: $(size_of build/mc2.o) bytes"
step "link build/mc2"         scripts/link.sh build/mc2 build/mc2.o

echo "-- stage 3: build/mc2 src/mc.mc -> build/mc3.o --"
step "mc2 compiles mc.mc"      build/mc2 src/mc.mc -o build/mc3.o
echo "  size build/mc3.o: $(size_of build/mc3.o) bytes"

echo "-- fixed-point criterion: cmp build/mc2.o build/mc3.o --"
if ! cmp build/mc2.o build/mc3.o; then
    echo "FAIL: build/mc2.o != build/mc3.o -- no fixed point" >&2
    echo "diagnosis: diff <(build/mc1 --dump-asm src/mc.mc) <(build/mc2 --dump-asm src/mc.mc)" >&2
    echo "then bisect by file/function (see docs/bootstrap.md)" >&2
    exit 1
fi
echo "  ok: build/mc2.o == build/mc3.o"

echo "-- golden SHA-256 of build/mc2.o --"
got_line=$(shasum -a 256 build/mc2.o)
got_hash=$(printf '%s\n' "$got_line" | awk '{print $1}')
mkdir -p "$(dirname "$golden")"
if [ ! -f "$golden" ]; then
    printf '%s\n' "$got_line" > "$golden"
    echo "  WARNING: $golden did not exist -- recorded now with the current hash:"
    echo "  $got_line"
else
    want_hash=$(awk '{print $1}' "$golden")
    if [ "$got_hash" != "$want_hash" ]; then
        echo "FAIL: build/mc2.o diverges from the golden $golden" >&2
        echo "  expected: $want_hash" >&2
        echo "  got:      $got_hash" >&2
        echo "  (if the change in src/*.mc or in codegen was intentional, review the" >&2
        echo "  --dump-asm diff and rewrite the golden -- see tests/golden/README.md)" >&2
        exit 1
    fi
    echo "  ok: $got_hash matches $golden"
fi

t_total1=$(now)
echo "=== total bootstrap time: $(dt "$t_total0" "$t_total1")s ==="

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
