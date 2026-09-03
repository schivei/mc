#!/bin/sh
# check-surface.sh [MC0] — criterio do M10 (Tier 2).
#
# Liga a demonstracao da superficie trocando o include de src/user.mc por
# lib/user_demo.mc, recompila o compilador com mc0 (build/mc1s), e para cada
# tests/*.mc compara o objeto do backend `arm64-surface` (escrito em .mc, fora
# do compilador) com o do backend `macho` embutido. Identidade byte a byte e o
# criterio. Depois liga lib/user_tokadd.mc (um user_init que so chama tok_add) e
# confere que os ids das palavras do nucleo continuam de pe. O src/user.mc
# original e sempre devolvido, mesmo se algo falhar.
mc0="${1:-build/mc0}"

if [ ! -x "$mc0" ]; then
    echo "FAIL: compilador '$mc0' nao encontrado ou nao executavel"
    exit 1
fi

user="src/user.mc"
save="${TMPDIR:-/tmp}/user.mc.$$"
tmp="${TMPDIR:-/tmp}/check-surface.$$"
mkdir -p "$tmp"
cp "$user" "$save"
# devolve o repositorio como estava, aconteca o que acontecer
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
cp "$save" "$user"          # o demo ja esta dentro de build/mc1s: solta o fonte

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

# o pass de demonstracao tem de alterar a AST de tests/061-pass.mc, e nenhuma outra
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

# Ordem de inicializacao: um user_init que chama tok_add nao pode deslocar os
# ids das palavras do nucleo (K_U8..K_EXTERN = 256..269). Ver lib/user_tokadd.mc.
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

[ "$fails" -eq 0 ]
