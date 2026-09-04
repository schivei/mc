#!/bin/sh
# check-mc.sh COMPILER — the tests that only the self-hosted compiler can
# compile (M15). They live in tests/mc/, not in tests/, on purpose:
# `#embed` and `#include <name>` exist in src/*.mc and NOT in the frozen
# stage0/*.c, so scripts/test.sh, check-obj.sh, check-ast.sh and check-asm.sh —
# which all compare mc0 against mc1 over tests/*.mc — would report a difference
# that is the whole point of the milestone. Keeping them in their own directory
# leaves those four cross-checks meaning exactly what they meant before.
#
# Same header contract as scripts/test.sh:
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
# Every test is built twice: through .o + scripts/link.sh, and through --exe.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

mkdir -p build/tests-mc
fails=0
total=0

# M38: on Windows a program that is not called *.exe cannot be launched.
hostexe=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) hostexe=".exe" ;; esac

for f in tests/mc/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    total=$((total + 1))
    obj="build/tests-mc/$name.o"
    exe="build/tests-mc/$name$hostexe"
    exe2="build/tests-mc/$name-exe"

    want_exit=$(sed -n 's|^// expect-exit: *||p' "$f" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$f" | head -1)
    has_out=$(grep -c '^// expect-stdout:' "$f")

    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no expect-exit header)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$("$mc" "$f" -o "$obj" 2>&1); then
        echo "FAIL $name (compilation: $msg)"; fails=$((fails + 1)); continue
    fi
    if ! msg=$(scripts/link-host.sh "$exe" "$obj" 2>&1); then
        echo "FAIL $name (link: $msg)"; fails=$((fails + 1)); continue
    fi
    # M37: `--exe` writes a direct executable FOR THE HOST. Linux and Windows
    # are registered with no such backend -- since the post-M41 review batch
    # the flag is refused there, and before it it silently produced a macOS
    # binary this machine cannot run -- so the second half of each case is the
    # object + linker path only, and only macOS runs both.
    runs="$exe"
    if [ "$(uname -s)" = "Darwin" ]; then
        rm -f "$exe2"
        if ! msg=$("$mc" --exe "$f" -o "$exe2" 2>&1); then
            echo "FAIL $name (--exe: $msg)"; fails=$((fails + 1)); continue
        fi
        runs="$exe $exe2"
    fi

    bad=0
    for run in $runs; do
        got_out=$("$run" 2>/dev/null)
        got_exit=$?
        if [ "$got_exit" != "$want_exit" ]; then
            echo "FAIL $name ($run: exit $got_exit, expected $want_exit)"; bad=1
        fi
        if [ "$has_out" != "0" ] && [ "$got_out" != "$want_out" ]; then
            echo "FAIL $name ($run: stdout '$got_out', expected '$want_out')"; bad=1
        fi
    done
    if [ "$bad" != "0" ]; then fails=$((fails + 1)); continue; fi
    echo "ok $name"
done

# the seed has to REFUSE these sources: the directives are Phase 2 surface that
# only lives in src/*.mc (docs/surface.md § Tier 1, M15)
if [ -x build/mc0 ]; then
    for f in tests/mc/070-embed.mc tests/mc/072-include-bundle.mc; do
        total=$((total + 1))
        if msg=$(build/mc0 "$f" -o build/tests-mc/seed.o 2>&1); then
            echo "FAIL: build/mc0 accepted $f"; fails=$((fails + 1))
        else
            echo "ok build/mc0 rejects $f ($msg)"
        fi
    done
fi

echo "$((total - fails))/$total mc-only tests passed"
[ "$fails" -eq 0 ]
