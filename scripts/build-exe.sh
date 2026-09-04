#!/bin/sh
# build-exe.sh MC OUT SRC — builds an executable from one .mc source with the
# compiler MC, whichever host this is (M37).
#
# On macOS that is `MC --exe SRC -o OUT`: the direct-executable backend, no
# linker. On Linux and on Windows there is no direct-executable backend -- `mc`
# writes an object and scripts/link-host.sh calls ld.lld against the musl
# sysroot, or lld-link against kernel32. The cross-checks that need a helper
# binary (check-toml, check-bundle) use this so they do not have to know which
# host they are on; on Windows the caller passes an OUT that ends in `.exe`.
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
