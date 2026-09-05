#!/bin/sh
# bootstrap-linux.sh [SEED] — the fixed point of `mc` on a Linux HOST (M37,
# docs/bootstrap.md § The Linux chain).
#
#   SEED src/mc_linux[_x86_64].mc -> build/mc1l.o  (+ link -> build/mc1l)
#   build/mc1l  same source        -> build/mc2l.o (+ link -> build/mc2l)
#   build/mc2l  same source        -> build/mc3l.o
#   cmp build/mc2l.o build/mc3l.o          <- the criterion
#   SHA-256 of build/mc2l.o vs tests/golden/mc2-linux-<target>.sha256
#
# It is scripts/bootstrap.sh with one difference that is not cosmetic: there is
# no `mc0` here. The C seed emits Mach-O and only Mach-O, so a Linux host does
# not start from clang -- it starts from a `mc` binary that already exists. That
# is what SEED is, and where it comes from is the only new thing:
#
#   1. an argument:            scripts/bootstrap-linux.sh /path/to/mc
#   2. build/mc-linux-<target> cross-built on macOS (docs/guide/90-linux-host.md)
#   3. a release asset, downloaded and checksum-verified by this script:
#
#        https://github.com/schivei/mc/releases/download/vVER/mc-VER-linux-ARCH.tar.gz
#        https://github.com/schivei/mc/releases/download/vVER/mc-VER-linux-ARCH.tar.gz.sha256
#
#      with ARCH = arm64 | x86_64 and VER the version without the `v`. `gh
#      release download` is used when the GitHub CLI is on PATH (it follows the
#      `latest` release by itself); otherwise `curl -fsSL` fetches both files and
#      the tarball is only unpacked after its SHA-256 matches the `.sha256`.
#      MC_SEED_VERSION pins the version, MC_SEED_REPO the repository.
#
# The link step is scripts/link-linux.sh (ld.lld + the musl sysroot). Set
# MC_SYSROOT to a directory that already has crt1.o/crti.o/crtn.o/libc.a --
# `/usr/lib` on Alpine with musl-dev -- and nothing is downloaded for it either.
#
# M42 adds a second road for that step, and it is the milestone's own:
#
#   --exe            each stage's executable is written by the PREVIOUS compiler
#                    (`elf-exe` / `elf-exe-x86_64`), so there is no ld.lld and no
#                    sysroot in the chain at all
#   --libc musl|gnu  which libc that executable is linked against, in the
#                    compiler's own vocabulary ([target].libc); gnu implies
#                    --exe, because the sysroot road has musl files and nothing
#                    else
#
# The default is unchanged on purpose: the SEED may be a published release older
# than M42, which has no `--exe` on Linux to offer.
#
# The `--exe` road goes through `mc build` and a generated config rather than
# through `mc --exe --libc=`, which the post-M42 patch made possible: what the
# config still carries and a command line cannot is `[limits] tolerance = 1.0`,
# and the compiler compiling itself is the one source in this repository where
# that matters (every table is sized for it in one go instead of doubling
# mid-build). The OBJECT each stage writes is the same either way -- an ELF
# object records no interpreter -- so the fixed point and the golden are the
# same values on both roads, which is what makes them comparable.
#
# No "set -e": every step checks its own exit code and says what failed.

repo="${MC_SEED_REPO:-schivei/mc}"
use_exe=0
libc="musl"
seed=""
while [ $# -gt 0 ]; do
    case "$1" in
        --exe) use_exe=1; shift ;;
        --libc)
            [ -n "$2" ] && [ "${2#-}" = "$2" ] \
                || { echo "FAIL: --libc needs a value (musl | gnu)" >&2; exit 1; }
            libc="$2"; shift 2
            ;;
        --libc=*) libc="${1#--libc=}"; shift ;;
        *) seed="$1"; shift ;;
    esac
done
# one key, one family: `libc = "gnu"` names both the loader path and the
# DT_NEEDED soname (the post-M42 patch, docs/reference/toml.md § [target]).
# There is no glibc sysroot here and no reason for one, so gnu implies --exe.
case "$libc" in
    musl) libckey="" ;;
    gnu)  libckey="gnu"; use_exe=1 ;;
    glibc)
        echo "FAIL: --libc glibc was renamed to --libc gnu (the compiler's own vocabulary: [target].libc = \"gnu\")" >&2
        exit 1
        ;;
    *) echo "FAIL: unknown --libc $libc (musl | gnu)" >&2; exit 1 ;;
esac

case "$(uname -s)" in
    Linux) : ;;
    *) echo "bootstrap-linux: this is the LINUX chain; on macOS run scripts/bootstrap.sh" >&2
       exit 1 ;;
esac

case "$(uname -m)" in
    aarch64|arm64) target="arm64";  entry="src/mc_linux.mc";        larch="aarch64" ;;
    x86_64|amd64)  target="x86_64"; entry="src/mc_linux_x86_64.mc"; larch="x86_64" ;;
    *) echo "bootstrap-linux: unsupported machine $(uname -m) (aarch64 | x86_64)" >&2
       exit 1 ;;
esac
golden="tests/golden/mc2-linux-$target.sha256"

if [ ! -f "$entry" ]; then
    echo "FAIL: $entry not found (run from the repository root)" >&2
    exit 1
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ---- the seed ----
fetch_seed() {
    out="build/seed"
    mkdir -p "$out" || return 1
    if command -v gh >/dev/null 2>&1; then
        echo "-- fetching the seed with gh release download ($repo) --"
        if [ -n "$MC_SEED_VERSION" ]; then
            gh release download "v$MC_SEED_VERSION" --repo "$repo" \
               --pattern "mc-*-linux-$target.tar.gz*" --dir "$out" --clobber || return 1
        else
            gh release download --repo "$repo" \
               --pattern "mc-*-linux-$target.tar.gz*" --dir "$out" --clobber || return 1
        fi
    else
        ver="$MC_SEED_VERSION"
        if [ -z "$ver" ]; then
            echo "FAIL: no gh on PATH; set MC_SEED_VERSION to the release to fetch" >&2
            return 1
        fi
        base="https://github.com/$repo/releases/download/v$ver"
        echo "-- fetching the seed with curl ($base) --"
        curl -fsSL -o "$out/mc-$ver-linux-$target.tar.gz" \
             "$base/mc-$ver-linux-$target.tar.gz" || return 1
        curl -fsSL -o "$out/mc-$ver-linux-$target.tar.gz.sha256" \
             "$base/mc-$ver-linux-$target.tar.gz.sha256" || return 1
    fi
    tgz=$(ls "$out"/mc-*-linux-"$target".tar.gz 2>/dev/null | head -1)
    [ -n "$tgz" ] || { echo "FAIL: no tarball downloaded into $out" >&2; return 1; }
    want=$(awk '{print $1}' "$tgz.sha256" 2>/dev/null)
    got=$(sha256_of "$tgz")
    if [ -z "$want" ]; then
        echo "FAIL: $tgz.sha256 is missing or empty -- refusing to unpack" >&2
        return 1
    fi
    if [ "$want" != "$got" ]; then
        echo "FAIL: checksum mismatch for $tgz" >&2
        echo "  expected: $want" >&2
        echo "  got:      $got" >&2
        return 1
    fi
    echo "  sha256 ok: $got"
    ( cd "$out" && tar xzf "$(basename "$tgz")" ) || return 1
    dir="${tgz%.tar.gz}"
    seed="$dir/mc"
    chmod 755 "$seed" 2>/dev/null
    [ -x "$seed" ] || { echo "FAIL: the tarball has no executable mc" >&2; return 1; }
    return 0
}

if [ -z "$seed" ] && [ "$libc" != "musl" ] && [ -x "build/mc-linux-$target-$libc" ]; then
    seed="build/mc-linux-$target-$libc"
    echo "seed: $seed (cross-built, $libc)"
fi
if [ -z "$seed" ] && [ -x "build/mc-linux-$target" ]; then
    seed="build/mc-linux-$target"
    echo "seed: $seed (cross-built)"
fi
if [ -z "$seed" ]; then
    fetch_seed || exit 1
    echo "seed: $seed (release asset)"
fi
if [ ! -x "$seed" ]; then
    echo "FAIL: seed '$seed' not found or not executable" >&2
    exit 1
fi

# the seed has to be a compiler for THIS host, not a cross-compiler that merely
# runs here: `--host` is the one question that settles it
seed_os=$("$seed" --host 2>/dev/null | sed -n 's|^os *||p')
seed_arch=$("$seed" --host 2>/dev/null | sed -n 's|^arch *||p')
if [ "$seed_os" != "linux" ] || [ "$seed_arch" != "$larch" ]; then
    echo "FAIL: the seed says it is hosted on '$seed_os/$seed_arch', not linux/$larch" >&2
    exit 1
fi

mkdir -p build
fails=0

step() {
    desc="$1"; shift
    # rc is read straight after the command: inside an `if ! cmd` branch `$?` is
    # the status of the negated test (always 0), never the command's own
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: $desc (exit $rc)" >&2
        echo "--- command: $* ---" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    echo "  $desc"
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

size_of() { wc -c < "$1" | tr -d ' '; }

# M42: "linking" without a linker -- the previous compiler writes the executable
# itself. $1 is that compiler, $2 the output. Everything is absolute, so the
# config's own directory does not enter into it.
bsroot=$(pwd)
link_exe() {
    cfg="$bsroot/build/bootstrap-exe.toml"
    {
        echo '[project]'
        echo "entry = \"$bsroot/$entry\""
        echo "out   = \"$bsroot/$2\""
        echo ''
        echo '[target]'
        echo 'os   = "linux"'
        echo "arch = \"$larch\""
        [ -n "$libckey" ] && echo "libc = \"$libckey\""
        echo ''
        echo '[limits]'
        echo 'tolerance = 1.0'
    } > "$cfg"
    rm -f "$2"
    "$1" build "$bsroot/build" --config "$cfg" > /dev/null || return 1
    [ -x "$2" ] || { echo "FAIL: $1 wrote no executable at $2" >&2; return 1; }
    return 0
}

# one name for both roads, so the three stages below read the same either way
link_stage() {                           # compiler, output
    if [ "$use_exe" = "1" ]; then
        link_exe "$1" "$2"
    else
        scripts/link-linux.sh --arch "$larch" "$2" "$2.o"
    fi
}

echo "=== M37 -- fixed point on linux/$target: seed -> mc1l -> mc2l -> mc3l ==="
echo "  entry: $entry"
if [ "$use_exe" = "1" ]; then
    echo "  link:  mc --exe ($libc), no ld.lld and no sysroot (M42)"
else
    echo "  link:  scripts/link-linux.sh (ld.lld + the musl sysroot)"
fi

echo "-- stage 1: $seed $entry -> build/mc1l.o --"
rm -f build/mc1l.o build/mc1l
step "seed compiles $entry"  "$seed" "$entry" -o build/mc1l.o
echo "  size build/mc1l.o: $(size_of build/mc1l.o) bytes"
step "link build/mc1l"       link_stage "$seed" build/mc1l

echo "-- stage 2: build/mc1l $entry -> build/mc2l.o --"
rm -f build/mc2l.o build/mc2l
step "mc1l compiles $entry"  build/mc1l "$entry" -o build/mc2l.o
echo "  size build/mc2l.o: $(size_of build/mc2l.o) bytes"
step "link build/mc2l"       link_stage build/mc1l build/mc2l

echo "-- stage 3: build/mc2l $entry -> build/mc3l.o --"
rm -f build/mc3l.o
step "mc2l compiles $entry"  build/mc2l "$entry" -o build/mc3l.o
echo "  size build/mc3l.o: $(size_of build/mc3l.o) bytes"

echo "-- fixed-point criterion: cmp build/mc2l.o build/mc3l.o --"
if ! cmp build/mc2l.o build/mc3l.o; then
    echo "FAIL: build/mc2l.o != build/mc3l.o -- no fixed point" >&2
    echo "diagnosis: diff <(build/mc1l --dump-asm $entry) <(build/mc2l --dump-asm $entry)" >&2
    exit 1
fi
echo "  ok: build/mc2l.o == build/mc3l.o"

echo "-- golden SHA-256 of build/mc2l.o --"
got_hash=$(sha256_of build/mc2l.o)
mkdir -p "$(dirname "$golden")"
if [ ! -f "$golden" ]; then
    printf '%s  build/mc2l.o\n' "$got_hash" > "$golden"
    echo "  WARNING: $golden did not exist -- recorded now:"
    echo "  $got_hash"
else
    want_hash=$(awk '{print $1}' "$golden")
    if [ "$got_hash" != "$want_hash" ]; then
        echo "FAIL: build/mc2l.o diverges from the golden $golden" >&2
        echo "  expected: $want_hash" >&2
        echo "  got:      $got_hash" >&2
        echo "  (review the --dump-asm diff before rewriting it -- tests/golden/README.md)" >&2
        exit 1
    fi
    echo "  ok: $got_hash matches $golden"
fi

# The seed is allowed to be an older compiler, so mc1l.o may differ from mc2l.o;
# what must NOT differ is what the two self-hosted stages SAY about the source.
echo "-- mc1l and mc2l agree on --dump-asm --"
if ! build/mc1l --dump-asm "$entry" > build/mc1l.asm 2> build/mc1l.asmerr; then
    echo "FAIL: build/mc1l --dump-asm $entry" >&2; cat build/mc1l.asmerr >&2; exit 1
fi
if ! build/mc2l --dump-asm "$entry" > build/mc2l.asm 2> build/mc2l.asmerr; then
    echo "FAIL: build/mc2l --dump-asm $entry" >&2; cat build/mc2l.asmerr >&2; exit 1
fi
if ! diff build/mc1l.asm build/mc2l.asm > build/mc-linux.asmdiff; then
    echo "FAIL: the --dump-asm of mc1l and mc2l differ" >&2
    sed -n '1,20p' build/mc-linux.asmdiff >&2
    exit 1
fi
echo "  ok: identical"

echo ""
if [ "$use_exe" = "1" ]; then
    # the whole suite through the compiler that just came out, with no linker
    # anywhere in it -- which is also the only road on a glibc host, where the
    # musl sysroot the linked road wants does not exist
    echo "=== scripts/test-linux.sh --arch $larch --exe --libc $libc build/mc2l ==="
    if ! scripts/test-linux.sh --arch "$larch" --exe --libc "$libc" build/mc2l; then
        echo "FAIL: scripts/test-linux.sh --exe with the bootstrapped compiler" >&2
        fails=1
    fi
else
    echo "=== scripts/test-linux.sh --arch $larch build/mc2l ==="
    if ! scripts/test-linux.sh --arch "$larch" build/mc2l; then
        echo "FAIL: scripts/test-linux.sh with the bootstrapped compiler" >&2
        fails=1
    fi
fi

[ "$fails" -eq 0 ]
