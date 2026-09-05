#!/bin/sh
# sandbox-trace.sh [--check] [--libc musl|gnu] [MC] — the seccomp profiles,
# MEASURED (M43 step C, docs/specs/M43.md § 4, acceptance 5).
#
#   sh scripts/sandbox-trace.sh            trace this host and rewrite the tables
#   sh scripts/sandbox-trace.sh --check    trace this host and compare, both ways
#
# The profiles src/sandbox_profiles.mc holds are not written by hand: they are
# what `strace` saw. This script is what writes them, and `--check` is what
# fails when the compiler grows a system call the table does not have (or keeps
# one nothing uses any more).
#
# WHAT IS TRACED, and why it is traced OUTSIDE the box.
#
# The box runs exactly two command lines per source (docs/reference/sandbox.md
# § The steps):
#
#     /mc --exe /src/X.mc -o /src/X        the compile step
#     /src/X                               the run step
#
# so those two are what is traced, on the host, with the same compiler and the
# same sources. Tracing the BOX instead would be wrong twice over: `strace -f`
# would also record the box's own setup -- unshare, mount, pivot_root,
# sethostname -- which must never be in a profile, and once a filter exists the
# measurement is circular, because a system call missing from the profile is
# refused before it can be observed. Running the two steps outside the box
# observes the same binaries with the same arguments; the only difference is
# that the host has an /etc, so the dynamic loader's `openat` of
# /etc/ld.so.cache succeeds and drags in one or two more calls. That makes the
# measurement a superset of what the box needs, which is the safe direction.
#
# WHAT IS WRITTEN. One list file per (architecture, libc, kind), because a
# profile is a property of the machine and of the C library the loader belongs
# to, and no host has more than one of each at a time:
#
#     tools/sandbox/<arch>-<libc>-compile.list
#     tools/sandbox/<arch>-<libc>-program.list
#     tools/sandbox/<arch>-<libc>-threads.list
#
# src/sandbox_profiles.mc is then GENERATED from every list file present, so a
# machine that can only measure one architecture never erases the other's
# numbers. The checked-in .mc is what this script printed; `--check` proves it
# by regenerating it and diffing.

check=0
libc=
mc=
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check=1; shift ;;
        --libc)  libc="$2"; shift 2 ;;
        *)       mc="$1"; shift ;;
    esac
done

case "$(uname -s)" in
    Linux) ;;
    *) echo "sandbox-trace: SKIPPED (Linux only; the profiles are Linux system calls)"; exit 0 ;;
esac
command -v strace > /dev/null 2>&1 || {
    echo "sandbox-trace: SKIPPED (no strace: apt-get install strace / apk add strace)"; exit 0; }

case "$(uname -m)" in
    aarch64|arm64) arch=aarch64; aname=arm64 ;;
    x86_64|amd64)  arch=x86_64;  aname=x86_64 ;;
    *) echo "FAIL: unsupported machine $(uname -m)"; exit 1 ;;
esac

# the compiler under test, and the C library its programs will be linked
# against -- which is the loader on THIS disk, the same question `mc sandbox`
# itself asks before it compiles anything (src/sandbox.mc, sb_libc_flag).
if [ -z "$mc" ]; then
    if [ -e "/lib/ld-musl-$arch.so.1" ]; then mc="build/mc-linux-$aname"; else mc="build/mc-linux-$aname-gnu"; fi
fi
[ -x "$mc" ] || { echo "FAIL: compiler '$mc' not found or not executable"; exit 1; }
# The C library is a property of the HOST, not of the compiler binary: the
# loader on this disk is what an --exe binary must name, which is the question
# src/sandbox.mc (sb_libc_flag) asks before it compiles anything inside the box.
# Grepping the compiler for "ld-musl" would answer musl on every host -- it
# carries both loader paths, one of them in the bundled source of the writer.
if [ -z "$libc" ]; then
    if [ -e "/lib/ld-musl-$arch.so.1" ]; then libc=musl; else libc=gnu; fi
fi
lf=
[ "$libc" = gnu ] && lf=--libc=gnu

out=build/sandbox-trace
rm -rf "$out"; mkdir -p "$out" tools/sandbox
echo "== sandbox-trace: $mc on linux/$arch ($libc), $(uname -r)"

# One raw trace, one list of names. `strace -c` is NOT used: its summary drops
# exit_group, which never returns and is therefore never counted -- and a
# profile without exit_group refuses every program at its last instruction.
# Measured: `-c` reported 15 calls for tests/013-putnum, the raw trace 16.
names() {   # names FILE
    sed -n 's/^[0-9]* *\([a-z_0-9]*\)(.*/\1/p' "$1"
}

trace() {   # trace OUTFILE CMD...
    o="$1"; shift
    strace -f -o "$o" "$@" > /dev/null 2>&1
}

# ---- the corpus -------------------------------------------------------------
# Every tests/*.mc this architecture can run, compiled and then executed, plus
# `mc build examples/lang` -- the project case, which is the only one that
# forks and execs a compiler it just wrote.
c_raw="$out/compile.names"
p_raw="$out/program.names"
: > "$c_raw"; : > "$p_raw"

hdr() { sed -n "s|^// $1: ||p" "$2" | head -1; }

n=0
for f in tests/*.mc; do
    name=$(basename "$f" .mc)
    reason=$(hdr skip-linux "$f")
    [ -z "$reason" ] && reason=$(hdr "skip-$arch" "$f")
    [ -n "$reason" ] && continue
    # shellcheck disable=SC2086
    trace "$out/c.$name" "$mc" --exe $lf "$f" -o "$out/bin.$name"
    names "$out/c.$name" >> "$c_raw"
    [ -x "$out/bin.$name" ] || continue
    ( cd "$out" && trace "c.run.$name" "./bin.$name" )
    names "$out/c.run.$name" >> "$p_raw"
    n=$((n + 1))
done

# One more program, and it is in the corpus for a reason the corpus itself
# cannot supply: every tests/*.mc writes with a raw `write` and allocates
# nothing, so their traces say nothing about what an ORDINARY C-library program
# needs -- stdio, malloc, a signal mask. Measured, that gap was three refusals
# in a row on programs nobody would call unusual (`refused: syscall 233
# (madvise)`, `refused: syscall 135 (rt_sigprocmask)`). So the profile is
# measured over one as well.
cat > "$out/libc.mc" <<'EOF'
extern uptr malloc(i64 n);
extern uptr realloc(uptr p, i64 n);
extern void free(uptr p);
extern uptr fopen(uptr path, uptr mode);
extern i64 fread(uptr p, i64 sz, i64 n, uptr f);
extern i32 fseek(uptr f, i64 off, i64 whence);
extern i64 ftell(uptr f);
extern i32 fclose(uptr f);
extern uptr opendir(uptr path);
extern uptr readdir(uptr d);
extern i32 closedir(uptr d);
extern i32 sigprocmask(i64 how, uptr set, uptr old);

i64 main() {
    // a heap that grows and shrinks
    i64 i = 0;
    loop {
        if (i >= 64) break;
        uptr p = malloc(4096 * (i + 1));
        st8(p, 1);
        free(p);
        i = i + 1;
    }
    // four megabytes in one block, which is what makes `madvise` appear EVERY
    // time instead of one run in twelve: glibc advises MADV_HUGEPAGE on a
    // mapped chunk this size. Measured 20/20 with it and 5/60 without
    // (aarch64, glibc 2.43) -- and a profile measured from a corpus that hits
    // a call one run in twelve is a box that refuses a legitimate program one
    // run in twelve.
    uptr big = malloc(4194304);
    st8(big, 2);
    big = realloc(big, 8388608);
    st8(big, 3);
    free(big);
    // stdio, a seek, a directory listing and a signal mask: the ordinary
    // things a C program does that no tests/*.mc does
    uptr f = fopen("libc.mc", "r");
    if (f) {
        uptr b = malloc(8192);
        fread(b, 1, 4096, f);
        fseek(f, 0, 0);
        ftell(f);
        fclose(f);
        free(b);
    }
    uptr d = opendir(".");
    if (d) {
        loop { if (readdir(d) == 0) break; }
        closedir(d);
    }
    u8 set[128];
    u8 old[128];
    i = 0;
    loop { if (i >= 128) break; st8(set + i, 0); st8(old + i, 0); i = i + 1; }
    sigprocmask(0, set, old);
    return 0;
}
EOF
# shellcheck disable=SC2086
trace "$out/c.libc" "$mc" --exe $lf "$out/libc.mc" -o "$out/libc"
names "$out/c.libc" >> "$c_raw"
( cd "$out" && trace "c.run.libc" ./libc )
names "$out/c.run.libc" >> "$p_raw"

cfg=examples/lang/mc.linux.toml
[ "$libc" = gnu ] && cfg=examples/lang/mc.linux-gnu.toml
trace "$out/c.lang" "$mc" build examples/lang --config "$cfg"
names "$out/c.lang" >> "$c_raw"

# ---- the --allow=threads delta ---------------------------------------------
# There is no threaded program in tests/, so the delta is measured on one
# written here: a thread created, joined, and a sleep, which is what the flag
# is for (docs/reference/sandbox.md § The filter).
cat > "$out/threaded.mc" <<'EOF'
extern i64 pthread_create(uptr th, uptr attr, uptr fn, uptr arg);
extern i64 pthread_join(i64 th, uptr ret);
extern i64 usleep(i64 us);
i64 worker(uptr a) { return 0; }
i64 main() {
    u8 th[8];
    pthread_create(th, 0, &worker, 0);
    pthread_join(ld64(th), 0);
    usleep(1000);
    return 0;
}
EOF
# shellcheck disable=SC2086
"$mc" --exe $lf "$out/threaded.mc" -o "$out/threaded" > /dev/null 2>&1
( cd "$out" && trace "c.threaded" ./threaded )
names "$out/c.threaded" | sort -u > "$out/threads.all"

sort -u "$c_raw" > "$out/compile.list"
sort -u "$p_raw" > "$out/program.list"
comm -23 "$out/threads.all" "$out/program.list" > "$out/threads.list"

echo "   corpus: $n sources compiled and run, plus mc build examples/lang"
echo "   compile $(wc -l < "$out/compile.list") calls, program $(wc -l < "$out/program.list") calls, threads delta $(wc -l < "$out/threads.list")"

# ---- every name must have an SN_* -------------------------------------------
# The tables are written in SN_* terms so that src/sandbox*.mc names no number
# (docs/reference/sandbox.md § The system-call shim). A name the enum does not
# have is a hard failure with the line to add, not a silent drop.
miss=
for s in $(cat "$out/compile.list" "$out/program.list" "$out/threads.list" | sort -u); do
    u=$(echo "$s" | tr 'a-z' 'A-Z')
    grep -q "^#define SN_$u  *[0-9]" src/sysno.mc || miss="$miss SN_$u"
done
if [ -n "$miss" ]; then
    echo "FAIL: src/sysno.mc has no index for:$miss"
    exit 1
fi

# ---- write the lists --------------------------------------------------------
newlist() {   # newlist KIND
    src="$out/$1.list"
    dst="tools/sandbox/$arch-$libc-$1.list"
    if [ "$check" = 1 ]; then
        if [ ! -f "$dst" ]; then echo "FAIL: $dst is missing"; return 1; fi
        if ! diff -u "$dst" "$src" > "$out/$1.diff"; then
            echo "FAIL: the $1 trace and $dst disagree:"
            sed 's/^/     /' "$out/$1.diff"
            return 1
        fi
        echo "ok   $1: $(wc -l < "$dst") calls, trace and table agree both ways"
        return 0
    fi
    cp "$src" "$dst"
    echo "     wrote $dst ($(wc -l < "$dst") calls)"
    return 0
}

rc=0
newlist compile || rc=1
newlist program || rc=1
newlist threads || rc=1

# ---- generate src/sandbox_profiles.mc --------------------------------------
# From every list file in tools/sandbox/, so the architecture this host cannot
# measure keeps the numbers the host that could measure it wrote.
emit() {   # emit > FILE
    cat <<'EOF'
// sandbox_profiles.mc — GENERATED by scripts/sandbox-trace.sh. Do not edit.
//
// The seccomp profiles of M43 step C (docs/specs/M43.md § 4,
// docs/reference/sandbox.md § The filter): the system calls a step is allowed
// to make without the supervisor being asked. Everything else reaches P as a
// SECCOMP_RET_USER_NOTIF notification, which is what turns a kill into a
// sentence -- `refused: syscall 198 (socket)`.
//
// They are MEASURED, never written: `strace -f` over every tests/*.mc compiled
// and run, and over `mc build examples/lang`, on each architecture and each C
// library. The recorded traces are tools/sandbox/*.list and this file is what
// the script printed from them; `sh scripts/sandbox-trace.sh --check` re-traces
// the host it runs on and fails if the trace and the list disagree in EITHER
// direction, or if regenerating this file from the lists does not reproduce it
// byte for byte.
//
// Three tables per architecture, plus one shared delta:
//
//   sbp_compile_*   the compile step: /mc itself, and the compiler it teaches
//   sbp_program_*   the run step: what an mc program plus its loader issues
//   sbp_gnu_*_*     what glibc's ld.so and libc need that musl's do not, per
//                   step -- the two are NOT the same list
//   sbp_threads     what --allow=threads adds (clone is not here: the filter
//                   gives it a flag test of its own, src/seccomp.mc)
//
// Each list is terminated by -1. An entry this architecture does not have
// answers -1 from host_sysno() and is skipped when the filter is built.
EOF
    for a in aarch64 x86_64; do
        for k in compile program; do
            base=$(cat "tools/sandbox/$a-musl-$k.list" 2>/dev/null)
            [ -n "$base" ] || base=$(cat "tools/sandbox/$a-gnu-$k.list" 2>/dev/null)
            echo
            echo "i64 sbp_${k}_${a}[] = {"
            emit_rows "$base"
            echo "};"
            # the glibc extras, PER KIND. Taking one delta over both kinds
            # together would be wrong in both directions: `read` is in musl's
            # compile trace and not in its program trace, so a union delta
            # would not give it to a glibc program (measured: `refused:
            # syscall 63 (read)` on the first run), and `clone3` is in the
            # compile trace only, so a union delta would hand a glibc PROGRAM
            # a way to fork that the profile is meant to refuse.
            g=
            if [ -f "tools/sandbox/$a-musl-$k.list" ] && [ -f "tools/sandbox/$a-gnu-$k.list" ]; then
                g=$(comm -23 "tools/sandbox/$a-gnu-$k.list" "tools/sandbox/$a-musl-$k.list")
            fi
            echo
            echo "i64 sbp_gnu_${k}_${a}[] = {"
            emit_rows "$g"
            echo "};"
        done
    done
    t=$(cat tools/sandbox/*-threads.list 2>/dev/null | sort -u | grep -vE '^(clone|clone3)$')
    echo
    echo "i64 sbp_threads[] = {"
    emit_rows "$t"
    echo "};"
    cat <<'EOF'

// the table for this architecture, by kind. host_arch() is the running
// machine, which is the only one whose numbers mean anything here.
uptr sbp_compile() {
    if (str_eq(host_arch(), "x86_64")) return sbp_compile_x86_64;
    return sbp_compile_aarch64;
}

uptr sbp_program() {
    if (str_eq(host_arch(), "x86_64")) return sbp_program_x86_64;
    return sbp_program_aarch64;
}

uptr sbp_gnu_compile() {
    if (str_eq(host_arch(), "x86_64")) return sbp_gnu_compile_x86_64;
    return sbp_gnu_compile_aarch64;
}

uptr sbp_gnu_program() {
    if (str_eq(host_arch(), "x86_64")) return sbp_gnu_program_x86_64;
    return sbp_gnu_program_aarch64;
}
EOF
}

emit_rows() {   # emit_rows "name name ..."
    if [ -z "$1" ]; then echo "    -1"; return; fi
    for s in $1; do
        u=$(echo "$s" | tr 'a-z' 'A-Z')
        printf '    SN_%s,\n' "$u"
    done
    echo "    -1"
}

emit > "$out/sandbox_profiles.mc"
if [ "$check" = 1 ]; then
    if diff -u src/sandbox_profiles.mc "$out/sandbox_profiles.mc" > "$out/gen.diff"; then
        echo "ok   src/sandbox_profiles.mc is what the lists generate"
    else
        echo "FAIL: src/sandbox_profiles.mc is not what tools/sandbox/*.list generate:"
        sed 's/^/     /' "$out/gen.diff"
        rc=1
    fi
else
    cp "$out/sandbox_profiles.mc" src/sandbox_profiles.mc
    echo "     wrote src/sandbox_profiles.mc"
fi

[ "$rc" = 0 ] || exit 1
exit 0
