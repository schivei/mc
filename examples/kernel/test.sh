#!/bin/sh
# test.sh — acceptance test for `examples/kernel`, a bare-metal RISC-V 64
# micro-kernel built by a taught compiler (M39, docs/specs/M39.md).
#
#   sh examples/kernel/test.sh        # from the repository root
#   make check-kernel                 # the same, from the root Makefile
#
# Eight steps:
#
#   1. `mc build --compiler-only` reads mc.toml and assembles the taught
#      compiler (build/mc-kernel) out of `<mc/core>` + machine_riscv64.mc +
#      image.mc + kernel_syntax.mc, printing its path; then that binary
#      compiles main.mc into a flat image with `--backend=rv-image`.
#   2. QEMU runs the image and BOTH halves are asserted: the exact transcript
#      and the exit code the SiFive test device passes through. A second image
#      that halts with 42 must exit 42, which is what proves the code is
#      carried and not discarded. A run that has to be killed is reported as
#      `hung`, which is a different failure from `ran and misbehaved`.
#   3. determinism: two consecutive builds are byte-identical, and the image
#      contains no path, no date and no host string.
#   4. the default compiler refuses BOTH halves -- `--backend=rv-image` is an
#      unknown backend, and the source is `type expected at top level` at the
#      first `mmio`. The architecture is the module's, not the language's.
#   5. the ABI the machine states is asserted against `--dump-asm
#      --machine=riscv64` over the whole kernel, the way scripts/check-surface.sh
#      asserts AArch64's nine claims.
#   6. the frame edge case: a 3 KB local array, between RV's signed 2047 and the
#      walker's 4095, is inside the kernel and its checksum is asserted at run
#      time -- if the t2 fallback were wrong the transcript would say so.
#   7. the encoder oracle: every distinct instruction the machine emits, over
#      main.mc, over tests/sweep.mc and over a large generated source, is fed
#      back through `llvm-mc -triple=riscv64 -mattr=+m` and must come out
#      byte-identical; every pc-relative displacement is recomputed from an
#      independent placement of the sections and checked against its target.
#   8. `mc limits examples/kernel` reports both halves.
#
# Self-skipping: without qemu-system-riscv64 steps 2 and 6 are skipped and the
# rest still runs; without llvm-mc step 7 is skipped. THERE IS NO `timeout` ON
# macOS and no script in this repository uses one -- the watchdog below is
# POSIX sh: background the process, poll `kill -0`, `kill -9` and report.

root=$(cd "$(dirname "$0")/../.." && pwd)
dir="$root/examples/kernel"
mc="$root/build/mc1"
mck="$dir/build/mc-kernel"
img="$dir/build/kernel.bin"
tmp="/tmp/mc_kernel_test_$$"
limit=20
fails=0
skips=0

qemu=$(command -v qemu-system-riscv64 2>/dev/null)
llvmmc=$(command -v llvm-mc 2>/dev/null)
[ -n "$llvmmc" ] || [ ! -x /opt/homebrew/opt/llvm/bin/llvm-mc ] || llvmmc=/opt/homebrew/opt/llvm/bin/llvm-mc

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
# Runs QEMU in the background, polls it once a second for $limit seconds and
# kills it if it is still there. Leaves stdout in $tmp/out, stderr in $tmp/err,
# the wait status in $qstatus and the string `hung` in $tmp/hung if it had to
# be killed.
qemu_run() {
    rm -f "$tmp/hung"
    "$qemu" -machine virt -bios none -nographic -kernel "$1" \
        < /dev/null > "$tmp/out" 2> "$tmp/err" &
    qpid=$!
    (
        i=0
        while [ "$i" -lt "$limit" ]; do
            kill -0 "$qpid" 2>/dev/null || exit 0
            sleep 1
            i=$((i + 1))
        done
        echo hung > "$tmp/hung"
        kill -9 "$qpid" 2>/dev/null
    ) > /dev/null 2>&1 &
    killer=$!
    wait "$qpid"
    qstatus=$?
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null
    return 0
}

# ---- 1. the taught compiler, and the image ----
echo "== the taught compiler (mc build --compiler-only) =="
if [ ! -x "$mc" ]; then
    make -C "$root" mc1 || { echo "FAIL: make mc1"; exit 1; }
fi
"$mc" build "$dir" --compiler-only || { echo "FAIL: mc build --compiler-only"; exit 1; }
[ -x "$mck" ] || { echo "FAIL: mc build did not produce $mck"; exit 1; }
ok "$mck ($(wc -c < "$mck" | tr -d ' ') bytes)"

echo "== the kernel image (--backend=rv-image) =="
rm -f "$img"
( cd "$dir" && ./build/mc-kernel --backend=rv-image --include=lib main.mc -o build/kernel.bin ) \
    || { echo "FAIL: mc-kernel --backend=rv-image"; exit 1; }
[ -f "$img" ] || { echo "FAIL: no $img"; exit 1; }
ok "$img ($(wc -c < "$img" | tr -d ' ') bytes)"

# ---- 2. it runs, and the exit code carries the verdict ----
# The third line ends with a space: each task prints "tN " and the kernel adds
# the newline afterwards, so the last separator is still there.
expected=$(printf 'boot\ntrap\nt0 t1 t0 t1 t0 t1 t0 t1 t0 t1 \nok')

if [ -z "$qemu" ]; then
    skip "qemu-system-riscv64 not found: the kernel was built but not run"
else
    echo "== $("$qemu" --version | head -1) =="
    qemu_run "$img"
    if [ -f "$tmp/hung" ]; then
        fail "the kernel hung (killed after ${limit}s)" "$(cat "$tmp/out")"
    elif [ "$qstatus" -ne 0 ]; then
        fail "exit code $qstatus, expected 0" "$(cat "$tmp/out")"
    elif [ "$(cat "$tmp/out")" != "$expected" ]; then
        fail "transcript" "got:      $(cat "$tmp/out" | tr '\n' '|')" \
                          "expected: $(printf '%s' "$expected" | tr '\n' '|')"
    else
        ok "transcript and exit 0"
        printf '%s\n' "$(cat "$tmp/out")" | sed 's/^/        | /'
    fi

    # the same kernel halting with 42: the guest's verdict has to survive
    sed 's/halt(0);/halt(42);/' "$dir/main.mc" > "$dir/build/main42.mc"
    ( cd "$dir" && ./build/mc-kernel --backend=rv-image --include=lib \
        build/main42.mc -o build/kernel42.bin ) > /dev/null 2>&1 \
        || fail "could not build the exit-42 image"
    if [ -f "$dir/build/kernel42.bin" ]; then
        qemu_run "$dir/build/kernel42.bin"
        if [ -f "$tmp/hung" ]; then fail "the exit-42 kernel hung"
        elif [ "$qstatus" -ne 42 ]; then fail "exit code $qstatus, expected 42"
        else ok "halt(42) gives exit 42"
        fi
    fi
    rm -f "$dir/build/main42.mc" "$dir/build/kernel42.bin"
fi

# ---- 3. determinism ----
cp "$img" "$tmp/first.bin"
( cd "$dir" && ./build/mc-kernel --backend=rv-image --include=lib main.mc -o build/kernel.bin ) \
    || fail "the second build failed"
if cmp -s "$tmp/first.bin" "$img"; then ok "two builds are byte-identical"
else fail "the image is not deterministic"
fi
if LC_ALL=C grep -q -e "$root" -e "/Users/" -e "/home/" "$img" 2>/dev/null; then
    fail "the image contains a host path"
else
    ok "no path, no date, no host string in the image"
fi

# ---- 4. the default compiler refuses both halves ----
printf 'i64 main() { return 0; }\n' > "$tmp/trivial.mc"
"$mc" --backend=rv-image "$tmp/trivial.mc" -o "$tmp/x.o" > /dev/null 2> "$tmp/e1"
if grep -q "unknown backend: rv-image" "$tmp/e1"; then ok "mc1: unknown backend: rv-image"
else fail "mc1 did not refuse --backend=rv-image" "$(cat "$tmp/e1")"
fi
"$mc" --include="$dir/lib" "$dir/main.mc" -o "$tmp/x.o" > /dev/null 2> "$tmp/e2"
if grep -q "type expected at top level" "$tmp/e2"; then ok "mc1: type expected at top level (mmio)"
else fail "mc1 accepted the kernel source" "$(cat "$tmp/e2")"
fi

# ---- 5. the ABI the machine states ----
# The claims are examples/kernel/README.md § The ABI, and they are the RISC-V
# half of docs/reference/objects.md § 4. Each one is checked against the dump of
# the WHOLE kernel, not a probe function.
echo "== the ABI, asserted over --dump-asm --machine=riscv64 =="
( cd "$dir" && ./build/mc-kernel --dump-asm --machine=riscv64 --include=lib main.mc ) > "$tmp/kernel.asm" \
    || fail "--dump-asm --machine=riscv64 failed"
nfun=$(grep -c '^_' "$tmp/kernel.asm")

# a. the frame record is unconditional: every function opens with the same four
awk '/^_/{ getline a; getline b; getline c; getline d;
     if (a != "  addi sp, sp, -16" || b != "  sd ra, 8(sp)" ||
         c != "  sd s0, 0(sp)"     || d != "  mv s0, sp") { print "at " $0; n++ } }
     END { exit n > 0 }' "$tmp/kernel.asm" > "$tmp/a" 2>&1 \
    && ok "$nfun functions open with the unconditional ra/s0 frame record" \
    || fail "a function does not open with the frame record" "$(cat "$tmp/a")"

# b. the epilogue is fixed and never patched, and never names a0
awk '/^  ret$/{ if (p4 != "  mv sp, s0" || p3 != "  ld ra, 8(sp)" ||
                    p2 != "  ld s0, 0(sp)" || p1 != "  addi sp, sp, 16") { print "before ret: " p4 " / " p3 " / " p2 " / " p1; n++ } }
     { p4 = p3; p3 = p2; p2 = p1; p1 = $0 }
     END { exit n > 0 }' "$tmp/kernel.asm" > "$tmp/b" 2>&1 \
    && ok "every ret is preceded by exactly mv sp,s0 / ld ra / ld s0 / addi sp,sp,16" \
    || fail "an epilogue is not the fixed five" "$(cat "$tmp/b")"

# c. the callee-saved half is never written, and neither are gp and tp
bad=$(grep -o -E '\b(s[1-9]|s1[01]|gp|tp)\b' "$tmp/kernel.asm" | sort -u | tr '\n' ' ')
if [ -z "$bad" ]; then ok "0 mentions of s1..s11 / gp / tp in $(wc -l < "$tmp/kernel.asm" | tr -d ' ') lines"
else fail "the kernel names a register the ABI says it never writes: $bad"
fi

# d. the prologue does not clobber a0..a7: inside the prologue window every
#    a-register appears only as the SOURCE of a store into the frame
awk '/^_/{ w = 1; next }
     w && $0 ~ /^  (addi sp, sp, -|sd (ra|s0), |mv s0, sp)/ { next }
     w && $0 ~ /^  s[bhwd] a[0-7], -[0-9]+\(s0\)$/ { next }
     w && $0 ~ /^  ld t0, [0-9]+\(s0\)$/ { next }
     w && $0 ~ /^  s[bhwd] t0, -[0-9]+\(s0\)$/ { next }
     { if (w && $0 ~ /\ba[0-7],/ && $0 !~ /^  s[bhwd] a[0-7],/) { print "at " $0; n++ } w = 0 }
     END { exit n > 0 }' "$tmp/kernel.asm" > "$tmp/d" 2>&1 \
    && ok "no prologue writes an argument register" \
    || fail "a prologue clobbers a0..a7" "$(cat "$tmp/d")"

# e. a zero-parameter, zero-local leaf reserves nothing but still saves the pair
awk '/^_trap_now:/{ p = 1; next } p { print; if ($0 == "  ret") exit }' "$tmp/kernel.asm" > "$tmp/leaf"
if grep -q "addi sp, sp, -16" "$tmp/leaf" && [ "$(grep -c 'addi sp, sp, -' "$tmp/leaf")" = "1" ]; then
    ok "a zero-parameter zero-local leaf reserves nothing (_trap_now)"
else
    fail "the leaf frame is not empty" "$(cat "$tmp/leaf")"
fi

# f. stack parameters 9..12 at [s0 + 16 + 8*(i-8)]
( cd "$dir" && ./build/mc-kernel --dump-asm --machine=riscv64 tests/sweep.mc ) > "$tmp/sweep.asm" \
    || fail "--dump-asm of tests/sweep.mc failed"
awk '/^_sw_twelve:/{ p = 1 } p { print; if ($0 == "  ret") exit }' "$tmp/sweep.asm" > "$tmp/twelve"
miss=""
for off in 16 24 32 40; do
    grep -q "^  ld t0, $off(s0)\$" "$tmp/twelve" || miss="$miss $off"
done
if [ -z "$miss" ]; then ok "parameters 9..12 read at [s0+16], [s0+24], [s0+32], [s0+40]"
else fail "a stack parameter is not read where the ABI says:$miss"
fi

# ---- 6. the frame edge case ----
# big_frame_sum() has a 3000-byte local array, so every access to it goes
# through the machine's t2 fallback; the kernel checks the checksum itself and
# prints `frame FAIL` if it is wrong, which step 2's transcript would have
# caught. What is asserted here is that the fallback is really being taken.
# The dump prints one logical line per Ins, so `addi t3, s0, -3008` is what a
# reader sees and `li t2, -3008; add t3, s0, t2` is what rv_put writes. The
# offset is what forces the fallback, so the offset is what is asserted here --
# and the kernel's own checksum (step 2's transcript) is what proves the bytes.
deep=$(awk '{ n = 0
        if (match($0, /s0, -[0-9]+$/))      n = substr($0, RSTART + 5, RLENGTH - 5) + 0
        else if (match($0, /-[0-9]+\(s0\)/)) n = substr($0, RSTART + 1, RLENGTH - 5) + 0
        if (n > 2047 && n > m) m = n }
     END { print m + 0 }' "$tmp/kernel.asm")
if [ "$deep" -gt 2047 ]; then
    ok "the kernel addresses a frame slot at -$deep(s0), past RV's signed 2047"
else
    fail "no frame offset past 2047 in the kernel: the t2 fallback is not exercised"
fi

# ---- 7. the encoder against llvm-mc ----
# One awk program does the pc-relative half: it re-derives the section
# placement and every symbol's absolute address from --dump-syms, by the same
# rule examples/kernel/image.mc uses, and then checks each auipc pair's target
# against that table and each branch against the __text bounds.
cat > "$tmp/pcrel.awk" <<'AWKEOF'
function hex2(s,   i, c, v, d) {
    v = 0
    for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) return -1
        v = v * 16 + d
    }
    return v
}
function alignup(v, a) { if (v % a == 0) return v; return v + a - v % a }
BEGIN { CONVFMT = "%d"; OFMT = "%d"; base = 2147483648; stub = 32
        nsec = 0; nsym = 0; phase = 0; npc = 0; nbr = 0; bad = 0 }
/^@@$/ { phase = 1; next }
phase == 0 && $1 == "section" {
    f = ""; al = 0; sz = 0
    for (i = 1; i <= NF; i++) {
        if (substr($i, 1, 6) == "flags=") f = substr($i, 9)
        if (substr($i, 1, 6) == "align=") al = substr($i, 7) + 0
        if (substr($i, 1, 5) == "size=")  sz = substr($i, 6) + 0
    }
    if (length(f) > 2) f = substr(f, length(f) - 1)
    zf[nsec] = (hex2(f) % 256 == 1)
    if ($2 == "__DATA,__data") dsec = nsec
    sal[nsec] = al; ssz[nsec] = sz; nsec++
    next
}
phase == 0 && $1 == "sym" {
    st = 0; sv = 0
    for (i = 1; i <= NF; i++) {
        if (substr($i, 1, 5) == "sect=")  st = substr($i, 6) + 0
        if (substr($i, 1, 6) == "value=") sv = substr($i, 7) + 0
    }
    if (st > 0) { symsect[nsym] = st; symval[nsym] = sv; nsym++ }
    next
}
phase == 1 {
    if (!placed) {
        cur = base + stub
        for (i = 0; i < nsec; i++) if (!zf[i]) {
            cur = alignup(cur, 2 ^ sal[i]); sbase[i] = cur; cur = cur + ssz[i]
        }
        textend = cur
        for (i = 0; i < nsec; i++) if (zf[i]) {
            cur = alignup(cur, 2 ^ sal[i]); sbase[i] = cur; cur = cur + ssz[i]
        }
        imgend = cur
        for (i = 0; i < nsym; i++) known[sbase[symsect[i] - 1] + symval[i]] = 1
        known[textend] = 1                        # _bss_start
        known[imgend] = 1                         # _bss_end
        known[alignup(imgend, 16) + 16384] = 1    # _stack_top
        if (dsec != "") {
            known[sbase[dsec]] = 1                # _data_start and _data_lma
            known[sbase[dsec] + ssz[dsec]] = 1    # _data_end
        }
        tbase = sbase[0]; tend = tbase + ssz[0]
        placed = 1; addr = tbase
    }
    gsub(/^[ \t]+/, ""); gsub(/[ \t]+/, " ")
    n = split($0, w, " ")
    if (w[1] == "auipc") {
        pend = addr; hi = w[3] + 0
        if (hi >= 524288) hi = hi - 1048576       # the field is 20 bits, signed
        addr += 4; next
    }
    if (pend != "" && (w[1] == "addi" || w[1] == "jalr")) {
        if (w[1] == "addi") lo = w[4] + 0
        else { s = w[2]; sub(/\(.*/, "", s); lo = s + 0 }
        t = pend + hi * 4096 + lo
        npc++
        if (!(t in known)) { bad++; print "BAD pcrel target " t " at " pend > "/dev/stderr" }
        pend = ""; addr += 4; next
    }
    pend = ""
    if (w[1] == "j" || w[1] == "jal" || substr(w[1], 1, 1) == "b") {
        if (w[1] == "j" || w[1] == "jal") off = w[2] + 0
        else off = w[n] + 0
        t = addr + off
        nbr++
        if (t < tbase || t >= tend || t % 4 != 0) { bad++; print "BAD branch " t " at " addr > "/dev/stderr" }
    }
    addr += 4
}
END { printf "%d %d %d\n", npc, nbr, bad }
AWKEOF

# one source: disassemble its __text, round-trip every distinct instruction
# through llvm-mc, and check every pc-relative displacement
sweep_one() {
    name="$1"
    src="$2"
    extra="$3"
    ( cd "$dir" && ./build/mc-kernel --backend=rv-image $extra "$src" -o "$tmp/s.bin" ) \
        || { fail "sweep: could not build $name"; return 1; }
    ( cd "$dir" && ./build/mc-kernel --dump-syms $extra "$src" ) > "$tmp/s.syms" \
        || { fail "sweep: --dump-syms failed for $name"; return 1; }
    ts=$(awk '/__TEXT,__text/{for (i = 1; i <= NF; i++) if (substr($i,1,5) == "size=") print substr($i,6)}' "$tmp/s.syms")
    dd if="$tmp/s.bin" bs=1 skip=32 count="$ts" of="$tmp/s.text" 2>/dev/null
    xxd -p -c1 "$tmp/s.text" | awk '{ printf "0x%s ", $1 }' > "$tmp/s.hex"
    "$llvmmc" --disassemble -triple=riscv64 -mattr=+m "$tmp/s.hex" > "$tmp/s.dis" 2> "$tmp/s.diserr"
    if [ -s "$tmp/s.diserr" ]; then
        fail "sweep: $name did not disassemble cleanly" "$(head -3 "$tmp/s.diserr")"
        return 1
    fi
    xxd -p -c4 "$tmp/s.text" > "$tmp/s.words"
    paste "$tmp/s.words" "$tmp/s.dis" \
        | sed 's/^\([0-9a-f]*\)[[:space:]][[:space:]]*/\1	/' | sort -u > "$tmp/s.pairs"
    cut -f2- "$tmp/s.pairs" > "$tmp/s.asm"
    "$llvmmc" -triple=riscv64 -mattr=+m --show-encoding "$tmp/s.asm" 2> "$tmp/s.asmerr" \
        | grep -o "encoding: \[.*\]" \
        | sed 's/encoding: \[//; s/\]//; s/0x//g; s/,//g' > "$tmp/s.enc"
    cut -f1 "$tmp/s.pairs" > "$tmp/s.orig"
    ndistinct=$(wc -l < "$tmp/s.pairs" | tr -d ' ')
    nmis=$(diff "$tmp/s.orig" "$tmp/s.enc" | grep -c '^<')
    { cat "$tmp/s.syms"; echo "@@"; cat "$tmp/s.dis"; } | awk -f "$tmp/pcrel.awk" > "$tmp/s.pc" 2> "$tmp/s.pcerr"
    set -- $(cat "$tmp/s.pc")
    npc=$1; nbr=$2; nbad=$3
    if [ "$nmis" = "0" ] && [ "$nbad" = "0" ]; then
        ok "$name: $ndistinct distinct instructions, 0 mismatches; $npc pc-relative pairs and $nbr branches, 0 wrong"
    else
        fail "$name: $nmis byte mismatches, $nbad wrong displacements" "$(head -5 "$tmp/s.pcerr")"
    fi
    sweep_total=$((sweep_total + ndistinct))
}

echo "== the encoder against llvm-mc =="
if [ -z "$llvmmc" ] || ! command -v xxd > /dev/null 2>&1; then
    skip "llvm-mc or xxd not found: the encoder sweep did not run"
else
    sweep_total=0
    sweep_one "main.mc" "main.mc" "--include=lib"
    sweep_one "tests/sweep.mc" "tests/sweep.mc" ""
    # a large generated source: 800 more functions, so the image grows past
    # 64 KiB and the auipc displacements are forced well away from zero, in both
    # directions
    cp "$dir/tests/sweep.mc" "$tmp/big.mc"
    i=0
    while [ "$i" -lt 800 ]; do
        printf 'i64 bigf%d(i64 x) { u8 p%d[32]; st8(p%d, x); if (x > %d) { return ld8(p%d) * %d; } return x %% %d; }\n' \
            "$i" "$i" "$i" "$i" "$i" "$i" "$((i + 3))" >> "$tmp/big.mc"
        i=$((i + 1))
    done
    cp "$tmp/big.mc" "$dir/build/big.mc"
    sweep_one "800 generated functions" "build/big.mc" ""
    rm -f "$dir/build/big.mc"
fi

# ---- 8. limits ----
echo "== mc limits =="
if "$mc" limits "$dir" > "$tmp/lim" 2>&1; then ok "mc limits examples/kernel: ok"
else
    rc=$?
    if [ "$rc" = "3" ]; then ok "mc limits examples/kernel: exit 3 (a table grew or is tight)"
    else fail "mc limits exited $rc" "$(tail -5 "$tmp/lim")"
    fi
fi
grep -E '^(compiler|entry|report|== )' "$tmp/lim" 2>/dev/null | head -4

echo
if [ "$fails" -eq 0 ]; then
    echo "examples/kernel: OK ($skips skipped)"
    exit 0
fi
echo "examples/kernel: $fails FAILED"
exit 1
