#!/bin/sh
# link-host.sh OUT IN.o [more.o...] — links objects for the HOST this is running
# on (M37). It is one `case` over `uname`: scripts/link.sh (ld + libSystem) on
# macOS, scripts/link-linux.sh (ld.lld + musl) on Linux. Every cross-check that
# has to build and RUN a helper program -- check-lex, check-ast, check-mc,
# check-toml, check-bundle -- goes through it instead of naming a linker.
set -e
case "$(uname -s)" in
    Darwin) exec scripts/link.sh "$@" ;;
    Linux)
        case "$(uname -m)" in
            aarch64|arm64) arch=aarch64 ;;
            x86_64|amd64)  arch=x86_64 ;;
            *) echo "link-host: unsupported machine $(uname -m)" >&2; exit 1 ;;
        esac
        exec scripts/link-linux.sh --arch "$arch" "$@" ;;
    *) echo "link-host: unsupported host $(uname -s)" >&2; exit 1 ;;
esac
