# The STRICT oracle: the simavr the distributions ship, which is not the one a
# developer installs by hand (M40, docs/specs/M40.md finding 11).
#
# Homebrew's `simavr` is built from git master; Debian's and Ubuntu's is 1.6,
# and the two differ in ways a firmware can trip over:
#
#   * 1.6 IGNORES section addresses when it loads an ELF. Its flash image is
#     the contents of `.text` immediately followed by the contents of `.data`
#     (simavr/sim/sim_elf.c: `flashsize = text + data`, two memcpy). Master
#     reads the program headers instead. An image whose `.data` load address is
#     not `sizeof(.text)` therefore runs on one and not on the other.
#   * 1.6 has no `SIMAVR_CMD_EXIT_CODE_0`/`_1` (its enum stops at
#     `SIMAVR_CMD_UART_LOOPBACK`), so a write to the .mmcu command register is
#     a no-op and every run that reaches `sleep` with interrupts off exits 0.
#   * 1.6 renders a UART byte below 0x20 as `.` and then breaks the line, so
#     `boot\n` comes out as `boot.`; master prints `boot`.
#   * on a bad access 1.6 calls `avr_sadly_crashed`, which starts its GDB stub
#     and WAITS -- which is why the failure this image exists to catch showed up
#     in CI as a 15-minute hang and not as an error.
#
# Built once and cached by tag; examples/avr/test.sh builds it on demand with
#
#     docker build --platform linux/amd64 -t mc-avr-oracle examples/avr/oracle
#
# and skips the whole step when there is no Docker. The CI leg installs the
# same two packages directly on its ubuntu runner.
FROM ubuntu:latest
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        simavr qemu-system-misc \
 && rm -rf /var/lib/apt/lists/*
