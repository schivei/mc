#!/bin/sh
# check-linux-host.sh [--arch A] — the Linux HOST proof, run from macOS (M37,
# docs/guide/90-linux-host.md).
#
# For each architecture (aarch64 and x86_64 unless --arch narrows it):
#
#   1. cross-build `mc` for that Linux host with build/mc1 and
#      src/mc.linux-<arch>.toml -> build/mc-linux-<target>
#   2. inside `docker run --platform linux/<platform> alpine:3`, with the
#      repository copied out of the mount so the container never fights the
#      macOS build/ directory:
#        * `make check SEED=<that binary>` -- the Linux subset, which starts
#          with scripts/bootstrap-linux.sh (seed -> mc1l -> mc2l -> mc3l, cmp,
#          golden, and the suite run natively by the compiler that came out) and
#          then runs the cross-checks (Makefile, HOST switch)
#   3. the CROSS PROOF: the Linux-hosted compiler compiles src/mc.mc (a macOS
#      program) with --backend=macho -- its DEFAULT backend is now this host's,
#      which is ELF -- and the Mach-O object it writes is compared with `cmp`
#      against build/mc2.o, the one macOS wrote for itself.
#
# Recorded goldens (tests/golden/mc2-linux-*.sha256) are copied back out of the
# container, so a first run records them and every later one verifies them.
#
# The container installs make, lld and musl-dev from Alpine and points
# MC_SYSROOT at /usr/lib, where musl-dev puts crt1.o/crti.o/crtn.o/libc.a --
# nothing is downloaded twice and no sysroot has to be built.
set -e
arches="aarch64 x86_64"
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   arches="$2"; shift 2 ;;
        --arch=*) arches="${1#--arch=}"; shift ;;
        *) echo "usage: check-linux-host.sh [--arch aarch64|x86_64]" >&2; exit 1 ;;
    esac
done

root=$(pwd)
mc="${MC:-build/mc1}"
[ -x "$mc" ] || { echo "FAIL: '$mc' not found (run 'make mc1')" >&2; exit 1; }
[ -f build/mc2.o ] || { echo "FAIL: build/mc2.o not found (run 'make bootstrap')" >&2; exit 1; }

for arch in $arches; do
    case "$arch" in
        aarch64) target="arm64";  platform="linux/arm64" ;;
        x86_64)  target="x86_64"; platform="linux/amd64" ;;
        *) echo "FAIL: unknown --arch $arch" >&2; exit 1 ;;
    esac
    bin="build/mc-linux-$target"

    echo "=================================================================="
    echo "== linux/$arch host =============================================="
    echo "=================================================================="
    echo "-- cross-build: $mc build src --config src/mc.linux-$arch.toml --"
    scripts/sysroot-linux.sh --arch "$arch" "build/sysroot/linux-$arch" >/dev/null
    rm -f "$bin"
    "$mc" build src --config "src/mc.linux-$arch.toml"
    ls -l "$bin"

    echo "-- inside docker run --platform $platform alpine:3 --"
    docker run --rm --platform "$platform" -v "$root":/w -w /w alpine:3 /bin/sh -c "
        set -e
        apk add --no-cache make lld musl-dev > /dev/null 2>&1
        mkdir -p /work
        cd /w && tar cf - --exclude=./build . | (cd /work && tar xf -)
        mkdir -p /work/build
        cp /w/build/$bin /work/build/ 2>/dev/null || cp /w/$bin /work/build/
        cp /w/build/mc2.o /work/build/mc2-macos.o
        cd /work
        export MC_SYSROOT=/usr/lib
        uname -m
        ./$bin --host
        echo ''
        echo '### make check (the Linux subset: bootstrap-linux first, then the cross-checks)'
        make check SEED=$bin
        # copied back BEFORE the cross proof: a first run records the golden and
        # a later failure must not throw it away
        cp -f tests/golden/mc2-linux-*.sha256 /w/tests/golden/ 2>/dev/null || true
        echo ''
        echo '### cross proof: build/mc2l --backend=macho src/mc.mc == the macOS build/mc2.o'
        build/mc2l --backend=macho src/mc.mc -o build/x-cross.o
        cmp build/x-cross.o build/mc2-macos.o
        echo 'ok: the Mach-O object written on linux/$arch is byte for byte the one macOS writes'
    "
    echo "== linux/$arch host: ok =========================================="
done
