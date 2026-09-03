#!/bin/sh
# test.sh — acceptance test for `examples/desktop` (M32): a GTK4 application
# written in `mc`, and the same application written in a taught UI language.
#
#   sh examples/desktop/test.sh       # from the repository root
#   make check-desktop                # the same, from the root Makefile
#
# Six steps:
#
#   1. `mc build examples/desktop` reads mc.toml and compiles main.mc into a
#      signed executable linked against the four Homebrew GTK4 dylibs, with no
#      make, no ld and no pkg-config in the build itself.
#   2. `mc build ... --config ui.toml` assembles the taught compiler
#      (build/mc-ui = the `mc` core from the bundle plus ui.mc) and compiles
#      main.ui with it.
#   3. both binaries run `--self-test`, which builds the widget tree, drives the
#      handlers directly and reads the values back out of the widgets. The two
#      outputs must be IDENTICAL and must match the expected text below.
#   4. `otool -L` on both must list libSystem plus the four GTK dylibs, and
#      `codesign --verify` must pass.
#   5. the DEFAULT compiler must refuse main.ui: `window` belongs to ui.mc.
#   6. the real application is launched for 3 seconds and killed with SIGTERM,
#      which proves the GTK main loop actually starts (exit code 143 = 128 + 15).
#
# EVERYTHING is skipped, with exit 0, when `pkg-config --exists gtk4` fails --
# the GitHub runners have no GTK4 at all and never open a window. Step 6 alone
# can also be skipped with MC_DESKTOP_NO_GUI=1, for a machine that has the
# libraries but no window server.
#
# Depends on ../../build/mc1 (built if missing), pkg-config, otool and codesign.

root=$(cd "$(dirname "$0")/../.." && pwd)
dir="$root/examples/desktop"
mc="$root/build/mc1"
appa="$dir/build/desktop"
appb="$dir/build/desktop-ui"
mcui="$dir/build/mc-ui"
tmp="/tmp/mc_desktop_test_$$"
fails=0

cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM
mkdir -p "$tmp"

fail() {
    echo "  FAIL  $1"
    shift
    for line in "$@"; do echo "        $line"; done
    fails=$((fails + 1))
}

# ---- the one guard: no GTK4, no test ----
if ! pkg-config --exists gtk4 2>/dev/null; then
    echo "check-desktop: SKIPPED (pkg-config --exists gtk4 failed: no GTK4 here)"
    exit 0
fi
echo "== GTK4 $(pkg-config --modversion gtk4) =="

# the four dylibs mc.toml names, by hand: a missing one is a clearer failure
# here than a dyld error three steps later
for lib in libgtk-4.1 libgobject-2.0.0 libgio-2.0.0 libglib-2.0.0; do
    if [ ! -e "/opt/homebrew/lib/$lib.dylib" ]; then
        echo "check-desktop: SKIPPED (/opt/homebrew/lib/$lib.dylib is missing)"
        exit 0
    fi
done

# ---- 1 + 2: both builds ----
echo "== mc build (Part A: main.mc, Part B: main.ui) =="
if [ ! -x "$mc" ]; then
    make -C "$root" mc1 || { echo "FAIL: make mc1"; exit 1; }
fi
"$mc" build "$dir" || { echo "FAIL: mc build examples/desktop"; exit 1; }
"$mc" build "$dir" --config "$dir/ui.toml" || { echo "FAIL: mc build --config ui.toml"; exit 1; }
[ -x "$appa" ] || { echo "FAIL: mc build did not produce $appa"; exit 1; }
[ -x "$mcui" ] || { echo "FAIL: mc build did not produce $mcui"; exit 1; }
[ -x "$appb" ] || { echo "FAIL: mc build did not produce $appb"; exit 1; }
echo "  ok    $appa ($(wc -c < "$appa" | tr -d ' ') bytes)"
echo "  ok    $mcui ($(wc -c < "$mcui" | tr -d ' ') bytes)"
echo "  ok    $appb ($(wc -c < "$appb" | tr -d ' ') bytes)"

# ---- 3: the two self-tests ----
cat > "$tmp/expect" <<'EOF'
count=1
echo=hello mc
rows=1
count=3
rows=2
about=About
ok
EOF

echo "== --self-test =="
for pair in "A:$appa" "B:$appb"; do
    part=${pair%%:*}
    bin=${pair#*:}
    "$bin" --self-test > "$tmp/out.$part" 2> "$tmp/err.$part"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "part $part --self-test exited $rc (expected 0)" "$(cat "$tmp/err.$part")"
    elif ! diff -u "$tmp/expect" "$tmp/out.$part" > "$tmp/diff.$part" 2>&1; then
        fail "part $part --self-test printed the wrong text" "$(cat "$tmp/diff.$part")"
    else
        echo "  ok    part $part: 7 lines, exit 0"
    fi
done

if diff -u "$tmp/out.A" "$tmp/out.B" > "$tmp/diff.AB" 2>&1; then
    echo "  ok    part A and part B print the same self-test output"
else
    fail "the two self-tests differ" "$(cat "$tmp/diff.AB")"
fi

# ---- 4: linkage and signature ----
echo "== otool -L / codesign =="
for pair in "A:$appa" "B:$appb"; do
    part=${pair%%:*}
    bin=${pair#*:}
    otool -L "$bin" > "$tmp/otool.$part"
    missing=""
    for lib in libSystem.B.dylib libgtk-4.1.dylib libgobject-2.0.0.dylib \
               libgio-2.0.0.dylib libglib-2.0.0.dylib; do
        grep -q "$lib" "$tmp/otool.$part" || missing="$missing $lib"
    done
    if [ -n "$missing" ]; then
        fail "part $part: otool -L is missing$missing" "$(cat "$tmp/otool.$part")"
    else
        echo "  ok    part $part: libSystem + the four GTK dylibs"
    fi
    if codesign --verify --verbose=2 "$bin" > "$tmp/cs.$part" 2>&1; then
        echo "  ok    part $part: codesign --verify"
    else
        fail "part $part: codesign --verify" "$(cat "$tmp/cs.$part")"
    fi
done

# ---- 5: the default compiler must refuse the DSL ----
echo "== the default compiler refuses main.ui =="
if "$mc" "$dir/main.ui" -o "$tmp/refused.o" > "$tmp/refuse.out" 2>&1; then
    fail 'build/mc1 accepted main.ui; the word window is supposed to belong to ui.mc'
else
    echo "  ok    $(head -1 "$tmp/refuse.out")"
fi

# ---- 6: the real main loop ----
# No gtimeout on this machine, so the shell does it: start, wait, SIGTERM.
# `wait` reports 128 + signal, so a clean kill is 143. Anything else means the
# process was already gone -- which is what a GTK failure looks like.
if [ "${MC_DESKTOP_NO_GUI:-0}" = "1" ]; then
    echo "== 3-second GUI run: SKIPPED (MC_DESKTOP_NO_GUI=1) =="
else
    echo "== 3-second GUI run (SIGTERM) =="
    for pair in "A:$appa" "B:$appb"; do
        part=${pair%%:*}
        bin=${pair#*:}
        "$bin" > "$tmp/gui.$part" 2>&1 &
        pid=$!
        sleep 3
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null
            wait "$pid"
            rc=$?
            if [ "$rc" -eq 143 ]; then
                echo "  ok    part $part: main loop ran 3 s, SIGTERM -> exit $rc"
            else
                fail "part $part: SIGTERM gave exit $rc (expected 143)" \
                     "$(cat "$tmp/gui.$part")"
            fi
        else
            wait "$pid"
            fail "part $part: the app died before 3 s (exit $?)" "$(cat "$tmp/gui.$part")"
        fi
    done
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "check-desktop: all checks passed"
    exit 0
fi
echo "check-desktop: $fails FAILED"
exit 1
