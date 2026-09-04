#!/bin/sh
# check-build.sh [MC] — acceptance criterion for M14's `mc build`.
#
# tests/proj/ is one program (app.mc + inc/db.mc) and three configs, so that
# every knob of the TOML is exercised by something that actually runs:
#
#   exe.toml   [include].paths + [libs]/[externs] + the built-in --exe backend
#              -> a signed binary that loads libsqlite3 by ordinal, no ld
#   link.toml  [linker] cmd/args with {out} {obj} {sdk} {libs}
#              -> mc writes the .o and `ld` produces the binary
#   obj.toml   kind = "obj" -> stop at the relocatable object
#
# app.mc's `#include "db.mc"` only resolves through [include].paths: without it
# the build stops, which is the check for that key. `sqlite3_libversion` has no
# `#dylib` anywhere -- the library comes from [libs] + [externs].
#
# M25 adds four more over tests/proj/lin.mc and the three sysroot-*.toml: the
# resolution chain of src/sysroot.mc -- an explicit path that is not a sysroot
# (exit 2, naming the missing marker), the cache road, the populated explicit
# path (same object, byte for byte) and --sysroot-dir.
#
# The last section checks the diagnostics: a foreign [target].os, os = "linux"
# with no [linker] (M16), a missing key and a bad [project].kind have to come
# out with file:line:col and exit 1.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

dir="tests/proj"
tmp="${TMPDIR:-/tmp}/check-build.$$"
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
mkdir -p "$tmp"
fails=0
total=0

want_exit=$(sed -n 's|^// expect-exit: *||p' "$dir/app.mc" | head -1)
want_out=$(sed -n 's|^// expect-stdout: *||p' "$dir/app.mc" | head -1)

ok()   { echo "ok $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

# runs a binary and compares it against app.mc's header
run_check() {
    got_out=$("$1" 2>/dev/null)
    got_exit=$?
    if [ "$got_exit" != "$want_exit" ]; then
        fail "$2" "exit $got_exit, expected $want_exit"; return 1
    fi
    if [ "$got_out" != "$want_out" ]; then
        fail "$2" "stdout '$got_out', expected '$want_out'"; return 1
    fi
    ok "$2"
}

rm -rf "$dir/build"

# ---- exe.toml: the direct executable ----
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/exe.toml" > "$tmp/o" 2>&1; then
    fail "exe.toml" "$(cat "$tmp/o")"
else
    sed 's|^|  |' "$tmp/o"
    run_check "$dir/build/app-exe" "exe.toml"
fi

total=$((total + 1))
if ! msg=$(codesign --verify --verbose=2 "$dir/build/app-exe" 2>&1); then
    fail "exe.toml signature" "$msg"
else
    ok "exe.toml signature"
fi

total=$((total + 1))
if ! otool -L "$dir/build/app-exe" | grep -q libsqlite3; then
    fail "exe.toml [libs]" "libsqlite3 not in otool -L (so [libs]/[externs] did not apply)"
else
    ok "exe.toml [libs] -> libsqlite3 bound by ordinal"
fi

# ---- link.toml: external linker with the four placeholders ----
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/link.toml" > "$tmp/o" 2>&1; then
    fail "link.toml" "$(cat "$tmp/o")"
else
    sed 's|^|  |' "$tmp/o"
    run_check "$dir/build/app-ld" "link.toml"
fi

total=$((total + 1))
if [ -e "$dir/build/app-ld.sdk" ]; then
    fail "link.toml {sdk}" "the temporary file build/app-ld.sdk was left behind"
else
    ok "link.toml {sdk} temporary removed"
fi

# ---- obj.toml: kind = "obj" ----
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/obj.toml" > "$tmp/o" 2>&1; then
    fail "obj.toml" "$(cat "$tmp/o")"
else
    sed 's|^|  |' "$tmp/o"
    if ! nm -m "$dir/build/app.o" 2>/dev/null | grep -q 'undefined.*_sqlite3_libversion'; then
        fail "obj.toml" "_sqlite3_libversion is not undefined in build/app.o"
    else
        ok "obj.toml"
    fi
fi

# ---- M25: the [sysroot] resolution chain (src/sysroot.mc) ----
# Three cases over tests/proj/lin.mc, a linux/aarch64 program whose [linker] is
# `echo`, so the resolved directory comes out on stdout and nothing here needs
# ld.lld, musl or Docker.
#
#   sysroot-bad.toml    [sysroot].path at a directory that is not a sysroot ->
#                       exit 2, and the message names the missing marker
#   sysroot-cache.toml  no [sysroot].path: the chain falls through the probe
#                       (skipped -- the host is not linux/aarch64) to the cache
#   sysroot-ok.toml     [sysroot].path at a populated directory: what an mc.toml
#                       written before M25 says, still doing what it did
mkdir -p "$dir/build/sysroots/linux-aarch64"
: > "$dir/build/sysroots/linux-aarch64/crt1.o"
: > "$dir/build/sysroots/linux-aarch64/libc.a"

total=$((total + 1))
"$mc" build "$dir" --config "$dir/sysroot-bad.toml" > "$tmp/o" 2>&1
rc=$?
if [ "$rc" != "2" ]; then
    fail "sysroot-bad.toml" "exit $rc, expected 2"
elif ! grep -q "no sysroot for linux-aarch64" "$tmp/o"; then
    fail "sysroot-bad.toml" "no 'no sysroot for linux-aarch64' in: $(cat "$tmp/o")"
elif ! grep -q "tests/proj/inc (no crt1.o)" "$tmp/o"; then
    fail "sysroot-bad.toml" "the message does not name the missing marker: $(cat "$tmp/o")"
else
    ok "sysroot-bad.toml -> exit 2, names the missing marker"
    sed -n '/no sysroot/,$p' "$tmp/o" | sed 's|^|  |'
fi

total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/sysroot-cache.toml" > "$tmp/o" 2>&1; then
    fail "sysroot-cache.toml" "$(cat "$tmp/o")"
elif ! grep -q "sysroot=$dir/build/sysroots/linux-aarch64 " "$tmp/o"; then
    fail "sysroot-cache.toml" "{sysroot} did not resolve to the cache: $(cat "$tmp/o")"
else
    ok "sysroot-cache.toml -> [sysroot].cache/<os>-<arch>"
    sed 's|^|  |' "$tmp/o"
fi

total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/sysroot-ok.toml" > "$tmp/o" 2>&1; then
    fail "sysroot-ok.toml" "$(cat "$tmp/o")"
elif ! grep -q "sysroot=$dir/build/sysroots/linux-aarch64 " "$tmp/o"; then
    fail "sysroot-ok.toml" "{sysroot} did not resolve to [sysroot].path: $(cat "$tmp/o")"
elif ! cmp -s "$dir/build/lin-ok.o" "$dir/build/lin-cache.o"; then
    fail "sysroot-ok.toml" "the object differs from the one the cache road wrote"
else
    ok "sysroot-ok.toml -> [sysroot].path, same object byte for byte"
fi

# --sysroot-dir names the directory ITSELF, and wins over [sysroot].cache
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/sysroot-cache.toml" \
        --sysroot-dir "$dir/build/sysroots/linux-aarch64" > "$tmp/o" 2>&1; then
    fail "--sysroot-dir" "$(cat "$tmp/o")"
elif ! grep -q "sysroot=$dir/build/sysroots/linux-aarch64 " "$tmp/o"; then
    fail "--sysroot-dir" "not honoured: $(cat "$tmp/o")"
else
    ok "--sysroot-dir DIR"
fi

# ---- diagnostics ----
# name, config path, config body, expected LAST line of output (CFG = config path).
# The error is always the last thing printed: a step line may come first.
diag() {
    total=$((total + 1))
    printf '%s' "$3" > "$2"
    "$mc" build "$dir" --config "$2" > "$tmp/o" 2>&1
    rc=$?
    got=$(tail -1 "$tmp/o")
    want=$(printf '%s' "$4" | sed "s|CFG|$2|")
    if [ "$rc" != "1" ]; then
        fail "$1" "exit $rc, expected 1"
    elif [ "$got" != "$want" ]; then
        fail "$1" "got '$got', expected '$want'"
    else
        ok "$1"
        echo "  $got"
    fi
}

diag "diag [target].os" "$tmp/d.toml" \
    '[project]
entry = "app.mc"
out   = "build/x"

[target]
os = "haiku"
' \
    'CFG:6:6: only macos, linux and windows (see docs/build.md): target.os'

# M16: os = "linux" is valid, but there is no direct executable for it -- a
# Linux build always hands the object to [linker].
diag "diag [target].os linux without [linker]" "$tmp/d.toml" \
    '[project]
entry = "app.mc"
out   = "build/x"

[target]
os = "linux"
' \
    'CFG:6:6: linux requires [linker]: there is no direct executable: target.os'

# M19: the same for Windows -- valid os, no direct executable, and the message
# names the operating system the file asked for.
diag "diag [target].os windows without [linker]" "$tmp/d.toml" \
    '[project]
entry = "app.mc"
out   = "build/x"

[target]
os = "windows"
' \
    'CFG:6:6: windows requires [linker]: there is no direct executable: target.os'

diag "diag missing project.entry" "$tmp/d.toml" \
    '[project]
out = "build/x"
' \
    'CFG: missing key: project.entry'

diag "diag bad project.kind" "$tmp/d.toml" \
    '[project]
entry = "app.mc"
out   = "build/x"
kind  = "lib"
' \
    'CFG:4:9: must be exe or obj: project.kind'

# the same program with no [include].paths: `#include "db.mc"` has nowhere left to
# resolve. The config goes inside build/ so that `entry` still points at app.mc.
diag "diag [include].paths missing" "$dir/build/noinc.toml" \
    '[project]
entry = "../app.mc"
out   = "noinc-out"
' \
    'mc: cannot open: tests/proj/db.mc'

rm -rf "$tmp"
echo "$((total - fails))/$total mc build checks passed"
[ "$fails" -eq 0 ]
