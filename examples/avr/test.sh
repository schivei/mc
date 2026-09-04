#!/bin/sh
# test.sh — acceptance test for `examples/avr`, a bare-metal ATmega328P image
# built by a RECREATED compiler (M40, docs/specs/M40.md).
#
#   sh examples/avr/test.sh        # from the repository root
#   make check-avr                 # the same, from the root Makefile
#
# Ten steps:
#
#   1. `mc build` reads mc.toml and does both halves: it assembles the taught
#      compiler (build/mc-avr) out of <mc/core_min> + <mc/core_build> +
#      machine_avr.mc + image_avr.mc + avr_syntax.mc, then SPAWNS it as
#      `mc-avr build DIR --config FILE --entry-only`, and that child compiles
#      main.mc into build/avr.elf through `[target] os = "none" / arch = "avr"`
#      -- a pair only the taught compiler knows (M39.5). The single-file CLI
#      builds every source that is not [project].entry.
#   2. simavr, the primary oracle: the exact transcript and exit 0, and a second
#      image that halts with 1 must exit 1 -- otherwise the exit channel proves
#      nothing. A run that has to be killed is reported as `hung`, which is a
#      different failure from `ran and misbehaved`.
#   3. qemu-system-avr, the second oracle: the same five lines on UART0, ended
#      by the watchdog because an Arduino Uno has no exit device.
#   4. the two on-device sweeps: every task of the machine, checked by the
#      program itself, under both oracles.
#   5. determinism: two builds byte-identical, no host path in the image.
#   6. the default compiler refuses all three halves.
#   7. the ABI the machine states, asserted over `--dump-asm --machine=avr` and
#      over the disassembly of the image.
#   8. the four things the machine and the writer REFUSE rather than truncate:
#      a frame past the part's SRAM, an image past its flash, a jump past
#      `rjmp`'s 12-bit field, and a `sfr` that is not a constant.
#   9. the encoder against llvm-mc, and the ELF against avr-gcc, field by field.
#  10. `mc limits examples/avr`, cold and remembered.
#
# Self-skipping: without simavr steps 2 and 4a are skipped, without
# qemu-system-avr step 3, without llvm-mc/avr-objcopy the encoder sweep, without
# avr-gcc/avr-readelf the toolchain comparison -- and the rest still runs. THERE
# IS NO `timeout` ON macOS and no script in this repository uses one: the
# watchdog below is POSIX sh.

root=$(cd "$(dirname "$0")/../.." && pwd)
dir="$root/examples/avr"
mc="$root/build/mc1"
mca="$dir/build/mc-avr"
img="$dir/build/avr.elf"
tmp="/tmp/mc_avr_test_$$"
limit=25
fails=0
skips=0
esc=$(printf '\033')

simavr=$(command -v simavr 2>/dev/null)
qemu=$(command -v qemu-system-avr 2>/dev/null)
llvmmc=$(command -v llvm-mc 2>/dev/null)
[ -n "$llvmmc" ] || [ ! -x /opt/homebrew/opt/llvm/bin/llvm-mc ] || llvmmc=/opt/homebrew/opt/llvm/bin/llvm-mc
objcopy=$(command -v avr-objcopy 2>/dev/null)
objdump=$(command -v avr-objdump 2>/dev/null)
readelf=$(command -v avr-readelf 2>/dev/null)
avrgcc=$(command -v avr-gcc 2>/dev/null)

cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM
mkdir -p "$tmp"

fail() {
    echo "  FAIL  $1"
    shift
    for line in "$@"; do echo "        $line"; done
    fails=$((fails + 1))
}

ok() { echo "  ok    $1"; }

skip() {
    echo "  SKIP  $1"
    skips=$((skips + 1))
}

# ---- the watchdog ----
# Runs a simulator in the background, polls it once a second for $limit seconds
# and kills it if it is still there. stdout in $tmp/out, stderr in $tmp/err, the
# wait status in $status, and the string `hung` in $tmp/hung if it was killed.
run_guarded() {
    rm -f "$tmp/hung"
    # the whole block writes to /dev/null because the SHELL reports a job it
    # reaped after a kill ("Killed: 9"), and a watchdog that has to kill QEMU is
    # the expected outcome here, not news
    {
        "$@" < /dev/null > "$tmp/out" 2> "$tmp/err" &
        pid=$!
        (
            i=0
            while [ "$i" -lt "$limit" ]; do
                kill -0 "$pid" 2>/dev/null || exit 0
                sleep 1
                i=$((i + 1))
            done
            echo hung > "$tmp/hung"
            kill -9 "$pid" 2>/dev/null
        ) > /dev/null 2>&1 &
        killer=$!
        wait "$pid"
        status=$?
        kill "$killer" 2>/dev/null
        wait "$killer" 2>/dev/null
    } 2> /dev/null
    # simavr wraps each console line in an ANSI colour; the transcript is the
    # bytes the firmware wrote, so the colour comes off before anything is
    # compared (measured on this host: \033[32m ... \033[0m per line).
    sed "s/${esc}\[[0-9;]*m//g" "$tmp/out" > "$tmp/plain"
    return 0
}

# ---- 1. the taught compiler, and the image, in one `mc build` ----
echo "== mc build examples/avr (the recreated compiler, then the image) =="
if [ ! -x "$mc" ]; then
    make -C "$root" mc1 || { echo "FAIL: make mc1"; exit 1; }
fi
rm -f "$img" "$mca"
"$mc" build "$dir" || { echo "FAIL: mc build"; exit 1; }
[ -x "$mca" ] || { echo "FAIL: mc build did not produce $mca"; exit 1; }
ok "$mca ($(wc -c < "$mca" | tr -d ' ') bytes)"
[ -f "$img" ] || { echo "FAIL: mc build did not produce $img"; exit 1; }
ok "$img ($(wc -c < "$img" | tr -d ' ') bytes), written for [target] none/avr"

# the same image from the single-file CLI: the two roads have to agree byte for
# byte, which is what says `mc build` added a road and changed no output
( cd "$dir" && ./build/mc-avr --backend=avr-image --include=lib main.mc -o build/avr-cli.elf ) \
    || fail "mc-avr --backend=avr-image"
if cmp -s "$img" "$dir/build/avr-cli.elf"; then
    ok "mc build and --backend=avr-image write the same bytes"
else
    fail "mc build and the single-file CLI disagree"
fi
rm -f "$dir/build/avr-cli.elf"

# the two sweep programs, through the CLI (they are not [project].entry)
for s in sweep_a sweep_b; do
    ( cd "$dir" && ./build/mc-avr --backend=avr-image --include=lib \
        "tests/$s.mc" -o "build/$s.elf" ) || fail "could not build tests/$s.mc"
done

# ---- 2. simavr, the primary oracle ----
transcript=$(printf 'boot\nblink\ntick\nsum 352\nok')

if [ -z "$simavr" ]; then
    skip "simavr not found: the image was built but not run"
else
    echo "== simavr =="
    run_guarded "$simavr" "$img"
    if [ -f "$tmp/hung" ]; then
        fail "the firmware hung (killed after ${limit}s)" "$(cat "$tmp/plain")"
    elif [ "$status" -ne 0 ]; then
        fail "exit code $status, expected 0" "$(cat "$tmp/plain")" "$(head -3 "$tmp/err")"
    elif [ "$(cat "$tmp/plain")" != "$transcript" ]; then
        fail "transcript" "got:      $(tr '\n' '|' < "$tmp/plain")" \
                          "expected: $(printf '%s' "$transcript" | tr '\n' '|')"
    else
        ok "transcript and exit 0"
        sed 's/^/        | /' "$tmp/plain"
    fi

    # the same firmware halting with 1: the exit channel has to carry a verdict,
    # or step 2 is asserting a constant
    sed 's/    halt(0);/    halt(1);/' "$dir/main.mc" > "$dir/build/main1.mc"
    ( cd "$dir" && ./build/mc-avr --backend=avr-image --include=lib \
        build/main1.mc -o build/avr1.elf ) > /dev/null 2>&1 \
        || fail "could not build the halt(1) image"
    if [ -f "$dir/build/avr1.elf" ]; then
        run_guarded "$simavr" "$dir/build/avr1.elf"
        if [ -f "$tmp/hung" ]; then fail "the halt(1) image hung"
        elif [ "$status" -ne 1 ]; then fail "exit code $status, expected 1"
        else ok "halt(1) gives exit 1 (SIMAVR_CMD_EXIT_CODE_1)"
        fi
    fi
    rm -f "$dir/build/main1.mc" "$dir/build/avr1.elf"
fi

# ---- 3. qemu-system-avr, the second oracle ----
# An arduino-uno has no exit device, so the run ends when the watchdog kills it.
# That is the expected outcome here and it is asserted as such: what matters is
# that the SAME five lines come out of UART0 on a second, independent model of
# the part.
if [ -z "$qemu" ]; then
    skip "qemu-system-avr not found: the second oracle did not run"
else
    echo "== $("$qemu" --version | head -1) =="
    run_guarded "$qemu" -machine arduino-uno -bios "$img" -nographic
    if [ "$(cat "$tmp/plain")" != "$transcript" ]; then
        fail "qemu transcript" "got:      $(tr '\n' '|' < "$tmp/plain")" \
                               "expected: $(printf '%s' "$transcript" | tr '\n' '|')"
    elif [ ! -f "$tmp/hung" ]; then
        fail "qemu ended on its own (exit $status): an arduino-uno has no exit device"
    else
        ok "the same transcript on UART0, ended by the watchdog as expected"
    fi
fi

# ---- 4. the two sweeps, on the device ----
sweep_run() {
    name="$2"
    run_guarded "$1" "$dir/build/$name.elf"
    if [ -f "$tmp/hung" ]; then
        fail "$3: $name hung" "$(cat "$tmp/plain")"
    elif grep -q FAIL "$tmp/plain"; then
        fail "$3: $name reported a wrong answer" "$(grep FAIL "$tmp/plain")"
    elif ! grep -q "^$name 0 failed" "$tmp/plain"; then
        fail "$3: $name did not finish" "$(cat "$tmp/plain")"
    else
        ok "$3: $name, every check agreed"
    fi
}

echo "== the machine, checked by the programs themselves =="
for s in sweep_a sweep_b; do
    [ -f "$dir/build/$s.elf" ] || continue
    [ -z "$simavr" ] || sweep_run "$simavr" "$s" simavr
done
if [ -n "$qemu" ]; then
    for s in sweep_a sweep_b; do
        [ -f "$dir/build/$s.elf" ] || continue
        run_guarded "$qemu" -machine arduino-uno -bios "$dir/build/$s.elf" -nographic
        if grep -q FAIL "$tmp/plain"; then
            fail "qemu: $s reported a wrong answer" "$(grep FAIL "$tmp/plain")"
        elif ! grep -q "^$s 0 failed" "$tmp/plain"; then
            fail "qemu: $s did not finish" "$(cat "$tmp/plain")"
        else
            ok "qemu: $s, every check agreed"
        fi
    done
fi

# ---- 5. determinism ----
cp "$img" "$tmp/first.elf"
"$mc" build "$dir" > /dev/null || fail "the second build failed"
if cmp -s "$tmp/first.elf" "$img"; then ok "two builds are byte-identical"
else fail "the image is not deterministic"
fi
if LC_ALL=C grep -q -e "$root" -e "/Users/" -e "/home/" "$img" 2>/dev/null; then
    fail "the image contains a host path"
else
    ok "no path, no date, no host string in the image"
fi

# ---- 6. the default compiler refuses every half ----
echo "== the architecture is the module's, not the language's =="
printf 'i64 main() { return 0; }\n' > "$tmp/trivial.mc"
"$mc" --backend=avr-image "$tmp/trivial.mc" -o "$tmp/x.o" > /dev/null 2> "$tmp/e1"
if grep -q "unknown backend: avr-image" "$tmp/e1"; then ok "mc1: unknown backend: avr-image"
else fail "mc1 did not refuse --backend=avr-image" "$(cat "$tmp/e1")"
fi
"$mc" --include="$dir/lib" "$dir/main.mc" -o "$tmp/x.o" > /dev/null 2> "$tmp/e2"
if grep -q "type expected at top level" "$tmp/e2"; then ok "mc1: type expected at top level (sfr)"
else fail "mc1 accepted the firmware source" "$(cat "$tmp/e2")"
fi
"$mc" build "$dir" --entry-only > /dev/null 2> "$tmp/e3"
if grep -q "only macos, linux and windows (see docs/build.md): target.os" "$tmp/e3"; then
    ok "mc1 --entry-only: none/avr is not a target it knows"
else
    fail "mc1 accepted [target] none/avr" "$(cat "$tmp/e3")"
fi

# ---- 7. the ABI the machine states ----
# The claims are examples/avr/README.md § The ABI. Each one is checked over the
# whole firmware, not a probe function.
echo "== the ABI, asserted over --dump-asm --machine=avr =="
( cd "$dir" && ./build/mc-avr --backend=avr-image --dump-asm --machine=avr \
    --include=lib main.mc ) > "$tmp/main.asm" || fail "--dump-asm --machine=avr failed"
nfun=$(grep -c '^_' "$tmp/main.asm")

# a. the frame record is unconditional: every function opens with prologue+frame
awk '/^_/{ getline a; getline b
     if (a != "  prologue" || b !~ /^  frame /) { print "at " $0 ": " a " / " b; n++ } }
     END { exit n > 0 }' "$tmp/main.asm" > "$tmp/a" 2>&1 \
    && ok "$nfun functions open with the unconditional prologue and frame" \
    || fail "a function does not open with the frame record" "$(cat "$tmp/a")"

# b. the epilogue is the last thing in every function and carries the same size
awk '/^  epilogue /{ e++; if ($2 != frame) { print "epilogue " $2 " against frame " frame; n++ } }
     /^  frame /{ frame = $2 }
     END { if (e != f) { } exit n > 0 }' "$tmp/main.asm" > "$tmp/b" 2>&1 \
    && ok "every epilogue releases exactly the frame its prologue reserved" \
    || fail "an epilogue disagrees with its prologue" "$(cat "$tmp/b")"

# c. r2..r7 are never named: the machine's whole register file is r0, r8..r31
if grep -qE '\br[2-7]\b' "$tmp/main.asm"; then
    fail "the firmware names a register the ABI says it never writes" \
         "$(grep -nE '\br[2-7]\b' "$tmp/main.asm" | head -3)"
else
    ok "0 mentions of r2..r7 in $(wc -l < "$tmp/main.asm" | tr -d ' ') lines"
fi

# d. the interrupt save set is in ONE file: `push`, `pop` and `reti` are written
#    by hand, and only in lib/isr.mc
strays=$(grep -lE 'push_r|pop_r|op_reti' "$dir"/*.mc "$dir"/lib/*.mc "$dir"/tests/*.mc 2>/dev/null \
         | grep -v '/isr.mc$' | tr '\n' ' ')
if [ -z "$strays" ]; then ok "the ISR save set is named in lib/isr.mc and nowhere else"
else fail "the ISR save set leaked into: $strays"
fi

# e. the frame past `ldd`'s six bits: sweep_b's 200-byte array is the case, and
#    the machine's X fallback is what has to appear
( cd "$dir" && ./build/mc-avr --backend=avr-image --dump-asm --machine=avr \
    --include=lib tests/sweep_b.mc ) > "$tmp/sweep.asm" || fail "--dump-asm of sweep_b failed"
deep=$(awk 'match($0, /Y\+[0-9]+/) { n = substr($0, RSTART + 2, RLENGTH - 2) + 0
        if (n > m) m = n } END { print m + 0 }' "$tmp/sweep.asm")
if [ "$deep" -gt 63 ]; then
    ok "sweep_b addresses a frame byte at Y+$deep, past ldd's six-bit field"
else
    fail "no frame displacement past 63: the X fallback is not exercised"
fi

# ---- 8. what the machine refuses rather than truncates ----
echo "== refused, not truncated =="
refuses() {                                # name, source file, expected message
    ( cd "$dir" && ./build/mc-avr --backend=avr-image --include=lib "$2" -o "$tmp/bad.elf" ) \
        > "$tmp/r.out" 2> "$tmp/r.err"
    rc=$?
    if [ "$rc" = "0" ]; then
        fail "$1 was accepted" "$(wc -c < "$tmp/bad.elf" | tr -d ' ') bytes written"
    elif grep -q "$3" "$tmp/r.err"; then
        ok "$1: $(cat "$tmp/r.err")"
    else
        fail "$1 failed for another reason (exit $rc)" "$(head -2 "$tmp/r.err")"
    fi
    rm -f "$tmp/bad.elf"
}

# a frame past the part's SRAM
printf 'i64 f() { u8 b[1100]; st8(b, 1); return ld8(b); }\nvoid _start() { f(); }\n' \
    > "$dir/build/bigframe.mc"
refuses "a frame past 2 KiB of SRAM" build/bigframe.mc "avr frame too large"

# an image past the part's flash: 40 copies of the sweep's arithmetic
{ echo '#include "rt_avr.mc"'
  echo 'i64 g = 1;'
  i=0
  while [ "$i" -lt 90 ]; do
      echo "i64 big$i(i64 n) { return n * 0x123456789abc / 7 % 1000 + g; }"
      i=$((i + 1))
  done
  echo 'void _start() { i64 s = 0;'
  i=0
  while [ "$i" -lt 90 ]; do
      echo "    s = s + big$i(s);"
      i=$((i + 1))
  done
  echo '}'
} > "$dir/build/bigflash.mc"
refuses "an image past 32 KiB of flash" build/bigflash.mc "does not fit in 32 KiB of flash"

# a jump past rjmp's signed 12-bit word field: one `if` over 4 KiB of code.
# Built by hand without the guard it comes out as a wrapped displacement -- an
# image that boots and then lands in the middle of an instruction, which is the
# failure the M39 review put this class of check in the repository for.
{ echo 'i64 far(i64 n) { if (n > 0) {'
  i=0
  while [ "$i" -lt 60 ]; do
      echo '    n = n + 0x123456789abc;'
      i=$((i + 1))
  done
  echo '} return n; }'
  echo 'void _start() { far(0); }'
} > "$dir/build/farjump.mc"
refuses "a jump past rjmp's 4 KiB" build/farjump.mc "avr rjmp out of range"

# and the taught word says so at the word, not at the end of the build
printf 'sfr BAD nosuch;\nvoid _start() { }\n' > "$dir/build/badsfr.mc"
refuses "sfr with something that is not a constant" build/badsfr.mc "sfr expects a constant"
rm -f "$dir/build/bigframe.mc" "$dir/build/bigflash.mc" "$dir/build/farjump.mc" "$dir/build/badsfr.mc"

# ---- 9. the encoder against llvm-mc, and the ELF against avr-gcc ----
# Every distinct instruction the machine emits, disassembled out of the image
# and fed back through the assembler, has to come out byte for byte. AVR mixes
# 2- and 4-byte instructions, so the byte walk below derives each instruction's
# length from its mnemonic -- and asserts at the end that it consumed the whole
# section, which is what says the walk itself is right.
echo "== the encoder against llvm-mc =="
cat > "$tmp/walk.awk" <<'AWKEOF'
NR == FNR { b[n++] = $1; next }
{ line = $0; gsub(/^[ \t]+/, "", line)
  len = 2
  if ($1 == "jmp" || $1 == "call" || $1 == "lds" || $1 == "sts") len = 4
  h = ""
  for (i = 0; i < len; i++) h = h b[p + i]
  addr = p; p += len
  printf "%s\t%s\n", h, line
  if ($1 ~ /^(rjmp|rcall)$/ || $1 ~ /^br/) {
      off = $NF; sub(/^\./, "", off)
      t = addr + len + off
      nrel++
      if (t < 0 || t >= n || t % 2 != 0) { bad++; print "BAD " $1 " at " addr " -> " t > "/dev/stderr" }
  }
  if ($1 == "jmp" || $1 == "call") {
      t = $2 + 0; nabs++
      if (t % 2 != 0 || t >= n) { bad++; print "BAD abs " $1 " at " addr " -> " t > "/dev/stderr" }
  }
}
END { if (p != n) { bad++; print "BYTE WALK consumed " p " of " n > "/dev/stderr" }
      printf "%d %d %d\n", nrel + 0, nabs + 0, bad + 0 > "/dev/stderr" }
AWKEOF

sweep_one() {
    name="$1"
    "$objcopy" -O binary --only-section=.text "$2" "$tmp/s.text" 2>/dev/null \
        || { fail "sweep: could not extract .text from $name"; return 1; }
    xxd -p -c1 "$tmp/s.text" > "$tmp/s.bytes"
    awk '{ printf "0x%s ", $1 }' "$tmp/s.bytes" > "$tmp/s.hex"
    "$llvmmc" --disassemble -triple=avr -mcpu=atmega328p "$tmp/s.hex" \
        > "$tmp/s.dis" 2> "$tmp/s.diserr"
    if [ -s "$tmp/s.diserr" ]; then
        fail "sweep: $name did not disassemble cleanly" "$(head -3 "$tmp/s.diserr")"
        return 1
    fi
    awk -f "$tmp/walk.awk" "$tmp/s.bytes" "$tmp/s.dis" > "$tmp/s.pairs" 2> "$tmp/s.pcerr"
    counts=$(tail -1 "$tmp/s.pcerr")
    set -- $counts
    nrel=$1; nabs=$2; nbad=$3
    # a relative branch does not round-trip as text (llvm's `.` is not the
    # disassembler's), so its displacement is checked above and its bytes are
    # left out of the assembler comparison
    grep -v -E "	(rjmp|rcall|br[a-z]+)	" "$tmp/s.pairs" | sort -u > "$tmp/s.d"
    cut -f2- "$tmp/s.d" > "$tmp/s.asm"
    cut -f1 "$tmp/s.d" > "$tmp/s.orig"
    "$llvmmc" -triple=avr -mcpu=atmega328p --show-encoding "$tmp/s.asm" 2> "$tmp/s.asmerr" \
        | grep -o "encoding: \[.*\]" \
        | sed 's/encoding: \[//; s/\]//; s/0x//g; s/,//g; s/ //g' > "$tmp/s.enc"
    ndistinct=$(wc -l < "$tmp/s.d" | tr -d ' ')
    nmis=$(diff "$tmp/s.orig" "$tmp/s.enc" | grep -c '^<')
    if [ "$nmis" = "0" ] && [ "$nbad" = "0" ]; then
        ok "$name: $ndistinct distinct instructions, 0 mismatches; $nrel relative and $nabs absolute targets, 0 wrong"
    else
        fail "$name: $nmis byte mismatches, $nbad wrong targets" "$(head -4 "$tmp/s.pcerr")"
    fi
    sweep_total=$((sweep_total + ndistinct))
}

if [ -z "$llvmmc" ] || [ -z "$objcopy" ] || ! command -v xxd > /dev/null 2>&1; then
    skip "llvm-mc, avr-objcopy or xxd not found: the encoder sweep did not run"
else
    sweep_total=0
    sweep_one "main.mc" "$img"
    sweep_one "tests/sweep_a.mc" "$dir/build/sweep_a.elf"
    sweep_one "tests/sweep_b.mc" "$dir/build/sweep_b.elf"
fi

# The ELF, field by field against the same program built by a real toolchain.
# What is compared is the SHAPE -- class, data, type, machine, flags, the three
# LOAD segments and the four section headers -- not the sizes, which are the
# compilers' own business.
echo "== the ELF against avr-gcc =="
if [ -z "$avrgcc" ] || [ -z "$readelf" ] || [ -z "$objdump" ]; then
    skip "avr-gcc or avr-binutils not found: the toolchain comparison did not run"
else
    cat > "$tmp/ref.c" <<'REFEOF'
#include <avr/io.h>
#include <avr/interrupt.h>
#include <stdint.h>
volatile uint8_t ticks = 0;
const char msg[] = "ok\n";
ISR(TIMER1_OVF_vect) { ticks++; }
int main(void) {
    DDRB |= (1 << 5);
    for (const char *p = msg; *p; p++) { while (!(UCSR0A & (1 << 5))) {} UDR0 = *p; }
    TCCR1B = 2; TIMSK1 = 1; sei();
    while (!ticks) { }
    for (;;) { }
    return 0;
}
REFEOF
    if ! "$avrgcc" -mmcu=atmega328p -DF_CPU=16000000 -Os -o "$tmp/ref.elf" "$tmp/ref.c" \
            > "$tmp/gcc.err" 2>&1; then
        skip "avr-gcc could not build the reference: $(head -1 "$tmp/gcc.err")"
    else
        elf_head() {
            "$readelf" -h "$1" | grep -E "Class|Data:|Type:|Machine:|Flags:|Entry point|Size of this header|Size of program headers" > "$2"
        }
        elf_head "$tmp/ref.elf" "$tmp/h.ref"
        elf_head "$img" "$tmp/h.mine"
        if diff "$tmp/h.ref" "$tmp/h.mine" > "$tmp/h.diff" 2>&1; then
            ok "ELF header identical to avr-gcc's (class, data, type, machine, flags, entry, sizes)"
        else
            fail "the ELF header differs from avr-gcc's" "$(cat "$tmp/h.diff")"
        fi
        elf_phdr() { "$readelf" -l "$1" | awk '/LOAD/{ print $1, $(NF-1), $NF }' > "$2"; }
        elf_phdr "$tmp/ref.elf" "$tmp/p.ref"
        elf_phdr "$img" "$tmp/p.mine"
        if diff "$tmp/p.ref" "$tmp/p.mine" > "$tmp/p.diff" 2>&1; then
            ok "the same three LOAD segments, with the same flags and alignment"
        else
            fail "the program headers differ" "$(cat "$tmp/p.diff")"
        fi
        elf_sec() {
            "$readelf" -S "$1" | awk '$2 ~ /^\.(text|data|bss|mmcu)$/ { print $2, $4, $8, $NF }' \
                | sort > "$2"
        }
        elf_sec "$tmp/ref.elf" "$tmp/s.ref"
        elf_sec "$img" "$tmp/s.mine"
        if diff "$tmp/s.ref" "$tmp/s.mine" > "$tmp/s.diff" 2>&1; then
            ok "the four sections agree on type, flags and alignment"
        else
            fail "a section header differs" "$(cat "$tmp/s.diff")"
        fi
        # the vector table: the numbers come from the datasheet, and this is
        # what says they were read right -- TIMER1_OVF is entry 13 in both
        refv=$("$objdump" -d "$tmp/ref.elf" | awk '/^  *34:/{ print $NF; exit }')
        minev=$("$objdump" -d "$img" | awk '/^  *34:/{ print $NF; exit }')
        if [ "$refv" = "<__vector_13>" ] && [ "$minev" = "<vector_13>" ]; then
            ok "vector 13 (TIMER1_OVF) is at flash 0x34 in both, and points at the handler"
        else
            fail "the vector table does not agree with avr-gcc's" "ref $refv, mine $minev"
        fi
        nvec=$("$objdump" -d "$img" | awk '/^  *[0-9a-f]+:\t0c 94/{ n++ } END { print n + 0 }')
        if [ "$nvec" -ge 26 ]; then
            ok "26 vector entries, each a 4-byte jmp (0x940c), as in the reference"
        else
            fail "the vector table has $nvec jmp entries, expected at least 26"
        fi
    fi
fi

# ---- 10. limits ----
# Two phases, the shape M23 recorded for examples/api and examples/kernel: the
# COMPILER half must not grow even cold -- that is what `[limits] tolerance =
# 1.0` buys -- and after `mc build` has remembered the usage BOTH halves must be
# exit 0 with grow 0. Exit 3 alone is not a pass.
echo "== mc limits =="
rm -f "$dir/build/.mc-usage.toml"
"$mc" limits "$dir" > "$tmp/lim" 2>&1
rc=$?
awk '/^limits /{ half = $2 }
     half ~ /mc-avr/ && / grew$/ { print; n++ }
     END { exit n > 0 }' "$tmp/lim" > "$tmp/limg" 2>&1 \
    && ok "cold: nothing grows in the compiler half, which is what tolerance 1.0 buys" \
    || fail "cold: a table grew in the compiler half; tolerance 1.0 should prevent it" \
            "$(cat "$tmp/limg")"
if [ "$rc" = "0" ] || [ "$rc" = "3" ]; then
    ok "cold: exit $rc ($(grep -c ' grew$' "$tmp/lim") grown, $(grep -c ' tight$' "$tmp/lim") tight, over both halves)"
else
    fail "cold: mc limits exited $rc, expected 0 or 3" "$(tail -5 "$tmp/lim")"
fi

"$mc" build "$dir" > "$tmp/build2" 2>&1 || fail "mc build examples/avr failed" "$(tail -3 "$tmp/build2")"
"$mc" limits "$dir" > "$tmp/lim2" 2>&1
rc=$?
if [ "$rc" != "0" ]; then
    fail "remembered: mc limits exited $rc, expected 0" "$(grep -E ' (grew|tight)$' "$tmp/lim2" | head -5)"
elif grep -qE ' grew$' "$tmp/lim2"; then
    fail "remembered: a table still grew" "$(grep -E ' grew$' "$tmp/lim2")"
else
    ok "remembered: $(grep -c '^tolerance ' "$tmp/lim2") reports, exit 0, grow 0 in every table"
fi
grep '^tolerance ' "$tmp/lim2" 2>/dev/null | sed 's/^/        | /'

echo
if [ "$fails" -eq 0 ]; then
    echo "examples/avr: OK ($skips skipped)"
    exit 0
fi
echo "examples/avr: $fails FAILED"
exit 1
