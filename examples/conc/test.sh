#!/bin/sh
# test.sh — acceptance test for `examples/conc`, concurrency taught to `lx` by a
# second module stacked on examples/lang's.
#
#   sh examples/conc/test.sh          # from the repository root
#   make check-conc                   # the same, from the root Makefile
#
# Five steps:
#
#   1. `mc build --compiler-only` reads mc.toml and assembles the taught
#      compiler (build/mc-conc) out of `<mc/core>` + ../lang/lang.mc + conc.mc,
#      printing its path; then that binary compiles main.lx into a signed
#      executable (build/conc-demo) with `build --entry-only`.
#   2. every tests/NN-*.lx is compiled by that binary with --exe and run under a
#      TIMEOUT: a missed unlock or a missed wake is a hang, not a wrong number,
#      so a test that stops making progress has to fail rather than wedge the
#      suite. `expect-error` compares the compiler's stderr instead;
#      `expect-panic` compares the PROGRAM's stderr, which is how the deadlock
#      case asserts both its message and exit 70.
#   3. the same source compiled twice gives a byte-identical object and a
#      byte-identical executable, and `--dump-asm` diffs empty (M31 section 6.6).
#   4. the default compiler refuses the same source -- the syntax belongs to the
#      modules -- but still compiles lib/*.mc, which is plain core `.mc`.
#   5. the five words of docs/specs/M31.md section 8.3 -- `spawn`, `await`,
#      `intent`, `chan`, `lock` -- are reserved for the whole program.
#
# Depends only on ../../build/mc1 (built if missing) and codesign.

root=$(cd "$(dirname "$0")/../.." && pwd)
dir="$root/examples/conc"
mc="$root/build/mc1"
mcconc="$dir/build/mc-conc"
# M37: the platform layer moved into lib/macos and lib/linux, so the
# single-file CLI needs the same extra `#include` root that [include].paths
# gives `mc build`. A Linux run of this example would pass lib/linux instead
# (examples/conc/mc.linux.toml).
plat="--include=$dir/lib/macos"
demo="$dir/build/conc-demo"
tmp="/tmp/mc_conc_test_$$"
limit=20
fails=0
ran=0

cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM
mkdir -p "$tmp"

fail() {
    echo "  FAIL  $1"
    shift
    for line in "$@"; do echo "        $line"; done
    fails=$((fails + 1))
}

# runs a program with a hard limit, leaving stdout in $tmp/out and stderr in
# $tmp/err. macOS has no timeout(1); this is the portable shape.
run_limited() {
    "$@" > "$tmp/out" 2> "$tmp/err" &
    pid=$!
    ( sleep "$limit"; kill -9 "$pid" 2>/dev/null ) > /dev/null 2>&1 &
    killer=$!
    wait "$pid"
    st=$?
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null
    return $st
}

echo "== building the taught compiler (mc build --compiler-only) =="
if [ ! -x "$mc" ]; then
    make -C "$root" mc1 || { echo "FAIL: make mc1"; exit 1; }
fi
"$mc" build "$dir" --compiler-only || { echo "FAIL: mc build --compiler-only"; exit 1; }
[ -x "$mcconc" ] || { echo "FAIL: mc build did not produce $mcconc"; exit 1; }
echo "== main.lx, compiled by that compiler (build --entry-only) =="
"$mcconc" build "$dir" --entry-only || { echo "FAIL: mc-conc build --entry-only"; exit 1; }
[ -x "$demo" ] || { echo "FAIL: mc-conc did not produce $demo"; exit 1; }
echo "  ok    $mcconc ($(wc -c < "$mcconc" | tr -d ' ') bytes)"
echo "  ok    $demo ($(wc -c < "$demo" | tr -d ' ') bytes)"

echo "== main.lx =="
if run_limited "$demo"; then
    got=$(cat "$tmp/out")
    exp=$(printf 'channel\n5050\nparallel sum\n31999996000000\nawait chain\n50\nlive\n0')
    if [ "$got" = "$exp" ]; then
        echo "  ok    build/conc-demo"
        echo "$got" | sed 's|^|        |'
    else
        fail "build/conc-demo" "expected: $exp" "got: $got"
    fi
else
    fail "build/conc-demo" "exit $? (killed after ${limit}s means it hung)"
fi

echo "== tests =="
cd "$dir" || exit 1
for t in tests/[0-9]*.lx; do
    name=$(basename "$t" .lx)
    ran=$((ran + 1))
    experr=$(sed -n 's|^// expect-error: ||p' "$t")
    if [ -n "$experr" ]; then
        got=$("$mcconc" "$plat" --exe "$t" -o "$tmp/$name" 2>&1 >/dev/null)
        if [ "$got" = "$experr" ]; then
            echo "  ok    $name (error)"
            echo "        $got"
        else
            fail "$name (error)" "expected: $experr" "got:      $got"
        fi
        continue
    fi
    expout=$(sed -n 's|^// expect-stdout: ||p' "$t")
    exppanic=$(sed -n 's|^// expect-panic: ||p' "$t")
    expexit=$(sed -n 's|^// expect-exit: ||p' "$t")
    [ -n "$expexit" ] || expexit=0
    rm -f "$tmp/$name"
    if ! err=$("$mcconc" "$plat" --exe "$t" -o "$tmp/$name" 2>&1); then
        fail "$name (compile)" "$err"
        continue
    fi
    if ! codesign --verify --verbose=1 "$tmp/$name" 2>/dev/null; then
        fail "$name (codesign)" "the ad-hoc signature does not verify"
        continue
    fi
    run_limited "$tmp/$name"
    st=$?
    got=$(cat "$tmp/out")
    goterr=$(cat "$tmp/err")
    if [ "$st" -eq 137 ]; then
        fail "$name" "killed after ${limit}s: the program made no progress"
        continue
    fi
    if [ "$st" -ne "$expexit" ]; then
        fail "$name" "expected exit $expexit, got $st" "stdout:" "$got" "stderr:" "$goterr"
        continue
    fi
    if [ -n "$exppanic" ] && [ "$goterr" != "$exppanic" ]; then
        fail "$name" "expected stderr: $exppanic" "got stderr:      $goterr"
        continue
    fi
    if [ "$got" != "$expout" ]; then
        fail "$name" "expected stdout:" "$expout" "got stdout:" "$got"
        continue
    fi
    if [ -n "$exppanic" ]; then
        echo "  ok    $name (exit $st, $goterr)"
    else
        echo "  ok    $name (exit $st, $(printf '%s' "$got" | grep -c '') lines)"
    fi
done

echo "== the same source compiled twice is byte for byte the same =="
"$mcconc" "$plat" tests/01-await-chain.lx -o "$tmp/a.o" || { echo "FAIL: object 1"; exit 1; }
"$mcconc" "$plat" tests/01-await-chain.lx -o "$tmp/b.o" || { echo "FAIL: object 2"; exit 1; }
if cmp "$tmp/a.o" "$tmp/b.o"; then
    echo "  ok    object: $(wc -c < "$tmp/a.o" | tr -d ' ') bytes, identical"
else
    fail "determinism" "two compilations of the same source disagree"
fi
mkdir -p "$tmp/x" "$tmp/y"
"$mcconc" "$plat" --exe tests/01-await-chain.lx -o "$tmp/x/prog" || { echo "FAIL: exe 1"; exit 1; }
"$mcconc" "$plat" --exe tests/01-await-chain.lx -o "$tmp/y/prog" || { echo "FAIL: exe 2"; exit 1; }
if cmp "$tmp/x/prog" "$tmp/y/prog"; then
    echo "  ok    executable: $(wc -c < "$tmp/x/prog" | tr -d ' ') bytes, identical"
else
    fail "determinism" "two --exe builds of the same source disagree"
fi
"$mcconc" "$plat" --dump-asm tests/01-await-chain.lx > "$tmp/a.s" || { echo "FAIL: asm 1"; exit 1; }
"$mcconc" "$plat" --dump-asm tests/01-await-chain.lx > "$tmp/b.s" || { echo "FAIL: asm 2"; exit 1; }
if diff -q "$tmp/a.s" "$tmp/b.s" > /dev/null; then
    echo "  ok    --dump-asm: $(wc -l < "$tmp/a.s" | tr -d ' ') lines, no diff"
else
    fail "determinism" "--dump-asm is not reproducible"
fi

echo "== the lowering is in the module, not in the core =="
for sym in _it_new _it_arg _it_submit _it_take _it_go _mx_lock _mx_unlock _conc_boot; do
    if grep -q "^$sym:" "$tmp/a.s"; then
        echo "  ok    $sym"
    else
        fail "--dump-asm" "$sym is not in the generated assembly"
    fi
done
echo "  -- the calls main() makes, in order (conc_boot comes from the pass):"
sed -n '/^_main:/,/^  ret/p' "$tmp/a.s" | grep "bl _it_\|bl _conc_boot" \
    | sed -n '1,6p' | sed 's|^|        |'

echo "== the syntax belongs to the modules, not to the language =="
got=$("$mc" "$plat" tests/01-await-chain.lx -o "$tmp/none.o" 2>&1 >/dev/null)
exp="lib/prelude.lx:27: type expected at top level"
if [ "$got" = "$exp" ]; then
    echo "  ok    the default compiler refuses the same source"
    echo "        $got"
else
    fail "default compiler" "expected: $exp" "got:      $got"
fi
# the runtime, on the other hand, is plain core `.mc` and the default compiler
# takes it unchanged: threads, channels and intents are program code
if "$mc" "$plat" lib/conc_rt.mc -o "$tmp/rt.o" 2>/dev/null; then
    echo "  ok    the default compiler still compiles lib/conc_rt.mc"
else
    fail "default compiler" "lib/conc_rt.mc is supposed to be plain core .mc"
fi

echo "== the five reserved words =="
# docs/specs/M31.md section 8.3: `spawn`, `await`, `intent`, `chan` and `lock`
# are words of the whole program, exactly like every other Tier 3 registration
mkdir -p "$tmp/w"
for w in spawn await intent chan lock; do
    printf '#include "%s/lib/prelude.lx"\nfn main() -> i64 { i64 %s = 1; return %s; }\n' \
        "$dir" "$w" "$w" > "$tmp/w/r.lx"
    got=$("$mcconc" "$plat" --exe "$tmp/w/r.lx" -o "$tmp/w/r" 2>&1 >/dev/null)
    exp="$tmp/w/r.lx:2: name reserved by a syntax/type_alias registration: $w"
    if [ "$got" = "$exp" ]; then
        echo "  ok    $w is reserved program-wide"
    else
        fail "reserved word $w" "expected: $exp" "got:      $got"
    fi
done

if [ "$fails" -ne 0 ]; then
    echo "== FAILED: $fails check(s), $ran tests =="
    exit 1
fi
echo "== ok: $ran tests, main.lx, determinism and --dump-asm =="
exit 0
