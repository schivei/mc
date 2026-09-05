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
#
# `--exe` CAN say which libc since the post-M42 patch: `--libc=gnu|musl` mirrors
# [target].libc, so this script is `mc --exe` on every host that has an
# executable backend. It still probes -- the COMPILER never does, because one
# source must give one answer on every host (docs/determinism.md), which is why
# the flag exists instead of a default that looks around. The probe is the
# loader on the disk, never the distribution's name: musl installs
# /lib/ld-musl-<arch>.so.1 and glibc does not.
set -e
mc="$1"; out="$2"; src="$3"
if [ -z "$mc" ] || [ -z "$out" ] || [ -z "$src" ]; then
    echo "usage: build-exe.sh MC OUT SRC" >&2
    exit 1
fi
rm -f "$out"

host_libc() {
    for l in /lib/ld-musl-*.so.1; do
        [ -e "$l" ] && { echo musl; return 0; }
    done
    echo gnu
}

case "$(uname -s)" in
    Darwin) exec "$mc" --exe "$src" -o "$out" ;;
    Linux)  exec "$mc" --exe --libc="$(host_libc)" "$src" -o "$out" ;;
    *)
        "$mc" "$src" -o "$out.o"
        exec scripts/link-host.sh "$out" "$out.o" ;;
esac
