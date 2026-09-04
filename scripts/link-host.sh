#!/bin/sh
# link-host.sh OUT IN.o [more.o...] — links objects for the HOST this is running
# on (M37). It is one `case` over `uname`: scripts/link.sh (ld + libSystem) on
# macOS, scripts/link-linux.sh (ld.lld + musl) on Linux, and since M38
# scripts/link-windows.sh (lld-link + kernel32) on Windows under Git Bash. Every
# cross-check that has to build and RUN a helper program -- check-lex, check-ast,
# check-mc, check-toml, check-bundle -- goes through it instead of naming a
# linker.
#
# OUT is used exactly as it is given. On Windows the caller writes the `.exe`
# itself: a file that is not called *.exe cannot be launched, and the caller is
# the one that later runs it.
set -e
case "$(uname -s)" in
    Darwin) exec scripts/link.sh "$@" ;;
    Linux)
        arch=$(sh scripts/host-arch.sh)   # never `uname -m`: Git Bash runs emulated on ARM64
        exec scripts/link-linux.sh --arch "$arch" "$@" ;;
    MINGW*|MSYS*|CYGWIN*)
        arch=$(sh scripts/host-arch.sh)   # never `uname -m`: Git Bash runs emulated on ARM64
        exec scripts/link-windows.sh --arch "$arch" "$@" ;;
    *) echo "link-host: unsupported host $(uname -s)" >&2; exit 1 ;;
esac
