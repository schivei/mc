#!/bin/sh
# test.sh — acceptance test for `examples/lang`, the `lx` language taught to
# `mc` by a prelude.
#
#   sh examples/lang/test.sh          # from the repository root
#   make check-lang                   # the same, from the root Makefile
#
# Three steps:
#
#   1. `mc build` reads mc.toml, assembles the taught compiler (build/mc-lang)
#      out of lang_core.mc + lang.mc, and uses it to compile main.lx into a
#      signed executable (build/lang-demo). There is no `--compiler-only` flag
#      in this checkout, so the compiler is built by the same `mc build` that
#      compiles the entry -- see the report's core gaps.
#   2. every tests/NN-*.lx is compiled by that binary with --exe and run; the
#      headers say what it must print and what it must exit with. A test whose
#      header carries `expect-error` is compiled and its stderr compared instead.
#   3. --dump-asm over the sample has to show the mangled instantiation and its
#      vtable, which is what proves the generic really produced a concrete class.
#
# Depends only on ../../build/mc1 (built if missing) and codesign.

root=$(cd "$(dirname "$0")/../.." && pwd)
dir="$root/examples/lang"
mc="$root/build/mc1"
mclang="$dir/build/mc-lang"
demo="$dir/build/lang-demo"
tmp="/tmp/mc_lang_test_$$"
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

echo "== building the taught compiler and main.lx (mc build) =="
if [ ! -x "$mc" ]; then
    make -C "$root" mc1 || { echo "FAIL: make mc1"; exit 1; }
fi
"$mc" build "$dir" || { echo "FAIL: mc build"; exit 1; }
[ -x "$mclang" ] || { echo "FAIL: mc build did not produce $mclang"; exit 1; }
[ -x "$demo" ]   || { echo "FAIL: mc build did not produce $demo"; exit 1; }
echo "  ok    $mclang ($(wc -c < "$mclang" | tr -d ' ') bytes)"
echo "  ok    $demo ($(wc -c < "$demo" | tr -d ' ') bytes)"

echo "== main.lx =="
got=$("$demo"); st=$?
exp=$(printf '13\n25\n12\nbox')
if [ "$got" = "$exp" ] && [ "$st" -eq 0 ]; then
    echo "  ok    build/lang-demo"
    echo "$got" | sed 's|^|        |'
else
    fail "build/lang-demo" "expected: $exp" "got: $got (exit $st)"
fi

echo "== tests =="
cd "$dir" || exit 1
for t in tests/[0-9]*.lx; do
    name=$(basename "$t" .lx)
    ran=$((ran + 1))
    experr=$(sed -n 's|^// expect-error: ||p' "$t")
    if [ -n "$experr" ]; then
        got=$("$mclang" --exe "$t" -o "$tmp/$name" 2>&1 >/dev/null)
        if [ "$got" = "$experr" ]; then
            echo "  ok    $name (error)"
            echo "        $got"
        else
            fail "$name (error)" "expected: $experr" "got:      $got"
        fi
        continue
    fi
    expout=$(sed -n 's|^// expect-stdout: ||p' "$t")
    expexit=$(sed -n 's|^// expect-exit: ||p' "$t")
    [ -n "$expexit" ] || expexit=0
    rm -f "$tmp/$name"
    if ! err=$("$mclang" --exe "$t" -o "$tmp/$name" 2>&1); then
        fail "$name (compile)" "$err"
        continue
    fi
    if ! codesign --verify --verbose=1 "$tmp/$name" 2>/dev/null; then
        fail "$name (codesign)" "the ad-hoc signature does not verify"
        continue
    fi
    got=$("$tmp/$name"); st=$?
    if [ "$got" = "$expout" ] && [ "$st" -eq "$expexit" ]; then
        echo "  ok    $name (exit $st, $(printf '%s' "$got" | grep -c '') lines)"
    else
        fail "$name" "expected exit $expexit, got $st" \
             "expected stdout:" "$expout" "got stdout:" "$got"
    fi
done

echo "== mangled names and vtables in --dump-asm =="
asm="$tmp/sample.s"
"$mclang" --dump-asm tests/12-sample.lx > "$asm" || { echo "FAIL: --dump-asm"; exit 1; }
for sym in _Box__Circle__4_push _Box__Circle__4_total _Box__Circle__4_vt_init \
           _Box__Circle__4_release _Circle_vt_init _Circle_area; do
    if grep -q "^$sym:" "$asm"; then
        echo "  ok    $sym"
    else
        fail "--dump-asm" "$sym is not in the generated assembly"
    fi
done
echo "  -- the vtable of the instantiation, filled by Box__Circle__4_vt_init:"
sed -n '/^_Box__Circle__4_vt_init:/,/^  ret/p' "$asm" | sed 's|^|        |'

echo "== the same source compiled twice is byte for byte the same object =="
"$mclang" tests/12-sample.lx -o "$tmp/a.o" || { echo "FAIL: object 1"; exit 1; }
"$mclang" tests/12-sample.lx -o "$tmp/b.o" || { echo "FAIL: object 2"; exit 1; }
if cmp "$tmp/a.o" "$tmp/b.o"; then
    echo "  ok    $(wc -c < "$tmp/a.o" | tr -d ' ') bytes, identical"
else
    fail "determinism" "two compilations of the same source disagree"
fi

echo "== the syntax belongs to the module, not to the language =="
got=$("$mc" tests/12-sample.lx -o "$tmp/none.o" 2>&1 >/dev/null)
exp="lib/prelude.lx:23: type expected at top level"
if [ "$got" = "$exp" ]; then
    echo "  ok    the default compiler refuses the same source"
    echo "        $got"
else
    fail "default compiler" "expected: $exp" "got:      $got"
fi
# lib/rt.mc, on the other hand, is plain core `.mc` and the default compiler
# takes it unchanged: the runtime is program code, not language
if "$mc" lib/rt.mc -o "$tmp/rt.o" 2>/dev/null; then
    echo "  ok    the default compiler still compiles lib/rt.mc"
else
    fail "default compiler" "lib/rt.mc is supposed to be plain core .mc"
fi

echo "== rules and operators the module taught (--dump-rules) =="
"$mclang" --dump-rules tests/12-sample.lx | sed -n '1,8p' | sed 's|^|        |'

if [ "$fails" -ne 0 ]; then
    echo "== FAILED: $fails check(s), $ran tests =="
    exit 1
fi
echo "== ok: $ran tests, main.lx, --dump-asm and --dump-rules =="
exit 0
