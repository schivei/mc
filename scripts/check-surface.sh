#!/bin/sh
# check-surface.sh [MC0] [MC1] — criterio do M10 (Tier 2) e do M12 (Tier 3).
#
# Liga a demonstracao da superficie trocando o include de src/user.mc por
# lib/user_demo.mc, recompila o compilador com mc0 (build/mc1s), e para cada
# tests/*.mc compara o objeto do backend `arm64-surface` (escrito em .mc, fora
# do compilador) com o do backend `macho` embutido. Identidade byte a byte e o
# criterio. Depois liga lib/user_tokadd.mc (um user_init que so chama tok_add) e
# confere que os ids das palavras do nucleo continuam de pe. O src/user.mc
# original e sempre devolvido, mesmo se algo falhar.
#
# M12 (Tier 3): no fim vem o caso que NAO mexe em src/user.mc — um compilador
# ensinado que e um arquivo proprio (lib/mc_syntax_demo.mc = src/core.mc + o
# modulo do usuario). MC1 o compila com --exe, e o binario que sai compila
# lib/syntax_demo_test.mc (que usa `unless`, `enum` e `bool`), tambem com --exe;
# o programa tem de sair 42, e o compilador padrao tem de recusar o mesmo fonte.
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

# ---- Tier 3 (M12): sintaxe ensinada por codigo, sem tocar em src/ ----
# 1. MC1 compila o compilador ensinado (src/core.mc + lib/user_syntax_demo.mc)
# 2. o compilador ensinado compila o teste que usa unless/enum/bool
# 3. o teste roda e devolve 42
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

# o compilador padrao tem de RECUSAR o mesmo fonte: a sintaxe e do modulo, nao
# do nucleo. `enum` la e so um identificador no lugar de um tipo.
if msg=$("$mc1" lib/syntax_demo_test.mc -o "$tmp/sdt.o" 2>&1); then
    echo "FAIL: o compilador padrao aceitou lib/syntax_demo_test.mc"
    fails=$((fails + 1))
else
    echo "ok o compilador padrao recusa o mesmo fonte ($msg)"
fi

[ "$fails" -eq 0 ]
