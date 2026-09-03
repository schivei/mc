#!/bin/sh
# link.sh OUT IN.o [more.o...]  — liga objetos Mach-O arm64 contra libSystem.
# ld nao e gcc/cc/clang: continua permitido apos o corte do cordao (M8).
set -e
out="$1"; shift
sdk="$(xcrun --show-sdk-path)"
exec ld -arch arm64 -platform_version macos 13.0 13.0 -syslibroot "$sdk" -lSystem -o "$out" "$@"
