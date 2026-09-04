#!/bin/sh
# test-linux.sh — the whole suite cross-compiled to Linux and run for real
# (M16 for linux/aarch64, M17 step B for linux/x86_64; docs/build.md § Linux
# targets).
#
#   test-linux.sh [--arch A] [MC]                       cross-compile, link, run
#   test-linux.sh [--arch A] --build-only OUTDIR [MC]   cross-compile only
#   test-linux.sh [--arch A] --run-only OUTDIR          link OUTDIR and run it
#
# --arch is aarch64 (the default) or x86_64. It picks the object backend through
# `[target].arch` in the generated mc.toml, the sysroot directory, the Docker
# platform and which `// skip-` header applies.
#
# For each tests/*.mc the default mode writes a Linux mc.toml in a temporary
# directory (absolute paths, so the config's directory does not matter), runs
# `mc build --config` on it -- which compiles with the `elf-obj` backend and
# hands the object to `ld.lld` against the musl sysroot -- and then executes the
# binary inside `docker run --platform linux/arm64|linux/amd64 alpine:3`
# (emulated on an Apple Silicon host for amd64), comparing exit code and stdout
# with the same headers scripts/test.sh uses:
#
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
#   // skip-linux: REASON    (this test is macOS-only; the reason is printed)
#   // skip-x86_64: REASON   (AArch64-specific: #opcode words, reloc() on a bl)
#
# The repository root is mounted at /w and is also the container's working
# directory, because a test may open its own source by a relative path
# (tests/025-linecount.mc does).
#
# The last case is the one with no libc at all: tests/linux/070-nolibc.mc uses
# `#include <sys_linux>` (raw `svc #0` syscalls plus a hand-written _start) and
# is linked with `-nostdlib -e _start`. Its syscalls are AArch64 words, so it
# carries a `// skip-x86_64:` header like any other test.
#
# The split modes (docs/ci.md) exist because the two halves need different
# machines: only macOS has `mc`, only a machine of the target architecture can
# run the result without emulation.
#
#   --build-only OUTDIR   needs `mc` and nothing else -- no ld.lld, no Docker,
#                         no sysroot. Writes OUTDIR/<name>.o (kind = "obj", so
#                         the driver stops at the ELF object), OUTDIR/<name>.expect
#                         with the header values, OUTDIR/manifest (one
#                         "<name> <linkmode>" line per object, in test order) and
#                         OUTDIR/skipped.
#   --run-only OUTDIR     needs ld.lld and the sysroot, not `mc`. Links each
#                         object and runs it: natively on a host of that
#                         architecture,
#                         otherwise in the same Docker container the default
#                         mode uses. The repository still has to be checked out,
#                         and the working directory still has to be its root.
#
# MC_SYSROOT overrides the sysroot directory (default
# build/sysroot/linux-<arch>) for the modes that link.
mode="full"
split=""
arch="aarch64"
mc=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)
            [ -n "$2" ] && [ "${2#-}" = "$2" ] \
                || { echo "FAIL: --arch needs a value (aarch64 | x86_64)" >&2; exit 1; }
            arch="$2"; shift 2
            ;;
        --arch=*) arch="${1#--arch=}"; shift ;;
        --build-only|--run-only)
            [ -n "$2" ] || { echo "FAIL: $1 needs a directory" >&2; exit 1; }
            if [ "$1" = "--build-only" ]; then mode="build"; else mode="run"; fi
            split="$2"; shift 2
            ;;
        *) mc="$1"; shift ;;
    esac
done

case "$arch" in
    aarch64) platform="linux/arm64" ;;
    x86_64)  platform="linux/amd64" ;;
    *) echo "FAIL: unknown --arch $arch (aarch64 | x86_64)" >&2; exit 1 ;;
esac
mc="${mc:-build/mc1}"
img="alpine:3"
sysroot="${MC_SYSROOT:-build/sysroot/linux-$arch}"
outdir="build/tests-linux-$arch"

if [ "$mode" != "run" ] && [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

# a host of the target architecture runs the binaries itself; anything else
# goes through Docker
native=0
if [ "$(uname -s)" = "Linux" ]; then
    case "$arch/$(uname -m)" in
        aarch64/aarch64|aarch64/arm64|x86_64/x86_64|x86_64/amd64) native=1 ;;
    esac
fi

if [ "$mode" != "build" ]; then
    if ! command -v ld.lld >/dev/null 2>&1; then
        echo "FAIL: ld.lld not in PATH (brew install lld)"
        exit 1
    fi
    # M37: Docker is only needed when this machine cannot execute the binaries
    # itself. On a Linux HOST of the target architecture -- which is where `make
    # check` runs this script since M37 -- every test runs natively.
    if [ "$native" = "0" ]; then
        if ! docker info >/dev/null 2>&1; then
            echo "FAIL: docker is not running"
            exit 1
        fi
    fi
    # the same four files sysroot-linux.sh itself checks for: libc.a alone is not
    # enough, a missing crt object only shows up later as an ld.lld error per test
    if [ ! -f "$sysroot/libc.a" ] || [ ! -f "$sysroot/crt1.o" ] \
       || [ ! -f "$sysroot/crti.o" ] || [ ! -f "$sysroot/crtn.o" ]; then
        scripts/sysroot-linux.sh --arch "$arch" "$sysroot" || exit 1
    fi
fi

# Homebrew hides the LLVM tools from the default PATH and a Linux distribution
# puts them under /usr/lib/llvm-*/bin; the same lookup scripts/test-windows.sh
# uses. Without them the two stack assertions below are skipped and say so --
# they are a property of the object, not of the program's behaviour, so they
# must not turn a green suite red on a machine that cannot inspect the file.
findtool() {
    t=$(command -v "$1" 2>/dev/null)
    if [ -z "$t" ]; then
        for cand in /opt/homebrew/opt/llvm/bin/"$1" /usr/local/opt/llvm/bin/"$1" \
                    /usr/lib/llvm-*/bin/"$1"; do
            if [ -x "$cand" ]; then t="$cand"; break; fi
        done
    fi
    echo "$t"
}
readobj=$(findtool llvm-readobj)
readelf=$(findtool llvm-readelf)
[ -n "$readelf" ] || readelf=$(command -v readelf 2>/dev/null)
notes=0                                  # objects whose .note.GNU-stack is right
stacks=0                                 # binaries whose PT_GNU_STACK is not X

# post-M41 review: every ELF object mc writes carries an empty `.note.GNU-stack`
# with sh_flags = 0. An object WITHOUT it tells the toolchain nothing, and an
# older toolchain then assumes the worst: GNU ld 2.35 answers PT_GNU_STACK RWE
# and GNU ld 2.38 drops the header entirely, leaving the kernel's own default
# (docs/reference/objects.md has the table). This is THE REGRESSION GUARD for
# that fix: it fails against a compiler whose ELF backend does not write the
# section. Asserted per object, on both architectures.
check_note() {                           # object, test name
    if [ -n "$readobj" ]; then           # the whole claim: type, flags and size
        got=$("$readobj" --sections "$1" 2>/dev/null | awk '
            /Name: \.note\.GNU-stack/ { inb = 1; next }
            inb && /Type:/            { type = $2 }
            inb && /Flags \[/         { flags = $3 }
            inb && /Size:/            { size = $2; exit }
            END                       { print type " " flags " " size }')
        if [ "$got" != "SHT_PROGBITS (0x0) 0" ]; then
            echo "FAIL $2 (.note.GNU-stack: got '$got', want 'SHT_PROGBITS (0x0) 0')"
            fails=$((fails + 1)); return 1
        fi
    elif [ -n "$readelf" ]; then         # a plain readelf: presence, at least
        if ! "$readelf" -SW "$1" 2>/dev/null | grep -q '\.note\.GNU-stack'; then
            echo "FAIL $2 (no .note.GNU-stack section in the object)"
            fails=$((fails + 1)); return 1
        fi
    else
        return 0
    fi
    notes=$((notes + 1))
    return 0
}

# and the END STATE, on the linked program: the header has to be there and it has
# to be RW, never RWE. This one is NOT a regression guard for the note. Both this
# script and CI link with ld.lld, which writes PT_GNU_STACK RW whether or not the
# inputs carry the section -- measured with ld.lld 22.1.7, where the program
# headers of the same program built by the two compilers, one commit apart, are
# byte-identical. It asserts the property that matters on the linker actually in
# use; check_note above is what catches the backend dropping the section.
check_stack() {                          # binary, test name
    [ -n "$readelf" ] || return 0
    got=$("$readelf" -lW "$1" 2>/dev/null | awk '$1 == "GNU_STACK" { print $(NF - 1) }')
    if [ -z "$got" ]; then
        echo "FAIL $2 (no PT_GNU_STACK in the linked binary)"
        fails=$((fails + 1)); return 1
    fi
    case "$got" in
        *E*) echo "FAIL $2 (PT_GNU_STACK is $got: the stack is executable)"
             fails=$((fails + 1)); return 1 ;;
    esac
    stacks=$((stacks + 1))
    return 0
}

root=$(pwd)
# M37: MC_SYSROOT may be an absolute path outside the repository -- on Alpine
# with musl-dev it is /usr/lib -- so it is not always root-relative.
case "$sysroot" in
    /*) sysabs="$sysroot" ;;
    *)  sysabs="$root/$sysroot" ;;
esac
tmp="${TMPDIR:-/tmp}/test-linux.$$"
mkdir -p "$tmp" "$outdir"
fails=0
total=0
skipped=""

if [ -n "$split" ]; then
    if [ "$mode" = "build" ]; then
        mkdir -p "$split" || exit 1
    elif [ ! -f "$split/manifest" ]; then
        echo "FAIL: '$split/manifest' not found (run --build-only first)"
        exit 1
    fi
    split=$(cd "$split" && pwd) || exit 1
fi

# writes $tmp/mc.toml for one test. $1 = entry, $2 = out, $3 = the [linker] args
gen_toml() {
    {
        echo '[project]'
        echo "entry = \"$1\""
        echo "out   = \"$2\""
        echo
        echo '[target]'
        echo 'os   = "linux"'
        echo "arch = \"$arch\""
        echo
        echo '[sysroot]'
        echo "path = \"$sysabs\""
        echo
        echo '[linker]'
        echo 'cmd  = "ld.lld"'
        echo "args = [$3]"
    } > "$tmp/mc.toml"
}

# the same file for --build-only: kind = "obj" stops the driver at the ELF
# object, so no sysroot and no linker are involved at all
gen_toml_obj() {
    {
        echo '[project]'
        echo "entry = \"$1\""
        echo "out   = \"$2\""
        echo 'kind  = "obj"'
        echo
        echo '[target]'
        echo 'os   = "linux"'
        echo "arch = \"$arch\""
    } > "$tmp/mc.toml"
}

# why this test cannot run on this target, or empty. `// skip-linux:` is the
# whole operating system; `// skip-<arch>:` is this instruction set only.
skip_reason() {
    r=$(sed -n 's|^// skip-linux: *||p' "$1" | head -1)
    [ -n "$r" ] && { echo "$r"; return; }
    sed -n "s|^// skip-$arch: *||p" "$1" | head -1
}

# reads the test's headers into want_exit / want_out / has_out
read_expect() {
    want_exit=$(sed -n 's|^// expect-exit: *||p' "$1" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$1" | head -1)
    has_out=$(grep -c '^// expect-stdout:' "$1")
}

MUSL_ARGS='"-o", "{out}", "{sysroot}/crt1.o", "{sysroot}/crti.o", "{obj}", "{libs}", "{sysroot}/libc.a", "{sysroot}/crtn.o"'
NOLIBC_ARGS='"-nostdlib", "-e", "_start", "-o", "{out}", "{obj}"'

# $1 = source, $2 = name, $3 = [linker] args
run_one() {
    f="$1"; name="$2"; largs="$3"
    total=$((total + 1))
    read_expect "$f"
    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no expect-exit header)"; fails=$((fails + 1)); return
    fi

    rm -f "$outdir/$name" "$outdir/$name.o"
    gen_toml "$root/$f" "$root/$outdir/$name" "$largs"
    if ! msg=$("$mc" build "$tmp" --config "$tmp/mc.toml" 2>&1); then
        echo "FAIL $name (build: $msg)"; fails=$((fails + 1)); return
    fi
    check_note "$outdir/$name.o" "$name" || return
    check_stack "$outdir/$name" "$name" || return

    # stderr goes to a file, not to /dev/null: an exec-level failure (missing or
    # non-executable binary, wrong architecture, docker/QEMU trouble) only says
    # "exit 127" or "exit 255" otherwise, which reads exactly like the program
    # itself returning the wrong code
    if [ "$native" = "1" ]; then
        got_out=$("$outdir/$name" 2>"$tmp/err")
    else
        got_out=$(docker run --rm --platform "$platform" -v "$root":/w -w /w "$img" \
                  "/w/$outdir/$name" 2>"$tmp/err")
    fi
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

# --build-only: the object plus everything the other half needs to judge it.
# $1 = source, $2 = name, $3 = link mode recorded in the manifest
build_one() {
    f="$1"; name="$2"; lmode="$3"
    total=$((total + 1))
    read_expect "$f"
    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no expect-exit header)"; fails=$((fails + 1)); return
    fi

    rm -f "$split/$name.o" "$split/$name.expect"
    gen_toml_obj "$root/$f" "$split/$name.o"
    if ! msg=$("$mc" build "$tmp" --config "$tmp/mc.toml" 2>&1); then
        echo "FAIL $name (build: $msg)"; fails=$((fails + 1)); return
    fi

    check_note "$split/$name.o" "$name" || return

    echo "exit: $want_exit" > "$split/$name.expect"
    if [ "$has_out" != "0" ]; then
        echo "stdout: $want_out" >> "$split/$name.expect"
    fi
    echo "$name $lmode" >> "$split/manifest"
    echo "built $name"
}

# --run-only: link one object and run it. $1 = name, $2 = link mode
link_run_one() {
    name="$1"; lmode="$2"
    total=$((total + 1))
    if [ ! -f "$split/$name.o" ] || [ ! -f "$split/$name.expect" ]; then
        echo "FAIL $name (missing $name.o or $name.expect in $split)"
        fails=$((fails + 1)); return
    fi
    want_exit=$(sed -n 's|^exit: *||p' "$split/$name.expect" | head -1)
    want_out=$(sed -n 's|^stdout: *||p' "$split/$name.expect" | head -1)
    has_out=$(grep -c '^stdout:' "$split/$name.expect")
    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no exit line in $name.expect)"; fails=$((fails + 1)); return
    fi

    rm -f "$split/$name"
    if [ "$lmode" = "nolibc" ]; then
        set -- -nostdlib -e _start -o "$split/$name" "$split/$name.o"
    else
        set -- -o "$split/$name" "$sysroot/crt1.o" "$sysroot/crti.o" \
               "$split/$name.o" "$sysroot/libc.a" "$sysroot/crtn.o"
    fi
    if ! msg=$(ld.lld "$@" 2>&1); then
        echo "FAIL $name (link: $msg)"; fails=$((fails + 1)); return
    fi
    check_note "$split/$name.o" "$name" || return
    check_stack "$split/$name" "$name" || return

    # same reasoning as run_one: an exec-level failure must not read like the
    # program returning the wrong code
    if [ "$native" = "1" ]; then
        got_out=$("$split/$name" 2>"$tmp/err")
    else
        got_out=$(docker run --rm --platform "$platform" -v "$root":/w -v "$split":/out \
                  -w /w "$img" "/out/$name" 2>"$tmp/err")
    fi
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

if [ "$mode" = "run" ]; then
    while read -r name lmode; do
        [ -n "$name" ] || continue
        link_run_one "$name" "$lmode"
    done < "$split/manifest"
    if [ -f "$split/skipped" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            skipped="$skipped
  $line"
        done < "$split/skipped"
    fi
else
    if [ "$mode" = "build" ]; then
        : > "$split/manifest"
        : > "$split/skipped"
    fi
    for f in tests/*.mc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .mc)
        why=$(skip_reason "$f")
        if [ -n "$why" ]; then
            skipped="$skipped
  $name — $why"
            [ "$mode" = "build" ] && echo "$name — $why" >> "$split/skipped"
            continue
        fi
        if [ "$mode" = "build" ]; then
            build_one "$f" "$name" musl
        else
            run_one "$f" "$name" "$MUSL_ARGS"
        fi
    done

    # M38: the one tests/mc/ case that belongs to every target. It lives there
    # because the frozen C seed refuses it (`at most 8 parameters`), not because
    # it needs anything the other tests do not -- twelve parameters, four of them
    # on the stack, is an ABI claim and every ABI has to answer it.
    why=$(skip_reason tests/mc/080-twelve-params.mc)
    if [ -n "$why" ]; then
        skipped="$skipped
  080-twelve-params — $why"
        [ "$mode" = "build" ] && echo "080-twelve-params — $why" >> "$split/skipped"
    elif [ "$mode" = "build" ]; then
        build_one tests/mc/080-twelve-params.mc 080-twelve-params musl
    else
        run_one tests/mc/080-twelve-params.mc 080-twelve-params "$MUSL_ARGS"
    fi

    # the no-libc case: no crt objects, no libc.a, entry point _start
    why=$(skip_reason tests/linux/070-nolibc.mc)
    if [ -n "$why" ]; then
        skipped="$skipped
  070-nolibc — $why"
        [ "$mode" = "build" ] && echo "070-nolibc — $why" >> "$split/skipped"
    elif [ "$mode" = "build" ]; then
        build_one tests/linux/070-nolibc.mc 070-nolibc nolibc
    else
        run_one tests/linux/070-nolibc.mc 070-nolibc "$NOLIBC_ARGS"
    fi
fi

rm -rf "$tmp"
if [ "$mode" = "build" ]; then
    echo "$((total - fails))/$total objects cross-compiled for linux/$arch in $split"
else
    echo "$((total - fails))/$total tests passed on linux/$arch"
fi
if [ -n "$readobj" ]; then
    echo "ok .note.GNU-stack (SHT_PROGBITS, no flags, size 0) in $notes objects"
elif [ -n "$readelf" ]; then
    echo "ok .note.GNU-stack present in $notes objects (no llvm-readobj: flags unchecked)"
else
    echo "note: no llvm-readobj and no readelf, .note.GNU-stack not checked"
fi
if [ "$mode" != "build" ]; then
    if [ -n "$readelf" ]; then
        echo "ok PT_GNU_STACK is not executable in $stacks linked binaries"
    else
        echo "note: no readelf, PT_GNU_STACK not checked"
    fi
fi
if [ -n "$skipped" ]; then
    echo "skipped (not portable to this target):$skipped"
fi
[ "$fails" -eq 0 ]
