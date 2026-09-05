#!/bin/sh
# test-linux.sh — the whole suite cross-compiled to Linux and run for real
# (M16 for linux/aarch64, M17 step B for linux/x86_64; docs/build.md § Linux
# targets).
#
#   test-linux.sh [--arch A] [--exe] [--libc L] [MC]              compile, link, run
#   test-linux.sh [--arch A] [--exe] [--libc L] --build-only D [MC] compile only
#   test-linux.sh [--arch A] [--exe] [--libc L] --run-only D        link D, run it
#
# --arch is aarch64 (the default) or x86_64. It picks the object backend through
# `[target].arch` in the generated mc.toml, the sysroot directory, the Docker
# platform and which `// skip-` header applies.
#
# --libc is musl (the default) or gnu, and it only means something with --exe:
# a dynamically linked executable names its loader and its library BY PATH, and
# ONE key decides both ([target].libc, a FAMILY and not a soname --
# docs/reference/toml.md). The vocabulary is the compiler's own, so what is
# written here is what an mc.toml and `mc --exe --libc=` say. musl runs in
# `alpine:3`, gnu in
# `ubuntu:latest` -- the newest Ubuntu, which is the baseline this repository
# measures glibc against. A binary built for one does not run on the other: the
# loader named in PT_INTERP simply is not there, and the kernel answers ENOENT
# ("no such file or directory", about the interpreter, not about the program).
# That is also why this flag exists at all: on a Linux HOST the suite runs
# natively, and a glibc runner cannot execute a musl-linked binary.
#
# --exe is M42: the same corpus and the same Docker oracle with THE LINKER TAKEN
# OUT OF THE PATH. Each mc.toml is six lines -- [project] and [target] -- with
# no [linker], no [sysroot] and no `kind`, so `mc build` writes a dynamic ELF64
# ET_EXEC itself through the `elf-exe` / `elf-exe-x86_64` backends. No ld.lld,
# no crt1.o, no libc.a: nothing outside the compiler is involved, which is the
# whole point of the milestone. The mode PROVES that rather than claiming it --
# it moves ~/.mc/sysroots/linux-* aside for the duration and puts it back -- and
# adds four assertions the object+link mode cannot make: PT_INTERP + DT_NEEDED +
# a JUMP_SLOT on a test that imports and none of the three on one that does not,
# GNU_STACK RW and never E on every binary, and two builds of the same source
# byte for byte identical.
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
# tests/linux/071-errno-malloc.mc is the case that goes past a plain `write`: it
# makes a libc call fail and reads errno (thread-local in both libcs) and it
# calls malloc -- the start-up state a crt-less entry point could plausibly
# leave uninitialised. It runs in both modes.
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
exe=0
libc="musl"
mc=""
while [ $# -gt 0 ]; do
    case "$1" in
        --exe) exe=1; shift ;;
        --libc)
            [ -n "$2" ] && [ "${2#-}" = "$2" ] \
                || { echo "FAIL: --libc needs a value (musl | gnu)" >&2; exit 1; }
            libc="$2"; shift 2
            ;;
        --libc=*) libc="${1#--libc=}"; shift ;;
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

# the container each libc lives in. The names inside the image -- the loader
# path and the DT_NEEDED soname -- are not written here any more: `libc = "gnu"`
# is the whole statement and the writer knows both halves of the family
# (the post-M42 patch). musl is the writer's own default, so its key is left
# unwritten and the default is exercised as well.
case "$libc" in
    musl) img="alpine:3";     libckey="" ;;
    gnu)  img="ubuntu:latest"; libckey="gnu" ;;
    glibc)
        echo "FAIL: --libc glibc was renamed to --libc gnu (the compiler's own vocabulary: [target].libc = \"gnu\")" >&2
        exit 1
        ;;
    *) echo "FAIL: unknown --libc $libc (musl | gnu)" >&2; exit 1 ;;
esac
if [ "$exe" = "0" ] && [ "$libc" != "musl" ]; then
    # the object+link road links against the musl sysroot scripts/sysroot-linux.sh
    # fetches; there is no glibc sysroot in this repository and no reason for one
    echo "FAIL: --libc $libc needs --exe (the linked road is musl only)" >&2
    exit 1
fi

sysroot="${MC_SYSROOT:-build/sysroot/linux-$arch}"
outdir="build/tests-linux-$arch"
if [ "$exe" = "1" ]; then
    outdir="build/tests-linux-$arch-exe"
    [ "$libc" = "musl" ] || outdir="$outdir-$libc"
fi

if [ "$mode" != "run" ] && [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

# a host of the target architecture runs the binaries itself; anything else
# goes through Docker. M42: the architecture is no longer the whole question --
# a dynamically linked executable also needs the loader named in its PT_INTERP
# to exist here, so a glibc host cannot run a musl-linked binary and the other
# way round. The host's libc is read from the loader that is on the disk (musl
# installs /lib/ld-musl-<arch>.so.1), never from the distribution's name.
host_libc="gnu"
if [ "$(uname -s)" = "Linux" ]; then
    for l in /lib/ld-musl-*.so.1; do
        [ -e "$l" ] && host_libc="musl"
    done
fi
native=0
if [ "$(uname -s)" = "Linux" ]; then
    case "$arch/$(uname -m)" in
        aarch64/aarch64|aarch64/arm64|x86_64/x86_64|x86_64/amd64) native=1 ;;
    esac
    if [ "$exe" = "1" ] && [ "$libc" != "$host_libc" ]; then
        native=0                         # this host has no such loader
    fi
fi

# --exe needs nothing but a way to RUN the binaries: no ld.lld and no sysroot,
# which is exactly what it is here to prove.
if [ "$mode" != "build" ] && [ "$exe" = "1" ] && [ "$native" = "0" ]; then
    if ! docker info >/dev/null 2>&1; then
        echo "FAIL: docker is not running"
        exit 1
    fi
fi

if [ "$mode" != "build" ] && [ "$exe" = "0" ]; then
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

# M42, acceptance 4: PT_GNU_STACK has to be RW and never E. It reads the same
# $readelf the post-M41 review's findtool() found above -- one lookup, not two
# -- and with no readelf at all every binary passes and the summary says so.
stack_is_rw() {
    [ -n "$readelf" ] || return 0
    line=$("$readelf" -l "$1" 2>/dev/null | grep GNU_STACK | head -1)
    [ -n "$line" ] || return 1
    # the flags column is what is left once the type and the six hex fields are
    # gone, so an 'E' in an address can never be read as PF_X
    flags=$(printf '%s' "$line" | sed 's/GNU_STACK//; s/0x[0-9a-fA-F]*//g' | tr -d ' \t')
    [ "$flags" = "RW" ]
}

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

# M42: the four-line config the --exe mode builds every test with. No [linker],
# no [sysroot], no `kind` -- src/driver.mc takes the executable backend of
# [target] and writes the binary itself.
gen_toml_exe() {
    {
        echo '[project]'
        echo "entry = \"$1\""
        echo "out   = \"$2\""
        echo
        echo '[target]'
        echo 'os   = "linux"'
        echo "arch = \"$arch\""
        # musl is the writer's own default, so --libc musl writes NO key at all
        # and the default is what gets exercised
        [ -n "$libckey" ] && echo "libc = \"$libckey\""
    } > "$tmp/mc.toml"
}

# M42, acceptance 3: the milestone's claim is that no sysroot is involved, so
# the cached ones are MOVED ASIDE while the mode runs and put back on the way
# out -- including on an interrupt. `mc sysroot` caches under ~/.mc/sysroots by
# default (docs/reference/sysroot.md), and build/sysroot/linux-* is where
# scripts/sysroot-linux.sh puts them for this repository.
sysroot_hidden=""
sysroot_hide() {
    for d in "$HOME/.mc/sysroots/linux-aarch64" "$HOME/.mc/sysroots/linux-x86_64" \
             "build/sysroot/linux-aarch64" "build/sysroot/linux-x86_64"; do
        [ -d "$d" ] || continue
        mv "$d" "$d.m42-aside" || exit 1
        sysroot_hidden="$sysroot_hidden $d"
    done
    [ -n "$sysroot_hidden" ] && echo "no-sysroot proof: moved aside$sysroot_hidden"
    return 0
}
sysroot_restore() {
    for d in $sysroot_hidden; do
        [ -d "$d.m42-aside" ] && mv "$d.m42-aside" "$d"
    done
    sysroot_hidden=""
    return 0
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

# M42 acceptance 3, armed once every function it needs exists
if [ "$exe" = "1" ] && [ "$mode" != "run" ]; then
    trap 'sysroot_restore' EXIT INT TERM
    sysroot_hide
fi

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
    if [ "$exe" = "1" ]; then
        gen_toml_exe "$root/$f" "$root/$outdir/$name"
    else
        gen_toml "$root/$f" "$root/$outdir/$name" "$largs"
    fi
    if ! msg=$("$mc" build "$tmp" --config "$tmp/mc.toml" 2>&1); then
        echo "FAIL $name (build: $msg)"; fails=$((fails + 1)); return
    fi
    # in --exe mode there is no object at all: the compiler wrote the binary,
    # so .note.GNU-stack has nothing to be checked in and PT_GNU_STACK is the
    # writer's own (src/backend_elf_exe.mc), not a linker's.
    [ "$exe" = "1" ] || check_note "$outdir/$name.o" "$name" || return
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

    rm -f "$split/$name.o" "$split/$name" "$split/$name.expect"
    if [ "$exe" = "1" ]; then
        lmode="exe"
        gen_toml_exe "$root/$f" "$split/$name"
    else
        gen_toml_obj "$root/$f" "$split/$name.o"
    fi
    if ! msg=$("$mc" build "$tmp" --config "$tmp/mc.toml" 2>&1); then
        echo "FAIL $name (build: $msg)"; fails=$((fails + 1)); return
    fi
    if [ "$exe" = "1" ]; then
        check_stack "$split/$name" "$name" || return
    else
        check_note "$split/$name.o" "$name" || return
    fi

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
    if [ ! -f "$split/$name.expect" ]; then
        echo "FAIL $name (missing $name.expect in $split)"
        fails=$((fails + 1)); return
    fi
    if [ "$lmode" != "exe" ] && [ ! -f "$split/$name.o" ]; then
        echo "FAIL $name (missing $name.o in $split)"
        fails=$((fails + 1)); return
    fi
    want_exit=$(sed -n 's|^exit: *||p' "$split/$name.expect" | head -1)
    want_out=$(sed -n 's|^stdout: *||p' "$split/$name.expect" | head -1)
    has_out=$(grep -c '^stdout:' "$split/$name.expect")
    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no exit line in $name.expect)"; fails=$((fails + 1)); return
    fi

    if [ "$lmode" = "exe" ]; then
        if [ ! -x "$split/$name" ]; then
            echo "FAIL $name (missing executable $name in $split)"; fails=$((fails + 1)); return
        fi
    else
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
    fi
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

    # M38, then M45: the tests/mc/ cases that belong to EVERY target. They live
    # there because the frozen C seed refuses them -- 080 with `at most 8
    # parameters`, 090..093 with `type expected`, since it has neither a
    # registry nor an alias table -- and not because they need anything the
    # other tests do not. Twelve parameters four of which are on the stack, and
    # a signed 32-bit integer, are ABI claims, and every ABI has to answer them.
    # The glob is `0[89]*` so that a new one is picked up by existing.
    for f in tests/mc/0[89]*.mc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .mc)
        why=$(skip_reason "$f")
        if [ -n "$why" ]; then
            skipped="$skipped
  $name — $why"
            [ "$mode" = "build" ] && echo "$name — $why" >> "$split/skipped"
        elif [ "$mode" = "build" ]; then
            build_one "$f" "$name" musl
        else
            run_one "$f" "$name" "$MUSL_ARGS"
        fi
    done

    # M42: errno (thread-local) and malloc, from an entry point that is not
    # crt1.o. It links like any other libc test in the object mode and is one
    # more binary in the --exe mode.
    why=$(skip_reason tests/linux/071-errno-malloc.mc)
    if [ -n "$why" ]; then
        skipped="$skipped
  071-errno-malloc — $why"
        [ "$mode" = "build" ] && echo "071-errno-malloc — $why" >> "$split/skipped"
    elif [ "$mode" = "build" ]; then
        build_one tests/linux/071-errno-malloc.mc 071-errno-malloc musl
    else
        run_one tests/linux/071-errno-malloc.mc 071-errno-malloc "$MUSL_ARGS"
    fi

    # M45: a call returns what the callee declared, against a real libc. Three
    # `int`-returning functions, one of which reproduces the defect on each
    # libc/architecture pair (docs/specs/M45.md § Implementation notes).
    why=$(skip_reason tests/linux/072-int-return.mc)
    if [ -n "$why" ]; then
        skipped="$skipped
  072-int-return — $why"
        [ "$mode" = "build" ] && echo "072-int-return — $why" >> "$split/skipped"
    elif [ "$mode" = "build" ]; then
        build_one tests/linux/072-int-return.mc 072-int-return musl
    else
        run_one tests/linux/072-int-return.mc 072-int-return "$MUSL_ARGS"
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

# ---- M42: the assertions only the --exe mode can make ----
# They read the binaries this run produced, so they belong to the half that
# BUILDS them (the macOS job in CI), not to the half that runs them.
exe_assertions() {
    d="$1"
    total=$((total + 1))
    if [ -z "$readelf" ]; then
        echo "ok   dynamic/static shape (skipped: no llvm-readelf in PATH or \$LLVM)"
        return 0
    fi
    dyn=$("$readelf" -l -d -r "$d/013-putnum" 2>/dev/null)
    sta=$("$readelf" -l -d -r "$d/001-return42" 2>/dev/null)
    bad=""
    echo "$dyn" | grep -q "INTERP"    || bad="$bad no-PT_INTERP"
    echo "$dyn" | grep -q "NEEDED"    || bad="$bad no-DT_NEEDED"
    echo "$dyn" | grep -q "JUMP_SLOT" || bad="$bad no-JUMP_SLOT"
    echo "$sta" | grep -q "INTERP"    && bad="$bad static-has-PT_INTERP"
    echo "$sta" | grep -q "NEEDED"    && bad="$bad static-has-DT_NEEDED"
    echo "$sta" | grep -q "JUMP_SLOT" && bad="$bad static-has-JUMP_SLOT"
    if [ -n "$bad" ]; then
        echo "FAIL dynamic/static shape:$bad"; fails=$((fails + 1))
    else
        echo "ok   013-putnum imports (PT_INTERP + DT_NEEDED + JUMP_SLOT), 001-return42 imports nothing"
    fi

    total=$((total + 1))
    nstack=0
    for b in "$d"/*; do
        case "$b" in *.expect|*.o|*/manifest|*/skipped) continue ;; esac
        [ -f "$b" ] || continue
        if ! stack_is_rw "$b"; then
            echo "FAIL $(basename "$b"): GNU_STACK is not RW"; fails=$((fails + 1)); return 1
        fi
        nstack=$((nstack + 1))
    done
    echo "ok   GNU_STACK is RW and never E on all $nstack binaries"

    total=$((total + 1))
    gen_toml_exe "$root/tests/013-putnum.mc" "$tmp/again"
    if ! msg=$("$mc" build "$tmp" --config "$tmp/mc.toml" 2>&1); then
        echo "FAIL determinism (build: $msg)"; fails=$((fails + 1))
    elif ! cmp -s "$tmp/again" "$d/013-putnum"; then
        echo "FAIL determinism: two builds of tests/013-putnum.mc differ"; fails=$((fails + 1))
    else
        echo "ok   two builds of the same source are byte for byte identical"
    fi
    return 0
}

if [ "$exe" = "1" ] && [ "$mode" != "run" ]; then
    if [ "$mode" = "build" ]; then exe_assertions "$split"; else exe_assertions "$outdir"; fi
fi

sysroot_restore
rm -rf "$tmp"
# which libc, and where it ran -- a green line has to say what it proved
tag=""
if [ "$exe" = "1" ]; then
    tag=" ($libc"
    if [ "$mode" = "build" ]; then tag="$tag)"
    elif [ "$native" = "1" ]; then tag="$tag, native)"
    else tag="$tag, $img)"
    fi
fi
if [ "$mode" = "build" ]; then
    what="objects"
    [ "$exe" = "1" ] && what="executables (and the --exe assertions)"
    echo "$((total - fails))/$total $what cross-compiled for linux/$arch$tag in $split"
else
    echo "$((total - fails))/$total tests passed on linux/$arch$tag"
fi
# --exe writes no object, so there is no .note.GNU-stack to report on: the
# executable's PT_GNU_STACK is written by src/backend_elf_exe.mc directly.
if [ "$exe" = "0" ]; then
    if [ -n "$readobj" ]; then
        echo "ok .note.GNU-stack (SHT_PROGBITS, no flags, size 0) in $notes objects"
    elif [ -n "$readelf" ]; then
        echo "ok .note.GNU-stack present in $notes objects (no llvm-readobj: flags unchecked)"
    else
        echo "note: no llvm-readobj and no readelf, .note.GNU-stack not checked"
    fi
fi
# --build-only without --exe produces no binary at all; with --exe it does.
if [ "$mode" != "build" ] || [ "$exe" = "1" ]; then
    if [ -n "$readelf" ]; then
        echo "ok PT_GNU_STACK is not executable in $stacks binaries"
    else
        echo "note: no readelf, PT_GNU_STACK not checked"
    fi
fi
if [ -n "$skipped" ]; then
    echo "skipped (not portable to this target):$skipped"
fi
[ "$fails" -eq 0 ]
