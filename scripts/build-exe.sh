#!/bin/sh
# build-exe.sh MC OUT SRC — builds an executable from one .mc source with the
# compiler MC, whichever host this is (M37).
#
# On macOS and, since M42, on Linux that is `MC --exe SRC -o OUT`: the host's
# direct-executable backend, no linker (src/cli.mc resolves `--exe` through the
# target registry). On Windows there is still none -- `mc` writes an object and
# scripts/link-host.sh calls lld-link against kernel32. The cross-checks that
# need a helper binary (check-toml, check-bundle) use this so they do not have
# to know which host they are on; on Windows the caller passes an OUT that ends
# in `.exe`.
set -e
mc="$1"; out="$2"; src="$3"
if [ -z "$mc" ] || [ -z "$out" ] || [ -z "$src" ]; then
    echo "usage: build-exe.sh MC OUT SRC" >&2
    exit 1
fi
rm -f "$out"
case "$(uname -s)" in
    Darwin|Linux) exec "$mc" --exe "$src" -o "$out" ;;
    *)
        "$mc" "$src" -o "$out.o"
        exec scripts/link-host.sh "$out" "$out.o" ;;
esac
