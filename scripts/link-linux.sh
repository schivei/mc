#!/bin/sh
# link-linux.sh [--arch A] [--nolibc] OUT IN.o [more.o...]
#
# Links ELF64 objects into a Linux executable with `ld.lld` against the musl
# sysroot scripts/sysroot-linux.sh populates (M37). It is scripts/link.sh's
# sibling: link.sh is `ld` + libSystem for macOS, this is `ld.lld` + musl for
# Linux, and neither is a compiler -- `mc` produced the object.
#
#   --arch A     aarch64 (default) or x86_64; picks build/sysroot/linux-A
#   --nolibc     -nostdlib -e _start, for a program that provides its own entry
#                point (lib/sys_linux.mc)
#
# MC_SYSROOT overrides the sysroot directory. The sysroot is populated on demand
# when the four files are not there yet, which needs Docker; on a Linux host
# with musl-dev installed, point MC_SYSROOT at /usr/lib/<arch>-linux-musl and
# nothing is downloaded.
set -e
arch="aarch64"
nolibc=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   arch="$2"; shift 2 ;;
        --arch=*) arch="${1#--arch=}"; shift ;;
        --nolibc) nolibc=1; shift ;;
        *) break ;;
    esac
done

if [ $# -lt 2 ]; then
    echo "usage: link-linux.sh [--arch A] [--nolibc] OUT IN.o [more.o...]" >&2
    exit 1
fi
out="$1"; shift

sysroot="${MC_SYSROOT:-build/sysroot/linux-$arch}"
if [ -z "$nolibc" ]; then
    if [ ! -f "$sysroot/libc.a" ] || [ ! -f "$sysroot/crt1.o" ] \
       || [ ! -f "$sysroot/crti.o" ] || [ ! -f "$sysroot/crtn.o" ]; then
        scripts/sysroot-linux.sh --arch "$arch" "$sysroot" >&2 || exit 1
    fi
    exec ld.lld -o "$out" "$sysroot/crt1.o" "$sysroot/crti.o" "$@" \
                "$sysroot/libc.a" "$sysroot/crtn.o"
fi
exec ld.lld -nostdlib -e _start -o "$out" "$@"
