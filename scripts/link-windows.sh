#!/bin/sh
# link-windows.sh [--arch A] OUT IN.obj [more.obj...]
#
# Links COFF objects into a Windows executable with `lld-link` against the
# kernel32 import library scripts/sysroot-windows.sh generates (M38). It is
# scripts/link-linux.sh's sibling: link.sh is `ld` + libSystem for macOS,
# link-linux.sh is `ld.lld` + musl for Linux, this is `lld-link` + kernel32 for
# Windows, and none of the three is a compiler -- `mc` produced the objects.
#
#   --arch A     aarch64 (default) or x86_64; picks -machine: and the sysroot
#
# Two objects are added to every link line besides the import library, because a
# Windows program built this way has no C runtime to take them from. All three
# live in the SYSROOT -- the directory that holds everything a link for this
# target needs and that is not the program:
#
#   kernel32.lib   the import library, generated from a list of names by
#                  llvm-dlltool (scripts/sysroot-windows.sh). No download, no SDK.
#   winstart.obj   lib/sys_windows_start.mc -- mc_start, what -entry: names. It
#                  is the one file that declares `main` extern, so it cannot
#                  live inside the system layer.
#   mcrt.obj       lib/sys_windows_host.mc -- the fifteen POSIX names the
#                  compiler declares extern, over kernel32.
#
# The import library is generated on demand; the two objects are built on demand
# with MC (default build/mc1) when there is one. On the Windows runners there is
# no `mc` until the seed has been linked, which is exactly the link this script
# is doing -- so both objects travel in the CI artifact, inside the sysroot
# directory, and nothing is compiled here. Without them and without a compiler
# the script says so and stops; it never links a half-resolved executable.
#
# MC_SYSROOT overrides the sysroot directory (default
# build/sysroot/windows-<arch>). It is the same variable
# scripts/link-linux.sh and scripts/test-windows.sh read.
#
# lld-link's options are written in the DASH form on purpose: this script runs
# under Git Bash on the Windows runners, where MSYS rewrites a leading `/out:`
# into `C:/Program Files/Git/out:` before the linker ever sees it.
set -e
arch="aarch64"
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   arch="$2"; shift 2 ;;
        --arch=*) arch="${1#--arch=}"; shift ;;
        *) break ;;
    esac
done

if [ $# -lt 2 ]; then
    echo "usage: link-windows.sh [--arch A] OUT IN.obj [more.obj...]" >&2
    exit 1
fi
out="$1"; shift

case "$arch" in
    aarch64) machine="arm64"; backend="coff-obj-arm64" ;;
    x86_64)  machine="x64";   backend="coff-obj-x86_64" ;;
    *) echo "link-windows: unknown --arch $arch (aarch64 | x86_64)" >&2; exit 1 ;;
esac

sysroot="${MC_SYSROOT:-build/sysroot/windows-$arch}"
mc="${MC:-build/mc1}"
start="$sysroot/winstart.obj"
rt="$sysroot/mcrt.obj"

# Homebrew keeps the LLVM tools out of the default PATH; the Windows runners
# have them wherever the LLVM release was unpacked, already on PATH.
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
linker=$(findtool lld-link)
if [ -z "$linker" ]; then
    echo "link-windows: lld-link not found (brew install lld; see docs/ci.md)" >&2
    exit 1
fi

if [ ! -f "$sysroot/kernel32.lib" ]; then
    sh scripts/sysroot-windows.sh --arch "$arch" "$sysroot" >&2 || exit 1
fi

for o in "$start" "$rt"; do
    [ -f "$o" ] && continue
    if [ "$o" = "$start" ]; then src="lib/sys_windows_start.mc"; else src="lib/sys_windows_host.mc"; fi
    if [ ! -f "$mc" ]; then
        echo "link-windows: '$o' is missing and there is no compiler to build it" >&2
        echo "  set MC to an mc binary, or MC_SYSROOT to a directory that already" >&2
        echo "  holds kernel32.lib, winstart.obj and mcrt.obj (the CI artifact)" >&2
        exit 1
    fi
    mkdir -p "$sysroot"
    echo "link-windows: building $o from $src with $mc"
    "$mc" --backend="$backend" "$src" -o "$o" || exit 1
done

# a running .exe cannot be replaced on Windows, and a stale one would be linked
# around silently
rm -f "$out"
# -stack: the reserve is 1 MiB by default on Windows against 8 MiB on macOS and
# Linux; the compiler is built for the latter, so the executable asks for it.
exec "$linker" -machine:$machine -subsystem:console -entry:mc_start -nodefaultlib \
     -stack:8388608 -out:"$out" "$@" "$start" "$rt" "$sysroot/kernel32.lib"
