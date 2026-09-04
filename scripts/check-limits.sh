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
# M17 added the seventeenth row, the one whose absence cost a milestone: the
# ARENA. Every MAX* table was under 57% when `build/mc0 src/mc.mc` started
# dying with `arena exhausted`, because the thing that was full is not a table
# -- it is `HEAP_SIZE` in stage0/arena.c, and the seed's growable arrays double
# and never free (`nodes_grow` in stage0/ast.c leaves every earlier copy behind,
# which is most of what is resident). See docs/build.md § limits.
#
# The verdict `mc limits` itself returns (0 / 3) is NOT what decides here: this
# check is about the seed's headroom, not about how good the estimate was.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

tmp="${TMPDIR:-/tmp}/check-limits.$$"
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
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

# HEAP_SIZE is written `(64u << 20)`, so it needs its own reader
heap_bytes() {
    grep -h '^#define HEAP_SIZE' stage0/arena.c 2>/dev/null |
        sed -E 's/.*\(([0-9]+)u? *<< *([0-9]+)\).*/\1 \2/' |
        awk '{ printf "%d", $1 * (2 ^ $2) }'
}

# The seed cannot report its own high-water mark, and instrumenting it would be
# a change to the frozen seed. The proxy is the maximum resident set size of one
# real run: the arena is a bss array, so only the pages the bump allocator
# actually touched are resident, plus a megabyte or two of the binary itself. It
# over-reports a little, which is the safe direction for a guard.
seed_rss() {
    out=$(/usr/bin/time -l build/mc0 src/mc.mc -o "$tmp/seed.o" 2>&1 >/dev/null)
    v=$(printf '%s\n' "$out" | awk '/maximum resident set size/ { print $1 }')
    if [ -z "$v" ]; then                          # GNU time, in kilobytes
        v=$(printf '%s\n' "$out" | awk -F': *' '/Maximum resident set size/ { print $2 * 1024 }')
    fi
    printf '%s' "$v"
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

# the arena, in bytes rather than elements
check_heap() {
    total=$((total + 1))
    c=$(heap_bytes)
    if [ -z "$c" ]; then
        echo "FAIL heap: HEAP_SIZE is not in stage0/arena.c"
        fails=$((fails + 1)); return
    fi
    # M37: the seed is a macOS program and there is no build/mc0 on a Linux
    # host. The row measures the SEED's arena, so on a host that cannot run it
    # the honest answer is that it was not measured, not a failure -- the macOS
    # job in CI is what guards this ceiling.
    if [ ! -x build/mc0 ]; then
        echo "ok   heap      SKIPPED (no build/mc0 on this host: the C seed is macOS-only)"
        return
    fi
    u=$(seed_rss)
    if [ -z "$u" ]; then
        echo "ok   heap      SKIPPED (no /usr/bin/time -l on this system)"
        return
    fi
    pct=$((u * 100 / c))
    if [ "$pct" -gt 90 ]; then
        echo "FAIL heap: $u/$c = $pct% of the seed's HEAP_SIZE (over 90%)"
        echo "     the C seed can no longer compile src/mc.mc for much longer;"
        echo "     raise HEAP_SIZE in stage0/arena.c (see docs/build.md § limits)"
        fails=$((fails + 1)); return
    fi
    printf 'ok   %-9s %6s / %-6s %3s%%  (%s)\n' heap \
        "$((u / 1048576))Mi" "$((c / 1048576))Mi" "$pct" "HEAP_SIZE, max RSS of build/mc0"
}

check_heap

rm -rf "$tmp"
echo "$((total - fails))/$total seed limits under 90%"
[ "$fails" -eq 0 ]
