#!/bin/sh
# check-surface.sh [MC0] [MC1] — acceptance criterion for M10 (Tier 2) and M12 (Tier 3).
#
# Wires up the surface demo by swapping src/user.mc's include for
# lib/user_demo.mc, rebuilds the compiler with mc0 (build/mc1s), and for each
# tests/*.mc compares the object from the `arm64-surface` backend (written in
# .mc, outside the compiler) with the one from the built-in `macho` backend.
# Byte-for-byte identity is the criterion. Then it wires up lib/user_tokadd.mc
# (a user_init that only calls tok_add) and checks that the core keywords' ids
# stay put. The original src/user.mc is always restored, no matter what fails.
#
# M12 (Tier 3): at the end comes the case that does NOT touch src/user.mc — a
# taught compiler that is its own file (lib/mc_syntax_demo.mc = src/core.mc +
# the user's module). MC1 compiles it with --exe, and the resulting binary
# compiles lib/syntax_demo_test.mc (which uses `unless`, `enum`, and `bool`),
# also with --exe; the program has to exit 42, and the default compiler has to
# refuse the same source.
#
# M21.5: and `on_stmt` (a counter over every statement, core or taught) and
# `syntax_stmt("{")` reaching the blocks parse_function and a `#rule` block hole
# parse. Both have to be inert: the AST from `main` on is what the default
# compiler prints.
#
# M21: the same taught compiler now also carries `bits`/`pipe` (syntax_expr),
# `.+`/`~>` (syntax_infix) and `tmpl`/`make` (p_skip_balanced + p_push_source +
# p_subst_* + p_resplit_punct). One case per hook, the four tests/err/ cases with
# their exact message, the duplicate registration refused at user_init time, the
# demo test compiled twice byte for byte, and the inertness check of 6(5).
mc0="${1:-build/mc0}"
mc1="${2:-build/mc1}"

for mc in "$mc0" "$mc1"; do
    if [ ! -x "$mc" ]; then
        echo "FAIL: compiler '$mc' not found or not executable"
        exit 1
    fi
done

user="src/user.mc"
save="${TMPDIR:-/tmp}/user.mc.$$"
tmp="${TMPDIR:-/tmp}/check-surface.$$"
mkdir -p "$tmp"
cp "$user" "$save"
# restore the repository to how it was, no matter what happens
trap 'cp "$save" "$user"; rm -f "$save"; rm -rf "$tmp"' EXIT INT TERM

sed 's|user_default\.mc|user_demo.mc|' "$save" > "$user"
if ! grep -q 'user_demo\.mc' "$user"; then
    echo "FAIL: could not wire lib/user_demo.mc into $user"
    exit 1
fi

mkdir -p build
if ! msg=$("$mc0" src/mc.mc -o build/mc1s.o 2>&1); then
    echo "FAIL: compiling src/mc.mc with the demo wired in: $msg"
    exit 1
fi
if ! msg=$(scripts/link.sh build/mc1s build/mc1s.o 2>&1); then
    echo "FAIL: linking build/mc1s: $msg"
    exit 1
fi
cp "$save" "$user"          # the demo is already baked into build/mc1s: release the source

fails=0
total=0
for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    total=$((total + 1))
    a="$tmp/$name.surface.o"
    b="$tmp/$name.macho.o"

    if ! msg=$(build/mc1s --backend=arm64-surface "$f" -o "$a" 2>&1); then
        echo "FAIL $name (arm64-surface: $msg)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$(build/mc1s "$f" -o "$b" 2>&1); then
        echo "FAIL $name (macho: $msg)"; fails=$((fails + 1)); continue
    fi
    if ! cmp "$a" "$b" > "$tmp/d" 2>&1; then
        echo "FAIL $name ($(cat "$tmp/d"))"
        cmp -l "$a" "$b" 2>/dev/null | head -8
        fails=$((fails + 1)); continue
    fi
    echo "ok $name"
done

echo "$((total - fails))/$total objects identical (arm64-surface vs macho)"

# the demo pass has to alter the AST of tests/061-pass.mc, and no other
"$mc0"        --dump-ast tests/061-pass.mc > "$tmp/ast-sem" 2>&1
build/mc1s    --dump-ast tests/061-pass.mc > "$tmp/ast-com" 2>&1
if cmp -s "$tmp/ast-sem" "$tmp/ast-com"; then
    echo "FAIL: the demo pass did not change --dump-ast of tests/061-pass.mc"
    fails=$((fails + 1))
else
    echo "ok pass_demo changes --dump-ast of tests/061-pass.mc"
fi
for f in tests/*.mc; do
    [ "$f" = "tests/061-pass.mc" ] && continue
    "$mc0"     --dump-ast "$f" > "$tmp/s" 2>&1
    build/mc1s --dump-ast "$f" > "$tmp/c" 2>&1
    if ! cmp -s "$tmp/s" "$tmp/c"; then
        echo "FAIL: the pass changed --dump-ast of $f (expected only 061-pass)"
        fails=$((fails + 1))
    fi
done

# Init order: a user_init that calls tok_add must not shift the core
# keywords' ids (K_U8..K_EXTERN = 256..269). See lib/user_tokadd.mc.
sed 's|user_default\.mc|user_tokadd.mc|' "$save" > "$user"
if ! grep -q 'user_tokadd\.mc' "$user"; then
    echo "FAIL: could not wire lib/user_tokadd.mc into $user"
    exit 1
fi
if ! msg=$("$mc0" src/mc.mc -o build/mc1t.o 2>&1); then
    echo "FAIL: compiling src/mc.mc with user_tokadd: $msg"
    fails=$((fails + 1))
elif ! msg=$(scripts/link.sh build/mc1t build/mc1t.o 2>&1); then
    echo "FAIL: linking build/mc1t: $msg"
    fails=$((fails + 1))
elif ! msg=$(build/mc1t tests/001-return42.mc -o "$tmp/t.o" 2>&1); then
    echo "FAIL: a user_init with tok_add broke the core: $msg"
    fails=$((fails + 1))
elif ! msg=$(scripts/link.sh "$tmp/t" "$tmp/t.o" 2>&1); then
    echo "FAIL: linking tests/001 with user_tokadd: $msg"
    fails=$((fails + 1))
else
    "$tmp/t"
    rc=$?
    if [ "$rc" != "42" ]; then
        echo "FAIL: tests/001 with user_tokadd returned $rc, expected 42"
        fails=$((fails + 1))
    else
        echo "ok user_init with tok_add does not shift the core ids (tests/001 = 42)"
    fi
fi
cp "$save" "$user"

# ---- Tier 3 (M12): syntax taught through code, without touching src/ ----
# 1. MC1 compiles the taught compiler (src/core.mc + lib/user_syntax_demo.mc)
# 2. the taught compiler compiles the test that uses unless/enum/bool
# 3. the test runs and exits 42
demo="build/mc-syntax-demo"
rm -f "$demo"
if ! msg=$("$mc1" --exe lib/mc_syntax_demo.mc -o "$demo" 2>&1); then
    echo "FAIL: compiling lib/mc_syntax_demo.mc: $msg"
    fails=$((fails + 1))
elif ! msg=$(codesign --verify --verbose=4 "$demo" 2>&1); then
    echo "FAIL: signature of $demo: $msg"
    fails=$((fails + 1))
elif ! msg=$("$demo" --exe lib/syntax_demo_test.mc -o "$tmp/sdt" 2>&1); then
    echo "FAIL: the taught compiler did not compile lib/syntax_demo_test.mc: $msg"
    fails=$((fails + 1))
else
    "$tmp/sdt"
    rc=$?
    if [ "$rc" != "42" ]; then
        echo "FAIL: lib/syntax_demo_test.mc returned $rc, expected 42"
        fails=$((fails + 1))
    else
        echo "ok syntax/syntax_stmt/type_alias: mc_syntax_demo compiles the test (exit 42)"
    fi
fi

# the default compiler has to REFUSE the same source: the syntax belongs to
# the module, not to the core. `enum` there is just an identifier where a type is expected.
if msg=$("$mc1" lib/syntax_demo_test.mc -o "$tmp/sdt.o" 2>&1); then
    echo "FAIL: the default compiler accepted lib/syntax_demo_test.mc"
    fails=$((fails + 1))
else
    echo "ok the default compiler rejects the same source ($msg)"
fi

# ---- M21: one case per hook ----
# Each case is a whole program compiled by the taught compiler with --exe and
# run: the exit code is the assertion. They are separate from
# lib/syntax_demo_test.mc on purpose — that file proves the hooks compose, these
# prove each one on its own, so a failure names the hook that broke.
hook_case() {                       # hook_case NAME EXPECTED-EXIT SOURCE
    name="$1"; want="$2"; src="$3"
    printf '%s\n' "$src" > "$tmp/$name.mc"
    if ! msg=$("$demo" --exe "$tmp/$name.mc" -o "$tmp/$name" 2>&1); then
        echo "FAIL $name (compilation: $msg)"; fails=$((fails + 1)); return
    fi
    "$tmp/$name"
    rc=$?
    if [ "$rc" != "$want" ]; then
        echo "FAIL $name (exit $rc, expected $want)"; fails=$((fails + 1)); return
    fi
    echo "ok $name"
}

hook_case syntax_expr-bits 42 'i64 main() { return bits u32 + 10; }'
hook_case syntax_expr-pipe 42 'i64 d(i64 x) { return x * 2; }
i64 main() { return pipe(21, d); }'
hook_case syntax_infix-sat 42 'i64 main() { return 50 .+ 60 - 58; }'
hook_case syntax_infix-field 42 'u64 b[4];
i64 main() { uptr p = b; p ~> len = 42; return p ~> len; }'
hook_case p_skip_balanced 42 'tmpl t<T, N> { T a[N]; return N + bits T / 8; }
make t<i64, 3>;
i64 main() { return t__i64__3() * 4 - 2; }'
hook_case p_resplit_punct 42 'tmpl t<T, N> { T a[N]; return N + bits T / 8; }
make t<i64, 3>;
make t<i64, sum<1, 2>>;
i64 main() { return t__i64__3() * 4 - 2; }'
hook_case p_subst_hygiene 42 'tmpl t<T, N> { i64 T_tag = N; uptr k = "T is T"; return T_tag + ld8(k); }
make t<i64, 2>;
i64 main() { return t__i64__2() - 44; }'

# ---- M21.5: on_stmt and the block dispatch ----
# The counts are RELATIVE (stmtcount - base) on purpose: the module pushes its
# own runtime as a second source at user_init, so the absolute count depends on
# that source and would break the test for an unrelated reason.
#
# on_stmt: four statements between the two reads -- the `i64 base = ...` itself,
# two declarations and one assignment.
hook_case on_stmt-count 42 'i64 main() { i64 base = stmtcount; i64 a = 1; i64 b = 2; a = a + b;
                             return stmtcount - base + 38; }'
# ordering: `unless` is a TAUGHT statement, and the node the hook counted is the
# N_IF its syntax_stmt handler built -- the handler runs first, the hook second.
hook_case on_stmt-order 42 'i64 main() { i64 base = ifcount; i64 a = 1; unless (a > 5) { a = 42; }
                             return ifcount - base + a - 1; }'
# parse_block through syntax_stmt("{"): the two `while` bodies are `block $b`
# holes of a `#rule` in <prelude>, and nesting 3 is only reachable if those
# holes come through the module. Without the M21.5 dispatch the answer is 1.
hook_case on_stmt-blockdepth 42 '#include <prelude>
i64 main() { i64 i = 0; while (i < 3) { while (i < 2) { i = i + 1; } i = i + 1; }
             return blockdepth + i + 36; }'

# ...and it rewrites NOTHING: the module's runtime is one leading declaration,
# so from `main` on the taught compiler's --dump-ast has to be what the default
# compiler prints for the same file. This covers on_stmt returning its node
# unchanged AND sd_block building the same N_BLOCK the core would have.
printf 'i64 main() { i64 a = 1; if (a) { a = 2; } return a; }\n' > "$tmp/inert-stmt.mc"
"$mc1"  --dump-ast "$tmp/inert-stmt.mc" > "$tmp/inert-stmt.a" 2>&1
"$demo" --dump-ast "$tmp/inert-stmt.mc" 2>&1 | sed -n '/^FUNC type=i64 name=main/,$p' > "$tmp/inert-stmt.b"
if cmp -s "$tmp/inert-stmt.a" "$tmp/inert-stmt.b"; then
    echo "ok on_stmt + syntax_stmt(\"{\") leave the AST byte for byte unchanged"
else
    echo "FAIL on_stmt/block dispatch changed the AST"
    diff -u "$tmp/inert-stmt.a" "$tmp/inert-stmt.b" | sed -n '1,20p'
    fails=$((fails + 1))
fi

# p_start/p_depth: the module drives top_add(parse_top()) until the pushed
# source is exhausted, so a `make` inside a unit produces a real declaration
if "$demo" --dump-ast "$tmp/p_skip_balanced.mc" 2>&1 | grep -q 'name=t__i64__3'; then
    echo "ok p_depth: the instantiation reached the unit as a declaration"
else
    echo "FAIL p_depth: t__i64__3 is not in the unit"
    fails=$((fails + 1))
fi

# decision 7.2: --dump-rules lists the operators, with the handler marked
if "$demo" --dump-rules "$tmp/syntax_infix-sat.mc" 2>&1 \
   | grep -q '^infix \.+ prec 9 left handler$'; then
    echo "ok --dump-rules lists the taught operator with its precedence"
else
    echo "FAIL --dump-rules does not list the taught operator"
    fails=$((fails + 1))
fi

# ---- M21: the tests/err/ cases, with their exact message ----
err_case() {                        # err_case FILE EXPECTED-MESSAGE
    f="$1"; want="$2"
    if msg=$("$demo" "$f" -o "$tmp/err.o" 2>&1); then
        echo "FAIL $f (the taught compiler accepted it)"; fails=$((fails + 1)); return
    fi
    if [ "$msg" != "$want" ]; then
        echo "FAIL $f"
        echo "  expected: $want"
        echo "  got:      $msg"
        fails=$((fails + 1)); return
    fi
    echo "ok $f ($msg)"
}

err_case tests/err/063-tmpl-attrib.mc \
    "slot__i64__0 instantiated from tests/err/063-tmpl-attrib.mc:15:2: array size must be a positive constant"
err_case tests/err/064-expr-noadvance.mc \
    "tests/err/064-expr-noadvance.mc:7: syntax_expr handler consumed no tokens: nop"
err_case tests/err/065-expr-nonode.mc \
    "tests/err/065-expr-nonode.mc:6: syntax_expr handler produced no expression: nil"
err_case tests/err/066-infix-drops-handler.mc \
    "tests/err/066-infix-drops-handler.mc:12: unknown name"

# determinism: the same source compiled twice by the same compiler is the same object
"$demo" lib/syntax_demo_test.mc -o "$tmp/sdt1.o" 2>/dev/null
"$demo" lib/syntax_demo_test.mc -o "$tmp/sdt2.o" 2>/dev/null
if cmp -s "$tmp/sdt1.o" "$tmp/sdt2.o"; then
    echo "ok the demo test compiled twice gives the same object"
else
    echo "FAIL the demo test is not deterministic"
    fails=$((fails + 1))
fi

# decision 7.3: teaching the same operator twice is refused at user_init time,
# before the first token of any source is read
sed 's|user_default\.mc|user_dupop.mc|' "$save" > "$user"
if ! grep -q 'user_dupop\.mc' "$user"; then
    echo "FAIL: could not wire lib/user_dupop.mc into $user"
    exit 1
fi
if ! msg=$("$mc0" src/mc.mc -o build/mc1d.o 2>&1); then
    echo "FAIL: compiling src/mc.mc with user_dupop: $msg"
    fails=$((fails + 1))
elif ! msg=$(scripts/link.sh build/mc1d build/mc1d.o 2>&1); then
    echo "FAIL: linking build/mc1d: $msg"
    fails=$((fails + 1))
elif msg=$(build/mc1d tests/001-return42.mc -o "$tmp/d.o" 2>&1); then
    echo "FAIL: a duplicate syntax_infix was accepted"
    fails=$((fails + 1))
elif [ "$msg" != "mc: operator already taught: .+" ]; then
    echo "FAIL: duplicate syntax_infix said '$msg'"
    fails=$((fails + 1))
else
    echo "ok duplicate syntax_infix refused at user_init ($msg)"
fi
cp "$save" "$user"

# ---- M21 acceptance 6(5): inert by construction ----
# With nothing registered, the compiler has to produce exactly what a compiler
# with no Tier 3 at all produces. `$mc0` IS that compiler: the frozen C seed
# knows nothing about syntax_expr, syntax_infix or a pushed source.
inert=0
for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    "$mc0" "$f" -o "$tmp/i0.o" 2>/dev/null
    "$mc1" "$f" -o "$tmp/i1.o" 2>/dev/null
    cmp -s "$tmp/i0.o" "$tmp/i1.o" || { echo "FAIL inert: object of $name"; inert=$((inert + 1)); }
    "$mc0" --dump-ast "$f" > "$tmp/i0.ast" 2>&1
    "$mc1" --dump-ast "$f" > "$tmp/i1.ast" 2>&1
    cmp -s "$tmp/i0.ast" "$tmp/i1.ast" || { echo "FAIL inert: --dump-ast of $name"; inert=$((inert + 1)); }
done
if [ "$inert" -eq 0 ]; then
    echo "ok inert: untaught objects and --dump-ast identical to the pre-Tier-3 seed"
else
    fails=$((fails + inert))
fi

[ "$fails" -eq 0 ]
