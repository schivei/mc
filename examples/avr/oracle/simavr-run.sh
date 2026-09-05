#!/bin/sh
# simavr-run.sh -- run one AVR image under one simavr and judge the result.
#
#   sh examples/avr/oracle/simavr-run.sh SIMAVR ELF WORKDIR MODE ARG [CODE]
#
#     SIMAVR   the simavr to use (a path or a name on PATH)
#     ELF      the image to run
#     WORKDIR  a scratch directory; it is created and overwritten
#     MODE     `exact` -- ARG is the transcript the firmware must write, and
#                         CODE (default 0) the verdict it must halt with
#              `sweep` -- ARG is the sweep's name: the transcript must contain
#                         `ARG 0 failed` and must not contain `FAIL`
#
# It exists because examples/avr/test.sh and the `baremetal-avr` CI leg have to
# judge the same bytes the same way, and because the two simavr versions in use
# do not present those bytes the same way at all (M40, docs/specs/M40.md
# finding 11):
#
#   * simavr master (what Homebrew builds, what a developer installs by hand)
#     writes the firmware's UART0 bytes to STDOUT, one line per `\n`.
#   * simavr 1.6 (what Debian and Ubuntu ship, and therefore what the CI leg
#     runs) writes them to STDERR, renders the `\n` itself as a trailing `.`,
#     and breaks the line after it.
#
# Both wrap each console line in the green ANSI pair `ESC[32m ... ESC[0m`, and
# neither colours its own log lines, so THAT is what separates the firmware's
# transcript from the simulator's chatter -- not a list of log prefixes, which
# a firmware could collide with. Measured on both versions, with the streams
# redirected to files, so the colour is not a tty artefact.
#
# The verdict is the other half. simavr master implements SIMAVR_CMD_EXIT_CODE_0
# and _1, so `halt(N)` becomes the simulator's own exit status. simavr 1.6's
# command enum stops at SIMAVR_CMD_UART_LOOPBACK: the same write to the .mmcu
# command register is a no-op there, it logs `code 0x05 has no handler (wrong
# MMCU config)` and the process exits 0 whatever the firmware asked for. So the
# verdict is read off the CHANNEL rather than off the process: at `-v -v -v`
# both versions log the byte the firmware wrote (`_avr_cmd_io_write: 0x04` for
# halt(0), `0x05` for halt(1)), and the process status is additionally required
# to match on the version that can carry it. Which version this is, is
# DETECTED (the `has no handler` line), never assumed from a version string.
#
# `-v -v -v` is also what makes a bad access visible: an image that reads
# outside SRAM logs `CORE: *** Invalid read address ...` and then
# `avr_sadly_crashed`, which on 1.6 starts a GDB stub and WAITS -- so the run is
# guarded by a watchdog and a killed run is reported as `hung`, a different
# failure from a wrong transcript. There is no `timeout` on macOS and no script
# in this repository uses one.
#
# Files left in WORKDIR: `out`/`err` (the two streams as they came), `transcript`
# (the firmware's bytes), `log` (everything else, ANSI stripped), `status`.
# Prints one `ok ...` line and exits 0, or one `FAIL ...` line per problem and
# exits 1.

sim=$1
elf=$2
w=$3
mode=$4
arg=$5
code=${6:-0}
limit=${SIMAVR_LIMIT:-60}

[ -n "$sim" ] && [ -n "$elf" ] && [ -n "$w" ] && [ -n "$mode" ] || {
    echo "usage: simavr-run.sh SIMAVR ELF WORKDIR MODE ARG [CODE]" >&2
    exit 2
}

rm -rf "$w"
mkdir -p "$w" || exit 2
esc=$(printf '\033')
name=$(basename "$elf")

# ---- the watchdog ----
# The whole block writes to /dev/null because the SHELL announces a job it
# reaped after a kill ("Killed: 9"), and having to kill a hung simulator is one
# of the outcomes this script exists to report, not news.
{
    "$sim" -v -v -v "$elf" < /dev/null > "$w/out" 2> "$w/err" &
    pid=$!
    (
        i=0
        while [ "$i" -lt "$limit" ]; do
            kill -0 "$pid" 2>/dev/null || exit 0
            sleep 1
            i=$((i + 1))
        done
        echo hung > "$w/hung"
        kill -9 "$pid" 2>/dev/null
    ) > /dev/null 2>&1 &
    killer=$!
    wait "$pid"
    st=$?
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null
} 2> /dev/null

# ---- normalisation ----
# The firmware's transcript is every GREEN line of either stream, with the
# colour taken off and 1.6's rendering of the newline (a trailing `.`) dropped.
# Concatenating stdout then stderr is safe in both directions: the stream that
# does not carry the console has no green line in it.
cat "$w/out" "$w/err" 2>/dev/null | grep "${esc}\[32m" \
    | sed "s/${esc}\[[0-9;]*m//g; s/\.\$//" > "$w/transcript"
cat "$w/out" "$w/err" 2>/dev/null | grep -v "${esc}\[32m" \
    | sed "s/${esc}\[[0-9;]*m//g" > "$w/log"
echo "${st:-?}" > "$w/status"

cmd=$(sed -n 's/.*_avr_cmd_io_write: 0x\([0-9a-fA-F][0-9a-fA-F]\).*/\1/p' "$w/log" | tail -1)
if grep -q "has no handler" "$w/log"; then cmdok=no; else cmdok=yes; fi

bad=0
say() { echo "FAIL  $name: $1"; bad=$((bad + 1)); }

# ---- the assertions ----
if [ -f "$w/hung" ]; then
    say "hung; killed after ${limit}s"
    sed 's/^/        | /' "$w/transcript"
    grep -E "Invalid (read|write)|avr_sadly_crashed" "$w/log" | sed 's/^/        | /'
    exit 1
fi

# a bad access: the simulator saw it even when the firmware went on to print
# something plausible, so it is checked before anything else is believed
if grep -qE "Invalid (read|write)|avr_sadly_crashed" "$w/log"; then
    say "the simulator reported a bad access"
    grep -E "Invalid (read|write)|avr_sadly_crashed" "$w/log" | sed 's/^/        | /'
fi

if [ "$mode" = "exact" ]; then
    if [ "$(cat "$w/transcript")" != "$arg" ]; then
        say "transcript"
        echo "        got:      $(tr '\n' '|' < "$w/transcript")"
        echo "        expected: $(printf '%s' "$arg" | tr '\n' '|')"
    fi
    want_cmd=04
    [ "$code" = "1" ] && want_cmd=05
    if [ "$cmd" != "$want_cmd" ]; then
        say "the firmware wrote 0x${cmd:-none} to the .mmcu command register, expected 0x$want_cmd"
    fi
    if [ "$cmdok" = "yes" ]; then
        [ "$st" = "$code" ] || say "exit $st, expected $code"
    else
        [ "$st" = "0" ] || say "exit $st; this simavr has no exit-code command, so 0 is the only status it can give"
    fi
elif [ "$mode" = "sweep" ]; then
    if grep -q FAIL "$w/transcript"; then
        say "reported a wrong answer"
        grep FAIL "$w/transcript" | sed 's/^/        | /'
    fi
    grep -q "^$arg 0 failed\$" "$w/transcript" \
        || { say "did not finish"; sed 's/^/        | /' "$w/transcript"; }
else
    say "unknown mode: $mode"
fi

[ "$bad" = "0" ] || exit 1

if [ "$mode" = "sweep" ]; then
    echo "ok    $name: every check agreed (exit $st, no bad access)"
elif [ "$cmdok" = "yes" ]; then
    echo "ok    $name: transcript, .mmcu command 0x$cmd, exit $st, no bad access"
else
    echo "ok    $name: transcript, .mmcu command 0x$cmd (this simavr cannot carry it: exit $st), no bad access"
fi
exit 0
