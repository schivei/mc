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
#
# M41.5 (second follow-up): syntax_infix on a CORE operator. lib/mc_coreop.mc
# teaches `+` (at the core's own precedence) and `*` (at 3, which is not) to lower
# to calls the PROGRAM provides; the answers change, --dump-rules reports both
# with `handler`, a `#infix` in the source still drops the handler, and a second
# registration on `+` is still refused.
#
# M31 (docs/specs/M31.md § 2): `widen` (decl_find + decl_ret + decl_nparams +
# decl_param_type), `guard` (on_jump), four more tests/err/ cases, and the ABI
# contract of docs/reference/objects.md § 4 -- every claim on that page asserted
# instruction by instruction against `--dump-asm`, so that a change to the code
# generator is a change to a documented, tested contract.
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
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
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

# M45 (review): a recorded region whose closing delimiter is the LAST token of
# an included file. p_skip_balanced used to read `nopen` after the lookahead
# next(), and lex_next pops an exhausted #include frame BEFORE it produces the
# next token -- so a perfectly balanced region was refused with `region crosses
# a file boundary`. The two halves are asserted together: the balanced one has
# to compile and run, the one that really does cross has to be refused, at the
# OPENING token's position.
mkdir -p "$tmp/inc"
printf 'tmpl t<T, N> { T a[N]; return N + bits T / 8; }\n' > "$tmp/inc/tpl.mc"
cat > "$tmp/inc/eof.mc" <<'EOF'
#include "tpl.mc"
make t<i64, 3>;
i64 main() { return t__i64__3() * 4 - 2; }
EOF
if ! msg=$("$demo" --exe "$tmp/inc/eof.mc" -o "$tmp/inc/eof" 2>&1); then
    echo "FAIL p_skip_balanced-include-eof (compilation: $msg)"; fails=$((fails + 1))
else
    "$tmp/inc/eof"
    rc=$?
    if [ "$rc" != 42 ]; then
        echo "FAIL p_skip_balanced-include-eof (exit $rc, expected 42)"; fails=$((fails + 1))
    else
        echo "ok p_skip_balanced-include-eof"
    fi
fi

# the region really does cross: the `{` is in the include, the `}` in the includer
printf 'tmpl t<T, N> { T a[N]; return N + bits T / 8;\n' > "$tmp/inc/open.mc"
cat > "$tmp/inc/cross.mc" <<'EOF'
#include "open.mc"
}
make t<i64, 3>;
i64 main() { return t__i64__3(); }
EOF
# the path is compared by suffix: $tmp comes from TMPDIR, which may end in a
# slash, and the compiler prints the path it opened, normalized.
if msg=$("$demo" --exe "$tmp/inc/cross.mc" -o "$tmp/inc/cross" 2>&1); then
    echo "FAIL p_skip_balanced-cross (the taught compiler accepted it)"; fails=$((fails + 1))
else
    case "$msg" in
        *"/inc/open.mc:1: region crosses a file boundary")
            echo "ok p_skip_balanced-cross (open.mc:1: region crosses a file boundary)" ;;
        *)
            echo "FAIL p_skip_balanced-cross"
            echo "  expected: .../inc/open.mc:1: region crosses a file boundary"
            echo "  got:      $msg"
            fails=$((fails + 1)) ;;
    esac
fi

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

# ---- M31 (2.1): `widen` reads the callee's declaration ----
# `low` returns u8, so `a` is a u8 local and 300 comes back 44; `keep` takes a
# u8, so the ARGUMENT is cast to u8 and 300 arrives as 44 as well. Neither type
# is written at the use site: both come from decl_ret / decl_param_type.
hook_case decl_find-widen 42 'u8  low(i64 x) { return x; }
i64 keep(u8 v)  { return v; }
i64 main() { widen a = low(300); widen b = keep(300); return a + b - 46; }'

# ...and the argument cast is in the tree, with the DECLARED parameter type on
# it. This is the half an FFI-marshalling module needs: a C callee does not
# narrow its own arguments the way an mc prologue does.
if "$demo" --dump-ast "$tmp/decl_find-widen.mc" 2>&1 | grep -q '^ *CAST type=u8$'; then
    echo "ok decl_param_type: the argument carries the declared parameter type"
else
    echo "FAIL decl_param_type: no CAST type=u8 in the tree"
    fails=$((fails + 1))
fi
if "$demo" --dump-ast "$tmp/decl_find-widen.mc" 2>&1 | grep -q '^ *VAR type=u8 name=a$'; then
    echo "ok decl_ret: the local carries the callee's declared return type"
else
    echo "FAIL decl_ret: the local is not u8"
    fails=$((fails + 1))
fi

# ---- M31 (2.2): on_jump, a statement on every exit edge ----
# h(1) leaves through the `return` INSIDE the guard body -- the edge an appended
# statement misses -- and h(0) falls off the end of it. bump() has to run once
# each: g_n == 2.
hook_case on_jump-guard 42 'i64 g_n = 0;
i64 bump() { g_n = g_n + 1; return 0; }
i64 h(i64 x) { guard bump() { if (x) { return 1; } } return 2; }
i64 main() { i64 a = h(1); i64 b = h(0); return a + b + g_n * 20 - 1; }'

# ordering, proved by a number: `retcount` counts the statements that still
# LOOKED like an N_RETURN when on_stmt ran. Between the two reads there are
# three returns in the source -- r0'"'"'s own, plain'"'"'s, and wrapped'"'"'s -- and only two
# reach on_stmt, because on_jump replaced the guarded one with an N_BLOCK first.
hook_case on_jump-before-on_stmt 42 'i64 g_n = 0;
i64 bump() { g_n = g_n + 1; return 0; }
i64 r0() { return retcount; }
i64 plain(i64 x)   { return x; }
i64 wrapped(i64 x) { guard bump() { return x; } }
i64 r1() { return retcount; }
i64 main() { return r1() - r0() + 40; }'

# `depth`: the deepest jump the hook saw. The `return 1` sits under the function
# body, two bare blocks and the `if` arm -- four open blocks; the `return 2` under
# one. Without the per-function rebase of parse_function the number would drift.
hook_case on_jump-depth 42 'i64 f(i64 x) { { { if (x) { return 1; } } } return 2; }
i64 main() { return jumpdepth + 38; }'

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

# ---- M41.5: syntax_param, the parameter position ----
# (a) a DEFAULT parameter. `y = 10` is not mc: the handler reads the whole
# parameter, keeps the constant for itself, and the module completes `f(1)` from
# a pass() with decl_find + decl_nparams. f(1) = 11, g(1) = 31.
#
# (c) p_decl_name(), with teeth: f and g differ ONLY in the default of the same
# parameter index. A module that ignored p_decl_name() would key the table by
# the index alone and give both the same number.
hook_case syntax_param-default 42 'i64 f(i64 x, i64 y = 10) { return x + y; }
i64 g(i64 x, i64 y = 30) { return x + y; }
i64 main() { return f(1) + g(1); }'

if "$demo" --dump-ast "$tmp/syntax_param-default.mc" 2>&1    | sed -n '/^FUNC type=i64 name=main/,$p' | grep -q 'INT val=10'    && "$demo" --dump-ast "$tmp/syntax_param-default.mc" 2>&1    | sed -n '/^FUNC type=i64 name=main/,$p' | grep -q 'INT val=30'; then
    echo "ok p_decl_name: f and g got their OWN default at the same parameter index"
else
    echo "FAIL p_decl_name: the two calls did not get different defaults"
    fails=$((fails + 1))
fi

# (b) a parameter that opens with a word the module taught. `params` stands
# where the core demands a type, which is the whole reason the hook is consulted
# BEFORE type_of_token; it lowers to an ordinary `uptr xs`.
hook_case syntax_param-params 42 'u64 vals[2] = { 40, 2 };
i64 sum2(params i64 xs) { return ld64(xs) + ld64(xs + 8); }
i64 main() { return sum2(vals); }'

if "$demo" --dump-ast "$tmp/syntax_param-params.mc" 2>&1 | grep -q '^ *PARAM type=uptr name=xs$'; then
    echo "ok syntax_param: the taught word lowered to an ordinary uptr parameter"
else
    echo 'FAIL syntax_param: params i64 xs did not become PARAM type=uptr'
    fails=$((fails + 1))
fi

# (d) M41.5 review: p_decl_name() inside a handler that owns the declaration.
# `capsule` parses its members itself with the PUBLIC parse_params()/parse_function(),
# so the core never reads their names -- p_set_decl_name() is what tells the
# parameter position whose parameters these are. The two members carry a default
# at the SAME index and differ only in its value: without the announcement the
# module cannot tell them apart, and the demo's own guard says so
# (`a default parameter needs a named declaration`).
hook_case syntax_param-capsule 42 'capsule Counter {
    i64 inc(i64 x, i64 y = 10) { return x + y; }
    i64 dec(i64 x, i64 y = 30) { return x + y; }
}
i64 main() { return inc(1) + dec(1); }'

if "$demo" --dump-ast "$tmp/syntax_param-capsule.mc" 2>&1 \
     | sed -n '/^FUNC type=i64 name=main/,$p' | grep -q 'INT val=10' \
   && "$demo" --dump-ast "$tmp/syntax_param-capsule.mc" 2>&1 \
     | sed -n '/^FUNC type=i64 name=main/,$p' | grep -q 'INT val=30'; then
    echo "ok p_set_decl_name: each member of the capsule kept its OWN default"
else
    echo "FAIL p_set_decl_name: the two members did not get different defaults"
    fails=$((fails + 1))
fi

# and the default compiler refuses all three, at the parameter list
for f in syntax_param-default syntax_param-params syntax_param-capsule; do
    if msg=$("$mc1" "$tmp/$f.mc" -o "$tmp/$f.o" 2>&1); then
        echo "FAIL: the default compiler accepted $f"
        fails=$((fails + 1))
    else
        echo "ok the default compiler rejects $f (${msg##*/})"
    fi
done

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

# ---- M31: the four cases the two new hooks own ----
err_case tests/err/067-widen-unknown.mc \
    "tests/err/067-widen-unknown.mc:8: widen: unknown function: nosuch"
err_case tests/err/068-widen-void.mc \
    "tests/err/068-widen-void.mc:11: widen: cannot bind the result of a void function: nothing"
err_case tests/err/069-widen-arity.mc \
    "tests/err/069-widen-arity.mc:8: widen: wrong number of arguments: two"
err_case tests/err/070-guard-break-level.mc \
    "tests/err/070-guard-break-level.mc:12: guard: break N leaves more than the guard body"

# ---- M41.5: the three guards the parameter position needs ----
err_case tests/err/071-param-noadvance.mc \
    "tests/err/071-param-noadvance.mc:13: syntax_param handler consumed no tokens: pnop"
err_case tests/err/072-param-nonparam.mc \
    "tests/err/072-param-nonparam.mc:12: syntax_param handler did not return a parameter"
# the review's finding: consuming and THEN declining. `sd_peat` reads
# `peat i64 x` and the comma after it and answers 0, so before the fix this
# source compiled clean as a two-parameter f(y, z) and ran with the wrong arity.
err_case tests/err/073-param-consumed-zero.mc \
    "tests/err/073-param-consumed-zero.mc:17: syntax_param handler consumed tokens and returned 0: peat"
# ...and the same latent shape at M24's literal position: `sd_leat` claims a
# literal ending in `q`, consumes it with p_take_lit and declines. Before the
# fix this compiled to `return 7;` with the `q` swallowed.
err_case tests/err/074-lit-consumed-zero.mc \
    "tests/err/074-lit-consumed-zero.mc:14: syntax_lit handler consumed tokens and returned 0: 7"

# ---- M31 (2.3): the ABI contract, asserted instruction by instruction ----
# docs/reference/objects.md § 4 writes down what a TAUGHT RUNTIME relies on -- a
# `#opcode` syscall wrapper, an atomic, a thread entry handed out as `&f`, a
# stack walker. Every claim on that page is checked here against `--dump-asm` of
# the DEFAULT compiler, never against a memory of the code generator: a change
# to gen_arm64.mc that breaks one of them fails with the function that changed.
abi_src="$tmp/abi.mc"
cat > "$abi_src" <<'ABIEOF'
i64 abi8(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h) { return h; }
i64 abileaf() { return 7; }
i64 abidepth(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g) {
    return a + (b + (c + (d + (e + (f + g)))));
}
i64 abispill(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h) {
    return a + (b + (c + (d + (e + (f + (g + h))))));
}
i64 abimod(i64 a, i64 b) { return a % b; }
i64 abicallp(uptr p, i64 a) { return callp(p, a); }
i64 abi12(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h, i64 i, i64 j, i64 k, i64 l) { return l; }
i64 abicall12(i64 a) { return abi12(a, a, a, a, a, a, a, a, a, a, a, a); }
extern i32 abiext32(i64 x);
extern u8  abiext8(i64 x);
extern i64 abiext64(i64 x);
i64 abinarrow32() { return abiext32(1); }
i64 abinarrow8()  { return abiext8(1); }
i64 abinarrow64() { return abiext64(1); }
ABIEOF
"$mc1" --dump-asm "$abi_src" > "$tmp/abi.asm" 2>&1

# the lowered body of one function, its label excluded
abi_fn() { awk -v f="_$1:" '$0 == f { on = 1; next } on && /^_/ { exit } on { print }' "$tmp/abi.asm"; }

abi_case() {                        # abi_case CLAIM FUNCTION EXPECTED
    got=$(abi_fn "$2")
    if [ "$got" = "$3" ]; then
        echo "ok abi: $1"
    else
        echo "FAIL abi: $1"
        printf '  expected:\n%s\n  got:\n%s\n' "$3" "$got"
        fails=$((fails + 1))
    fi
}

abi_case "parameters 1..8 arrive in x0..x7 and the prologue does not clobber them" abi8 "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #64
  str x0, [sp, #56]
  str x1, [sp, #48]
  str x2, [sp, #40]
  str x3, [sp, #32]
  str x4, [sp, #24]
  str x5, [sp, #16]
  str x6, [sp, #8]
  str x7, [sp]
  ldr x9, [sp]
  mov x0, x9
  b L1
L1:
  add sp, sp, #64
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "a zero-parameter, zero-local function has frame == 0, and the epilogue leaves x0 alone" abileaf "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  movz x9, #7
  mov x0, x9
  b L1
L1:
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "expression depths 0..6 live in x9..x15" abidepth "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #64
  str x0, [sp, #56]
  str x1, [sp, #48]
  str x2, [sp, #40]
  str x3, [sp, #32]
  str x4, [sp, #24]
  str x5, [sp, #16]
  str x6, [sp, #8]
  ldr x9, [sp, #56]
  ldr x10, [sp, #48]
  ldr x11, [sp, #40]
  ldr x12, [sp, #32]
  ldr x13, [sp, #24]
  ldr x14, [sp, #16]
  ldr x15, [sp, #8]
  add x14, x14, x15
  add x13, x13, x14
  add x12, x12, x13
  add x11, x11, x12
  add x10, x10, x11
  add x9, x9, x10
  mov x0, x9
  b L1
L1:
  add sp, sp, #64
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "depth 7 and beyond spills through x16/x17" abispill "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #80
  str x0, [sp, #72]
  str x1, [sp, #64]
  str x2, [sp, #56]
  str x3, [sp, #48]
  str x4, [sp, #40]
  str x5, [sp, #32]
  str x6, [sp, #24]
  str x7, [sp, #16]
  ldr x9, [sp, #72]
  ldr x10, [sp, #64]
  ldr x11, [sp, #56]
  ldr x12, [sp, #48]
  ldr x13, [sp, #40]
  ldr x14, [sp, #32]
  ldr x15, [sp, #24]
  ldr x16, [sp, #16]
  str x16, [sp, #8]
  ldr x17, [sp, #8]
  add x15, x15, x17
  add x14, x14, x15
  add x13, x13, x14
  add x12, x12, x13
  add x11, x11, x12
  add x10, x10, x11
  add x9, x9, x10
  mov x0, x9
  b L1
L1:
  add sp, sp, #80
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "x8 is the only scratch the remainder uses" abimod "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #16
  str x0, [sp, #8]
  str x1, [sp]
  ldr x9, [sp, #8]
  ldr x10, [sp]
  sdiv x8, x9, x10
  msub x9, x8, x10, x9
  mov x0, x9
  b L1
L1:
  add sp, sp, #16
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "callp puts the pointer in x16, the arguments in x0.., and reads the result from x0" abicallp "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #16
  str x0, [sp, #8]
  str x1, [sp]
  ldr x9, [sp, #8]
  ldr x10, [sp]
  mov x16, x9
  mov x0, x10
  blr x16
  mov x9, x0
  mov x0, x9
  b L1
L1:
  add sp, sp, #16
  ldp x29, x30, [sp], #16
  ret
EOF
)"

# M38: parameters 9..12 are not in a register at all. The CALLEE reads them
# above its own frame record, at [x29 + 16 + 8*(i-8)]; the CALLER leaves them at
# the bottom of its frame, at [sp, #0..#24], and reserves those bytes as part of
# the frame instead of moving sp around the call -- REG_FRAME is only turned into
# an sp-relative address at the end of the function, so an sp that moved inside
# the body would break every spilled depth (docs/reference/objects.md § 4).
abi_case "parameters 9..12 are read at [x29 + 16 + 8*(i-8)]" abi12 "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #96
  str x0, [sp, #88]
  str x1, [sp, #80]
  str x2, [sp, #72]
  str x3, [sp, #64]
  str x4, [sp, #56]
  str x5, [sp, #48]
  str x6, [sp, #40]
  str x7, [sp, #32]
  ldr x16, [x29, #16]
  str x16, [sp, #24]
  ldr x16, [x29, #24]
  str x16, [sp, #16]
  ldr x16, [x29, #32]
  str x16, [sp, #8]
  ldr x16, [x29, #40]
  str x16, [sp]
  ldr x9, [sp]
  mov x0, x9
  b L1
L1:
  add sp, sp, #96
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "arguments 9..12 are stored at [sp, #0..#24] before x0..x7 are written" abicall12 "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #80
  str x0, [sp, #72]
  ldr x9, [sp, #72]
  ldr x10, [sp, #72]
  ldr x11, [sp, #72]
  ldr x12, [sp, #72]
  ldr x13, [sp, #72]
  ldr x14, [sp, #72]
  ldr x15, [sp, #72]
  ldr x16, [sp, #72]
  str x16, [sp, #64]
  ldr x16, [sp, #72]
  str x16, [sp, #56]
  ldr x16, [sp, #72]
  str x16, [sp, #48]
  ldr x16, [sp, #72]
  str x16, [sp, #40]
  ldr x16, [sp, #72]
  str x16, [sp, #32]
  ldr x16, [sp, #56]
  str x16, [sp]
  ldr x16, [sp, #48]
  str x16, [sp, #8]
  ldr x16, [sp, #40]
  str x16, [sp, #16]
  ldr x16, [sp, #32]
  str x16, [sp, #24]
  mov x0, x9
  mov x1, x10
  mov x2, x11
  mov x3, x12
  mov x4, x13
  mov x5, x14
  mov x6, x15
  ldr x7, [sp, #64]
  bl _abi12
  mov x9, x0
  mov x0, x9
  b L1
L1:
  add sp, sp, #80
  ldp x29, x30, [sp], #16
  ret
EOF
)"

# the `#opcode` fixed-register rule, on the real user of it: lib/sys_svc.mc's
# `write` is a whole syscall in two words, and it works only because x0..x2 still
# hold the arguments when the first `.word` executes and the epilogue does not
# touch the x0 the kernel left.
"$mc1" --dump-asm tests/032-svc.mc > "$tmp/svc.asm" 2>&1
# ---- M45: a call returns what the callee DECLARED ----
# The walker issues MTASK_CAST after MTASK_CALL when the declared result is
# narrower than the word (docs/reference/objects.md § 4). Every ABI this
# compiler targets leaves the bits above a 32/16/8-bit result UNSPECIFIED, so
# the extension is the caller's to perform, and its FLAVOUR is the type's kind:
# sign for a TK_SINT, zero for a TK_INT, nothing at all at width 8.
abi_case "a call declared i32 is sign-extended from bit 31 (sxtw)" abinarrow32 "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  movz x9, #1
  mov x0, x9
  bl _abiext32
  mov x9, x0
  sxtw x9, w9
  mov x0, x9
  b L1
L1:
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "a call declared u8 is zero-extended from bit 7 (and #255)" abinarrow8 "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  movz x9, #1
  mov x0, x9
  bl _abiext8
  mov x9, x0
  and x9, x9, #255
  mov x0, x9
  b L1
L1:
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_case "a call declared i64 gets no cast at all" abinarrow64 "$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  movz x9, #1
  mov x0, x9
  bl _abiext64
  mov x9, x0
  mov x0, x9
  b L1
L1:
  ldp x29, x30, [sp], #16
  ret
EOF
)"

abi_fn2() { awk -v f="_$1:" '$0 == f { on = 1; next } on && /^_/ { exit } on { print }' "$tmp/svc.asm"; }
got=$(abi_fn2 write)
want=$(cat <<'EOF'
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  sub sp, sp, #32
  str x0, [sp, #24]
  str x1, [sp, #16]
  str x2, [sp, #8]
  .word 0xd2800090
  .word 0xd4001001
L1:
  add sp, sp, #32
  ldp x29, x30, [sp], #16
  ret
EOF
)
if [ "$got" = "$want" ]; then
    echo "ok abi: #opcode names its own registers and nothing is inserted around it"
else
    echo "FAIL abi: the #opcode word of lib/sys_svc.mc write() moved"
    printf '  expected:\n%s\n  got:\n%s\n' "$want" "$got"
    fails=$((fails + 1))
fi

# ...and the same three claims over the biggest program there is, src/mc.mc:
# every function opens with the same two words, every `ret` is preceded by
# exactly that `ldp`, and x18..x28 are never mentioned at all.
"$mc1" --dump-asm src/mc.mc > "$tmp/mc.asm" 2>&1
nfn=$(grep -c '^_' "$tmp/mc.asm")
nline=$(grep -c '' "$tmp/mc.asm")
badpro=$(awk '/^_/ { getline a; getline b;
                     if (a != "  stp x29, x30, [sp, #-16]!" || b != "  mov x29, sp") n++ }
              END { print n + 0 }' "$tmp/mc.asm")
nret=$(grep -c '^  ret$' "$tmp/mc.asm")
okret=$(awk 'p == "  ldp x29, x30, [sp], #16" && $0 == "  ret" { n++ } { p = $0 } END { print n + 0 }' "$tmp/mc.asm")
nhigh=$(grep -cE 'x(1[89]|2[0-8])\b' "$tmp/mc.asm")
if [ "$badpro" = "0" ] && [ "$nret" = "$okret" ] && [ "$nret" = "$nfn" ]; then
    echo "ok abi: $nfn functions of src/mc.mc, all with the same frame record and epilogue"
else
    echo "FAIL abi: src/mc.mc has $nfn functions, $badpro bad prologues, $okret/$nret guarded returns"
    fails=$((fails + 1))
fi
if [ "$nhigh" = "0" ]; then
    echo "ok abi: x18..x28 never appear in $nline lines of lowered src/mc.mc"
else
    echo "FAIL abi: x18..x28 appear $nhigh times in the lowering of src/mc.mc"
    grep -nE 'x(1[89]|2[0-8])\b' "$tmp/mc.asm" | sed -n '1,5p'
    fails=$((fails + 1))
fi

# determinism: the same source compiled twice by the same compiler is the same object
"$demo" lib/syntax_demo_test.mc -o "$tmp/sdt1.o" 2>/dev/null
"$demo" lib/syntax_demo_test.mc -o "$tmp/sdt2.o" 2>/dev/null
if cmp -s "$tmp/sdt1.o" "$tmp/sdt2.o"; then
    echo "ok the demo test compiled twice gives the same object"
else
    echo "FAIL the demo test is not deterministic"
    fails=$((fails + 1))
fi

# ---- M24 (Tier 4): type_new, syntax_lit, the fold guards and a derived machine ----
# `fix` is 16.16 signed fixed point in eight bytes and `pair` a sixteen-byte
# opaque value, both registered with type_new by lib/user_syntax_demo.mc, and
# `1.5` is read by its syntax_lit handler out of the raw source -- the lexer's
# token is still `1` and --dump-tokens has not moved.
#
# One program covers three of the four core decisions M24 delegates: `fix` names
# a PARAMETER, a CAST names it back to i64, and the literal survives resolve
# with the module's type on it (without M2 it would come back TY_I64 and the
# division would be by the wrong scale).
hook_case type_new-param-cast 42 'i64 f(fix v) { return (i64) v / 65536; }
i64 main() { fix a = 1.5; return f(a) * 28 + 14; }'

# the fourth: the frame slot is the TYPE's width. Two `pair` locals reserve 32
# bytes where two i64 locals reserve 16 -- the whole of M5, visible.
printf 'i64 f() { pair a; pair b; return 1; }\n' > "$tmp/m24-wide.mc"
printf 'i64 f() { i64 a; i64 b; return 1; }\n'   > "$tmp/m24-narrow.mc"
wide=$("$demo" --dump-asm "$tmp/m24-wide.mc"   | sed -n '/^_f:/,/ret/p' | grep -c 'sub sp, sp, #32')
narrow=$("$demo" --dump-asm "$tmp/m24-narrow.mc" | sed -n '/^_f:/,/ret/p' | grep -c 'sub sp, sp, #16')
if [ "$wide" = 1 ] && [ "$narrow" = 1 ]; then
    echo "ok type_new: a 16-byte type gets a 16-byte frame slot (32 vs 16 bytes)"
else
    echo "FAIL slot_new(type_width): wide=$wide narrow=$narrow"
    fails=$((fails + 1))
fi

# M3, as M45 D17 re-pointed it: the guard is the KIND, not the id. The core
# folds what its own operators compute -- TK_INT and TK_SINT, core or registered
# -- and delegates TK_FLOAT, TK_WIDE and TK_OPAQUE. So `fix`, a TK_INT of width
# 8, folds exactly as a core literal does, and it is right that it does: at run
# time the machine's integer `add` of the two 16.16 representations is precisely
# what the folder just computed. A `f64` does NOT fold, and that is the half
# that has to be proved, because there the runtime is `fadd` and an integer
# addition of two IEEE-754 patterns would be an infinity with no diagnostic.
#
# The observable is --dump-asm, not --dump-ast: fold() runs after the AST dump.
# An unfolded expression leaves instructions behind -- an `add` beside the
# frame's own, a `neg`, an `mvn`, a `cmp`/`cset` -- and a folded one leaves a
# single `movz` and nothing else.
fold_ops() {                        # fold_ops COMPILER SOURCE OP -> how many in _main
    "$1" --dump-asm --machine=arm64 "$2" | sed -n '/^_main:/,/^$/p' | grep -cE "^  $3 "
}
printf 'i64 main() { fix a = 1.5 + 2.5; fix b = -1.5; fix c = ~1.5; i64 d = !1.5; fix e = (fix) 3; i64 g = (i64) 1.5; return d; }\n' > "$tmp/m24-fold.mc"
printf 'i64 main() { i64 a = 1 + 2; i64 b = -1; i64 c = ~1; i64 d = !1; i64 e = (u8) 3; i64 g = (i64) 1; return d; }\n'          > "$tmp/m24-nofold.mc"
unfolded=0
# a registered TK_INT folds exactly as a core literal does...
[ "$(fold_ops "$demo" "$tmp/m24-fold.mc" add)"  = 1 ] || { echo "FAIL fold guard: fix + did not fold"; unfolded=1; }
[ "$(fold_ops "$demo" "$tmp/m24-fold.mc" neg)"  = 0 ] || { echo "FAIL fold guard: fix - did not fold"; unfolded=1; }
[ "$(fold_ops "$demo" "$tmp/m24-fold.mc" mvn)"  = 0 ] || { echo "FAIL fold guard: fix ~ did not fold"; unfolded=1; }
[ "$(fold_ops "$demo" "$tmp/m24-fold.mc" cset)" = 0 ] || { echo "FAIL fold guard: fix ! did not fold"; unfolded=1; }
# ...which is the same shape the core literals themselves produce
[ "$(fold_ops "$demo" "$tmp/m24-nofold.mc" add)"  = 1 ] || { echo "FAIL fold guard: core + stopped folding"; unfolded=1; }
[ "$(fold_ops "$demo" "$tmp/m24-nofold.mc" neg)"  = 0 ] || { echo "FAIL fold guard: core - stopped folding"; unfolded=1; }
[ "$(fold_ops "$demo" "$tmp/m24-nofold.mc" mvn)"  = 0 ] || { echo "FAIL fold guard: core ~ stopped folding"; unfolded=1; }
[ "$(fold_ops "$demo" "$tmp/m24-nofold.mc" cset)" = 0 ] || { echo "FAIL fold guard: core ! stopped folding"; unfolded=1; }
# the AST assertion stands unchanged: fold() runs after --dump-ast, so the cast
# node is still there to be seen
if "$demo" --dump-ast "$tmp/m24-fold.mc" 2>&1 | grep -q 'CAST type=fix'; then :
else echo "FAIL fold guard: (fix) 3 is not in the tree"; unfolded=1; fi
# and the half that must NOT fold, through <float>'s f64 -- a TK_FLOAT, whose
# arithmetic is its module's
mcfloat="build/mc-float-surface"
rm -f "$mcfloat"
if ! msg=$("$mc1" --exe lib/mc_float.mc -o "$mcfloat" 2>&1); then
    echo "FAIL fold guard: compiling lib/mc_float.mc: $msg"; unfolded=1
else
    printf 'i64 main() { f64 a = 1.5 + 2.5; f64 b = -1.5; i64 d = !1.5; return d; }\n' > "$tmp/m45-ffold.mc"
    [ "$(fold_ops "$mcfloat" "$tmp/m45-ffold.mc" fadd)" = 1 ] || { echo "FAIL fold guard: f64 + folded"; unfolded=1; }
    [ "$(fold_ops "$mcfloat" "$tmp/m45-ffold.mc" fneg)" = 1 ] || { echo "FAIL fold guard: f64 - folded"; unfolded=1; }
    [ "$(fold_ops "$mcfloat" "$tmp/m45-ffold.mc" fcmp)" = 1 ] || { echo "FAIL fold guard: f64 ! folded"; unfolded=1; }
fi
if [ "$unfolded" = 0 ]; then
    echo "ok fold guards by kind: a TK_INT literal folds like a core one, a TK_FLOAT does not"
else
    fails=$((fails + unfolded))
fi

# ---- M45: p_cp(), the lexer's cursor, against p_start(), the token ----
# A syntax_lit-style handler scans raw source forward. p_start() is where the
# CURRENT TOKEN starts -- and on a token p_subst_name() replaced, subst_apply
# swapped tok_start/tok_len for the REPLACEMENT string, which lives in the
# arena. So inside a p_push_source frame a scan from p_start() reads the arena
# lexeme, not the source. p_cp() is the cursor and still points into the pushed
# text, just past the token.
#
# The demo's `srcbyte` reports ld8(p_cp()) and `srcbyte0` reports ld8(p_start());
# `probe p1;` pushes `i64 p1() { return W  * 1000 + V; }` with W -> srcbyte and
# V -> srcbyte0, so both words run on SUBSTITUTED tokens. The numbers are what
# make the two positions distinguishable:
#
#   a = 59   the `;` after `srcbyte` in ordinary source
#   b = 115  's', the first byte of the word `srcbyte0` -- here p_start() IS
#            the source, so the two agree outside a substitution
#   p1() = 32115, i.e. W -> 32 and V -> 115: p_cp() answers the SPACE that
#            really follows `W` in the pushed text, while p_start() answers
#            's' -- the arena copy of "srcbyte0" -- where the source holds `V`
#            (86). A handler scanning from p_start() there reads the arena.
hook_case p_cp-under-substitution 42 'probe p1;
i64 main() {
    i64 a = srcbyte;
    i64 b = srcbyte0;
    if (a != 59) return 1;
    if (b != 115) return 2;
    if (p1() != 32115) return 3;
    return 42;
}'

# ---- M45: what one type_new(name, w, a, TK_SINT) buys ----
# lib/user_syntax_demo.mc registers `i16` in ONE line and gets, from the core
# and from the bundled machine and with no line of its own: a sign-extending
# load (ldrsh), a sign-extending cast (sxth), signed arithmetic and comparison,
# and the narrowing of a call result. The word `i16` is one the seed never
# spells, so the registration itself compiles under the frozen stage0.
cat > "$tmp/m45-i16.mc" <<'I16EOF'
i16 f(i64 x) { return x; }
i64 main() {
    i16 a = -2;
    if (f(40000) != -25536) return 1;
    if (a * 2 != -4) return 2;
    if (a >= 0) return 3;
    return 42;
}
I16EOF
if ! msg=$("$demo" --exe "$tmp/m45-i16.mc" -o "$tmp/m45-i16" 2>&1); then
    echo "FAIL i16 (compilation: $msg)"; fails=$((fails + 1))
else
    "$tmp/m45-i16"; rc=$?
    asm=$("$demo" --dump-asm --machine=arm64 "$tmp/m45-i16.mc")
    ldrsh=$(printf '%s\n' "$asm" | grep -c '^  ldrsh ')
    sxth=$(printf '%s\n' "$asm" | grep -c '^  sxth ')
    if [ "$rc" = 42 ] && [ "$ldrsh" -ge 1 ] && [ "$sxth" -ge 1 ]; then
        echo "ok type_new(TK_SINT): i16 in one line -- $ldrsh ldrsh, $sxth sxth, exit 42"
    else
        echo "FAIL i16 (exit $rc, ldrsh $ldrsh, sxth $sxth)"; fails=$((fails + 1))
    fi
fi

# M1: type_new goes through word_add, so a type named after a core keyword is
# refused at user_init time, exactly as type_alias, syntax and syntax_infix are
sed 's|user_default\.mc|user_dupty.mc|' "$save" > "$user"
if ! grep -q 'user_dupty\.mc' "$user"; then
    echo "FAIL: could not wire lib/user_dupty.mc into $user"
    exit 1
fi
if ! msg=$("$mc0" src/mc.mc -o build/mc1t.o 2>&1); then
    echo "FAIL: compiling src/mc.mc with user_dupty: $msg"
    fails=$((fails + 1))
elif ! msg=$(scripts/link.sh build/mc1t build/mc1t.o 2>&1); then
    echo "FAIL: linking build/mc1t: $msg"
    fails=$((fails + 1))
elif msg=$(build/mc1t tests/001-return42.mc -o "$tmp/t.o" 2>&1); then
    echo "FAIL: type_new(\"if\", ...) was accepted"
    fails=$((fails + 1))
elif [ "$msg" != "mc: cannot redefine core keyword: if" ]; then
    echo "FAIL: type_new on a core keyword said '$msg'"
    fails=$((fails + 1))
else
    echo "ok type_new refuses a core keyword at user_init ($msg)"
fi
cp "$save" "$user"

# M6, the inertness shape: a module whose ONLY registration is syntax_lit and
# whose handler answers 0 for every literal has to produce exactly the tree and
# exactly the object the compiler without the hook produces. The callp happens
# on every numeric literal of every program -- 0 is the handler declining, not
# the absence of a handler.
litnop="build/mc-lit-nop"
rm -f "$litnop"
if ! msg=$("$mc1" --exe lib/mc_lit_nop.mc -o "$litnop" 2>&1); then
    echo "FAIL: compiling lib/mc_lit_nop.mc: $msg"
    fails=$((fails + 1))
else
    litfails=0
    for f in tests/*.mc; do
        [ -f "$f" ] || continue
        "$mc1"    --dump-ast "$f" > "$tmp/ln0.ast" 2>&1
        "$litnop" --dump-ast "$f" > "$tmp/ln1.ast" 2>&1
        cmp -s "$tmp/ln0.ast" "$tmp/ln1.ast" || {
            echo "FAIL syntax_lit inert: --dump-ast of $f"; litfails=$((litfails + 1)); }
        "$mc1"    "$f" -o "$tmp/ln0.o" 2>/dev/null
        "$litnop" "$f" -o "$tmp/ln1.o" 2>/dev/null
        cmp -s "$tmp/ln0.o" "$tmp/ln1.o" || {
            echo "FAIL syntax_lit inert: object of $f"; litfails=$((litfails + 1)); }
    done
    if [ "$litfails" = 0 ]; then
        echo "ok syntax_lit returning 0: --dump-ast and objects identical over tests/"
    else
        fails=$((fails + litfails))
    fi
fi

# M41.5, the same inertness shape for syntax_param: a module whose ONLY
# registration is syntax_param and whose handler answers 0 for every parameter
# has to produce exactly the tree and exactly the object the compiler without
# the hook produces. The callp happens at every parameter of every function --
# 0 is the handler declining, not the absence of a handler.
pnop="build/mc-param-nop"
rm -f "$pnop"
if ! msg=$("$mc1" --exe lib/mc_param_nop.mc -o "$pnop" 2>&1); then
    echo "FAIL: compiling lib/mc_param_nop.mc: $msg"
    fails=$((fails + 1))
else
    pnfails=0
    for f in tests/*.mc; do
        [ -f "$f" ] || continue
        "$mc1"  --dump-ast "$f" > "$tmp/pn0.ast" 2>&1
        "$pnop" --dump-ast "$f" > "$tmp/pn1.ast" 2>&1
        cmp -s "$tmp/pn0.ast" "$tmp/pn1.ast" || {
            echo "FAIL syntax_param inert: --dump-ast of $f"; pnfails=$((pnfails + 1)); }
        "$mc1"  "$f" -o "$tmp/pn0.o" 2>/dev/null
        "$pnop" "$f" -o "$tmp/pn1.o" 2>/dev/null
        cmp -s "$tmp/pn0.o" "$tmp/pn1.o" || {
            echo "FAIL syntax_param inert: object of $f"; pnfails=$((pnfails + 1)); }
    done
    if [ "$pnfails" = 0 ]; then
        echo "ok syntax_param returning 0: --dump-ast and objects identical over tests/"
    else
        fails=$((fails + pnfails))
    fi
fi

# M4/M8: the probe machine (lib/machine_probe.mc). It derives from `arm64` with
# machine_tab/machine_slot, delegates every task through the pristine copy, and
# asserts the depth-type contract on every task it sees -- over the whole of
# src/mc.mc, which is the only corpus large enough to settle it. A stale entry
# is wrong code, not a diagnostic, so the criterion is both halves: the assertion
# never fires AND the object is byte for byte the one the bundled machine writes.
probe="build/mc-probe"
rm -f "$probe"
if ! msg=$("$mc1" --exe lib/mc_probe.mc -o "$probe" 2>&1); then
    echo "FAIL: compiling lib/mc_probe.mc: $msg"
    fails=$((fails + 1))
elif ! msg=$("$probe" --backend=macho-probe-core src/mc.mc -o "$tmp/probe.o" 2>&1); then
    echo "FAIL: the probe machine over src/mc.mc: $msg"
    fails=$((fails + 1))
else
    "$mc1" src/mc.mc -o "$tmp/probe-ref.o" 2>/dev/null
    if cmp -s "$tmp/probe.o" "$tmp/probe-ref.o"; then
        echo "ok machine_tab/machine_slot: derived machine, $msg, object identical"
    else
        echo "FAIL the probe machine changed the object"
        fails=$((fails + 1))
    fi
fi

# ---- M24 step B: intrinsic() and --dump-machine ----
# `rbit` is AArch64's bit-reversal applied to an ARBITRARY expression -- the
# case #opcode cannot reach, because it folds constants and names fixed
# registers. The handler finds its operand through val_reg/dst_reg/dst_done,
# the three names contract version 3 publishes.
hook_case intrinsic-rbit 42 'i64 v(i64 x) { return x; }
i64 main() { return (i64) rbit(v(0x8000000000000000)) + 41; }'

# ...and at a depth the allocator SPILLED: eight live values put the operand
# past the register file, so val_reg has to load it and dst_done has to store it
hook_case intrinsic-rbit-spilled 42 'i64 v(i64 x) { return x; }
i64 main() { return v(1) + v(2) + v(3) + v(4) + v(5) + v(6) + v(7)
                  + (i64) rbit(v(0x8000000000000000)) + 13; }'

# a core intrinsic can never be shadowed: the dispatch puts them first, so the
# registration is refused where it is made rather than failing silently later
sed 's|user_default\.mc|user_dupintrin.mc|' "$save" > "$user"
if ! grep -q 'user_dupintrin\.mc' "$user"; then
    echo "FAIL: could not wire lib/user_dupintrin.mc into $user"
    exit 1
fi
if ! msg=$("$mc0" src/mc.mc -o build/mc1i.o 2>&1); then
    echo "FAIL: compiling src/mc.mc with user_dupintrin: $msg"
    fails=$((fails + 1))
elif ! msg=$(scripts/link.sh build/mc1i build/mc1i.o 2>&1); then
    echo "FAIL: linking build/mc1i: $msg"
    fails=$((fails + 1))
elif msg=$(build/mc1i tests/001-return42.mc -o "$tmp/i.o" 2>&1); then
    echo "FAIL: intrinsic(\"ld64\", ...) was accepted"
    fails=$((fails + 1))
elif [ "$msg" != "mc: cannot shadow a core intrinsic: ld64" ]; then
    echo "FAIL: shadowing ld64 said '$msg'"
    fails=$((fails + 1))
else
    echo "ok intrinsic cannot shadow a core intrinsic ($msg)"
fi
cp "$save" "$user"

# the observable-override proof the old spec asked of `#machine`, delivered
# without the directive: ONE slot of a derived table lowers `+` as a subtraction,
# the program's answer changes, and --dump-machine names the slot that moved.
badmach="build/mc-badmach"
rm -f "$badmach"
printf 'i64 v(i64 x) { return x; }\ni64 main() { return v(50) + v(8); }\n' > "$tmp/m24-bad.mc"
if ! msg=$("$mc1" --exe lib/mc_badmach.mc -o "$badmach" 2>&1); then
    echo "FAIL: compiling lib/mc_badmach.mc: $msg"
    fails=$((fails + 1))
else
    "$mc1"     --exe "$tmp/m24-bad.mc" -o "$tmp/m24-good" 2>/dev/null; "$tmp/m24-good"; good=$?
    "$badmach" --exe "$tmp/m24-bad.mc" -o "$tmp/m24-badx" 2>/dev/null; "$tmp/m24-badx"; bad=$?
    if [ "$good" != 58 ] || [ "$bad" != 42 ]; then
        echo "FAIL machine_slot override: default=$good overridden=$bad (want 58 and 42)"
        fails=$((fails + 1))
    else
        echo "ok machine_slot: one replaced task changes the program's answer (58 -> 42)"
    fi
    # ...and the dump says which slot, on the arm64 row, with everything else
    # still bundled. The re-registration REUSED arm64's slot (D5), so there are
    # three machines and not four.
    "$badmach" --dump-machine "$tmp/m24-bad.mc" > "$tmp/m24-dm" 2>&1
    n=$(grep -c '^machine ' "$tmp/m24-dm")
    if grep -q '^machine arm64 (current)$' "$tmp/m24-dm" \
       && grep -q '^  bin  *taught$' "$tmp/m24-dm" \
       && [ "$(grep -c 'taught' "$tmp/m24-dm")" = 1 ] && [ "$n" = 3 ]; then
        echo "ok --dump-machine: exactly one taught slot, on the re-registered arm64 row"
    else
        echo "FAIL --dump-machine did not report the override"
        grep -E '^machine |taught' "$tmp/m24-dm" | sed -n 1,6p
        fails=$((fails + 1))
    fi
fi
# and with nothing taught, every slot of every machine is bundled
if [ "$("$mc1" --dump-machine "$tmp/m24-bad.mc" 2>&1 | grep -c taught)" = 0 ]; then
    echo "ok --dump-machine: the stock compiler reports no taught slot"
else
    echo "FAIL --dump-machine reports a taught slot in the stock compiler"
    fails=$((fails + 1))
fi

# ---- M41.5: syntax_infix on a CORE operator ----
# The parser-level counterpart of the machine-level proof just above. Before
# M41.5 the registration was accepted and then silently undone: ops_init() filled
# the core precedence table as parse_unit's FIRST statement -- after user_init()
# -- and infix_set clears the handler column, so a handler with a die() in it
# never fired and `1 + 2` still compiled to 3. ops_init() is now idempotent and
# syntax_infix() calls it, so the core entry exists before the lookup.
coreop="build/mc-coreop"
rm -f "$coreop"
# `plus` and `star` cannot use `+` or `*` in their own bodies: this module's
# rewrite is unconditional and program-wide, so they would call themselves.
cat > "$tmp/coreop.mc" <<'EOF'
i64 plus(i64 a, i64 b) { return a - b; }
i64 star(i64 a, i64 b) { return a - b; }
i64 v(i64 x) { return x; }
i64 main() { return v(50) + v(8); }
EOF
# the module's precedence wins: `*` is taught at 3, looser than `-`, so this is
# star(55 - 6, 7) = 42 here and 55 - (6 * 7) = 13 with the stock compiler
cat > "$tmp/coreop-prec.mc" <<'EOF'
i64 plus(i64 a, i64 b) { return a - b; }
i64 star(i64 a, i64 b) { return a - b; }
i64 main() { return 55 - 6 * 7; }
EOF
# a `#infix` on the same token in the SOURCE still drops the handler (M21's rule,
# tests/err/066): this program defines no `plus`, so if the handler had survived
# the compile would die with `unknown function: plus`
cat > "$tmp/coreop-infix.mc" <<'EOF'
#infix "+" 9 left $1 - $2

i64 v(i64 x) { return x; }
i64 main() { return v(50) + v(8); }
EOF
if ! msg=$("$mc1" --exe lib/mc_coreop.mc -o "$coreop" 2>&1); then
    echo "FAIL: compiling lib/mc_coreop.mc: $msg"
    fails=$((fails + 1))
else
    "$mc1"    --exe "$tmp/coreop.mc" -o "$tmp/coreop-good" 2>/dev/null; "$tmp/coreop-good"; good=$?
    "$coreop" --exe "$tmp/coreop.mc" -o "$tmp/coreop-tgt" 2>/dev/null; "$tmp/coreop-tgt"; tgt=$?
    if [ "$good" != 58 ] || [ "$tgt" != 42 ]; then
        echo "FAIL syntax_infix on a core operator: default=$good taught=$tgt (want 58 and 42)"
        fails=$((fails + 1))
    else
        echo "ok syntax_infix(\"+\"): the taught operator changes the program's answer (58 -> 42)"
    fi
    # and it is a PARSER-level change: `+` never becomes an N_BINARY
    if "$coreop" --dump-ast "$tmp/coreop.mc" 2>&1 | grep -q '^      CALL type=i64 name=plus$' \
       && ! "$coreop" --dump-ast "$tmp/coreop.mc" 2>&1 | grep -q 'op=+'; then
        echo "ok syntax_infix(\"+\"): the tree holds a call, not a binary node"
    else
        echo "FAIL syntax_infix(\"+\"): the tree still holds a binary +"
        fails=$((fails + 1))
    fi
    # the module's precedence replaces the core's, and --dump-rules says so
    "$mc1"    --exe "$tmp/coreop-prec.mc" -o "$tmp/prec-good" 2>/dev/null; "$tmp/prec-good"; good=$?
    "$coreop" --exe "$tmp/coreop-prec.mc" -o "$tmp/prec-tgt" 2>/dev/null; "$tmp/prec-tgt"; tgt=$?
    if [ "$good" != 13 ] || [ "$tgt" != 42 ]; then
        echo "FAIL syntax_infix precedence: default=$good taught=$tgt (want 13 and 42)"
        fails=$((fails + 1))
    else
        echo "ok syntax_infix: the module's precedence wins over the core's (13 -> 42)"
    fi
    "$coreop" --dump-rules "$tmp/coreop.mc" > "$tmp/coreop-rules" 2>&1
    if grep -q '^infix + prec 9 left handler$' "$tmp/coreop-rules" \
       && grep -q '^infix \* prec 3 left handler$' "$tmp/coreop-rules" \
       && grep -q '^infix - prec 9 left$' "$tmp/coreop-rules"; then
        echo "ok --dump-rules: the two taught core operators, with the module's precedence"
    else
        echo "FAIL --dump-rules does not report the taught core operators"
        grep '^infix ' "$tmp/coreop-rules" | sed -n 1,6p
        fails=$((fails + 1))
    fi
    # M21's rule is untouched: #infix in the source drops the handler
    if ! msg=$("$coreop" --exe "$tmp/coreop-infix.mc" -o "$tmp/coreop-inf" 2>&1); then
        echo "FAIL #infix on a taught core operator: $msg"
        fails=$((fails + 1))
    else
        "$tmp/coreop-inf"; tgt=$?
        if [ "$tgt" = 42 ] \
           && ! "$coreop" --dump-ast "$tmp/coreop-infix.mc" 2>&1 | grep -q 'name=plus'; then
            echo "ok #infix in the source still drops the handler of a core operator"
        else
            echo "FAIL #infix did not drop the handler (exit $tgt)"
            fails=$((fails + 1))
        fi
    fi
fi

# decision 7.3: teaching the same operator twice is refused at user_init time,
# before the first token of any source is read -- for a taught token (.+) and,
# since M41.5, for a core one (+), where the FIRST registration is allowed
# because a core operator carries no handler to override
dup_case() {
    sed "s|user_default\\.mc|$1|" "$save" > "$user"
    if ! grep -q "$1" "$user"; then
        echo "FAIL: could not wire lib/$1 into $user"
        exit 1
    fi
    if ! msg=$("$mc0" src/mc.mc -o build/mc1d.o 2>&1); then
        echo "FAIL: compiling src/mc.mc with $1: $msg"
        fails=$((fails + 1))
    elif ! msg=$(scripts/link.sh build/mc1d build/mc1d.o 2>&1); then
        echo "FAIL: linking build/mc1d: $msg"
        fails=$((fails + 1))
    elif msg=$(build/mc1d tests/001-return42.mc -o "$tmp/d.o" 2>&1); then
        echo "FAIL: a duplicate syntax_infix was accepted ($1)"
        fails=$((fails + 1))
    elif [ "$msg" != "$2" ]; then
        echo "FAIL: duplicate syntax_infix said '$msg' (want '$2')"
        fails=$((fails + 1))
    else
        echo "ok duplicate syntax_infix refused at user_init ($msg)"
    fi
    cp "$save" "$user"
}

dup_case user_dupop.mc     "mc: operator already taught: .+"
dup_case user_dupcoreop.mc "mc: operator already taught: +"

# ---- M43 step A: the AArch64 system-call shim, word by word ----
# src/sysno_linux_aarch64.mc is eight #opcode words and nothing else, and every
# claim the sandbox makes stands on them. They are asserted here against
# --dump-asm rather than trusted: what is checked is that the NUMBER goes to x8
# BEFORE x0 is overwritten and that each argument slides down by exactly one
# register, in ascending order (docs/reference/objects.md § 4 -- the prologue
# leaves the argument registers alone). Each word was produced by
# `llvm-mc -triple=aarch64-linux-musl --show-encoding` (docs/specs/M43.md § 2).
sys6_want='  .word 0xaa0003e8
  .word 0xaa0103e0
  .word 0xaa0203e1
  .word 0xaa0303e2
  .word 0xaa0403e3
  .word 0xaa0503e4
  .word 0xaa0603e5
  .word 0xd4000001'
sys6_got=$("$mc1" --dump-asm src/sysno_linux_aarch64.mc 2>&1 | grep '^  \.word ')
if [ "$sys6_got" = "$sys6_want" ]; then
    echo "ok sys6 (aarch64): mov x8,x0 / mov x0..x5,x1..x6 / svc #0"
else
    echo "FAIL sys6 (aarch64): the shim's words moved"
    printf '%s\n' "$sys6_got"
    fails=$((fails + 1))
fi

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
