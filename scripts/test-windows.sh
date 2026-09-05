#!/bin/sh
# test-windows.sh — the whole suite cross-compiled to Windows and, on a Windows
# machine, linked and run for real (M19/M20, docs/build.md § Windows targets).
#
#   test-windows.sh [--arch A] [MC]                     cross-compile + validate
#   test-windows.sh [--arch A] --build-only OUTDIR [MC] cross-compile only
#   test-windows.sh [--arch A] --run-only OUTDIR        link OUTDIR and run it
#
# --arch is aarch64 or x86_64: the COFF writer is `coff-obj-arm64` over the arm64
# machine, or `coff-obj-x86_64` over `x86_64-win`, the Win64 half of the x86-64
# machine (docs/reference/machine.md).
#
# The split is not an optimisation, it is the only shape that works: `mc` runs
# on macOS arm64 and nowhere else, and a Windows binary runs on Windows and
# nowhere else. So the objects are produced here and the linking and the running
# happen on the windows-11-arm runner (docs/ci.md).
#
#   --build-only OUTDIR   needs `mc`, and `llvm-dlltool` for the import library.
#                         Writes OUTDIR/<name>.obj (kind = "obj", so the driver
#                         stops at the COFF object), OUTDIR/<name>.expect with
#                         the header values, OUTDIR/manifest (one
#                         "<name> <linkmode>" line per object, in test order),
#                         OUTDIR/skipped, plus the two files the other half needs
#                         and cannot make for itself: OUTDIR/winrt.obj (the
#                         kernel32 system layer, lib/sys_windows.mc, compiled the
#                         same way), OUTDIR/winstart.obj (the entry point,
#                         lib/sys_windows_start.mc) and OUTDIR/kernel32.lib (the
#                         import library).
#   --run-only OUTDIR     needs a Windows linker (lld-link) and nothing else --
#                         no `mc`, no compiler, no SDK. Links each object and
#                         runs the .exe from the repository root, because a test
#                         may open its own source by a relative path
#                         (tests/025-linecount.mc does).
#
# The default mode is what `make test-windows` runs on the development machine:
# cross-compile everything, check every object's COFF header with `llvm-readobj`
# when it is available, and LINK every one of them with `lld-link`, each with
# the link mode the manifest recorded, to prove the objects are linkable. It
# does not run anything -- there is no Windows host here, and the CI leg is the
# runtime oracle for behaviour. Linking all of them and not a sample is what
# makes a test classified into the wrong link mode fail HERE (M45: 073 was in
# the `self` list and CI was the first to say so).
#
# Headers, the same ones scripts/test.sh and scripts/test-linux.sh read:
#
#   // expect-exit: N        (required)
#   // expect-stdout: TEXT   (optional)
#   // skip-windows: REASON  (this test cannot run on Windows at all; printed)
#   // skip-<arch>: REASON    (this instruction set only, shared with test-linux.sh)
#
# Link modes in the manifest:
#
#   kernel32   the test object plus winrt.obj plus kernel32.lib. The test's
#              `extern` write/open/read/close (directly, or through
#              lib/sys.mc) resolve against the layer, exactly as they resolve
#              against libc.a on Linux.
#   self       the test object plus kernel32.lib and nothing else: the source
#              already includes <sys_windows>, so it carries the layer itself and
#              a second copy would be a duplicate symbol.
#
# Both modes also carry winstart.obj (lib/sys_windows_start.mc, M20): mc_start
# lives there and nowhere else, because it is the one place `main` is named as an
# extern and the layer a program includes cannot both declare and define it.
#
# MC_SYSROOT overrides the sysroot directory (default
# build/sysroot/windows-<arch>) for the modes that need kernel32.lib.
mode="full"
split=""
arch="aarch64"
mc=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)   arch="$2"; shift 2 ;;
        --arch=*) arch="${1#--arch=}"; shift ;;
        --build-only|--run-only)
            [ -n "$2" ] || { echo "FAIL: $1 needs a directory" >&2; exit 1; }
            if [ "$1" = "--build-only" ]; then mode="build"; else mode="run"; fi
            split="$2"; shift 2
            ;;
        *) mc="$1"; shift ;;
    esac
done

case "$arch" in
    aarch64) lmachine="arm64"; cmachine="IMAGE_FILE_MACHINE_ARM64" ;;
    x86_64)  lmachine="x64";   cmachine="IMAGE_FILE_MACHINE_AMD64" ;;
    *) echo "FAIL: unknown --arch $arch (aarch64, x86_64)" >&2; exit 1 ;;
esac
mc="${mc:-build/mc1}"
sysroot="${MC_SYSROOT:-build/sysroot/windows-$arch}"
outdir="build/tests-windows-$arch"
[ "$mode" = "full" ] && split="$outdir"

if [ "$mode" != "run" ] && [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

# Homebrew hides the LLVM tools from the default PATH; the Windows runner has
# them wherever the LLVM release was unpacked. Look for each one and remember
# whether it is there -- the default mode degrades, the run mode cannot.
findtool() {
    t=$(command -v "$1" 2>/dev/null)
    if [ -z "$t" ]; then
        for cand in /opt/homebrew/opt/llvm/bin/"$1" /usr/local/opt/llvm/bin/"$1" \
                    /usr/lib/llvm-*/bin/"$1"; do
            if [ -x "$cand" ]; then t="$cand"; break; fi
        done
    fi
    echo "$t"
}
readobj=$(findtool llvm-readobj)
linker=$(findtool lld-link)

if [ "$mode" = "run" ] && [ -z "$linker" ]; then
    echo "FAIL: lld-link not in PATH (see docs/ci.md § the windows/arm64 leg)"
    exit 1
fi

root=$(pwd)
# Every absolute path below reaches a NATIVE tool (mc, lld-link), and under Git
# Bash `pwd` answers /c/a/... -- a form only MSYS understands. The CI jobs set
# MSYS2_ARG_CONV_EXCL so that lld-link's options are never rewritten, which also
# means no path is; so the script hands over C:/a/... itself (cygpath -m),
# which both the shell and the native side accept. The v0.6.0 release lost
# both Windows legs to exactly this (lld-link: could not open '/c/a/mc/...').
winpath() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" ;; *) printf '%s\n' "$1" ;; esac; }
root=$(winpath "$root")
tmp="${TMPDIR:-/tmp}/test-windows.$$"
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
mkdir -p "$tmp" "$outdir"
fails=0
total=0
skipped=""

if [ "$mode" = "run" ]; then
    [ -f "$split/manifest" ] || {
        echo "FAIL: '$split/manifest' not found (run --build-only first)"; exit 1; }
else
    mkdir -p "$split" || exit 1
fi
split=$(cd "$split" && pwd) || exit 1
split=$(winpath "$split")

# kernel32.lib travels with the objects, so the Windows half normally needs no
# dlltool and no SDK; when it did not travel, this half builds its own.
implib="$split/kernel32.lib"
if [ ! -f "$implib" ] && [ "$mode" = "run" ]; then
    implib="$root/$sysroot/kernel32.lib"
    if [ ! -f "$implib" ]; then
        sh scripts/sysroot-windows.sh --arch "$arch" "$sysroot" || exit 1
    fi
fi

# writes $tmp/mc.toml for one object. $1 = entry, $2 = out
gen_toml_obj() {
    {
        echo '[project]'
        echo "entry = \"$1\""
        echo "out   = \"$2\""
        echo 'kind  = "obj"'
        echo
        echo '[target]'
        echo 'os   = "windows"'
        echo "arch = \"$arch\""
    } > "$tmp/mc.toml"
}

# why this test cannot run on this target, or empty. `// skip-windows:` is the
# whole operating system; `// skip-<arch>:` is this instruction set only -- the
# same two levels scripts/test-linux.sh reads, and the same headers, so no test
# gains a Windows-specific one.
skip_reason() {
    r=$(sed -n 's|^// skip-windows: *||p' "$1" | head -1)
    [ -n "$r" ] && { echo "$r"; return; }
    sed -n "s|^// skip-$arch: *||p" "$1" | head -1
}

# reads the test's headers into want_exit / want_out / has_out
read_expect() {
    want_exit=$(sed -n 's|^// expect-exit: *||p' "$1" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$1" | head -1)
    has_out=$(grep -c '^// expect-stdout:' "$1")
}

# compiles one source to a COFF object. $1 = source, $2 = output path
compile_obj() {
    rm -f "$2"
    gen_toml_obj "$root/$1" "$2"
    "$mc" build "$tmp" --config "$tmp/mc.toml" 2>&1
}

# the object plus everything the other half needs to judge it.
# $1 = source, $2 = name, $3 = link mode recorded in the manifest
build_one() {
    f="$1"; name="$2"; lmode="$3"
    total=$((total + 1))
    read_expect "$f"
    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no expect-exit header)"; fails=$((fails + 1)); return
    fi

    rm -f "$split/$name.expect"
    if ! msg=$(compile_obj "$f" "$split/$name.obj"); then
        echo "FAIL $name (build: $msg)"; fails=$((fails + 1)); return
    fi
    if [ -n "$readobj" ]; then
        got=$("$readobj" --file-headers "$split/$name.obj" 2>&1)
        case "$got" in
            *"$cmachine"*) ;;
            *) echo "FAIL $name (not an $arch COFF object)"; fails=$((fails + 1)); return ;;
        esac
        # determinism: TimeDateStamp is always 0, never the clock
        case "$got" in
            *"TimeDateStamp: 1970-01-01 00:00:00"*) ;;
            *) echo "FAIL $name (TimeDateStamp is not 0)"; fails=$((fails + 1)); return ;;
        esac
    fi

    echo "exit: $want_exit" > "$split/$name.expect"
    if [ "$has_out" != "0" ]; then
        echo "stdout: $want_out" >> "$split/$name.expect"
    fi
    echo "$name $lmode" >> "$split/manifest"
    echo "built $name"
}

# link one object. $1 = name, $2 = link mode; leaves the .exe next to it.
# lld-link takes its options with either prefix; the dash form is used because
# the CI leg runs this script under Git Bash on Windows, where MSYS rewrites a
# leading "/out:" or "/nodefaultlib" into "C:/Program Files/Git/..." before the
# linker ever sees it (0/32 on the first run of the windows-11-arm job).
link_one() {
    if [ -z "$implib" ] || [ ! -f "$implib" ]; then
        echo "no kernel32.lib (run scripts/sysroot-windows.sh)"
        return 1
    fi
    rm -f "$split/$1.exe"
    # winstart.obj is in every link line: mc_start lives there (M20) and it is
    # what -entry: names. `self` differs only in not taking winrt.obj, which the
    # source already carries.
    if [ "$2" = "self" ]; then
        set -- "-out:$split/$1.exe" "$split/$1.obj" "$split/winstart.obj" "$implib"
    else
        set -- "-out:$split/$1.exe" "$split/$1.obj" "$split/winrt.obj" \
               "$split/winstart.obj" "$implib"
    fi
    "$linker" -machine:$lmachine -subsystem:console -entry:mc_start -nodefaultlib "$@" 2>&1
}

# --run-only: link one object and run it. $1 = name, $2 = link mode
link_run_one() {
    name="$1"; lmode="$2"
    total=$((total + 1))
    if [ ! -f "$split/$name.obj" ] || [ ! -f "$split/$name.expect" ]; then
        echo "FAIL $name (missing $name.obj or $name.expect in $split)"
        fails=$((fails + 1)); return
    fi
    want_exit=$(sed -n 's|^exit: *||p' "$split/$name.expect" | head -1)
    want_out=$(sed -n 's|^stdout: *||p' "$split/$name.expect" | head -1)
    has_out=$(grep -c '^stdout:' "$split/$name.expect")
    if [ -z "$want_exit" ]; then
        echo "FAIL $name (no exit line in $name.expect)"; fails=$((fails + 1)); return
    fi

    if ! msg=$(link_one "$name" "$lmode"); then
        echo "FAIL $name (link: $msg)"; fails=$((fails + 1)); return
    fi

    # stderr goes to a file, not to /dev/null: a load-level failure (a missing
    # DLL, the wrong architecture) only says "exit 53" or "exit 216" otherwise,
    # which reads exactly like the program returning the wrong code
    got_out=$("$split/$name.exe" 2>"$tmp/err")
    got_exit=$?
    if [ "$got_exit" != "$want_exit" ]; then
        echo "FAIL $name (exit $got_exit, expected $want_exit)"
        err=$(cat "$tmp/err")
        [ -n "$err" ] && echo "     stderr: $err"
        fails=$((fails + 1)); return
    fi
    if [ "$has_out" != "0" ] && [ "$got_out" != "$want_out" ]; then
        echo "FAIL $name (stdout '$got_out', expected '$want_out')"; fails=$((fails + 1)); return
    fi
    echo "ok $name"
}

if [ "$mode" = "run" ]; then
    while read -r name lmode; do
        [ -n "$name" ] || continue
        link_run_one "$name" "$lmode"
    done < "$split/manifest"
    if [ -f "$split/skipped" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            skipped="$skipped
  $line"
        done < "$split/skipped"
    fi
else
    : > "$split/manifest"
    : > "$split/skipped"

    # the import library and the system layer, both of which the Windows half
    # has no way to produce for itself. The import library is the only piece
    # that needs a tool beyond `mc`; without llvm-dlltool the objects are still
    # produced and the other half regenerates it, so this warns instead of
    # failing.
    if msg=$(sh scripts/sysroot-windows.sh --arch "$arch" "$sysroot" 2>&1); then
        cp "$root/$sysroot/kernel32.lib" "$split/kernel32.lib" || exit 1
        implib="$split/kernel32.lib"
    else
        echo "warning: no kernel32.lib ($msg); --run-only will build its own"
        implib=""
    fi
    if ! msg=$(compile_obj lib/sys_windows.mc "$split/winrt.obj"); then
        echo "FAIL winrt.obj (build: $msg)"
        exit 1
    fi
    echo "built winrt.obj (lib/sys_windows.mc)"
    # the entry point, on its own and in EVERY link line (M20)
    if ! msg=$(compile_obj lib/sys_windows_start.mc "$split/winstart.obj"); then
        echo "FAIL winstart.obj (build: $msg)"
        exit 1
    fi
    echo "built winstart.obj (lib/sys_windows_start.mc)"

    for f in tests/*.mc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .mc)
        why=$(skip_reason "$f")
        if [ -n "$why" ]; then
            skipped="$skipped
  $name — $why"
            echo "$name — $why" >> "$split/skipped"
            continue
        fi
        build_one "$f" "$name" kernel32
    done

    # M38, then M45: the tests/mc/ cases that belong to EVERY target -- twelve
    # parameters, four of them on the stack, and a signed 32-bit integer. They
    # live in tests/mc/ because the frozen C seed refuses them (`at most 8
    # parameters`, `type expected`), not because they need anything Windows
    # cannot give: they link like every other test here.
    for f in tests/mc/0[89]*.mc; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .mc)
        why=$(skip_reason "$f")
        if [ -n "$why" ]; then
            skipped="$skipped
  $name — $why"
            echo "$name — $why" >> "$split/skipped"
        else
            build_one "$f" "$name" kernel32
        fi
    done

    # the cases with no runtime object next to them: the source includes
    # <sys_windows> itself, so it carries the wrappers and links with nothing but
    # winstart.obj and the import library. 071 and 072 are the M20 ABI tests and
    # are portable to both Windows architectures.
    for name in 070-kernel32 071-nested-args 072-six-params; do
        f="tests/windows/$name.mc"
        [ -f "$f" ] || continue
        why=$(skip_reason "$f")
        if [ -n "$why" ]; then
            skipped="$skipped
  $name — $why"
            echo "$name — $why" >> "$split/skipped"
            continue
        fi
        build_one "$f" "$name" self
    done

    # M45's 073 lives in tests/windows/ for the same reason 070-072 do -- it
    # names kernel32 entry points and nothing else does -- but it is a
    # `kernel32` link, not a `self` one. `self` means "the source includes
    # <sys_windows>", and 073 deliberately does not: it declares the three
    # entry points it uses itself. Without the layer next to it, winstart.obj
    # (which is in EVERY link line) has no win_setup/win_argv to call, and the
    # link fails with two undefined symbols -- which is exactly what both
    # Windows CI legs reported. Nothing in it collides with the layer's names.
    for name in 073-int-return; do
        f="tests/windows/$name.mc"
        [ -f "$f" ] || continue
        why=$(skip_reason "$f")
        if [ -n "$why" ]; then
            skipped="$skipped
  $name — $why"
            echo "$name — $why" >> "$split/skipped"
            continue
        fi
        build_one "$f" "$name" kernel32
    done

    # the default mode's own gate: EVERY object has to be LINKABLE, with the
    # link mode the manifest recorded for it. It used to be three of them, one
    # per mode, and that is how a test classified into the wrong mode reached
    # CI: an undefined symbol is a property of the pair (object, mode), so only
    # linking the pair can see it. The linker is here, so the rule applies --
    # what can run locally runs locally, and the CI leg is left with the one
    # thing it alone can do, which is EXECUTE.
    if [ "$mode" = "full" ] && [ -n "$linker" ]; then
        linked=0
        while read -r lname lmode; do
            [ -n "$lname" ] || continue
            [ -f "$split/$lname.obj" ] || continue
            if ! msg=$(link_one "$lname" "$lmode"); then
                echo "FAIL $lname (link: $msg)"; fails=$((fails + 1)); continue
            fi
            if [ -n "$readobj" ]; then
                case "$("$readobj" --file-headers "$split/$lname.exe" 2>&1)" in
                    *"$cmachine"*) ;;
                    *) echo "FAIL $lname (linked .exe is not $arch)"; fails=$((fails + 1)); continue ;;
                esac
            fi
            linked=$((linked + 1))
        done < "$split/manifest"
        echo "$linked executables linked with lld-link (not executed: no Windows host)"
    fi
fi

rm -rf "$tmp"
if [ "$mode" = "run" ]; then
    echo "$((total - fails))/$total tests passed on windows/$arch"
else
    echo "$((total - fails))/$total objects cross-compiled for windows/$arch in $split"
fi
if [ -n "$skipped" ]; then
    echo "skipped (not portable to this target):$skipped"
fi
[ "$fails" -eq 0 ]
