#!/bin/sh
# sysroot-linux.sh [DIR] — populates the musl sysroot for linux/aarch64 that the
# `{sysroot}` placeholder of an `os = "linux"` mc.toml points at (M16,
# docs/build.md § Linux targets).
#
# The four files a static musl link needs come straight out of Alpine's
# `musl-dev` package, copied out of a throwaway linux/arm64 container:
#
#   crt1.o crti.o crtn.o   the C runtime startup/finish objects
#   libc.a                 musl itself
#   libc.so                only for reference (`readelf` on the real thing)
#
# The directory is a CACHE: if the four files are already there the script says
# so and does nothing, so `make test-linux` does not pull an image on every run.
# Pass -f (or set FORCE=1) to repopulate it.
dir="${1:-build/sysroot/linux-aarch64}"
[ "$1" = "-f" ] && { dir="build/sysroot/linux-aarch64"; FORCE=1; }
[ "$2" = "-f" ] && FORCE=1

if [ -z "$FORCE" ] && [ -f "$dir/libc.a" ] && [ -f "$dir/crt1.o" ] \
   && [ -f "$dir/crti.o" ] && [ -f "$dir/crtn.o" ]; then
    echo "sysroot already populated: $dir"
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    echo "sysroot-linux: docker is not running; cannot populate $dir" >&2
    exit 1
fi

mkdir -p "$dir"
abs=$(cd "$dir" && pwd)

# `apk add musl-dev` inside the container, then copy the artifacts to the bind
# mount. Nothing from the host toolchain is involved.
docker run --rm --platform linux/arm64 -v "$abs":/out alpine:3 /bin/sh -c '
    set -e
    apk add --no-cache musl-dev >/dev/null 2>&1
    cp /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o /usr/lib/libc.a /out/
    cp /usr/lib/libc.so /out/ 2>/dev/null || true
    cat /etc/alpine-release > /out/ALPINE_VERSION
' || { echo "sysroot-linux: docker run failed" >&2; exit 1; }

echo "sysroot populated from alpine:3 ($(cat "$dir/ALPINE_VERSION" 2>/dev/null)) in $dir"
ls -l "$dir"
