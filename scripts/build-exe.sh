#!/bin/sh
# build-exe.sh MC OUT SRC — builds an executable from one .mc source with the
# compiler MC, whichever host this is (M37).
#
# On macOS that is `MC --exe SRC -o OUT`: the direct-executable backend, no
# linker. On Linux there is no direct-executable backend -- `mc` writes an ELF
# object and scripts/link-linux.sh calls ld.lld against the musl sysroot. The
# cross-checks that need a helper binary (check-toml, check-bundle) use this so
# they do not have to know which host they are on.
set -e
mc="$1"; out="$2"; src="$3"
if [ -z "$mc" ] || [ -z "$out" ] || [ -z "$src" ]; then
    echo "usage: build-exe.sh MC OUT SRC" >&2
    exit 1
fi
rm -f "$out"
case "$(uname -s)" in
    Darwin) exec "$mc" --exe "$src" -o "$out" ;;
    *)
        "$mc" "$src" -o "$out.o"
        exec scripts/link-host.sh "$out" "$out.o" ;;
esac
