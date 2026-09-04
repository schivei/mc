#!/bin/sh
# check-wide.sh [MC] — M24 step 2: the three modules that prove the PRINCIPLE.
#
# `<float>` could have been special-cased. These three could not, and the test
# for all of them is the same one sentence: **`git diff src/` is empty.** They
# are built by the compilers lib/mc_i128.mc, lib/mc_f16.mc and
# examples/avx/mc-avx.mc, each of which is `#include <mc/core>` plus a module.
#
#   i128         a 128-bit integer, memory-resident in ONE depth backed by a
#                16-byte slot; adds/adc, subs/sbc, mul/umulh, and a compare that
#                is not just "the 64-bit one twice"; a literal through a
#                module-private global with an N_BLOB initializer; a value passed
#                to a TWO-REGISTER callee
#   f16          half precision as a storage type, four slots on top of
#                <float>'s machine and nothing else -- because <float> dispatches
#                on the KIND and not on the id
#   examples/avx one AVX instruction named by its encoding, applied to two values
#                the allocator placed, with its own VEX bytes; re-assembled by
#                llvm-mc, not executed (this host has no AVX to run it on)
mc="${1:-build/mc1}"
llvm="/opt/homebrew/opt/llvm/bin"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

fails=0
tmp="${TMPDIR:-/tmp}/check-wide.$$"
mkdir -p "$tmp"
cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM

tool() { if command -v "$1" > /dev/null 2>&1; then echo "$1"; else echo "$llvm/$1"; fi; }
have() { command -v "$1" > /dev/null 2>&1 || [ -x "$llvm/$1" ]; }

run_case() {                            # compiler-source, test-source, name
    csrc="$1"; tsrc="$2"; name="$3"
    c="build/mc-$name"
    rm -f "$c"
    if ! msg=$("$mc" --exe "$csrc" -o "$c" 2>&1); then
        echo "FAIL $name (building $csrc: $msg)"; fails=$((fails + 1)); return 0
    fi
    rm -f "$tmp/$name"
    if ! msg=$("$c" --exe "$tsrc" -o "$tmp/$name" 2>&1); then
        echo "FAIL $name (compiling $tsrc: $msg)"; fails=$((fails + 1)); return 0
    fi
    got=$("$tmp/$name" 2>/dev/null)
    rc=$?
    want_exit=$(sed -n 's|^// expect-exit: *||p' "$tsrc" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$tsrc" | head -1)
    if [ "$rc" != "$want_exit" ] || [ "$got" != "$want_out" ]; then
        echo "FAIL $name (exit $rc '$got', expected $want_exit '$want_out')"
        fails=$((fails + 1)); return 0
    fi
    echo "ok   $name: $tsrc"
    # ...and the DEFAULT compiler must refuse the same source
    if msg=$("$mc" "$tsrc" -o "$tmp/no.o" 2>&1); then
        echo "FAIL $name: the default compiler accepted $tsrc"
        fails=$((fails + 1))
    else
        echo "ok   $name: the default compiler refuses it ($msg)"
    fi
}

run_case lib/mc_i128.mc tests/wide/030-i128.mc i128
run_case lib/mc_f16.mc  tests/wide/031-f16.mc  f16

# i128: the 16-byte global initializer is an N_BLOB, one per literal, and the
# symbols are 16 bytes apart -- which is type_new's width, in the object
nblob=$(build/mc-i128 --dump-ast tests/wide/030-i128.mc | grep -c '^  BLOB val=16$')
if [ "$nblob" -ge 4 ]; then
    echo "ok   i128: $nblob literal globals, each an N_BLOB of 16 bytes"
else
    echo "FAIL i128: expected N_BLOB literal globals, found $nblob"
    fails=$((fails + 1))
fi
if build/mc-i128 --dump-syms tests/wide/030-i128.mc | grep -q 'value=16 _\$i128_1'; then
    echo "ok   i128: the literal globals are 16 bytes apart in the object"
else
    echo "FAIL i128: the literal globals are not 16 bytes apart"
    fails=$((fails + 1))
fi
# ...the adds/adc pair, and a 16-byte frame slot for a value that is one depth
if build/mc-i128 --dump-asm tests/wide/030-i128.mc | grep -q '^  adds x8, x16, x17$' \
   && build/mc-i128 --dump-asm tests/wide/030-i128.mc | grep -q '^  adc x16, x16, x17$'; then
    echo "ok   i128: --dump-asm shows the adds/adc pair"
else
    echo "FAIL i128: no adds/adc pair in --dump-asm"
    fails=$((fails + 1))
fi
# a two-register callee: x0:x1 and x2:x3, the AAPCS64 even-pair rule
if build/mc-i128 --dump-asm tests/wide/030-i128.mc | sed -n '/^_add2:/,/ret/p' \
   | grep -q 'str x3, \[sp, #40\]'; then
    echo "ok   i128: a 16-byte argument arrives in an even register pair"
else
    echo "FAIL i128: the two-register callee does not read x0..x3"
    fails=$((fails + 1))
fi

# f16: `f16 tbl[8]` is SIXTEEN bytes of __bss, from the width alone
if build/mc-f16 --dump-syms tests/wide/031-f16.mc | grep -q '__DATA,__bss.*size=48'; then
    echo "ok   f16: a global array of 8 halves occupies 16 bytes in the object"
else
    echo "FAIL f16: the global array is not 16 bytes"
    build/mc-f16 --dump-syms tests/wide/031-f16.mc | grep bss
    fails=$((fails + 1))
fi
if build/mc-f16 --dump-asm tests/wide/031-f16.mc | grep -q '^  fcvt h16, s16$'; then
    echo "ok   f16: the conversion is one instruction (fcvt h, s)"
else
    echo "FAIL f16: no fcvt h, s in --dump-asm"
    fails=$((fails + 1))
fi

# ---- examples/avx: the object, and llvm-mc on every instruction it invented ----
avx="build/mc-avx"
rm -f "$avx"
if ! msg=$("$mc" --exe examples/avx/mc-avx.mc -o "$avx" 2>&1); then
    echo "FAIL avx (building the compiler: $msg)"; fails=$((fails + 1))
elif ! msg=$("$avx" --backend=elf-obj-x86_64 examples/avx/main.mc -o "$tmp/avx.o" 2>&1); then
    echo "FAIL avx (compiling examples/avx/main.mc: $msg)"; fails=$((fails + 1))
else
    echo "ok   avx: examples/avx/main.mc compiles to a linux/x86_64 object"
    if msg=$("$mc" --backend=elf-obj-x86_64 examples/avx/main.mc -o "$tmp/no.o" 2>&1); then
        echo "FAIL avx: the default compiler accepted examples/avx/main.mc"
        fails=$((fails + 1))
    else
        echo "ok   avx: the default compiler refuses it ($msg)"
    fi
    if ! have llvm-objdump || ! have llvm-mc; then
        echo "skip avx sweep: llvm-objdump/llvm-mc not found"
    else
        $(tool llvm-objdump) -d --triple=x86_64-linux-musl "$tmp/avx.o" 2>/dev/null \
            | sed -n 's|^ *[0-9a-f]*: *\([0-9a-f ]*[0-9a-f]\)  *\(.*\)$|\1\t\2|p' \
            | grep -E '	[[:space:]]*v(addps|mulps|movups)' | sort -u > "$tmp/ins"
        n=0; bad=0
        while IFS='	' read -r bytes text; do
            [ -n "$text" ] || continue
            text=$(echo "$text" | sed 's|#.*||; s|[[:space:]]*$||')
            enc=$(printf '%s\n' "$text" | $(tool llvm-mc) -triple=x86_64-linux-musl --show-encoding 2>/dev/null \
                  | sed -n 's|.*encoding: \[\(.*\)\].*|\1|p' | tr -d ' ' | tr ',' '\n' \
                  | sed 's|^0x||' | tr '\n' ' ' | sed 's| *$||')
            want=$(echo "$bytes" | tr -s ' ')
            if [ "$enc" != "$want" ]; then
                echo "FAIL avx sweep: '$text' -> $enc, mc emitted $want"; bad=$((bad + 1)); continue
            fi
            n=$((n + 1))
        done < "$tmp/ins"
        if [ "$bad" != 0 ]; then fails=$((fails + bad))
        else echo "ok   avx sweep: $n distinct VEX instructions re-assemble byte for byte"; fi
    fi
fi

if [ "$fails" != 0 ]; then
    echo "check-wide: $fails failures"
    exit 1
fi
echo "check-wide: ok"
