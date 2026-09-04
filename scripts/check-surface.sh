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

abi_case "parameters arrive in x0..x7 and the prologue does not clobber them" abi8 "$(cat <<'EOF'
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

# the `#opcode` fixed-register rule, on the real user of it: lib/sys_svc.mc's
# `write` is a whole syscall in two words, and it works only because x0..x2 still
# hold the arguments when the first `.word` executes and the epilogue does not
# touch the x0 the kernel left.
"$mc1" --dump-asm tests/032-svc.mc > "$tmp/svc.asm" 2>&1
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
