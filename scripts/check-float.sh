#!/bin/sh
# check-float.sh [MC] — M24 step 1: the `<float>` library, on every leg this
# host can reach.
#
# `<float>` is not in the compiler. It is lib/float.mc plus two derived machines
# (lib/machine_arm64_float.mc, lib/machine_x86_64_float.mc), wired together by
# lib/user_float.mc, and the compiler that carries it is built here from
# lib/mc_float.mc with `MC --exe`. `git diff src/` for the whole of step 1 is
# empty, and this script is what says so out loud.
#
# For each tests/float/*.mc, the same headers scripts/test.sh uses:
#
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
#   // skip-windows: REASON  (this test needs something Windows does not have)
#   // skip-<arch>: REASON   (this instruction set only)
#
# The legs, each self-skipping with a reason rather than failing:
#
#   macos/aarch64     always, with --exe: the host
#   linux/aarch64     ld.lld + the musl sysroot + Docker (native on Apple silicon)
#   linux/x86_64      the same, emulated
#   windows/aarch64   objects + lld-link only; the windows-11-arm CI leg RUNS them
#   windows/x86_64    the same, windows-2025
#
# ...and the llvm-mc sweep: every DISTINCT float instruction the two machines
# emit over the whole corpus is fed back through the assembler and required to
# come out byte for byte. It is the only credible check on a hand-written
# encoder, and on an MTASK_INS_SIZE / MTASK_ENCODE disagreement.
#
# MC_SYSROOT is honoured the way test-linux.sh honours it.
# --build-only writes the float half of an EXISTING cross-compile artifact -- the
# same OUTDIR scripts/test-linux.sh and scripts/test-windows.sh fill, in the same
# shape (`<name>.o`/`.obj`, `<name>.expect`, one manifest line) -- so the
# `--run-only` half of those scripts links and runs the float tests on the CI
# legs with no change at all. It must run AFTER them: they truncate the manifest.
#
#   check-float.sh --build-only OUTDIR --os linux   --arch aarch64|x86_64 [MC]
#   check-float.sh --build-only OUTDIR --os windows --arch aarch64|x86_64 [MC]
mode="full"
split=""
bos=""
barch=""
while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) mode="build"; split="$2"; shift 2 ;;
        --os)         bos="$2"; shift 2 ;;
        --arch)       barch="$2"; shift 2 ;;
        *)            break ;;
    esac
done

mc="${1:-build/mc1}"
root=$(pwd)
llvm="/opt/homebrew/opt/llvm/bin"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

fails=0
tmp="${TMPDIR:-/tmp}/check-float.$$"
mkdir -p "$tmp" build/float
cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM

have() { command -v "$1" > /dev/null 2>&1 || [ -x "$llvm/$1" ]; }
tool() { if command -v "$1" > /dev/null 2>&1; then echo "$1"; else echo "$llvm/$1"; fi; }

# ---------------------------------------------------------------- the compiler
demo="build/mc-float"
rm -f "$demo"
if ! msg=$("$mc" --exe lib/mc_float.mc -o "$demo" 2>&1); then
    echo "FAIL: compiling lib/mc_float.mc: $msg"
    exit 1
fi
echo "ok   built $demo (the taught compiler: <float> + two derived machines)"

want_exit0() { sed -n 's|^// expect-exit: *||p' "$1" | head -1; }
want_out0()  { sed -n 's|^// expect-stdout: *||p' "$1" | head -1; }
skip_for0()  { sed -n "s|^// skip-$2: *||p" "$1" | head -1; }

if [ "$mode" = "build" ]; then
    [ -n "$split" ] && [ -n "$bos" ] && [ -n "$barch" ] || {
        echo "FAIL: --build-only needs OUTDIR, --os and --arch"; exit 1; }
    [ -f "$split/manifest" ] || {
        echo "FAIL: '$split/manifest' not found (run the suite's --build-only first)"; exit 1; }
    lmode="libc"
    ext="o"
    if [ "$bos" = "windows" ]; then lmode="kernel32"; ext="obj"; fi
    tmpb="$tmp/build"
    mkdir -p "$tmpb"
    n=0
    for f in tests/float/*.mc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .mc)
        why=$(skip_for0 "$f" "$bos")
        if [ -z "$why" ]; then why=$(skip_for0 "$f" "$barch"); fi
        if [ -n "$why" ]; then
            echo "skip $name ($why)"
            echo "$name — $why" >> "$split/skipped"
            continue
        fi
        {
            echo '[project]'
            echo "entry = \"$root/$f\""
            echo "out   = \"$root/$split/$name.$ext\""
            echo 'kind  = "obj"'
            echo
            echo '[target]'
            echo "os   = \"$bos\""
            echo "arch = \"$barch\""
        } > "$tmpb/mc.toml"
        if ! msg=$("$demo" build "$tmpb" --config "$tmpb/mc.toml" 2>&1); then
            echo "FAIL $name (build: $msg)"; fails=$((fails + 1)); continue
        fi
        echo "exit: $(want_exit0 "$f")" > "$split/$name.expect"
        if grep -q '^// expect-stdout:' "$f"; then
            echo "stdout: $(want_out0 "$f")" >> "$split/$name.expect"
        fi
        echo "$name $lmode" >> "$split/manifest"
        echo "built $name"
        n=$((n + 1))
    done
    if [ "$fails" != 0 ]; then echo "check-float --build-only: $fails failures"; exit 1; fi
    echo "check-float --build-only: $n float objects for $bos/$barch in $split"
    exit 0
fi

# the default compiler has to REFUSE the same source: floats belong to the
# module, and lib/user_default.mc does not load it
if msg=$("$mc" tests/float/010-arith.mc -o "$tmp/no.o" 2>&1); then
    echo "FAIL: the default compiler accepted a float program"
    fails=$((fails + 1))
else
    echo "ok   the default compiler rejects tests/float/010-arith.mc ($msg)"
fi

want_exit() { sed -n 's|^// expect-exit: *||p' "$1" | head -1; }
want_out()  { sed -n 's|^// expect-stdout: *||p' "$1" | head -1; }
skip_for()  { sed -n "s|^// skip-$2: *||p" "$1" | head -1; }

# ------------------------------------------------------------ macos/aarch64
pass=0
total=0
for f in tests/float/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    total=$((total + 1))
    # rm -f first: overwriting a SIGNED executable at the same inode makes the
    # kernel kill the next run with SIGKILL (CLAUDE.md, the M12 operational note)
    rm -f "build/float/$name"
    if ! msg=$("$demo" --exe "$f" -o "build/float/$name" 2>&1); then
        echo "FAIL $name (compilation: $msg)"; fails=$((fails + 1)); continue
    fi
    got=$("build/float/$name" 2>/dev/null)
    rc=$?
    if [ "$rc" != "$(want_exit "$f")" ]; then
        echo "FAIL $name (exit $rc, expected $(want_exit "$f"))"; fails=$((fails + 1)); continue
    fi
    if [ "$got" != "$(want_out "$f")" ]; then
        echo "FAIL $name"
        echo "     got      $got"
        echo "     expected $(want_out "$f")"
        fails=$((fails + 1)); continue
    fi
    pass=$((pass + 1))
done
echo "ok   macos/aarch64: $pass/$total"

# ------------------------------------------------------------- the linux legs
gen_linux_toml() {                      # entry, out, sysroot
    {
        echo '[project]'
        echo "entry = \"$1\""
        echo "out   = \"$2\""
        echo
        echo '[target]'
        echo 'os   = "linux"'
        echo "arch = \"$4\""
        echo
        echo '[sysroot]'
        echo "path = \"$3\""
        echo
        echo '[linker]'
        echo 'cmd  = "ld.lld"'
        echo 'args = ["-o", "{out}", "{sysroot}/crt1.o", "{sysroot}/crti.o", "{obj}", "{sysroot}/libc.a", "{sysroot}/crtn.o", "-static"]'
    } > "$tmp/mc.toml"
}

linux_leg() {                           # arch, docker platform
    arch="$1"; platform="$2"
    sysroot="${MC_SYSROOT:-$root/build/sysroot/linux-$arch}"
    if ! have ld.lld; then
        echo "skip linux/$arch: ld.lld not in PATH (brew install lld)"; return 0
    fi
    if ! docker info > /dev/null 2>&1; then
        echo "skip linux/$arch: docker is not running"; return 0
    fi
    if [ ! -f "$sysroot/libc.a" ]; then
        if ! msg=$(sh scripts/sysroot-linux.sh --arch "$arch" 2>&1); then
            echo "skip linux/$arch: no musl sysroot ($msg)"; return 0
        fi
    fi
    mkdir -p "build/float-$arch"
    lp=0; lt=0; ls=0
    list=""
    for f in tests/float/*.mc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .mc)
        why=$(skip_for "$f" "$arch")
        if [ -n "$why" ]; then echo "skip linux/$arch $name ($why)"; ls=$((ls + 1)); continue; fi
        lt=$((lt + 1))
        gen_linux_toml "$root/$f" "$root/build/float-$arch/$name" "$sysroot" "$arch"
        if ! msg=$("$demo" build "$tmp" --config "$tmp/mc.toml" 2>&1); then
            echo "FAIL linux/$arch $name (build: $msg)"; fails=$((fails + 1)); continue
        fi
        list="$list $name"
    done
    # one container for the whole leg: starting one per test is most of the time
    { echo '# one crash must not hide the rest of the leg'
      for name in $list; do echo "echo \"### $name\"; ./build/float-$arch/$name; echo \"rc=\$?\""; done
    } > "$tmp/run.sh"
    docker run --rm --platform "$platform" -v "$root":/w -w /w alpine:3 \
        /bin/sh /w/"${tmp#$root/}"/run.sh > "$tmp/out-$arch" 2>&1 || true
    for name in $list; do
        f="tests/float/$name.mc"
        got=$(sed -n "/^### $name\$/,/^rc=/p" "$tmp/out-$arch" | sed '1d;$d')
        rc=$(sed -n "/^### $name\$/,/^rc=/p" "$tmp/out-$arch" | sed -n 's|^rc=||p')
        if [ "$rc" != "$(want_exit "$f")" ] || [ "$got" != "$(want_out "$f")" ]; then
            echo "FAIL linux/$arch $name (exit $rc '$got', expected $(want_exit "$f") '$(want_out "$f")')"
            fails=$((fails + 1)); continue
        fi
        lp=$((lp + 1))
    done
    if [ "$ls" != 0 ]; then echo "ok   linux/$arch: $lp/$lt ($ls skipped)"
    else                    echo "ok   linux/$arch: $lp/$lt"; fi
}

# the temporary directory has to be reachable from inside the container, so it
# lives under the repository root for the duration of the linux legs
if docker info > /dev/null 2>&1 && have ld.lld; then
    tmp2="$root/build/float-tmp"
    rm -rf "$tmp2"; mkdir -p "$tmp2"
    old="$tmp"; tmp="$tmp2"
    linux_leg aarch64 linux/arm64
    linux_leg x86_64  linux/amd64
    tmp="$old"
else
    echo "skip linux/aarch64 and linux/x86_64: need docker and ld.lld"
fi

# ------------------------------------------------------------ the windows legs
# Objects and a link, no execution: there is no Windows host here, and the two
# CI legs are the runtime oracle (docs/ci.md). The same shape scripts/
# test-windows.sh uses -- kernel32.lib, winstart.obj and winrt.obj beside the
# test's own object.
windows_leg() {                         # arch, lld machine
    arch="$1"; lmachine="$2"
    if ! have lld-link || ! have llvm-dlltool; then
        echo "skip windows/$arch: lld-link or llvm-dlltool not found (brew install lld llvm)"
        return 0
    fi
    sysroot="build/sysroot/windows-$arch"
    if [ ! -f "$sysroot/kernel32.lib" ]; then
        if ! msg=$(sh scripts/sysroot-windows.sh --arch "$arch" "$sysroot" 2>&1); then
            echo "skip windows/$arch: no kernel32.lib ($msg)"; return 0
        fi
    fi
    out="build/float-windows-$arch"
    mkdir -p "$out"
    backend="coff-obj-arm64"
    if [ "$arch" = "x86_64" ]; then backend="coff-obj-x86_64"; fi
    # the two support objects have no floats and are built by the STOCK
    # compiler: they are the same objects scripts/test-windows.sh links
    for m in sys_windows sys_windows_start; do
        if ! msg=$("$mc" --backend=$backend "lib/$m.mc" -o "$out/$m.obj" 2>&1); then
            echo "FAIL windows/$arch (lib/$m.mc: $msg)"; fails=$((fails + 1)); return 0
        fi
    done
    wp=0; wt=0; ws=0
    for f in tests/float/*.mc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .mc)
        why=$(skip_for "$f" windows)
        if [ -z "$why" ]; then why=$(skip_for "$f" "$arch"); fi
        if [ -n "$why" ]; then echo "skip windows/$arch $name ($why)"; ws=$((ws + 1)); continue; fi
        wt=$((wt + 1))
        if ! msg=$("$demo" --backend=$backend "$f" -o "$out/$name.obj" 2>&1); then
            echo "FAIL windows/$arch $name (compile: $msg)"; fails=$((fails + 1)); continue
        fi
        if ! msg=$($(tool lld-link) -machine:$lmachine -subsystem:console -entry:mc_start \
                   -nodefaultlib -out:"$out/$name.exe" "$out/$name.obj" "$out/sys_windows.obj" \
                   "$out/sys_windows_start.obj" "$sysroot/kernel32.lib" 2>&1); then
            echo "FAIL windows/$arch $name (link: $msg)"; fails=$((fails + 1)); continue
        fi
        wp=$((wp + 1))
    done
    if [ "$ws" != 0 ]; then echo "ok   windows/$arch: $wp/$wt objects linked ($ws skipped, not executed here)"
    else                    echo "ok   windows/$arch: $wp/$wt objects linked (not executed here)"; fi
}

windows_leg aarch64 arm64
windows_leg x86_64  x64

# --------------------------------------------------------------- the llvm-mc sweep
# Every DISTINCT float instruction the two machines emitted over the whole
# corpus, fed back through the assembler. A hand-written encoder and a
# hand-written MTASK_INS_SIZE are the two things nothing else here can catch.
FLOAT_RE='(fadd|fsub|fmul|fdiv|fmin|fmax|fneg|fabs|fsqrt|fcmp|fcvt|scvtf|ucvtf|fmov|addsd|subsd|mulsd|divsd|minsd|maxsd|sqrtsd|addss|subss|mulss|divss|minss|maxss|sqrtss|movsd|movss|ucomisd|ucomiss|xorpd|xorps|andpd|andps|cvtsi2sd|cvtsi2ss|cvttsd2si|cvttss2si|cvtss2sd|cvtsd2ss|movq)'

sweep() {                               # label, triple, objects...
    label="$1"; triple="$2"; shift 2
    if ! have llvm-objdump || ! have llvm-mc; then
        echo "skip sweep $label: llvm-objdump/llvm-mc not found"; return 0
    fi
    : > "$tmp/ins"
    for o in "$@"; do
        [ -f "$o" ] || continue
        $(tool llvm-objdump) -d --triple="$triple" "$o" 2>/dev/null \
            | sed -n 's|^ *[0-9a-f]*: *\([0-9a-f ]*[0-9a-f]\)  *\(.*\)$|\1\t\2|p' \
            | grep -Ei "	$FLOAT_RE" >> "$tmp/ins"
    done
    sort -u "$tmp/ins" -o "$tmp/ins"
    n=0; bad=0
    while IFS='	' read -r bytes text; do
        [ -n "$text" ] || continue
        case "$text" in *"#"*) text=$(echo "$text" | sed 's|#.*||') ;; esac
        text=$(echo "$text" | sed 's|[[:space:]]*$||')
        enc=$(printf '%s\n' "$text" | $(tool llvm-mc) -triple="$triple" --show-encoding 2>/dev/null \
              | sed -n 's|.*encoding: \[\(.*\)\].*|\1|p' | tr -d ' ' | tr ',' '\n' \
              | sed 's|^0x||' | tr '\n' ' ' | sed 's| *$||')
        # llvm-objdump prints an AArch64 instruction as ONE big-endian word and
        # an x86 one as spaced little-endian bytes; llvm-mc always answers in
        # little-endian bytes, so a bare 8-hex-digit word is split here
        want=$(echo "$bytes" | tr -s ' ')
        case "$want" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
                want="$(echo "$want" | cut -c7-8) $(echo "$want" | cut -c5-6) $(echo "$want" | cut -c3-4) $(echo "$want" | cut -c1-2)" ;;
        esac
        if [ -z "$enc" ]; then
            echo "FAIL sweep $label: llvm-mc could not assemble '$text'"; bad=$((bad + 1)); continue
        fi
        if [ "$enc" != "$want" ]; then
            echo "FAIL sweep $label: '$text' -> $enc, mc emitted $want"; bad=$((bad + 1)); continue
        fi
        n=$((n + 1))
    done < "$tmp/ins"
    if [ "$bad" != 0 ]; then fails=$((fails + bad)); return 0; fi
    echo "ok   sweep $label: $n distinct instructions re-assemble byte for byte"
}

macho_objs=""
for f in tests/float/*.mc; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .mc)
    "$demo" "$f" -o "build/float/$name.o" > /dev/null 2>&1 && macho_objs="$macho_objs build/float/$name.o"
done
sweep "arm64 (mach-o)" aarch64-apple-macos $macho_objs
sweep "aarch64 (elf)"  aarch64-linux-musl  build/float-aarch64/*.o
sweep "x86_64 (elf)"   x86_64-linux-musl   build/float-x86_64/*.o
sweep "x86_64 (coff)"  x86_64-windows-msvc build/float-windows-x86_64/*.obj

if [ "$fails" != 0 ]; then
    echo "check-float: $fails failures"
    exit 1
fi
echo "check-float: ok"
