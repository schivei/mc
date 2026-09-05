#!/bin/sh
# test-exe.sh COMPILER — the whole suite via the path with no `ld`: for each
# tests/*.mc, compiles straight to build/tests-exe/NAME with --exe, runs it,
# and compares against the source's header, exactly like scripts/test.sh does
# via the .o + ld path:
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
# On macOS it also checks that the binary is signed ad hoc (codesign --verify).
# Only the .mc compiler has --exe; stage0 in C does not (docs/surface.md § Tier 2).
#
# M42: `--exe` is no longer macOS-only. It resolves the HOST's direct-executable
# backend through the target registry (src/cli.mc), and both Linux targets have
# one now, so this script is what proves `mc --exe` on a Linux host -- the same
# corpus, natively, with no linker. Two things are then host-dependent and both
# are asked rather than assumed: `codesign` exists only on macOS, and a test
# carrying a `// skip-<os>:` header for THIS host is not portable to it (that is
# tests/032-svc.mc, whose syscalls are Darwin's).
#
# The third host-dependent thing is the libc, and it is the one place this
# script cannot use the flag it is named after. A dynamic ELF executable names
# its loader BY PATH, and `mc --exe` has no way to be told which one: the two
# names are TOML keys ([target].interp and [target].libc), and the writer's
# default is musl -- deliberately a CONSTANT and not a probe of the machine, so
# that the same source gives the same bytes on every host (docs/determinism.md).
# On a glibc Linux host a musl-linked binary does not start at all, so there the
# executables are written through `mc build` with the two keys instead. It is
# the same backend, the same object and the same corpus; what differs is the
# eighteen bytes of PT_INTERP. The line printed below says which road was taken.
mc="${1:-build/mc1}"
mkdir -p build/tests-exe
fails=0
total=0
skipped=""
host_os=$("$mc" --host | sed -n 's|^os ||p')
host_arch=$("$mc" --host | sed -n 's|^arch ||p')

# which road, and the two glibc names when it is that one
road="--exe"
interp=""
soname=""
if [ "$host_os" = "linux" ]; then
    have_musl=0
    for l in /lib/ld-musl-*.so.1; do
        [ -e "$l" ] && have_musl=1
    done
    if [ "$have_musl" = "0" ]; then
        road="build"
        soname="libc.so.6"
        case "$host_arch" in
            aarch64) interp="/lib/ld-linux-aarch64.so.1" ;;
            x86_64)  interp="/lib64/ld-linux-x86-64.so.2" ;;
            *) echo "FAIL: no known glibc loader for linux/$host_arch"; exit 1 ;;
        esac
    fi
fi

# compile one test to an executable, by whichever road this host needs
build_exe() {                            # source, output
    if [ "$road" = "--exe" ]; then
        "$mc" --exe "$1" -o "$2" 2>&1
        return $?
    fi
    cfg="build/tests-exe/mc.toml"
    {
        echo '[project]'
        echo "entry = \"$PWD/$1\""
        echo "out   = \"$PWD/$2\""
        echo ''
        echo '[target]'
        echo "os   = \"$host_os\""
        echo "arch = \"$host_arch\""
        echo "interp = \"$interp\""
        echo "libc   = \"$soname\""
    } > "$cfg"
    "$mc" build "$PWD/build/tests-exe" --config "$PWD/$cfg" > /dev/null 2>&1 \
        || "$mc" build "$PWD/build/tests-exe" --config "$PWD/$cfg" 2>&1
    return $?
}

for f in tests/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    why=$(sed -n "s|^// skip-$host_os: *||p" "$f" | head -1)
    [ -n "$why" ] || why=$(sed -n "s|^// skip-$host_arch: *||p" "$f" | head -1)
    if [ -n "$why" ]; then
        skipped="$skipped
  $name — $why"
        continue
    fi
    total=$((total + 1))
    exe="build/tests-exe/$name"

    want_exit=$(sed -n 's|^// expect-exit: *||p' "$f" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$f" | head -1)
    has_out=$(grep -c '^// expect-stdout:' "$f")

    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no expect-exit header)"; fails=$((fails + 1)); continue
    fi
    rm -f "$exe"
    if ! msg=$(build_exe "$f" "$exe"); then
        echo "FAIL $name (compilation: $msg)"; fails=$((fails + 1)); continue
    fi
    if [ "$host_os" = "macos" ] && ! msg=$(codesign --verify --verbose=4 "$exe" 2>&1); then
        echo "FAIL $name (signature: $msg)"; fails=$((fails + 1)); continue
    fi

    got_out=$("$exe" 2>/dev/null)
    got_exit=$?
    if [ "$got_exit" != "$want_exit" ]; then
        echo "FAIL $name (exit $got_exit, expected $want_exit)"; fails=$((fails + 1)); continue
    fi
    if [ "$has_out" != "0" ] && [ "$got_out" != "$want_out" ]; then
        echo "FAIL $name (stdout '$got_out', expected '$want_out')"; fails=$((fails + 1)); continue
    fi
    echo "ok $name"
done

if [ "$road" = "--exe" ]; then
    echo "$((total - fails))/$total tests passed via --exe"
else
    echo "$((total - fails))/$total tests passed via mc build (glibc host: interp = $interp)"
fi
if [ -n "$skipped" ]; then
    echo "skipped (not portable to this host):$skipped"
fi
[ "$fails" -eq 0 ]
