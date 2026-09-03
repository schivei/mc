#!/bin/sh
# check-limits.sh [MC] — the seed guard of M23 (docs/specs/M23.md, § Seed guard).
#
# `src/*.mc` has no MAX* left: every table grows on demand. `stage0/*.c` still
# has its fixed ceilings, and stage0 has to keep compiling exactly one program,
# `src/mc.mc`. This script is the early warning the architect lacked at M15: it
# runs `mc limits src/mc.mc`, reads the seed's constants straight out of
# stage0/mc.h and stage0/*.c, and FAILS when the self-hosted compiler uses more
# than 90% of any of them.
#
# The verdict `mc limits` itself returns (0 / 3) is NOT what decides here: this
# check is about the seed's headroom, not about how good the estimate was.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

tmp="${TMPDIR:-/tmp}/check-limits.$$"
mkdir -p "$tmp"

# exit 3 means `grew`/`tight`, which is a report, not a failure; only a real
# compile error (1, or anything else) stops us
"$mc" limits src/mc.mc > "$tmp/o" 2>&1
rc=$?
if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
    echo "FAIL: $mc limits src/mc.mc exited $rc"
    sed -n '1,10p' "$tmp/o"
    rm -rf "$tmp"
    exit 1
fi

# used count of one table in the report
used() {
    awk -v t="$1" '$1 == t { print $4 }' "$tmp/o"
}

# value of a #define in the seed's C sources
seed() {
    grep -h "^#define $1[[:space:]]" stage0/mc.h stage0/*.c 2>/dev/null |
        head -1 | awk '{ print $3 }'
}

fails=0
total=0

# table in `mc limits` -> constant in stage0. Tables the seed grows on demand
# (nodes, symbols, msecs) have no constant and are left out on purpose.
check() {
    total=$((total + 1))
    u=$(used "$1")
    c=$(seed "$2")
    if [ -z "$u" ] || [ -z "$c" ]; then
        echo "FAIL $1: no usage ('$u') or no $2 in stage0 ('$c')"
        fails=$((fails + 1)); return
    fi
    pct=$((u * 100 / c))
    if [ "$pct" -gt 90 ]; then
        echo "FAIL $1: $u/$c = $pct% of the seed's $2 (over 90%)"
        fails=$((fails + 1)); return
    fi
    printf 'ok   %-9s %6s / %-6s %3s%%  (%s)\n' "$1" "$u" "$c" "$pct" "$2"
}

check tokens   MAXTOK
check includes MAXINC
check opens    MAXOPEN
check defines  MAXDEFS
check infix    MAXOPS
check prefix   MAXOPS
check opcodes  MAXOPCS
check sections MAXSECS
check rules    MAXRULES
check funcs    MAXFUNCS
check lowered  MAXFUNCS
check globals  MAXGLOBALS
check strings  MAXSTRS
check locals   MAXLOCALS
check loops    MAXLOOPS
check prel     MAXPREL

rm -rf "$tmp"
echo "$((total - fails))/$total seed limits under 90%"
[ "$fails" -eq 0 ]
