#!/bin/sh
# link.sh OUT IN.o [more.o...]  — links arm64 Mach-O objects against libSystem.
# ld is not gcc/cc/clang: it stays allowed after the cord is cut (M8).
set -e
out="$1"; shift
sdk="$(xcrun --show-sdk-path)"
exec ld -arch arm64 -platform_version macos 13.0 13.0 -syslibroot "$sdk" -lSystem -o "$out" "$@"
