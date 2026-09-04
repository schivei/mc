#!/bin/sh
# host-arch.sh -- prints the architecture of the machine this shell runs on,
# as mc.toml spells it: aarch64 or x86_64 (M38).
#
# `uname -m` is not enough on Windows: Git for Windows is an x64 program, and
# on Windows on ARM it runs under emulation, where `uname -m` answers x86_64
# for a machine whose kernel is ARM64. The environment tells the truth --
# PROCESSOR_ARCHITEW6432 is the real architecture when a process runs
# emulated, PROCESSOR_ARCHITECTURE otherwise -- so on Windows those are read
# first. MC_HOSTARCH overrides everything, and the CI jobs pass HOSTARCH to
# make explicitly: on a runner the architecture is stated, never guessed.
if [ -n "${MC_HOSTARCH:-}" ]; then
    echo "$MC_HOSTARCH"; exit 0
fi
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # 1. GitHub Actions says what the runner is. 2. The SYSTEM environment in
        # the registry is the machine's own (an emulated x64 process sees AMD64
        # in its own PROCESSOR_ARCHITECTURE and, on Windows on ARM, no
        # PROCESSOR_ARCHITEW6432 at all -- measured on windows-11-arm).
        # 3. The process environment, for a native shell.
        a="${RUNNER_ARCH:-}"
        if [ -z "$a" ] && command -v reg.exe >/dev/null 2>&1; then
            a=$(reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' \
                    /v PROCESSOR_ARCHITECTURE 2>/dev/null | awk '/PROCESSOR_ARCHITECTURE/ {print $NF}')
        fi
        [ -n "$a" ] || a="${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-}}"
        case "$a" in
            ARM64|arm64|aarch64) echo aarch64; exit 0 ;;
            AMD64|amd64|x86_64|X64|x64) echo x86_64; exit 0 ;;
        esac ;;
esac
case "$(uname -m)" in
    aarch64|arm64) echo aarch64 ;;
    x86_64|amd64)  echo x86_64 ;;
    *) uname -m ;;
esac
