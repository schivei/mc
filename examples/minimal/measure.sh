#!/bin/sh
# measure.sh — build the smallest program four ways and print what each floor
# costs (M34, docs/guide/80-footprint.md).
#
#   sh examples/minimal/measure.sh            build every reachable variant, print the tables
#   sh examples/minimal/measure.sh --check     assert the ceilings, exit 1 on a violation
#
# The four variants, all of the same `i64 main() { return 0; }`:
#
#   macos-exe      mc --exe          -> a signed Mach-O executable, no ld       (mc.toml)
#   macos-ld       mc -o x.o + ld    -> the same program through the system linker
#   linux-musl     mc + ld.lld       -> ELF, statically linked against musl     (mc.linux.toml)
#   linux-nolibc   mc + ld.lld       -> ELF, -nostdlib -e _start, <sys_linux>   (mc.nolibc.toml)
#
# What it needs: `mc` (build/mc1, or $MC) for everything; `ld.lld` and a running
# Docker for the two Linux rows, which are cross-compiled here and measured
# inside `docker run --platform linux/arm64 alpine:3`. A missing tool skips its
# rows and says so; it is never an error, except under --check where a violated
# ceiling is.
#
# TWO TABLES on purpose. The first one is sizes and memory and is byte-identical
# across runs on the same machine (every number in it is either read out of the
# file or a kernel high-water mark that does not move here — see the note under
# it). The second one is times, which move by a few percent per run and would
# otherwise make the whole report impossible to diff. The header above them
# carries the machine and the date, because the numbers only compare within one.
#
# Measurement notes, all of them load-bearing:
#
#   * max RSS on macOS is `/usr/bin/time -l`, the smallest of 5 runs; peak
#     footprint is the same tool's "peak memory footprint" (what `vmmap` calls
#     "Physical footprint (peak)" and the only one of the two that excludes the
#     pages shared with the rest of the system).
#   * max RSS on Linux is GNU time (`apk add time` inside the container), also
#     the smallest of 5 runs. Read the explanation block before believing it:
#     the kernel keeps the high-water mark across `exec`, so what comes out is
#     max(the measuring process before it forked, the program) and both Linux
#     rows sit on that floor rather than on their own usage.
#   * "own mapped" is what the program itself asks the kernel to map, computed
#     from the file: the sum of the Mach-O segments' vmsize with __PAGEZERO
#     dropped (it is reserved address space, not memory), and on ELF the sum of
#     the PT_LOAD MemSiz rounded up to the 4 KiB page. It is the honest lower
#     bound the RSS column cannot reach.
#   * times use `hyperfine --warmup 3 --min-runs 20` when it is installed, and
#     otherwise a 100-run loop timed with `/usr/bin/time -p`, which gives a mean
#     and no min (the column says `-`).
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root" || exit 1
rel=${here#"$root"/}

mc="${MC:-$root/build/mc1}"
out="$here/build"
facts="$out/facts"
tmp="$out/tmp"
img="alpine:3"
sysroot="${MC_SYSROOT:-build/sysroot/linux-aarch64}"
runs=100                       # loop runs when hyperfine is missing
bench_min=5                    # runs whose minimum a memory number is

check=0
[ "${1:-}" = "--check" ] && check=1

VARIANTS="macos-exe macos-ld linux-musl linux-nolibc"

# ---------------------------------------------------------------- facts store
# One file per variant, `key value` per line: written by the collectors, read by
# the printers, so a half-measured variant is visible instead of silently zero.
fput() { mkdir -p "$facts"; echo "$2 $3" >> "$facts/$1"; }
fget() {
    v=$(awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$facts/$1" 2>/dev/null)
    [ -n "$v" ] || v="${3:--}"
    echo "$v"
}
fhas() { [ -f "$facts/$1" ] && [ -n "$(fget "$1" "$2" "")" ]; }

# ------------------------------------------------------------------- helpers
die() { echo "measure.sh: $*" >&2; exit 1; }

# thousands separator, so a 16-thousand-byte file does not read as 168
group() {
    awk -v n="$1" 'BEGIN {
        if (n !~ /^[0-9]+$/) { print n; exit }
        s = ""; t = n
        while (length(t) > 3) { s = " " substr(t, length(t) - 2) s; t = substr(t, 1, length(t) - 3) }
        print t s
    }'
}

fsize() { wc -c < "$1" | tr -d ' '; }

# the smallest of N runs of `/usr/bin/time -l CMD`, field $1 of the line matching $2
mac_mem() {
    field="$1"; shift
    best=""
    i=0
    while [ "$i" -lt "$bench_min" ]; do
        val=$(/usr/bin/time -l "$@" 2>&1 >/dev/null | awk -v k="$field" '$0 ~ k { print $1; exit }')
        case "$val" in ''|*[!0-9]*) val="" ;; esac
        if [ -n "$val" ]; then
            [ -z "$best" ] && best="$val"
            [ "$val" -lt "$best" ] && best="$val"
        fi
        i=$((i + 1))
    done
    echo "${best:--}"
}

# Mach-O: LC_SEGMENT_64 count, section count, mapped bytes (no __PAGEZERO),
# __text bytes. One awk over `otool -l`, with its own hex reader because the awk
# macOS ships has no strtonum.
macho_facts() {
    otool -l "$1" | awk '
        function h2d(s,   i, c, n, d) {
            sub(/^0[xX]/, "", s); n = 0
            for (i = 1; i <= length(s); i++) {
                c = tolower(substr(s, i, 1)); d = index("0123456789abcdef", c) - 1
                n = n * 16 + d
            }
            return n
        }
        /^Load command/ { inseg = 0; insect = 0; next }
        $1 == "cmd" && $2 == "LC_SEGMENT_64" { inseg = 1; next }
        $1 == "Section" { insect = 1; nsec++; next }
        inseg && !insect && $1 == "segname" { seg = $2; nseg++; next }
        inseg && !insect && $1 == "vmsize" { if (seg != "__PAGEZERO") mapped += h2d($2); next }
        insect && $1 == "sectname" { sect = $2; next }
        insect && $1 == "size" && sect == "__text" { code += h2d($2); next }
        END { printf "segments %d\nsections %d\nmapped %d\ncode %d\n", nseg, nsec, mapped, code }'
}

# ------------------------------------------------------------------- timings
have_hyperfine=0
command -v hyperfine > /dev/null 2>&1 && have_hyperfine=1

# bench NAME CMD...  -> writes "NAME_mean" / "NAME_min" (ms) into $facts/$var
# hyperfine when present (warmup 3, at least 20 runs), otherwise a $runs-long
# loop timed as a whole, which yields a mean and no min.
bench() {
    var="$1"; key="$2"; shift 2
    mkdir -p "$tmp"
    if [ "$have_hyperfine" = "1" ]; then
        rm -f "$tmp/hf.csv"
        hyperfine --warmup 3 --min-runs 20 --style none \
                  --export-csv "$tmp/hf.csv" -- "$*" > /dev/null 2>&1
        mean=$(awk -F, 'NR == 2 { printf "%.2f", $2 * 1000 }' "$tmp/hf.csv" 2>/dev/null)
        min=$(awk -F, 'NR == 2 { printf "%.2f", $7 * 1000 }' "$tmp/hf.csv" 2>/dev/null)
    else
        {
            echo "i=0"
            echo "while [ \$i -lt $runs ]; do"
            echo "  $* > /dev/null 2>&1"
            echo "  i=\$((i + 1))"
            echo "done"
        } > "$tmp/work.sh"
        real=$(/usr/bin/time -p sh "$tmp/work.sh" 2>&1 > /dev/null | awk '$1 == "real" { print $2 }')
        mean=$(awk -v r="$real" -v n="$runs" 'BEGIN { printf "%.2f", r * 1000 / n }')
        min="-"
    fi
    [ -n "${mean:-}" ] || mean="-"
    fput "$var" "${key}_mean" "$mean"
    fput "$var" "${key}_min" "${min:--}"
}

# ------------------------------------------------------------ what we can run
[ -x "$mc" ] || die "compiler '$mc' not found or not executable (make mc1)"

have_lld=0
command -v ld.lld > /dev/null 2>&1 && have_lld=1
have_docker=0
docker info > /dev/null 2>&1 && have_docker=1

linux_skip=""
if [ "$have_lld" = "0" ]; then
    linux_skip="ld.lld not in PATH (brew install lld)"
elif [ "$have_docker" = "0" ]; then
    linux_skip="docker is not running"
fi

rm -rf "$facts" "$tmp"
mkdir -p "$out" "$facts" "$tmp"

# ------------------------------------------------------------------- builds
# Every artefact is removed first: overwriting a signed executable in place
# leaves the kernel with a stale signature and kills the next run (CLAUDE.md).
build_macos() {
    rm -rf "$out/exe" "$out/ld"
    mkdir -p "$out/exe" "$out/ld"
    "$mc" build "$here" > "$tmp/log" 2>&1 || { cat "$tmp/log" >&2; die "mc build (mc.toml) failed"; }
    "$mc" "$here/main.mc" -o "$out/ld/minimal.o" > "$tmp/log" 2>&1 \
        || { cat "$tmp/log" >&2; die "mc -o .o failed"; }
    sh "$root/scripts/link.sh" "$out/ld/minimal" "$out/ld/minimal.o" > "$tmp/log" 2>&1 \
        || { cat "$tmp/log" >&2; die "scripts/link.sh failed"; }
}

build_linux() {
    [ -z "$linux_skip" ] || return 0
    if [ ! -f "$sysroot/libc.a" ] || [ ! -f "$sysroot/crt1.o" ] \
       || [ ! -f "$sysroot/crti.o" ] || [ ! -f "$sysroot/crtn.o" ]; then
        scripts/sysroot-linux.sh "$sysroot" > /dev/null 2>&1 \
            || { linux_skip="the musl sysroot could not be populated"; return 0; }
    fi
    rm -rf "$out/musl" "$out/nolibc"
    "$mc" build "$here" --config "$here/mc.linux.toml" > "$tmp/log" 2>&1 \
        || { cat "$tmp/log" >&2; die "mc build (mc.linux.toml) failed"; }
    "$mc" build "$here" --config "$here/mc.nolibc.toml" > "$tmp/log" 2>&1 \
        || { cat "$tmp/log" >&2; die "mc build (mc.nolibc.toml) failed"; }
}

# ------------------------------------------------------------ static numbers
collect_macos_static() {
    for v in macos-exe macos-ld; do
        case "$v" in
            macos-exe) bin="$out/exe/minimal" ;;
            macos-ld)  bin="$out/ld/minimal" ;;
        esac
        fput "$v" bin "$bin"
        fput "$v" size "$(fsize "$bin")"
        macho_facts "$bin" | while read -r k n; do fput "$v" "$k" "$n"; done
        fput "$v" page 16384
    done
}

# One container does all of it: the two Linux rows' sections, segments, mapped
# bytes, .text, max RSS and startup time. `apk add` is the price of GNU time and
# binutils; its output is dropped so the table stays byte-identical.
collect_linux() {
    [ -z "$linux_skip" ] || return 0
    cat > "$out/incontainer.sh" <<'INNER'
#!/bin/sh
# Runs inside alpine:3 (linux/arm64). Prints `variant key value` lines.
apk add --no-cache time binutils > /dev/null 2>&1 || exit 1
runs=$1
for v in musl nolibc; do
    b="$2/$v/minimal"
    name="linux-$v"
    echo "$name code $(size -A "$b" | awk '$1 == ".text" { print $2; exit }')"
    # $6 is MemSiz. Its own hex reader, because busybox awk has no strtonum
    # either; each PT_LOAD is rounded up to the 4 KiB page the kernel maps.
    readelf -lW "$b" | awk -v n="$name" '
        function h2d(s,   i, c, v, d) {
            sub(/^0[xX]/, "", s); v = 0
            for (i = 1; i <= length(s); i++) {
                c = tolower(substr(s, i, 1)); d = index("0123456789abcdef", c) - 1
                v = v * 16 + d
            }
            return v
        }
        $1 == "LOAD" { nseg++; m = h2d($6); mapped += int((m + 4095) / 4096) * 4096 }
        END { printf "%s segments %d\n%s mapped %d\n", n, nseg, n, mapped }'
    # section headers, minus the mandatory null one at index 0
    echo "$name sections $(readelf -SW "$b" | awk '/^ *\[ *[0-9]+\]/ { n++ } END { print n - 1 }')"
    echo "$name page 4096"
    # 20 runs, not 5: this number is the measuring process's own floor (see the
    # explanation block) and jitters by a 4 KiB page, so only a minimum over
    # enough runs is stable enough to belong in a table meant to be diffed
    best=""
    i=0
    while [ "$i" -lt 20 ]; do
        r=$(/usr/bin/time -v "$b" 2>&1 | awk '/Maximum resident/ { print $NF; exit }')
        case "$r" in ''|*[!0-9]*) r="" ;; esac
        if [ -n "$r" ]; then
            [ -z "$best" ] && best="$r"
            [ "$r" -lt "$best" ] && best="$r"
        fi
        i=$((i + 1))
    done
    [ -n "$best" ] && echo "$name rss $((best * 1024))"
    t=$(/usr/bin/time -f %e sh -c "i=0; while [ \$i -lt $runs ]; do $b; i=\$((i+1)); done" 2>&1 | tail -1)
    echo "$name start_mean $(awk -v r="$t" -v n="$runs" 'BEGIN { printf "%.2f", r * 1000 / n }')"
    echo "$name start_min -"
done
INNER
    docker run --rm --platform linux/arm64 -v "$root":/w -w /w "$img" \
        sh "/w/$rel/build/incontainer.sh" "$runs" "/w/$rel/build" 2>/dev/null \
        | while read -r v k n; do
            [ -n "$n" ] && fput "$v" "$k" "$n"
        done
    fput linux-musl bin "$out/musl/minimal"
    fput linux-nolibc bin "$out/nolibc/minimal"
    fput linux-musl size "$(fsize "$out/musl/minimal")"
    fput linux-nolibc size "$(fsize "$out/nolibc/minimal")"
}

collect_macos_mem() {
    fput macos-exe rss "$(mac_mem 'maximum resident set size' "$out/exe/minimal")"
    fput macos-exe peak "$(mac_mem 'peak memory footprint' "$out/exe/minimal")"
    fput macos-ld rss "$(mac_mem 'maximum resident set size' "$out/ld/minimal")"
    fput macos-ld peak "$(mac_mem 'peak memory footprint' "$out/ld/minimal")"
}

# -------------------------------------------------------------------- timings
collect_times() {
    bench macos-exe start "$out/exe/minimal"
    bench macos-ld start "$out/ld/minimal"

    # compiling: exactly the command that produced the artefact above, plus the
    # compiler's own peak RSS for that one compilation
    bench macos-exe compile "$mc" --exe "$here/main.mc" -o "$out/exe/minimal"
    fput macos-exe crss "$(mac_mem 'maximum resident set size' "$mc" --exe "$here/main.mc" -o "$tmp/minimal")"

    bench macos-ld compile "$mc" "$here/main.mc" -o "$out/ld/minimal.o"
    fput macos-ld crss "$(mac_mem 'maximum resident set size' "$mc" "$here/main.mc" -o "$tmp/minimal.o")"
    bench macos-ld link sh "$root/scripts/link.sh" "$out/ld/minimal" "$out/ld/minimal.o"

    if [ -z "$linux_skip" ]; then
        # one `mc build` is compile AND link (mc writes the ELF, ld.lld links it)
        bench linux-musl compile "$mc" build "$here" --config "$here/mc.linux.toml"
        fput linux-musl crss "$(mac_mem 'maximum resident set size' \
            "$mc" build "$here" --config "$here/mc.linux.toml")"
        bench linux-nolibc compile "$mc" build "$here" --config "$here/mc.nolibc.toml"
        fput linux-nolibc crss "$(mac_mem 'maximum resident set size' \
            "$mc" build "$here" --config "$here/mc.nolibc.toml")"
    fi
    # the artefacts were just rewritten by the benchmarks; they are byte for byte
    # what they were, but the .o + ld pair is relinked here to keep them in step
    sh "$root/scripts/link.sh" "$out/ld/minimal" "$out/ld/minimal.o" > /dev/null 2>&1
}

# --------------------------------------------------------------------- output
label() {
    case "$1" in
        macos-exe)    echo "macOS  --exe (no ld)" ;;
        macos-ld)     echo "macOS  .o + ld" ;;
        linux-musl)   echo "Linux  musl static" ;;
        linux-nolibc) echo "Linux  nolibc _start" ;;
    esac
}

header() {
    model=$(sysctl -n hw.model 2>/dev/null || echo "?")
    cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "?")
    osv=$(sw_vers -productVersion 2>/dev/null || uname -r)
    bld=$(sw_vers -buildVersion 2>/dev/null || echo "?")
    echo "examples/minimal — what the smallest program costs"
    echo
    echo "machine:  $model ($cpu), macOS $osv $bld, $(uname -m)"
    echo "compiler: $mc"
    echo "date:     $(date +%Y-%m-%d)"
    if [ -n "$linux_skip" ]; then
        echo "linux:    SKIPPED ($linux_skip)"
    else
        echo "linux:    $img linux/arm64 under docker, musl sysroot $sysroot"
    fi
    echo
}

table_sizes() {
    echo "| variant | file size | code bytes | segments/sections | max RSS | peak footprint | own mapped |"
    echo "|---|---:|---:|---:|---:|---:|---:|"
    for v in $VARIANTS; do
        if ! fhas "$v" size; then
            printf '| %-20s | %9s | %10s | %17s | %9s | %9s | %9s |\n' \
                "$(label "$v")" "not built" "-" "-" "-" "-" "-"
            continue
        fi
        printf '| %-20s | %9s | %10s | %17s | %9s | %9s | %9s |\n' \
            "$(label "$v")" \
            "$(group "$(fget "$v" size)")" \
            "$(group "$(fget "$v" code)")" \
            "$(fget "$v" segments) / $(fget "$v" sections)" \
            "$(group "$(fget "$v" rss)")" \
            "$(group "$(fget "$v" peak)")" \
            "$(group "$(fget "$v" mapped)")"
    done
    echo
    echo "All bytes. Every number above is read out of the file or is a kernel high-water mark"
    echo "that does not move between runs on this machine: the table is byte-identical run to run."
    echo "segments = LC_SEGMENT_64 (__PAGEZERO included) on Mach-O, PT_LOAD on ELF; sections"
    echo "excludes ELF's mandatory null section header."
    [ -n "$linux_skip" ] && echo "The two Linux rows were not built: $linux_skip."
}

# "1.80" -> "1.80 ms", "-" -> "-": a variant with no separate link step must not
# read as a link that took no time
ms() { if [ "$1" = "-" ]; then echo "-"; else echo "$1 ms"; fi; }

table_times() {
    echo "| variant | compile mean | compile min | compiler RSS | link mean | startup mean | startup min |"
    echo "|---|---:|---:|---:|---:|---:|---:|"
    for v in $VARIANTS; do
        fhas "$v" size || continue
        printf '| %-20s | %12s | %11s | %12s | %9s | %12s | %11s |\n' \
            "$(label "$v")" \
            "$(ms "$(fget "$v" compile_mean)")" \
            "$(ms "$(fget "$v" compile_min)")" \
            "$(group "$(fget "$v" crss)")" \
            "$(ms "$(fget "$v" link_mean)")" \
            "$(ms "$(fget "$v" start_mean)")" \
            "$(ms "$(fget "$v" start_min)")"
    done
    echo
    if [ "$have_hyperfine" = "1" ]; then
        echo "hyperfine --warmup 3 --min-runs 20."
    else
        echo "hyperfine is not installed: each figure is the mean of a $runs-run loop timed as a"
        echo "whole with /usr/bin/time -p, which has no per-run minimum (the min columns say -)."
    fi
    echo "The Linux rows compile on macOS and link with ld.lld in the same \`mc build\`, so their"
    echo "\"compile\" is compile + link and their \"link\" column is empty. Their startup is measured"
    echo "inside the container, so it excludes docker's own ~300 ms of container setup."
}

explain() {
    cat <<'EOF'
Where each floor comes from
---------------------------
macOS, one 16 KiB page plus 308 bytes of __LINKEDIT. arm64 macOS has a 16 KiB
  page and every segment starts on one, so the Mach-O header, the 12 load
  commands (624 bytes of them) and the 28 bytes of code all share the first
  __TEXT page, and the file is that whole page plus __LINKEDIT -- the symbol
  table and the ad-hoc CS_SuperBlob, which has to be last in the file. 16 384 +
  308 = 16 692, of which 28 bytes are the program. The .o + ld row is 148 bytes
  bigger and every one of those bytes is __LINKEDIT (456 against 308): ld also
  writes chained fixups, function starts and a data-in-code table. Its four
  extra load commands are free, because they sit inside a page that is there
  either way. The signature's identifier is the output's basename, so renaming
  the file changes the size by the difference in name length -- which is why
  every variant here is called `minimal`.
dyld and libSystem, ~1.3 MB of RSS for a program that calls nothing. The two
  macOS rows map 32 KiB of their own (two pages: __TEXT and __LINKEDIT) and
  report over a megabyte of RSS, because a Mach-O executable on macOS is started
  by dyld, which maps itself and libSystem out of the shared cache before main
  runs. The peak footprint (~950 KB) is the part the kernel charges to this
  process; the rest is shared with every other process on the machine. A static
  Mach-O would avoid it and is not an option: the kernel refuses to exec one
  (see M0.5 in docs/bootstrap.md).
musl static, 2 504 bytes of .text for 28 bytes of program. Linking crt1.o pulls
  in __libc_start_main, which pulls the auxv walk, the TLS and stack-guard setup
  and the exit machinery. The file is ten times bigger than what it loads
  because Alpine's libc.a carries debug information that ld.lld copies through:
  `strip` takes this exact binary from 32 592 bytes to 3 984 and from 21
  sections to 10, without touching a single loadable byte. None of this is mc's
  doing; a C hello-world links the same way.
nolibc, the true floor: 756 bytes of .text and 8 KiB mapped. <sys_linux> is the
  kernel interface written in the language itself: `svc #0` with the number in
  x8, plus a _start that reads argc/argv off the entry stack, calls main and
  hands x0 to exit_group. No crt objects, no libc, one ELF with two PT_LOADs and
  nothing to relocate. Most of even those 756 bytes is dead code -- mc emits
  every function it parses, and <sys_linux> defines open/creat/read/write/close/
  fchmod/exit plus lib/io.mc's strlen/puts/putnum, none of which this program
  calls. `strip` takes the file from 1 888 bytes to 1 360; the rest is ELF
  headers, program headers and the section table.
Why the two Linux RSS numbers are equal and both wrong. Linux keeps a process's
  RSS high-water mark across exec, so what wait4 reports to the measuring program
  is max(what the measurer had mapped when it forked, what the program used). GNU
  time's own image is ~256 KB and both of these programs are far below it, so
  both land on that floor -- the same binaries measured with busybox's time,
  whose image is ~716 KB, report 716 KB instead. The "own mapped" column is the
  number that actually separates them: 16 KiB against 8 KiB.
EOF
}

# ------------------------------------------------------------------ --check
# The ceilings are regression guards for the backends, not tuning targets: they
# sit just above what the tree produces today, and a violation means a backend
# started emitting something it did not emit before.
CEIL_MACOS_EXE=17000
CEIL_MACOS_RSS=2000000
CEIL_LINUX_NOLIBC=2000

do_check() {
    fails=0
    n=$(fget macos-exe size)
    if [ "$n" -le "$CEIL_MACOS_EXE" ]; then
        echo "ok   macos --exe size          $(group "$n") <= $(group $CEIL_MACOS_EXE) bytes"
    else
        echo "FAIL macos --exe size          $(group "$n") > $(group $CEIL_MACOS_EXE) bytes"
        fails=$((fails + 1))
    fi
    n=$(fget macos-exe rss)
    if [ "$n" = "-" ]; then
        echo "skip macos --exe max RSS       (/usr/bin/time -l gave no number)"
    elif [ "$n" -le "$CEIL_MACOS_RSS" ]; then
        echo "ok   macos --exe max RSS       $(group "$n") <= $(group $CEIL_MACOS_RSS) bytes"
    else
        echo "FAIL macos --exe max RSS       $(group "$n") > $(group $CEIL_MACOS_RSS) bytes"
        fails=$((fails + 1))
    fi
    if [ -n "$linux_skip" ]; then
        echo "skip linux nolibc size         ($linux_skip)"
    else
        n=$(fget linux-nolibc size)
        if [ "$n" -le "$CEIL_LINUX_NOLIBC" ]; then
            echo "ok   linux nolibc size         $(group "$n") <= $(group $CEIL_LINUX_NOLIBC) bytes"
        else
            echo "FAIL linux nolibc size         $(group "$n") > $(group $CEIL_LINUX_NOLIBC) bytes"
            fails=$((fails + 1))
        fi
    fi
    if [ "$fails" -ne 0 ]; then
        echo "$fails ceiling(s) violated"
        return 1
    fi
    echo "all ceilings hold"
    return 0
}

# --------------------------------------------------------------------- main
build_macos
build_linux
collect_macos_static
collect_linux

if [ "$check" = "1" ]; then
    collect_macos_mem
    do_check
    exit $?
fi

collect_macos_mem
collect_times

header
table_sizes
echo
table_times
echo
explain
