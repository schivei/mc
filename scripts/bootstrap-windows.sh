#!/bin/sh
# bootstrap-windows.sh [SEED] — the fixed point of `mc` on a Windows HOST (M38,
# docs/bootstrap.md § The Windows chain).
#
#   SEED src/mc_windows[_x86_64].mc -> build/mc1w.obj  (+ link -> build/mc1w.exe)
#   build/mc1w.exe  same source      -> build/mc2w.obj (+ link -> build/mc2w.exe)
#   build/mc2w.exe  same source      -> build/mc3w.obj
#   cmp build/mc2w.obj build/mc3w.obj          <- the criterion
#   SHA-256 of build/mc2w.obj vs tests/golden/mc2-windows-<target>.sha256
#   build/mc2w.exe --host  =>  os windows / arch <arch>
#   scripts/test-windows.sh --arch <arch> --run-only <objdir>
#
# bootstrap-windows.sh [--arch aarch64|x86_64] [SEED]
#   build/mc2w.exe --backend=macho src/mc.mc  ==  build/mc2.o   (the cross proof)
#
# It is scripts/bootstrap-linux.sh's sibling, and it has the same one difference
# from scripts/bootstrap.sh that that script has: there is no `mc0` here. The C
# seed emits Mach-O and only Mach-O, so a Windows host does not start from
# clang -- it starts from a `mc` binary that already exists. That is what SEED
# is, and where it comes from:
#
#   1. an argument:                 scripts/bootstrap-windows.sh /path/to/mc.exe
#   2. build/mc-windows-<target>.exe, linked here from the object the macOS job
#      cross-compiled (docs/guide/95-windows-host.md)
#   3. build/mc-windows-<target>.obj, the artifact itself: this script links it
#      with scripts/link-windows.sh when the .exe is not there yet
#   4. a release asset, downloaded and checksum-verified:
#
#        https://github.com/schivei/mc/releases/download/vVER/mc-VER-windows-ARCH.tar.gz
#        https://github.com/schivei/mc/releases/download/vVER/mc-VER-windows-ARCH.tar.gz.sha256
#
#      with ARCH = arm64 | x86_64. `gh release download` is used when the GitHub
#      CLI is on PATH; otherwise `curl -fsSL` fetches both files and the tarball
#      is only unpacked after its SHA-256 matches. MC_SEED_VERSION pins the
#      version, MC_SEED_REPO the repository.
#
# Every file name carries `.exe` explicitly: under MSYS `[ -x build/mc2w ]` is
# not reliable, and neither is leaving the suffix off a command.
#
# A RUNNING .exe cannot be deleted or replaced on Windows. Nothing here rewrites
# the binary that is running: mc1w.exe writes mc2w.obj, and mc2w.exe is linked
# by lld-link while mc1w.exe is no longer running.
#
# No "set -e": every step checks its own exit code and says what failed.

repo="${MC_SEED_REPO:-schivei/mc}"
harch=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   harch="$2"; shift 2 ;;
        --arch=*) harch="${1#--arch=}"; shift ;;
        *) break ;;
    esac
done
seed="$1"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) : ;;
    *) echo "bootstrap-windows: this is the WINDOWS chain; on macOS run scripts/bootstrap.sh," >&2
       echo "  on Linux scripts/bootstrap-linux.sh" >&2
       exit 1 ;;
esac

# --arch wins; otherwise scripts/host-arch.sh, which reads the environment
# before `uname -m` -- under Git Bash on Windows on ARM the shell itself runs
# emulated and `uname -m` answers x86_64 (the first CI run of this script died
# on exactly that: "the seed says it is hosted on windows/aarch64, not x86_64").
[ -n "$harch" ] || harch=$(sh scripts/host-arch.sh)
case "$harch" in
    aarch64|arm64) target="arm64";  entry="src/mc_windows.mc";        larch="aarch64" ;;
    x86_64|amd64)  target="x86_64"; entry="src/mc_windows_x86_64.mc"; larch="x86_64" ;;
    *) echo "bootstrap-windows: unsupported machine $harch (aarch64 | x86_64)" >&2
       exit 1 ;;
esac
golden="tests/golden/mc2-windows-$target.sha256"
objdir="${MC_WINTESTS:-build/tests-windows-$larch}"

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
               --pattern "mc-*-windows-$target.tar.gz*" --dir "$out" --clobber || return 1
        else
            gh release download --repo "$repo" \
               --pattern "mc-*-windows-$target.tar.gz*" --dir "$out" --clobber || return 1
        fi
    else
        ver="$MC_SEED_VERSION"
        if [ -z "$ver" ]; then
            echo "FAIL: no gh on PATH; set MC_SEED_VERSION to the release to fetch" >&2
            return 1
        fi
        base="https://github.com/$repo/releases/download/v$ver"
        echo "-- fetching the seed with curl ($base) --"
        curl -fsSL -o "$out/mc-$ver-windows-$target.tar.gz" \
             "$base/mc-$ver-windows-$target.tar.gz" || return 1
        curl -fsSL -o "$out/mc-$ver-windows-$target.tar.gz.sha256" \
             "$base/mc-$ver-windows-$target.tar.gz.sha256" || return 1
    fi
    tgz=$(ls "$out"/mc-*-windows-"$target".tar.gz 2>/dev/null | head -1)
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
    seed="$dir/mc.exe"
    [ -f "$seed" ] || { echo "FAIL: the tarball has no mc.exe" >&2; return 1; }
    return 0
}

mkdir -p build

if [ -z "$seed" ] && [ -f "build/mc-windows-$target.exe" ]; then
    seed="build/mc-windows-$target.exe"
    echo "seed: $seed (cross-built)"
fi
# the artifact the macOS job uploads is the OBJECT; linking it is this script's
# job, and lld-link is on PATH here because everything below needs it anyway
if [ -z "$seed" ] && [ -f "build/mc-windows-$target.obj" ]; then
    echo "-- linking the cross-compiled seed object --"
    if ! out=$(scripts/link-windows.sh --arch "$larch" \
               "build/mc-windows-$target.exe" "build/mc-windows-$target.obj" 2>&1); then
        echo "FAIL: linking build/mc-windows-$target.obj" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf '%s\n' "$out"
    seed="build/mc-windows-$target.exe"
    echo "seed: $seed (linked from the cross-compiled object)"
fi
if [ -z "$seed" ]; then
    fetch_seed || exit 1
    echo "seed: $seed (release asset)"
fi
if [ ! -f "$seed" ]; then
    echo "FAIL: seed '$seed' not found" >&2
    exit 1
fi

# the seed has to be a compiler for THIS host, not a cross-compiler that merely
# runs here: `--host` is the one question that settles it
seed_os=$("$seed" --host 2>/dev/null | sed -n 's|^os *||p')
seed_arch=$("$seed" --host 2>/dev/null | sed -n 's|^arch *||p')
if [ "$seed_os" != "windows" ] || [ "$seed_arch" != "$larch" ]; then
    echo "FAIL: the seed says it is hosted on '$seed_os/$seed_arch', not windows/$larch" >&2
    exit 1
fi

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

echo "=== M38 -- fixed point on windows/$target: seed -> mc1w -> mc2w -> mc3w ==="
echo "  entry: $entry"

echo "-- stage 1: $seed $entry -> build/mc1w.obj --"
rm -f build/mc1w.obj build/mc1w.exe
step "seed compiles $entry"   "$seed" "$entry" -o build/mc1w.obj
echo "  size build/mc1w.obj: $(size_of build/mc1w.obj) bytes"
step "link build/mc1w.exe"    scripts/link-windows.sh --arch "$larch" build/mc1w.exe build/mc1w.obj

echo "-- stage 2: build/mc1w.exe $entry -> build/mc2w.obj --"
rm -f build/mc2w.obj build/mc2w.exe
step "mc1w compiles $entry"   build/mc1w.exe "$entry" -o build/mc2w.obj
echo "  size build/mc2w.obj: $(size_of build/mc2w.obj) bytes"
step "link build/mc2w.exe"    scripts/link-windows.sh --arch "$larch" build/mc2w.exe build/mc2w.obj

echo "-- stage 3: build/mc2w.exe $entry -> build/mc3w.obj --"
rm -f build/mc3w.obj
step "mc2w compiles $entry"   build/mc2w.exe "$entry" -o build/mc3w.obj
echo "  size build/mc3w.obj: $(size_of build/mc3w.obj) bytes"

echo "-- fixed-point criterion: cmp build/mc2w.obj build/mc3w.obj --"
if ! cmp build/mc2w.obj build/mc3w.obj; then
    echo "FAIL: build/mc2w.obj != build/mc3w.obj -- no fixed point" >&2
    echo "diagnosis: diff <(build/mc1w.exe --dump-asm $entry) <(build/mc2w.exe --dump-asm $entry)" >&2
    exit 1
fi
echo "  ok: build/mc2w.obj == build/mc3w.obj"

echo "-- golden SHA-256 of build/mc2w.obj --"
got_hash=$(sha256_of build/mc2w.obj)
mkdir -p "$(dirname "$golden")"
if [ ! -f "$golden" ]; then
    printf '%s  build/mc2w.obj\n' "$got_hash" > "$golden"
    echo "  WARNING: $golden did not exist -- recorded now:"
    echo "  $got_hash"
else
    want_hash=$(awk '{print $1}' "$golden")
    if [ "$got_hash" != "$want_hash" ]; then
        echo "FAIL: build/mc2w.obj diverges from the golden $golden" >&2
        echo "  expected: $want_hash" >&2
        echo "  got:      $got_hash" >&2
        echo "  (review the --dump-asm diff before rewriting it -- tests/golden/README.md)" >&2
        exit 1
    fi
    echo "  ok: $got_hash matches $golden"
fi

# the seed check, on the compiler that came out of the chain rather than on the
# one that went in
echo "-- build/mc2w.exe --host --"
host_out=$(build/mc2w.exe --host 2>&1)
printf '%s\n' "$host_out"
got_os=$(printf '%s\n' "$host_out" | sed -n 's|^os *||p')
got_arch=$(printf '%s\n' "$host_out" | sed -n 's|^arch *||p')
if [ "$got_os" != "windows" ] || [ "$got_arch" != "$larch" ]; then
    echo "FAIL: mc2w.exe says it is hosted on '$got_os/$got_arch', not windows/$larch" >&2
    exit 1
fi

# The seed is allowed to be an older compiler, so mc1w.obj may differ from
# mc2w.obj; what must NOT differ is what the two self-hosted stages SAY about
# the source.
echo "-- mc1w and mc2w agree on --dump-asm --"
if ! build/mc1w.exe --dump-asm "$entry" > build/mc1w.asm 2> build/mc1w.asmerr; then
    echo "FAIL: build/mc1w.exe --dump-asm $entry" >&2; cat build/mc1w.asmerr >&2; exit 1
fi
if ! build/mc2w.exe --dump-asm "$entry" > build/mc2w.asm 2> build/mc2w.asmerr; then
    echo "FAIL: build/mc2w.exe --dump-asm $entry" >&2; cat build/mc2w.asmerr >&2; exit 1
fi
if ! diff build/mc1w.asm build/mc2w.asm > build/mc-windows.asmdiff; then
    echo "FAIL: the --dump-asm of mc1w and mc2w differ" >&2
    sed -n '1,20p' build/mc-windows.asmdiff >&2
    exit 1
fi
echo "  ok: identical"

echo ""
echo "=== scripts/test-windows.sh --arch $larch --run-only $objdir ==="
# The objects normally arrive in the CI artifact, already cross-compiled on
# macOS. With none there, the compiler that has just bootstrapped makes its own
# -- it is a full `mc` on this host, so --build-only works here too.
if [ ! -f "$objdir/manifest" ]; then
    echo "-- no $objdir/manifest: cross-compiling the suite with build/mc2w.exe --"
    if ! scripts/test-windows.sh --arch "$larch" --build-only "$objdir" build/mc2w.exe; then
        echo "FAIL: scripts/test-windows.sh --build-only with the bootstrapped compiler" >&2
        exit 1
    fi
fi
if ! scripts/test-windows.sh --arch "$larch" --run-only "$objdir"; then
    echo "FAIL: scripts/test-windows.sh with the bootstrapped compiler" >&2
    fails=1
fi

# The proof that a Windows-hosted mc is the SAME compiler: the Mach-O object it
# writes for src/mc.mc is byte for byte the one macOS writes for itself
# (build/mc2.o, uploaded by the macOS job). Skipped, with the reason, when that
# reference is not there.
echo ""
echo "=== cross proof: mc2w.exe --backend=macho src/mc.mc == build/mc2.o ==="
if [ -f build/mc2.o ]; then
    rm -f build/x-cross.o
    if ! out=$(build/mc2w.exe --backend=macho src/mc.mc -o build/x-cross.o 2>&1); then
        echo "FAIL: mc2w.exe --backend=macho src/mc.mc" >&2
        printf '%s\n' "$out" >&2
        fails=1
    elif ! cmp build/x-cross.o build/mc2.o; then
        echo "FAIL: the Mach-O object written on windows/$target is not the one macOS writes" >&2
        fails=1
    else
        echo "  ok: byte for byte build/mc2.o"
    fi
else
    echo "  SKIPPED: build/mc2.o is not here (the macOS job uploads it as mc2-macos-arm64)"
fi

[ "$fails" -eq 0 ]
