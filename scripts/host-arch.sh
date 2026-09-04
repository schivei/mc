#!/bin/sh
# host-arch.sh -- prints the architecture of the machine this shell runs on,
# as mc.toml spells it: aarch64 or x86_64 (M38).
#
# `uname -m` is not enough on Windows: Git for Windows is an x64 program, and
# on Windows on ARM it runs under emulation, where `uname -m` answers x86_64
# for a machine whose kernel is ARM64. The environment tells the truth --
# PROCESSOR_ARCHITEW6432 is the real architecture when a process runs
# emulated, PROCESSOR_ARCHITECTURE otherwise -- so on Windows those are read
# first. MC_HOSTARCH overrides everything (the CI jobs set nothing: they run on
# the machine they name, and this script must agree with them).
if [ -n "${MC_HOSTARCH:-}" ]; then
    echo "$MC_HOSTARCH"; exit 0
fi
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        a="${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-}}"
        case "$a" in
            ARM64|arm64) echo aarch64; exit 0 ;;
            AMD64|amd64|x86_64) echo x86_64; exit 0 ;;
        esac ;;
esac
case "$(uname -m)" in
    aarch64|arm64) echo aarch64 ;;
    x86_64|amd64)  echo x86_64 ;;
    *) uname -m ;;
esac
