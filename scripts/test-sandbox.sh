#!/bin/sh
# test-sandbox.sh [MC] — the suite and the isolation cases through `mc sandbox`
# (M43 step B, docs/specs/M43.md § 8, docs/reference/sandbox.md).
#
#   scripts/test-sandbox.sh [MC]        on a Linux host: run everything
#   scripts/test-sandbox.sh --delegate  from macOS: run it on a Linux host
#
# It contains no mechanism: the box is `mc sandbox`, written in mc. What is here
# is the corpus, the expectations and -- from macOS, where there is no sandbox
# at all -- the delegation to a Linux kernel (the Lima VM of docs/build.md
# § Lima, else `docker run --privileged`).
#
# Seven parts, in the order of the milestone's acceptance list:
#
#   1  mc sandbox check          the guard: without it the rest is skipped
#   2  tests/sandbox/*.mc        the isolation cases, each with its own headers
#   2b tests/sandbox/linkbomb/  a hostile project: mc.toml names a fork bomb as
#                               its [linker].cmd, so the bomb runs in the
#                               COMPILE step
#   3  tests/*.mc                the whole suite, compiled AND run inside the box
#   4  mc sandbox exec           on binaries built outside it, one of them
#                                dynamic (it reaches libc through the bind of
#                                /lib and nothing else of the host)
#   5  examples/lang             a project: the box teaches the compiler and
#                                runs what it compiled
#   6  determinism               two reports byte for byte, and no host file
#                                touched by any of it
#   7  overhead                  the median cost of a box, printed
#
# Each test file in tests/sandbox/ carries its own expectations in its header:
#
#   // sandbox-exit: N       the exit code of `mc sandbox`
#   // sandbox-stdout: TEXT  the program's stdout, exactly (the header may be
#                            present and empty, which asserts that there is none)
#   // sandbox-report: LINE  a report line that must be there, exactly
#   // sandbox-report-<arch>: LINE   the same, when the two architectures
#                            disagree -- a refusal names a system call NUMBER,
#                            and `socket` is 198 on AArch64 and 41 on x86-64
#                            (a refused fork does NOT need one any more: since
#                            the post-M43 review it is counted, not named)
#   // sandbox-opts: OPTS    extra options for this case
#   // sandbox-alt-*:        a SECOND run of the same source with other options,
#                            for the case that has two answers: a fork bomb is
#                            refused at its first clone by default and at the
#                            sixty-fifth with --allow=threads
#
# tests/*.mc keep the headers scripts/test.sh reads (`// expect-exit:`,
# `// expect-stdout:`) and the skip headers scripts/test-linux.sh reads.

fail=0
pass=0
skip=0

say_ok()   { echo "ok   $*"; pass=$((pass + 1)); }
say_fail() { echo "FAIL $*"; fail=$((fail + 1)); }
say_skip() { echo "skip $*"; skip=$((skip + 1)); }

# ---- 0. the host -----------------------------------------------------------
# On macOS `mc sandbox` refuses by design (§ 7), so the script cross-builds the
# Linux compiler and hands the whole run to a Linux kernel. Lima first (the
# repository is mounted there at the same path, and the VM's kernel is the 7.x
# one docs/build.md pins); then Docker, which needs --privileged because its
# default seccomp profile puts `unshare`, `mount` and `pivot_root` behind
# CAP_SYS_ADMIN.
delegate() {
    root=$(pwd)
    if [ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]; then
        larch=aarch64; lname=arm64
    else
        larch=x86_64;  lname=x86_64
    fi
    if command -v limactl > /dev/null 2>&1 && limactl list 2>/dev/null | grep -q "^mc-k7 *Running"; then
        # Lima runs Ubuntu: glibc, so the -gnu compiler is the one that runs there
        make "mc-linux-gnu" > /dev/null || exit 1
        echo "test-sandbox: delegating to Lima (mc-k7), glibc/$larch"
        limactl shell mc-k7 -- sudo sh -c "cd $root && sh scripts/test-sandbox.sh build/mc-linux-$lname-gnu"
        exit $?
    fi
    if docker info > /dev/null 2>&1; then
        make "mc-linux" > /dev/null || exit 1
        echo "test-sandbox: delegating to docker --privileged (alpine:3, musl/$larch)"
        docker run --rm --privileged --platform "linux/$lname" -v "$root:/w" -w /w alpine:3 \
            sh scripts/test-sandbox.sh "build/mc-linux-$lname"
        exit $?
    fi
    echo "test-sandbox: SKIPPED (no Lima instance mc-k7 and no docker; the sandbox is a Linux feature)"
    exit 0
}

case "$(uname -s)" in
    Linux) ;;
    *) delegate ;;
esac

case "$(uname -m)" in
    aarch64|arm64) arch=aarch64; aname=arm64 ;;
    x86_64|amd64)  arch=x86_64;  aname=x86_64 ;;
    *) echo "FAIL: unsupported machine $(uname -m)"; exit 1 ;;
esac

# the compiler that runs the box: it has to be a binary THIS host can execute,
# so the family is the one whose loader is on this disk -- the question
# scripts/test-exe.sh asks, and the one `mc sandbox` itself asks before it
# compiles anything inside the box.
mc="$1"
if [ -z "$mc" ]; then
    if [ -e "/lib/ld-musl-$arch.so.1" ]; then mc="build/mc-linux-$aname"; else mc="build/mc-linux-$aname-gnu"; fi
fi
if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi
if [ -e "/lib/ld-musl-$arch.so.1" ]; then libc=musl; else libc=gnu; fi
# The flag every `--exe` build in this script needs, and it is set HERE rather
# than beside the first use: part 2b builds a program too, and building it for
# the wrong C library gives a binary this host cannot execute -- measured, the
# box then stops at `refused: syscall 95 (waitid)`, which is glibc's posix_spawn
# reaping a child that never exec'd, and the case under test never happens.
lf=
[ "$libc" = gnu ] && lf=--libc=gnu

out=build/sandbox
rm -rf "$out"; mkdir -p "$out"

echo "== mc sandbox: $mc on linux/$arch ($libc), $(uname -r)"

# ---- 1. the guard ----------------------------------------------------------
if ! "$mc" sandbox check > "$out/check.txt" 2>&1; then
    echo "test-sandbox: SKIPPED (mc sandbox check:"
    sed 's/^/    /' "$out/check.txt"
    echo ")"
    exit 0
fi
sed 's/^/    /' "$out/check.txt"

# a marker every part of this script compares against: nothing under the
# repository may be newer than it when the run is over (acceptance 6)
touch "$out/marker"

hdr() { sed -n "s|^// $1: ||p" "$2" | head -1; }
# is the header there at all? An expectation of "no output" is a header with
# nothing after the colon, and it has to be told apart from no header.
has_hdr() { grep -q "^// $1:" "$2"; }

# one case: MC sandbox run OPTS FILE, against an exit code, a stdout and a
# report line
run_case() {   # run_case NAME FILE OPTS WANT_EXIT WANT_REPORT CHECK_STDOUT
    cname="$1"; cfile="$2"; copts="$3"; cexit="$4"; crep="$5"; cstdout="$6"
    # shellcheck disable=SC2086
    "$mc" sandbox run $copts --report "$out/$cname.report" "$cfile" \
          > "$out/$cname.out" 2> "$out/$cname.err"
    crc=$?
    cok=1
    [ "$crc" = "$cexit" ] || { cok=0; echo "     exit $crc, want $cexit"; sed 's/^/       /' "$out/$cname.report"; }
    if [ "$cstdout" = 1 ]; then
        cgot=$(cat "$out/$cname.out")
        [ "$cgot" = "$want_out" ] || { cok=0; echo "     stdout [$cgot], want [$want_out]"; }
    fi
    if [ -n "$crep" ]; then
        grep -qx "sandbox: $crep" "$out/$cname.report" || {
            cok=0; echo "     report has no line 'sandbox: $crep':"; sed 's/^/       /' "$out/$cname.report"; }
    fi
    if [ "$cok" = 1 ]; then say_ok "$cname"; else say_fail "$cname"; fi
}

# ---- 2. the isolation cases ------------------------------------------------
echo "-- isolation"
procs_before=$(ls /proc | grep -c '^[0-9]')
mem_before=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)

for f in tests/sandbox/*.mc; do
    name=$(basename "$f" .mc)
    want_exit=$(hdr sandbox-exit "$f")
    want_out=$(hdr sandbox-stdout "$f")
    # the most specific header wins: a refusal names a system call NUMBER, and
    # which number a `fork` is depends on the architecture AND on the C library
    # (musl on x86-64 uses fork(57), glibc uses clone(56), and AArch64 has no
    # fork at all)
    want_rep=$(hdr "sandbox-report-$arch-$libc" "$f")
    [ -n "$want_rep" ] || want_rep=$(hdr "sandbox-report-$arch" "$f")
    [ -n "$want_rep" ] || want_rep=$(hdr sandbox-report "$f")
    opts=$(hdr sandbox-opts "$f")
    # clean.mc is tests/013-putnum.mc VERBATIM (the acceptance list says so), so
    # it carries the suite's own headers and not this milestone's.
    [ -n "$want_exit" ] || want_exit=$(hdr expect-exit "$f")
    check_out=0
    has_hdr sandbox-stdout "$f" && check_out=1
    if [ "$check_out" = 0 ] && has_hdr expect-stdout "$f"; then
        want_out=$(hdr expect-stdout "$f"); check_out=1
    fi
    [ -n "$want_exit" ] || { say_skip "$name (no // sandbox-exit: header)"; continue; }
    run_case "$name" "$f" "$opts" "$want_exit" "$want_rep" "$check_out"

    # the same source with other options, when the header asks for it
    if has_hdr sandbox-alt-exit "$f"; then
        want_out=
        run_case "$name (alt)" "$f" "$(hdr sandbox-alt-opts "$f")" \
                 "$(hdr sandbox-alt-exit "$f")" "$(hdr sandbox-alt-report "$f")" 1
    fi
done

# ---- 2b. a hostile project: the fork bomb in the COMPILE step --------------
# The reproduction of the post-M43 review's first finding (docs/specs/M43.md
# § Implementation notes -- the review). `mc build` runs whatever
# [linker].cmd names, and that name comes out of the source tree's own
# mc.toml -- so an untrusted tree chooses a binary the COMPILE step executes.
# The bomb is compiled here, with the compiler under test, into a copy of the
# project under build/: nothing binary is checked in, and the host tree is
# untouched (the marker above covers it).
echo "-- a hostile project (the compile step's own fork bomb)"
lbdir="$out/linkbomb"
rm -rf "$lbdir"; mkdir -p "$lbdir"
cp tests/sandbox/linkbomb/mc.toml tests/sandbox/linkbomb/app.mc tests/sandbox/linkbomb/bomb.mc "$lbdir/"
# shellcheck disable=SC2086
if ! "$mc" --exe $lf "$lbdir/bomb.mc" -o "$lbdir/bomb" > "$lbdir/bomb.build" 2>&1; then
    say_fail "linkbomb (the bomb could not be built)"; sed 's/^/     /' "$lbdir/bomb.build"
else
    "$mc" sandbox run --report "$out/linkbomb.report" "$lbdir" \
          > "$out/linkbomb.out" 2> "$out/linkbomb.err"
    rc=$?
    ok=1
    [ "$rc" = 125 ] || { ok=0; echo "     exit $rc, want 125"; sed 's/^/       /' "$out/linkbomb.report"; }
    grep -qx "sandbox: refused: process limit (16)" "$out/linkbomb.report" || {
        ok=0; echo "     report has no line 'sandbox: refused: process limit (16)':"
        sed 's/^/       /' "$out/linkbomb.report"; }
    if [ "$ok" = 1 ]; then say_ok "linkbomb (the compile step is bounded and named)"
    else say_fail "linkbomb"; fi
fi

# What the isolation cases must NOT have done to the host (acceptance 2): the
# fork bomb's children were inside the pid namespace and died with it, and the
# eight-gibibyte mapping was never made.
procs_after=$(ls /proc | grep -c '^[0-9]')
mem_after=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
# The property is that nothing the BOX created is still running on the host:
# the fork bomb's two hundred children, the sixty-four of the --allow=threads
# half, the linkbomb's, the sleeper. So count the survivors BY NAME -- every
# isolation program runs under its own basename inside the box, and a survivor
# would carry it here -- and require zero. The global count was the first shape
# of this check (a window of eight) and it was a flake: on a shared CI runner
# unrelated processes come and go by the dozen between the two readings
# (measured on PR #27: 153 -> 166, then 154 -> 177, with nothing of the box's
# among them). It is printed for the record and no longer judged.
survivors=$(cat /proc/[0-9]*/comm 2>/dev/null \
    | grep -c -E '^(forkbomb|sleeper|forever|bomb|nsclone|nsclone3|eightgib|shadow|connect|clean|rocwd|libcuser)$')
if [ "$survivors" = 0 ]; then
    say_ok "no process of the box survives on the host (global count $procs_before -> $procs_after, informational)"
else
    say_fail "$survivors process(es) of the box survive on the host"
    cat /proc/[0-9]*/comm 2>/dev/null | grep -E '^(forkbomb|sleeper|forever|bomb|nsclone|nsclone3|eightgib|shadow|connect|clean|rocwd|libcuser)$' | sort | uniq -c | sed 's/^/     /'
fi
# a 64 MiB window: the machine is doing other things, and 8 GiB is not 64 MiB
mem_lost=$((mem_before - mem_after))
if [ "$mem_lost" -lt 64 ]; then
    say_ok "the host's available memory is unchanged (${mem_before} MiB -> ${mem_after} MiB)"
else
    say_fail "the host lost ${mem_lost} MiB of available memory"
fi

# ---- 3. the suite ----------------------------------------------------------
# Every tests/*.mc, compiled AND run inside the box: the source goes in, the
# executable is written to the overlay, and both halves are the box's.
echo "-- the suite through mc sandbox run"
for f in tests/*.mc; do
    name=$(basename "$f" .mc)
    reason=$(hdr skip-linux "$f")
    [ -z "$reason" ] && reason=$(hdr "skip-$arch" "$f")
    if [ -n "$reason" ]; then say_skip "$name ($reason)"; continue; fi
    want_exit=$(hdr expect-exit "$f")
    want_out=$(sed -n 's|^// expect-stdout: ||p' "$f")
    # --root: /src is the REPOSITORY, not the test's own directory. Half the
    # corpus includes ../lib/sys.mc, and 025-linecount opens its own source by a
    # path relative to the repository root -- both resolve inside the box
    # exactly as they do outside it, and nothing in tests/*.mc had to change
    # (they are frozen for M43: docs/specs/M43.md acceptance 12).
    "$mc" sandbox run --root . "$f" > "$out/$name.out" 2> "$out/$name.err"
    rc=$?
    ok=1
    [ "$rc" = "$want_exit" ] || { ok=0; echo "     exit $rc, want $want_exit"; sed 's/^/       /' "$out/$name.err"; }
    if [ -n "$want_out" ]; then
        got=$(cat "$out/$name.out")
        [ "$got" = "$want_out" ] || { ok=0; echo "     stdout [$got], want [$want_out]"; }
    fi
    if [ "$ok" = 1 ]; then say_ok "$name"; else say_fail "$name"; fi
done

# ---- 4. mc sandbox exec ----------------------------------------------------
# The other half of § 5: a binary that was built OUTSIDE the box and only runs
# inside it. libcuser is the dynamic one -- it allocates, reads a file through
# stdio and hands both back, so it needs its loader and its libc, and the only
# reason it finds them is the read-only bind of /lib, /lib64 and /usr/lib (§ 3).
#
# It replaced tests/linux/071-errno-malloc.mc here when step C landed, and the
# reason is the milestone's own policy rather than an accident: that program
# opens /nonexistent-m42/nope on purpose, to read an errno, and a path under
# none of the box's roots is `refused: open ...`, exit 125 (§ 4). The box does
# not answer ENOENT for a path it will not look at.
echo "-- mc sandbox exec"
for pair in "013-putnum tests/013-putnum.mc 46368" "libcuser tests/sandbox/libcuser.mc libc ok"; do
    set -- $pair
    n=$1; src=$2; shift 2; want="$*"
    # shellcheck disable=SC2086
    if ! "$mc" --exe $lf "$src" -o "$out/$n" > "$out/$n.build" 2>&1; then
        say_fail "exec $n (the build outside the box failed)"; sed 's/^/     /' "$out/$n.build"; continue
    fi
    "$mc" sandbox exec "$out/$n" > "$out/$n.out" 2> "$out/$n.err"
    rc=$?
    got=$(cat "$out/$n.out")
    if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then say_ok "exec $n"
    else say_fail "exec $n (exit $rc, stdout [$got], want [$want])"; fi
done
if readelf -l "$out/libcuser" 2>/dev/null | grep -q INTERP; then
    say_ok "exec libcuser is dynamic (PT_INTERP)"
else
    say_skip "PT_INTERP check (no readelf on this host)"
fi

# ---- 5. a project ----------------------------------------------------------
# `mc build` inside the box: it writes a taught compiler, spawns it, and the
# program that compiler compiles is the run step. /src is the REPOSITORY here,
# because examples/lang includes ../../lib/prelude.mc -- and every byte it
# writes lands in the overlay's upper layer, which dies with the box.
echo "-- a project inside the box"
cfg=examples/lang/mc.linux.toml
[ "$libc" = gnu ] && cfg=examples/lang/mc.linux-gnu.toml
"$mc" sandbox run --time 120 --wall 300 --mem 4096 --out 256 --config "$cfg" . \
      > "$out/lang.out" 2> "$out/lang.err"
rc=$?
want="13
25
12
box"
got=$(cat "$out/lang.out" | grep -v '^compile\|^compiler')
if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then say_ok "examples/lang built and run inside the box"
else say_fail "examples/lang (exit $rc)"; sed 's/^/     /' "$out/lang.err"; echo "$got" | sed 's/^/     /'; fi

# ---- 6. determinism, and nothing written on the host -----------------------
echo "-- determinism"
"$mc" sandbox run --report "$out/det1.txt" tests/sandbox/clean.mc > /dev/null 2>&1
"$mc" sandbox run --report "$out/det2.txt" tests/sandbox/clean.mc > /dev/null 2>&1
if cmp -s "$out/det1.txt" "$out/det2.txt"; then say_ok "two reports byte for byte"
else say_fail "the report is not deterministic"; diff "$out/det1.txt" "$out/det2.txt" | sed 's/^/     /'; fi
if grep -Eq '[0-9]{4,}' "$out/det1.txt"; then
    say_fail "the report carries a long number (a pid or a time?)"; sed 's/^/     /' "$out/det1.txt"
else say_ok "the report carries no pid and no time"; fi

# everything this script wrote is under build/; nothing else in the tree may be
# newer than the marker taken before the first box ran
touched=$(find . -newer "$out/marker" -type f \
          -not -path './build/*' -not -path './.git/*' 2>/dev/null | head -5)
if [ -z "$touched" ]; then say_ok "the host tree is untouched"
else say_fail "files newer than the marker:"; echo "$touched" | sed 's/^/     /'; fi
if [ -n "$(ls -d /tmp/.mc-box* 2>/dev/null)" ]; then
    say_fail "a box directory was left in /tmp: $(ls -d /tmp/.mc-box* | head -3)"
else say_ok "no box directory left in /tmp"; fi

# ---- 7. the overhead -------------------------------------------------------
# What a box costs, which is the number the playground's capacity math needs
# (acceptance 7). It is the same program run 200 times each way, and what is
# reported is the difference of the two totals divided by 200.
echo "-- overhead"
cat > "$out/true.mc" <<'EOF'
i64 main() { return 0; }
EOF
# shellcheck disable=SC2086
"$mc" --exe $lf "$out/true.mc" -o "$out/true" > /dev/null 2>&1
n=200
t0=$(date +%s%N)
i=0; while [ $i -lt $n ]; do "$out/true"; i=$((i + 1)); done
t1=$(date +%s%N)
i=0; while [ $i -lt $n ]; do "$mc" sandbox exec "$out/true" 2> /dev/null; i=$((i + 1)); done
t2=$(date +%s%N)
plain=$(( (t1 - t0) / n / 1000 ))
boxed=$(( (t2 - t1) / n / 1000 ))
if [ "$boxed" = 0 ]; then
    # busybox `date` has no %N: it prints the literal, and the arithmetic
    # collapses to zero. Say so instead of reporting a free sandbox.
    say_skip "overhead (this shell's date has no nanoseconds)"
else
    echo "     plain $plain us, boxed $boxed us, box costs $(( boxed - plain )) us per run"
    say_ok "overhead measured"
fi

echo "== test-sandbox: $pass ok, $fail failed, $skip skipped"
[ "$fail" = 0 ] || exit 1
exit 0
