#!/bin/sh
# check-standalone.sh [MC_EXE] [REF_OBJ] — the M15 acceptance criterion:
# the binary alone is the toolchain.
#
# Copies build/mc-exe into an empty temporary directory, under the name `mc`,
# and never leaves that directory again. Everything below is compiled with
# `#include <name>` only — no path into this repository, no lib/, no src/:
#
#   1. a program that uses <sys> and <prelude> (which in turn pulls <io> in by
#      its own relative #include, resolved by name inside the bundle);
#   2. a taught compiler built from <mc/core> + <user_syntax_demo>, with --exe;
#   3. that compiler compiling <syntax_demo_test>, which uses `unless`, `enum`
#      and `bool` — and the copied `mc` refusing the same source, because the
#      syntax belongs to the module;
#   4. `#include <mc/host>` + `<mc/core>` + `<user_default>` compiled to an object
#      and compared byte for byte against build/mc2.o. That is the strongest
#      statement available: the core inside the bundle is the core in src/,
#      down to the last byte, INCLUDING the `mc/bundle_data` that core.mc
#      includes and that src/bundle.mc regenerates from the blob on the fly.
#   5. an unknown bundled name gives `unknown bundled include: <name>`.
#
# The only files copied in are the compiler and that reference object; the
# reference is test data, not an input to any compilation.
mc_exe="${1:-build/mc-exe}"
ref="${2:-build/mc2.o}"

for f in "$mc_exe" "$ref"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: '$f' not found (run 'make check' or 'make bootstrap' first)"
        exit 1
    fi
done

tmp="${TMPDIR:-/tmp}/check-standalone.$$"
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
rm -rf "$tmp"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

cp "$mc_exe" "$tmp/mc"
cp "$ref" "$tmp/ref.o"
chmod +x "$tmp/mc"

cat > "$tmp/hello.mc" <<'EOF'
#include <sys>
#include <prelude>

i64 main() {
    i64 n = 0;
    for (i64 i = 0; i < 6; i = i + 1) { n += 7; }
    puts("standalone\n");
    return n;
}
EOF

cat > "$tmp/mymc.mc" <<'EOF'
#include <mc/host>
#include <mc/core>
#include <user_syntax_demo>
EOF

cat > "$tmp/t.mc" <<'EOF'
#include <syntax_demo_test>
EOF

cat > "$tmp/def.mc" <<'EOF'
#include <mc/host>
#include <mc/core>
#include <user_default>
EOF

cat > "$tmp/bad.mc" <<'EOF'
#include <no/such/module>
i64 main() { return 0; }
EOF

fails=0
here=$(pwd)
cd "$tmp" || exit 1

step_fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# 1. a program from <sys> + <prelude>
if ! msg=$(./mc --exe hello.mc -o hello 2>&1); then
    step_fail "compiling hello.mc with <sys>/<prelude>: $msg"
else
    out=$(./hello 2>/dev/null); rc=$?
    if [ "$rc" != "42" ] || [ "$out" != "standalone" ]; then
        step_fail "hello: exit $rc, stdout '$out' (expected 42 / standalone)"
    else
        echo "ok <sys> + <prelude>: hello runs, exit 42"
    fi
fi

# 2. a taught compiler from <mc/core> + a syntax module
if ! msg=$(./mc --exe mymc.mc -o mymc 2>&1); then
    step_fail "building the taught compiler from <mc/core>: $msg"
elif ! msg=$(codesign --verify --verbose=4 ./mymc 2>&1); then
    step_fail "signature of the taught compiler: $msg"
else
    echo "ok <mc/core> + <user_syntax_demo>: taught compiler built and signed"
    # 3. it compiles what the default compiler cannot
    if ! msg=$(./mymc --exe t.mc -o t 2>&1); then
        step_fail "the taught compiler did not compile <syntax_demo_test>: $msg"
    else
        ./t; rc=$?
        if [ "$rc" != "42" ]; then
            step_fail "<syntax_demo_test> returned $rc, expected 42"
        else
            echo "ok the taught compiler compiles <syntax_demo_test> (exit 42)"
        fi
    fi
    if msg=$(./mc --exe t.mc -o t2 2>&1); then
        step_fail "the copied compiler accepted <syntax_demo_test>"
    else
        echo "ok the copied compiler rejects the same source ($msg)"
    fi
fi

# 4. the bundled core is the core in src/, byte for byte
if ! msg=$(./mc def.mc -o def.o 2>&1); then
    step_fail "compiling <mc/core> + <user_default>: $msg"
elif ! cmp def.o ref.o; then
    step_fail "the object from <mc/core> differs from the one from src/mc.mc"
else
    echo "ok <mc/host> + <mc/core> + <user_default> == src/mc.mc, byte for byte"
fi

# 5. a name that is not in the bundle
msg=$(./mc bad.mc -o bad.o 2>&1)
if [ $? -eq 0 ]; then
    step_fail "an unknown bundled include was accepted"
elif ! printf '%s' "$msg" | grep -q 'unknown bundled include: no/such/module'; then
    step_fail "wrong message for an unknown bundled include: $msg"
else
    echo "ok unknown name: $msg"
fi

cd "$here" || exit 1
if [ "$fails" -eq 0 ]; then
    echo "standalone: the binary alone is the toolchain"
fi
[ "$fails" -eq 0 ]
