#!/bin/sh
# check-linux-host.sh [--arch A] [--libc L] — the Linux HOST proof, run from
# macOS (M37, docs/guide/90-linux-host.md).
#
# Two cells per architecture, one per libc, because a dynamic executable names
# its loader by path and the two libcs are two different systems to be hosted on:
#
#   musl   `alpine:3`, the full one -- `make check SEED=...`, i.e. the whole
#          Linux subset, plus the cross proof
#   gnu    `ubuntu:latest` (the newest Ubuntu, this repository's glibc baseline),
#          M42 § acceptance 9 -- the compiler itself built DYNAMICALLY against
#          glibc, taken to its own fixed point with scripts/bootstrap-linux.sh
#          --libc gnu, the suite run natively through `mc --exe`, and the same
#          cross proof. Nothing is installed in that container: no make, no lld,
#          no musl-dev. The chain has no linker in it at all.
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
libcs="musl gnu"
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   arches="$2"; shift 2 ;;
        --arch=*) arches="${1#--arch=}"; shift ;;
        --libc)   libcs="$2"; shift 2 ;;
        --libc=*) libcs="${1#--libc=}"; shift ;;
        *) echo "usage: check-linux-host.sh [--arch aarch64|x86_64] [--libc musl|gnu]" >&2
           exit 1 ;;
    esac
done
case " $libcs " in *" gnu "*)
    if ! docker image inspect ubuntu:latest > /dev/null 2>&1; then
        docker pull -q ubuntu:latest > /dev/null 2>&1 \
            || { echo "FAIL: ubuntu:latest is not available (the glibc oracle)" >&2; exit 1; }
    fi
    ;;
esac

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

  for libc in $libcs; do
   if [ "$libc" = "musl" ]; then
    bin="build/mc-linux-$target"

    echo "=================================================================="
    echo "== linux/$arch host, musl (alpine:3) ============================="
    echo "=================================================================="
    echo "-- cross-build: $mc build src --config src/mc.linux-$arch.toml --"
    # M42: no sysroot is fetched here any more. src/mc.linux-<arch>.toml lost
    # its [linker] and its [sysroot] -- `mc build` writes the dynamic ELF64
    # executable itself -- so the cross-build needs nothing but `mc`. The
    # container below still installs musl-dev, because scripts/bootstrap-linux.sh
    # links mc1l and mc2l with ld.lld against MC_SYSROOT: the SEED may be a
    # published release older than this milestone, so that chain does not assume
    # a `--exe` that only a new enough compiler has.
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
    echo "== linux/$arch host, musl: ok ===================================="
   else
    # ---- M42 § acceptance 9: the compiler itself, dynamic against glibc ----
    bin="build/mc-linux-$target-gnu"

    echo "=================================================================="
    echo "== linux/$arch host, gnu (glibc, ubuntu:latest) ================="
    echo "=================================================================="
    echo "-- cross-build: $mc build src --config src/mc.linux-$arch-gnu.toml --"
    # the same config as the musl one with ONE key added, [target].libc = "gnu":
    # a family, which names both the loader and the soname. No files, no
    # sysroot, no linker.
    rm -f "$bin"
    "$mc" build src --config "src/mc.linux-$arch-gnu.toml"
    ls -l "$bin"

    echo "-- inside docker run --platform $platform ubuntu:latest --"
    # NOTHING is installed in this container. The chain is
    # seed -> mc1l -> mc2l -> mc3l with every executable written by the previous
    # compiler, then the suite through `mc --exe`, then the cross proof. The
    # golden is the same file the musl chain verifies -- an ELF object records
    # no interpreter, so both roads must produce the same bytes.
    # `cp -a` and not `tar cf - | tar xf -`: the amd64 ubuntu image is emulated on
    # an arm64 host, and GNU tar there fails every open with `Function not
    # implemented` (alpine's busybox tar does not). The copy is the same copy.
    docker run --rm --platform "$platform" -v "$root":/w -w /w ubuntu:latest /bin/sh -c "
        set -e
        mkdir -p /work
        cp -a /w/. /work/
        rm -rf /work/build
        mkdir -p /work/build
        cp /w/$bin /work/build/
        cp /w/build/mc2.o /work/build/mc2-macos.o
        cd /work
        uname -m
        cat /etc/os-release | grep '^VERSION='
        ./$bin --host
        echo ''
        echo '### scripts/bootstrap-linux.sh --libc gnu (no linker, no sysroot)'
        sh scripts/bootstrap-linux.sh --libc gnu $bin
        cp -f tests/golden/mc2-linux-*.sha256 /w/tests/golden/ 2>/dev/null || true
        echo ''
        echo '### cross proof: build/mc2l --backend=macho src/mc.mc == the macOS build/mc2.o'
        build/mc2l --backend=macho src/mc.mc -o build/x-cross.o
        cmp build/x-cross.o build/mc2-macos.o
        echo 'ok: the Mach-O object written on gnu linux/$arch is byte for byte the one macOS writes'
    "
    echo "== linux/$arch host, gnu: ok ====================================="
   fi
  done
done
