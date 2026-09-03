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
mc0="${1:-build/mc0}"
mc1="${2:-build/mc1}"

for mc in "$mc0" "$mc1"; do
    if [ ! -x "$mc" ]; then
        echo "FAIL: compilador '$mc' nao encontrado ou nao executavel"
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
    echo "FAIL: nao consegui ligar lib/user_demo.mc em $user"
    exit 1
fi

mkdir -p build
if ! msg=$("$mc0" src/mc.mc -o build/mc1s.o 2>&1); then
    echo "FAIL: compilacao de src/mc.mc com o demo ligado: $msg"
    exit 1
fi
if ! msg=$(scripts/link.sh build/mc1s build/mc1s.o 2>&1); then
    echo "FAIL: link de build/mc1s: $msg"
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

echo "$((total - fails))/$total objetos identicos (arm64-surface vs macho)"

# the demo pass has to alter the AST of tests/061-pass.mc, and no other
"$mc0"        --dump-ast tests/061-pass.mc > "$tmp/ast-sem" 2>&1
build/mc1s    --dump-ast tests/061-pass.mc > "$tmp/ast-com" 2>&1
if cmp -s "$tmp/ast-sem" "$tmp/ast-com"; then
    echo "FAIL: o pass de demonstracao nao alterou --dump-ast de tests/061-pass.mc"
    fails=$((fails + 1))
else
    echo "ok pass_demo altera --dump-ast de tests/061-pass.mc"
fi
for f in tests/*.mc; do
    [ "$f" = "tests/061-pass.mc" ] && continue
    "$mc0"     --dump-ast "$f" > "$tmp/s" 2>&1
    build/mc1s --dump-ast "$f" > "$tmp/c" 2>&1
    if ! cmp -s "$tmp/s" "$tmp/c"; then
        echo "FAIL: o pass alterou --dump-ast de $f (esperado so 061-pass)"
        fails=$((fails + 1))
    fi
done

# Init order: a user_init that calls tok_add must not shift the core
# keywords' ids (K_U8..K_EXTERN = 256..269). See lib/user_tokadd.mc.
sed 's|user_default\.mc|user_tokadd.mc|' "$save" > "$user"
if ! grep -q 'user_tokadd\.mc' "$user"; then
    echo "FAIL: nao consegui ligar lib/user_tokadd.mc em $user"
    exit 1
fi
if ! msg=$("$mc0" src/mc.mc -o build/mc1t.o 2>&1); then
    echo "FAIL: compilacao de src/mc.mc com user_tokadd: $msg"
    fails=$((fails + 1))
elif ! msg=$(scripts/link.sh build/mc1t build/mc1t.o 2>&1); then
    echo "FAIL: link de build/mc1t: $msg"
    fails=$((fails + 1))
elif ! msg=$(build/mc1t tests/001-return42.mc -o "$tmp/t.o" 2>&1); then
    echo "FAIL: user_init com tok_add quebrou o nucleo: $msg"
    fails=$((fails + 1))
elif ! msg=$(scripts/link.sh "$tmp/t" "$tmp/t.o" 2>&1); then
    echo "FAIL: link de tests/001 com user_tokadd: $msg"
    fails=$((fails + 1))
else
    "$tmp/t"
    rc=$?
    if [ "$rc" != "42" ]; then
        echo "FAIL: tests/001 com user_tokadd devolveu $rc, esperado 42"
        fails=$((fails + 1))
    else
        echo "ok user_init com tok_add nao desloca os ids do nucleo (tests/001 = 42)"
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
    echo "FAIL: compilacao de lib/mc_syntax_demo.mc: $msg"
    fails=$((fails + 1))
elif ! msg=$(codesign --verify --verbose=4 "$demo" 2>&1); then
    echo "FAIL: assinatura de $demo: $msg"
    fails=$((fails + 1))
elif ! msg=$("$demo" --exe lib/syntax_demo_test.mc -o "$tmp/sdt" 2>&1); then
    echo "FAIL: o compilador ensinado nao compilou lib/syntax_demo_test.mc: $msg"
    fails=$((fails + 1))
else
    "$tmp/sdt"
    rc=$?
    if [ "$rc" != "42" ]; then
        echo "FAIL: lib/syntax_demo_test.mc devolveu $rc, esperado 42"
        fails=$((fails + 1))
    else
        echo "ok syntax/syntax_stmt/type_alias: mc_syntax_demo compila o teste (exit 42)"
    fi
fi

# the default compiler has to REFUSE the same source: the syntax belongs to
# the module, not to the core. `enum` there is just an identifier where a type is expected.
if msg=$("$mc1" lib/syntax_demo_test.mc -o "$tmp/sdt.o" 2>&1); then
    echo "FAIL: o compilador padrao aceitou lib/syntax_demo_test.mc"
    fails=$((fails + 1))
else
    echo "ok o compilador padrao recusa o mesmo fonte ($msg)"
fi

[ "$fails" -eq 0 ]
