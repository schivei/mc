#!/bin/sh
# test-linux.sh [MC] — the whole suite cross-compiled to linux/aarch64 and run
# for real (M16, docs/build.md § Linux targets).
#
# For each tests/*.mc the script writes a Linux mc.toml in a temporary directory
# (absolute paths, so the config's directory does not matter), runs
# `mc build --config` on it -- which compiles with the `elf-obj` backend and
# hands the object to `ld.lld` against the musl sysroot -- and then executes the
# binary inside `docker run --platform linux/arm64 alpine:3`, comparing exit
# code and stdout with the same headers scripts/test.sh uses:
#
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
#   // skip-linux: REASON    (this test is macOS-only; the reason is printed)
#
# The repository root is mounted at /w and is also the container's working
# directory, because a test may open its own source by a relative path
# (tests/025-linecount.mc does).
#
# The last case is the one with no libc at all: tests/linux/070-nolibc.mc uses
# `#include <sys_linux>` (raw `svc #0` syscalls plus a hand-written _start) and
# is linked with `-nostdlib -e _start`.
mc="${1:-build/mc1}"
img="alpine:3"
sysroot="build/sysroot/linux-aarch64"
outdir="build/tests-linux"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi
if ! command -v ld.lld >/dev/null 2>&1; then
    echo "FAIL: ld.lld not in PATH (brew install lld)"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "FAIL: docker is not running"
    exit 1
fi
# the same four files sysroot-linux.sh itself checks for: libc.a alone is not
# enough, a missing crt object only shows up later as an ld.lld error per test
if [ ! -f "$sysroot/libc.a" ] || [ ! -f "$sysroot/crt1.o" ] \
   || [ ! -f "$sysroot/crti.o" ] || [ ! -f "$sysroot/crtn.o" ]; then
    scripts/sysroot-linux.sh "$sysroot" || exit 1
fi

root=$(pwd)
tmp="${TMPDIR:-/tmp}/test-linux.$$"
mkdir -p "$tmp" "$outdir"
fails=0
total=0
skipped=""

# writes $tmp/mc.toml for one test. $1 = entry, $2 = out, $3 = the [linker] args
gen_toml() {
    {
        echo '[project]'
        echo "entry = \"$1\""
        echo "out   = \"$2\""
        echo
        echo '[target]'
        echo 'os   = "linux"'
        echo 'arch = "aarch64"'
        echo
        echo '[sysroot]'
        echo "path = \"$root/$sysroot\""
        echo
        echo '[linker]'
        echo 'cmd  = "ld.lld"'
        echo "args = [$3]"
    } > "$tmp/mc.toml"
}

MUSL_ARGS='"-o", "{out}", "{sysroot}/crt1.o", "{sysroot}/crti.o", "{obj}", "{libs}", "{sysroot}/libc.a", "{sysroot}/crtn.o"'
NOLIBC_ARGS='"-nostdlib", "-e", "_start", "-o", "{out}", "{obj}"'

# $1 = source, $2 = name, $3 = [linker] args
run_one() {
    f="$1"; name="$2"; largs="$3"
    total=$((total + 1))
    want_exit=$(sed -n 's|^// expect-exit: *||p' "$f" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$f" | head -1)
    has_out=$(grep -c '^// expect-stdout:' "$f")
    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no expect-exit header)"; fails=$((fails + 1)); return
    fi

    rm -f "$outdir/$name" "$outdir/$name.o"
    gen_toml "$root/$f" "$root/$outdir/$name" "$largs"
    if ! msg=$("$mc" build "$tmp" --config "$tmp/mc.toml" 2>&1); then
        echo "FAIL $name (build: $msg)"; fails=$((fails + 1)); return
    fi

    # stderr goes to a file, not to /dev/null: an exec-level failure (missing or
    # non-executable binary, wrong architecture, docker/QEMU trouble) only says
    # "exit 127" or "exit 255" otherwise, which reads exactly like the program
    # itself returning the wrong code
    got_out=$(docker run --rm --platform linux/arm64 -v "$root":/w -w /w "$img" \
              "/w/$outdir/$name" 2>"$tmp/err")
    got_exit=$?
    if [ "$got_exit" != "$want_exit" ]; then
        echo "FAIL $name (exit $got_exit, expected $want_exit)"
        err=$(cat "$tmp/err")
        [ -n "$err" ] && echo "     stderr: $err"
        fails=$((fails + 1)); return
    fi
    if [ "$has_out" != "0" ] && [ "$got_out" != "$want_out" ]; then
        echo "FAIL $name (stdout '$got_out', expected '$want_out')"; fails=$((fails + 1)); return
    fi
    echo "ok $name"
}

for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    why=$(sed -n 's|^// skip-linux: *||p' "$f" | head -1)
    if [ -n "$why" ]; then
        skipped="$skipped
  $name — $why"
        continue
    fi
    run_one "$f" "$name" "$MUSL_ARGS"
done

# the no-libc case: no crt objects, no libc.a, entry point _start
run_one tests/linux/070-nolibc.mc 070-nolibc "$NOLIBC_ARGS"

rm -rf "$tmp"
echo "$((total - fails))/$total tests passed on linux/arm64"
if [ -n "$skipped" ]; then
    echo "skipped (macOS only):$skipped"
fi
[ "$fails" -eq 0 ]
