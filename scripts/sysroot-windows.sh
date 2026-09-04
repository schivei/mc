#!/bin/sh
# sysroot-windows.sh [--arch ARCH] [DIR] [-f] — populates the Windows sysroot the
# `{sysroot}` placeholder of an `os = "windows"` mc.toml points at
# (M19, docs/build.md § Windows targets).
#
# There is nothing to download. A Windows program does not link against a copy
# of kernel32.dll: it links against an IMPORT LIBRARY, which is a small archive
# holding one thunk per exported name and no code from the DLL at all. That
# archive can be generated from a plain list of names, and `llvm-dlltool` is the
# tool that does it -- so this script writes the list (`kernel32.def`) and builds
# `kernel32.lib` from it, with no network and no Windows SDK.
#
# The list is exactly the entry points lib/sys_windows.mc and
# lib/sys_windows_host.mc declare. A
# program that needs more than that (a whole SDK, other DLLs) is what
# `mc sysroot fetch windows-*` will be for; this is the toolchain the test suite
# needs and nothing else.
#
# The directory is a CACHE: with kernel32.lib already there the script says so
# and does nothing, so `make test-windows` does not rebuild it on every run.
# Pass -f (or set FORCE=1) to repopulate it.
arch="aarch64"
dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   arch="$2"; shift 2 ;;
        --arch=*) arch="${1#--arch=}"; shift ;;
        -f)       FORCE=1; shift ;;
        *)        dir="$1"; shift ;;
    esac
done

# llvm-dlltool's machine name, which is not the one mc.toml uses
case "$arch" in
    aarch64) machine="arm64" ;;
    x86_64)  machine="i386:x86-64" ;;
    *) echo "sysroot-windows: unknown --arch $arch (aarch64 | x86_64)" >&2; exit 1 ;;
esac
[ -n "$dir" ] || dir="build/sysroot/windows-$arch"

if [ -z "$FORCE" ] && [ -f "$dir/kernel32.lib" ]; then
    echo "sysroot already populated: $dir"
    exit 0
fi

# Homebrew keeps llvm-dlltool out of the default PATH, the same place
# llvm-readobj lives; look there before giving up.
dlltool=$(command -v llvm-dlltool 2>/dev/null)
if [ -z "$dlltool" ]; then
    for cand in /opt/homebrew/opt/llvm/bin/llvm-dlltool /usr/local/opt/llvm/bin/llvm-dlltool \
                /usr/lib/llvm-*/bin/llvm-dlltool; do
        if [ -x "$cand" ]; then dlltool="$cand"; break; fi
    done
fi
if [ -z "$dlltool" ]; then
    echo "sysroot-windows: llvm-dlltool not found (brew install llvm)" >&2
    exit 1
fi

mkdir -p "$dir" || exit 1

# The kernel32 entry points the two layers declare, one per line: the seven of
# lib/sys_windows.mc (M19) and the six more lib/sys_windows_host.mc needs for a
# HOSTED compiler (M38) -- spawning a tool, waiting for it, creating and
# deleting a file, and the arena's mapping. Keep this list and the `extern`s in
# those two files in step: a name here that no layer uses costs nothing, a name
# a layer uses and this list does not have is an "unresolved external symbol" at
# link time.
cat > "$dir/kernel32.def" <<'DEF'
LIBRARY kernel32.dll
EXPORTS
CloseHandle
CreateDirectoryA
CreateFileA
CreateProcessA
DeleteFileA
ExitProcess
GetCommandLineA
GetExitCodeProcess
GetStdHandle
ReadFile
VirtualAlloc
WaitForSingleObject
WriteFile
DEF

"$dlltool" -m "$machine" -d "$dir/kernel32.def" -D kernel32.dll -l "$dir/kernel32.lib" \
    || { echo "sysroot-windows: llvm-dlltool failed" >&2; exit 1; }

echo "sysroot populated by $dlltool in $dir"
ls -l "$dir"
