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
# The one thing `--exe` cannot say is WHICH LIBC. A dynamic ELF executable names
# its loader by an absolute path, the two names are TOML keys ([target].interp
# and [target].libc), and the writer's default is musl -- a constant and not a
# probe of the machine, so that one source gives one answer on every host
# (docs/determinism.md). A glibc Linux host cannot run that binary at all, so
# there the same backend is reached through `mc build` with the two keys. The
# probe is the loader on the disk, never the distribution's name.
set -e
mc="$1"; out="$2"; src="$3"
if [ -z "$mc" ] || [ -z "$out" ] || [ -z "$src" ]; then
    echo "usage: build-exe.sh MC OUT SRC" >&2
    exit 1
fi
rm -f "$out"

# a config's paths are resolved against the config's own directory, so both
# sides are made absolute first -- the caller may pass either shape
abspath() {
    case "$1" in
        /*) echo "$1" ;;
        *)  echo "$PWD/$1" ;;
    esac
}

host_libc() {
    for l in /lib/ld-musl-*.so.1; do
        [ -e "$l" ] && { echo musl; return 0; }
    done
    echo glibc
}

case "$(uname -s)" in
    Darwin) exec "$mc" --exe "$src" -o "$out" ;;
    Linux)
        [ "$(host_libc)" = "musl" ] && exec "$mc" --exe "$src" -o "$out"
        arch=$("$mc" --host | sed -n 's|^arch ||p')
        case "$arch" in
            aarch64) interp="/lib/ld-linux-aarch64.so.1" ;;
            x86_64)  interp="/lib64/ld-linux-x86-64.so.2" ;;
            *) echo "build-exe.sh: no known glibc loader for linux/$arch" >&2; exit 1 ;;
        esac
        mkdir -p build
        cfg="build/build-exe.toml"
        cat > "$cfg" <<TOML
[project]
entry = "$(abspath "$src")"
out   = "$(abspath "$out")"

[target]
os     = "linux"
arch   = "$arch"
interp = "$interp"
libc   = "libc.so.6"
TOML
        exec "$mc" build "$PWD/build" --config "$PWD/$cfg" > /dev/null ;;
    *)
        "$mc" "$src" -o "$out.o"
        exec scripts/link-host.sh "$out" "$out.o" ;;
esac
