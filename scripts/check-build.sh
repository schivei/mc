#!/bin/sh
# check-build.sh [MC] — acceptance criterion for M14's `mc build`.
#
# tests/proj/ is one program (app.mc + inc/db.mc) and three configs, so that
# every knob of the TOML is exercised by something that actually runs:
#
#   exe.toml   [include].paths + [libs]/[externs] + the built-in --exe backend
#              -> a signed binary that loads libsqlite3 by ordinal, no ld
#   link.toml  [linker] cmd/args with {out} {obj} {sdk} {libs}
#              -> mc writes the .o and `ld` produces the binary
#   obj.toml   kind = "obj" -> stop at the relocatable object
#   linux-exe.toml / linux-exe-x86.toml
#              M42: os = "linux" with NO [linker] and NO sysroot -> a dynamic
#              ELF64 ET_EXEC straight out of the compiler
#
# app.mc's `#include "db.mc"` only resolves through [include].paths: without it
# the build stops, which is the check for that key. `sqlite3_libversion` has no
# `#dylib` anywhere -- the library comes from [libs] + [externs].
#
# M25 adds four more over tests/proj/lin.mc and the three sysroot-*.toml: the
# resolution chain of src/sysroot.mc -- an explicit path that is not a sysroot
# (exit 2, naming the missing marker), the cache road, the populated explicit
# path (same object, byte for byte) and --sysroot-dir.
#
# M39.5 adds two configs over a TAUGHT compiler (tests/proj/noobj.mc, which
# registers `target("toy", "toy", 0, "macho-exe")` and nothing else), because a
# module is the only thing that can write a 0 into one of the two backend slots:
#
#   noobj.toml  kind = "obj" -> the object slot is 0: a diagnostic, at the
#               value's position (it used to be a null dereference)
#   toy.toml    the same project with the fix the message asks for,
#               kind = "exe" -> the exe slot is `macho-exe`, and it runs
#
# The post-M41 review adds three more taught compilers, for the SINGLE-FILE CLI,
# which reaches the same registry through src/cli.mc: tests/proj/mc-noexe.mc
# (the exe slot at 0, `--exe` refused), mc-objswap.mc (the host pair
# re-registered with another object backend, which `mc x.mc -o x.o` has to
# honour) and mc-noobjhost.mc (the object slot at 0, refused with the advice
# `--exe`, which the same compiler then carries out).
#
# The post-M42 patch adds THE LINUX MATRIX, both roads (`mc build` keys and the
# single-file CLI's flags), over tests/proj/lin.mc (imports nothing) and
# tests/proj/lin-libc.mc (imports `write`): libc gnu/musl/none against link
# dynamic/static, each cell either built and inspected or refused with the exact
# message. It needs no Docker -- nothing here is executed, only read.
#
# The last section checks the diagnostics: a foreign [target].os, os = "windows"
# with no [linker] (M19), a missing key and a bad [project].kind have to come
# out with file:line:col and exit 1 -- and the same two [target] messages,
# byte for byte, from `mc sysroot stub`, which reaches the same resolution
# without going through a compile (M39.5).
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

dir="tests/proj"
tmp="${TMPDIR:-/tmp}/check-build.$$"
# Under Git Bash on Windows, MSYS hands TMPDIR to this shell in /d/... form, a
# path the native mc cannot open; cygpath -m gives D:/... which both accept.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
mkdir -p "$tmp"
fails=0
total=0

want_exit=$(sed -n 's|^// expect-exit: *||p' "$dir/app.mc" | head -1)
want_out=$(sed -n 's|^// expect-stdout: *||p' "$dir/app.mc" | head -1)

ok()   { echo "ok $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

# runs a binary and compares it against app.mc's header
run_check() {
    got_out=$("$1" 2>/dev/null)
    got_exit=$?
    if [ "$got_exit" != "$want_exit" ]; then
        fail "$2" "exit $got_exit, expected $want_exit"; return 1
    fi
    if [ "$got_out" != "$want_out" ]; then
        fail "$2" "stdout '$got_out', expected '$want_out'"; return 1
    fi
    ok "$2"
}

rm -rf "$dir/build"

# ---- exe.toml: the direct executable ----
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/exe.toml" > "$tmp/o" 2>&1; then
    fail "exe.toml" "$(cat "$tmp/o")"
else
    sed 's|^|  |' "$tmp/o"
    run_check "$dir/build/app-exe" "exe.toml"
fi

total=$((total + 1))
if ! msg=$(codesign --verify --verbose=2 "$dir/build/app-exe" 2>&1); then
    fail "exe.toml signature" "$msg"
else
    ok "exe.toml signature"
fi

total=$((total + 1))
if ! otool -L "$dir/build/app-exe" | grep -q libsqlite3; then
    fail "exe.toml [libs]" "libsqlite3 not in otool -L (so [libs]/[externs] did not apply)"
else
    ok "exe.toml [libs] -> libsqlite3 bound by ordinal"
fi

# ---- link.toml: external linker with the four placeholders ----
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/link.toml" > "$tmp/o" 2>&1; then
    fail "link.toml" "$(cat "$tmp/o")"
else
    sed 's|^|  |' "$tmp/o"
    run_check "$dir/build/app-ld" "link.toml"
fi

total=$((total + 1))
if [ -e "$dir/build/app-ld.sdk" ]; then
    fail "link.toml {sdk}" "the temporary file build/app-ld.sdk was left behind"
else
    ok "link.toml {sdk} temporary removed"
fi

# ---- obj.toml: kind = "obj" ----
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/obj.toml" > "$tmp/o" 2>&1; then
    fail "obj.toml" "$(cat "$tmp/o")"
else
    sed 's|^|  |' "$tmp/o"
    if ! nm -m "$dir/build/app.o" 2>/dev/null | grep -q 'undefined.*_sqlite3_libversion'; then
        fail "obj.toml" "_sqlite3_libversion is not undefined in build/app.o"
    else
        ok "obj.toml"
    fi
fi

# ---- M39.5: a target a module registered, with one of the two slots at 0 ----
# tests/proj/noobj.mc is the whole taught compiler: `target("toy", "toy", 0,
# "macho-exe")`. The pair IS registered -- what is missing is the object
# backend, which only a module can express, since every target src/main.mc
# registers has one. Asking for that role used to hand the 0 to backend_find(),
# whose str_eq dereferenced it: the child died of SIGSEGV with the `compile
# x -> y` step line as its last word (exit 139, seen through drv_teach as
# exit 1). Now it is the message below, and toy.toml proves the advice in it is
# a build this same compiler can do.
total=$((total + 1))
"$mc" build "$dir" --config "$dir/noobj.toml" > "$tmp/o" 2>&1
rc=$?
got=$(tail -1 "$tmp/o")
want="$dir/noobj.toml:19:8: toy/toy has no object backend: use kind = \"exe\": target.os"
if [ "$rc" != "1" ]; then
    fail "noobj.toml" "exit $rc, expected 1"
elif [ "$got" != "$want" ]; then
    fail "noobj.toml" "got '$got', expected '$want'"
else
    ok "noobj.toml -> the object slot is 0, and it is a diagnostic"
    echo "  $got"
fi

total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/toy.toml" > "$tmp/o" 2>&1; then
    fail "toy.toml" "$(cat "$tmp/o")"
else
    sed 's|^|  |' "$tmp/o"
    run_check "$dir/build/app-toy" "toy.toml -> kind = \"exe\" through the taught target"
fi

# ---- post-M41: `--exe` resolves the HOST's exe slot, and a 0 there is refused ----
# The third entry point into the same registry, and the reason it belongs in
# this script: `mc build` (above), `mc sysroot stub` (below) and the single-file
# `--exe` all have to reach the same registration and say the same thing about
# it. Until the post-M41 review batch `--exe` was the literal name `macho-exe`
# in src/cli.mc, so a Linux- or Windows-hosted mc answered it with a Mach-O
# binary its own kernel refuses with ENOEXEC (reproduced with
# build/mc-linux-arm64 under Docker).
# The host this script runs on always has an exe backend, so the empty slot is
# reached the way M39.5 reached the empty object one -- a taught compiler,
# tests/proj/mc-noexe.mc, which re-registers the host pair with that slot at 0.
os=$("$mc" --host | sed -n 's|^os ||p')
noexe="$tmp/mc-noexe"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) noexe="$noexe.exe" ;; esac

total=$((total + 1))
if ! msg=$(scripts/build-exe.sh "$mc" "$noexe" "$dir/mc-noexe.mc" 2>&1); then
    fail "mc-noexe.mc" "$msg"
else
    ok "mc-noexe.mc -> a compiler whose host target has no exe backend"

    # the refusal: exit 1 and the message, byte for byte
    total=$((total + 1))
    "$noexe" --exe tests/001-return42.mc -o "$tmp/noexe-out" > "$tmp/o" 2>&1
    rc=$?
    got=$(tail -1 "$tmp/o")
    want="mc: $os requires a linker: there is no direct executable"
    if [ "$rc" != "1" ]; then
        fail "--exe with an empty exe slot" "exit $rc, expected 1"
    elif [ "$got" != "$want" ]; then
        fail "--exe with an empty exe slot" "got '$got', expected '$want'"
    elif [ -e "$tmp/noexe-out" ]; then
        fail "--exe with an empty exe slot" "it wrote $tmp/noexe-out anyway"
    else
        ok "--exe with an empty exe slot -> a diagnostic, and no file written"
        echo "  $got"
    fi

    # and the object road of the SAME compiler is untouched: the refusal is
    # about the exe slot, not about the target being unusable.
    total=$((total + 1))
    if ! msg=$("$noexe" tests/001-return42.mc -o "$tmp/noexe.o" 2>&1); then
        fail "the object road of the same compiler" "$msg"
    else
        ok "the object road of the same compiler still writes an object"
    fi
fi

# ---- post-M41 review: the OBJECT slot, from the single-file CLI ----
# The default object backend is the obj slot of the host's target(), and
# src/cli.mc used to resolve it while the flags were being read -- before
# user_init(). Two consequences, one case each, and the module is the only way
# to reach either, exactly as in the two blocks above.
arch=$("$mc" --host | sed -n 's|^arch ||p')
magic() { od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n'; }

# (1) a module that re-registers the host pair with a DIFFERENT object backend
# was silently ignored: `mc x.mc -o x.o` kept writing the format the compiler
# was born with. tests/proj/objswap.mc asks for a format the host does not use,
# so the first four bytes of the object are the whole assertion.
want_magic=7f454c46                      # ELF, what objswap.mc asks for
case "$os" in linux) want_magic=cffaedfe ;; esac   # there it asks for Mach-O
objswap="$tmp/mc-objswap"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) objswap="$objswap.exe" ;; esac
total=$((total + 1))
if ! msg=$(scripts/build-exe.sh "$mc" "$objswap" "$dir/mc-objswap.mc" 2>&1); then
    fail "mc-objswap.mc" "$msg"
else
    ok "mc-objswap.mc -> a compiler that re-registers the host's object backend"
    total=$((total + 1))
    rm -f "$tmp/objswap.o"
    if ! msg=$("$objswap" tests/001-return42.mc -o "$tmp/objswap.o" 2>&1); then
        fail "the re-registered object backend" "$msg"
    elif [ "$(magic "$tmp/objswap.o")" != "$want_magic" ]; then
        fail "the re-registered object backend" \
             "magic $(magic "$tmp/objswap.o"), expected $want_magic"
    else
        ok "mc x.mc -o x.o honours the module's target() (magic $want_magic)"
    fi
fi

# (2) and a module that leaves that slot at 0 -- a registration, not an omission
# -- must be refused instead of handing the 0 to backend_find(), whose str_eq
# dereferences it. Reproduced with a compiler that registers the pair before
# mc_main (a recreated compiler, docs/guide/98): exit 139, SIGSEGV, no message.
noobjh="$tmp/mc-noobjhost"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) noobjh="$noobjh.exe" ;; esac
total=$((total + 1))
if ! msg=$(scripts/build-exe.sh "$mc" "$noobjh" "$dir/mc-noobjhost.mc" 2>&1); then
    fail "mc-noobjhost.mc" "$msg"
else
    ok "mc-noobjhost.mc -> a compiler whose host target has no object backend"

    total=$((total + 1))
    rm -f "$tmp/noobjhost.o"
    "$noobjh" tests/001-return42.mc -o "$tmp/noobjhost.o" > "$tmp/o" 2>&1
    rc=$?
    got=$(tail -1 "$tmp/o")
    want="mc: $os/$arch has no object backend: use --exe"
    if [ "$rc" != "1" ]; then
        fail "the object road with an empty object slot" "exit $rc, expected 1"
    elif [ "$got" != "$want" ]; then
        fail "the object road with an empty object slot" "got '$got', expected '$want'"
    elif [ -e "$tmp/noobjhost.o" ]; then
        fail "the object road with an empty object slot" "it wrote $tmp/noobjhost.o anyway"
    else
        ok "an empty object slot -> a diagnostic, and no file written"
        echo "  $got"
    fi

    # and the advice in it: `--exe` on the same compiler. On a host whose exe
    # slot is 0 as well (linux, windows) there is no direct executable at all,
    # and the only right answer is the OTHER message -- asserted, not skipped.
    total=$((total + 1))
    rm -f "$tmp/noobjhost-exe"
    "$noobjh" --exe tests/001-return42.mc -o "$tmp/noobjhost-exe" > "$tmp/o" 2>&1
    rc=$?
    got=$(tail -1 "$tmp/o")
    if [ "$rc" = "0" ]; then
        run_check_exit=0
        "$tmp/noobjhost-exe"; run_check_exit=$?
        if [ "$run_check_exit" = "42" ]; then
            ok "the advice works: --exe on the same compiler runs (exit 42)"
        else
            fail "the advice (--exe)" "the binary exited $run_check_exit, expected 42"
        fi
    elif [ "$got" = "mc: $os requires a linker: there is no direct executable" ]; then
        ok "no direct executable on this host either, and it says so"
        echo "  $got"
    else
        fail "the advice (--exe)" "exit $rc, last line '$got'"
    fi
fi

# ---- M25: the [sysroot] resolution chain (src/sysroot.mc) ----
# Three cases over tests/proj/lin.mc, a linux/aarch64 program whose [linker] is
# `echo`, so the resolved directory comes out on stdout and nothing here needs
# ld.lld, musl or Docker.
#
#   sysroot-bad.toml    [sysroot].path at a directory that is not a sysroot ->
#                       exit 2, and the message names the missing marker
#   sysroot-cache.toml  no [sysroot].path: the chain falls through the probe
#                       (skipped -- the host is not linux/aarch64) to the cache
#   sysroot-ok.toml     [sysroot].path at a populated directory: what an mc.toml
#                       written before M25 says, still doing what it did
mkdir -p "$dir/build/sysroots/linux-aarch64"
: > "$dir/build/sysroots/linux-aarch64/crt1.o"
: > "$dir/build/sysroots/linux-aarch64/libc.a"

total=$((total + 1))
"$mc" build "$dir" --config "$dir/sysroot-bad.toml" > "$tmp/o" 2>&1
rc=$?
if [ "$rc" != "2" ]; then
    fail "sysroot-bad.toml" "exit $rc, expected 2"
elif ! grep -q "no sysroot for linux-aarch64" "$tmp/o"; then
    fail "sysroot-bad.toml" "no 'no sysroot for linux-aarch64' in: $(cat "$tmp/o")"
elif ! grep -q "tests/proj/inc (no crt1.o)" "$tmp/o"; then
    fail "sysroot-bad.toml" "the message does not name the missing marker: $(cat "$tmp/o")"
else
    ok "sysroot-bad.toml -> exit 2, names the missing marker"
    sed -n '/no sysroot/,$p' "$tmp/o" | sed 's|^|  |'
fi

total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/sysroot-cache.toml" > "$tmp/o" 2>&1; then
    fail "sysroot-cache.toml" "$(cat "$tmp/o")"
elif ! grep -q "sysroot=$dir/build/sysroots/linux-aarch64 " "$tmp/o"; then
    fail "sysroot-cache.toml" "{sysroot} did not resolve to the cache: $(cat "$tmp/o")"
else
    ok "sysroot-cache.toml -> [sysroot].cache/<os>-<arch>"
    sed 's|^|  |' "$tmp/o"
fi

total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/sysroot-ok.toml" > "$tmp/o" 2>&1; then
    fail "sysroot-ok.toml" "$(cat "$tmp/o")"
elif ! grep -q "sysroot=$dir/build/sysroots/linux-aarch64 " "$tmp/o"; then
    fail "sysroot-ok.toml" "{sysroot} did not resolve to [sysroot].path: $(cat "$tmp/o")"
elif ! cmp -s "$dir/build/lin-ok.o" "$dir/build/lin-cache.o"; then
    fail "sysroot-ok.toml" "the object differs from the one the cache road wrote"
else
    ok "sysroot-ok.toml -> [sysroot].path, same object byte for byte"
fi

# --sysroot-dir names the directory ITSELF, and wins over [sysroot].cache
total=$((total + 1))
if ! "$mc" build "$dir" --config "$dir/sysroot-cache.toml" \
        --sysroot-dir "$dir/build/sysroots/linux-aarch64" > "$tmp/o" 2>&1; then
    fail "--sysroot-dir" "$(cat "$tmp/o")"
elif ! grep -q "sysroot=$dir/build/sysroots/linux-aarch64 " "$tmp/o"; then
    fail "--sysroot-dir" "not honoured: $(cat "$tmp/o")"
else
    ok "--sysroot-dir DIR"
fi

# ---- M42: os = "linux" with no [linker] and no sysroot ----
# Until M42 these two configs were the diagnostic `linux requires [linker]`.
# The executable slot of both Linux targets is filled now, so the same six lines
# write a dynamic ELF64 ET_EXEC with nothing external involved -- no ld.lld, no
# crt1.o, no libc.a. Only the header is read here (this script has no Docker);
# running the result is scripts/test-linux.sh --exe.
#
# e_ident[4] is the class (2 = ELF64), e_type is at 16 (2 = ET_EXEC) and
# e_machine at 18 (183 = AArch64, 62 = x86-64) -- read with od, so the check
# needs no LLVM either.
elf_hdr() { od -An -tu1 -j "$2" -N "$3" -v "$1" | tr -s ' ' | sed 's/^ //;s/ $//'; }

for a in aarch64:linux-exe.toml:lin-exe:183 x86_64:linux-exe-x86.toml:lin-exe-x86:62; do
    arch=${a%%:*}; rest=${a#*:}
    cfg=${rest%%:*}; rest=${rest#*:}
    out=${rest%%:*}; mach=${rest##*:}
    total=$((total + 1))
    rm -f "$dir/build/$out"
    if ! "$mc" build "$dir" --config "$dir/$cfg" > "$tmp/o" 2>&1; then
        fail "$cfg" "$(cat "$tmp/o")"
    elif [ ! -x "$dir/build/$out" ]; then
        fail "$cfg" "build/$out was not written"
    elif [ "$(elf_hdr "$dir/build/$out" 0 5)" != "127 69 76 70 2" ]; then
        fail "$cfg" "not an ELF64 image: $(elf_hdr "$dir/build/$out" 0 5)"
    elif [ "$(elf_hdr "$dir/build/$out" 16 2)" != "2 0" ]; then
        fail "$cfg" "e_type is not ET_EXEC: $(elf_hdr "$dir/build/$out" 16 2)"
    elif [ "$(elf_hdr "$dir/build/$out" 18 1)" != "$mach" ]; then
        fail "$cfg" "e_machine is not $mach: $(elf_hdr "$dir/build/$out" 18 1)"
    else
        ok "$cfg -> ELF64 ET_EXEC for linux/$arch, no [linker] and no sysroot"
        sed 's|^|  |' "$tmp/o"
    fi
done

# determinism: the same source built twice is the same file
total=$((total + 1))
cp "$dir/build/lin-exe" "$tmp/lin-exe.1"
if ! "$mc" build "$dir" --config "$dir/linux-exe.toml" > "$tmp/o" 2>&1; then
    fail "linux-exe.toml twice" "$(cat "$tmp/o")"
elif ! cmp -s "$tmp/lin-exe.1" "$dir/build/lin-exe"; then
    fail "linux-exe.toml twice" "two builds of the same source differ"
else
    ok "linux-exe.toml twice -> byte for byte the same executable"
fi

# ---- the Linux matrix: libc (gnu | musl | none) x link (dynamic | static) ----
# The two axes of a Linux target, in the one vocabulary both roads speak
# (docs/build.md § Linux targets). Nothing is executed here -- these are
# cross-built images and this machine may be neither Linux nor this
# architecture -- so every cell is read out of the file.
#
# llvm-readelf is how a program header is read; without it the three assertions
# that need one say so and are skipped, exactly as scripts/test-linux.sh does
# with its stack checks. They are properties of the file, not of the program's
# behaviour, and must not turn a green suite red on a machine with no LLVM.
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
readelf=$(findtool llvm-readelf)
[ -n "$readelf" ] || readelf=$(command -v readelf 2>/dev/null)

# builds one cell and checks the loader path and the DT_NEEDED soname in it
# name, config, output, interpreter, soname
dyn_cell() {
    total=$((total + 1))
    rm -f "$dir/$3"
    if ! "$mc" build "$dir" --config "$dir/$2" > "$tmp/o" 2>&1; then
        fail "$1" "$(cat "$tmp/o")"
        return
    fi
    if [ -z "$readelf" ]; then
        ok "$1 (built; no llvm-readelf here, headers not read)"
        return
    fi
    "$readelf" -l -d "$dir/$3" > "$tmp/e" 2>&1
    if ! grep -q "Requesting program interpreter: $4" "$tmp/e"; then
        fail "$1" "PT_INTERP is not $4: $(grep -i interpreter "$tmp/e")"
    elif ! grep -qF "Shared library: [$5]" "$tmp/e"; then
        fail "$1" "DT_NEEDED is not $5: $(grep -i 'Shared library' "$tmp/e")"
    else
        ok "$1 -> PT_INTERP $4, DT_NEEDED $5"
    fi
}

dyn_cell "matrix musl/dynamic (the default, no key)" linux-musl.toml \
    build/lin-musl /lib/ld-musl-aarch64.so.1 libc.so
dyn_cell "matrix gnu/dynamic (libc = \"gnu\")" linux-gnu.toml \
    build/lin-gnu /lib/ld-linux-aarch64.so.1 libc.so.6

# the static cell: a program that imports nothing, asked for explicitly. No
# PT_INTERP, no PT_DYNAMIC, no loader involved at run time at all.
total=$((total + 1))
rm -f "$dir/build/lin-static"
if ! "$mc" build "$dir" --config "$dir/linux-static.toml" > "$tmp/o" 2>&1; then
    fail "matrix none/static (link = \"static\")" "$(cat "$tmp/o")"
elif [ -z "$readelf" ]; then
    ok "matrix none/static (built; no llvm-readelf here, headers not read)"
else
    "$readelf" -l "$dir/build/lin-static" > "$tmp/e" 2>&1
    if grep -q "INTERP" "$tmp/e"; then
        fail "matrix none/static" "the image has a PT_INTERP"
    elif grep -q "DYNAMIC" "$tmp/e"; then
        fail "matrix none/static" "the image has a PT_DYNAMIC"
    else
        ok "matrix none/static -> no PT_INTERP and no PT_DYNAMIC"
    fi
fi

# the fourth cell: static WITH a libc, which is the one mc cannot write and the
# one [linker] is still here for. The key does not refuse there -- it describes
# the link the external linker is asked to make, and the driver takes the object
# road it has always taken. `echo` stands in for ld.lld, so this needs nothing
# installed; the object is what is being checked, and the spawn.
total=$((total + 1))
rm -f "$dir/build/lin-static-linked.o"
if ! "$mc" build "$dir" --config "$dir/linux-static-linker.toml" > "$tmp/o" 2>&1; then
    fail "matrix gnu|musl/static through [linker]" "$(cat "$tmp/o")"
elif [ ! -f "$dir/build/lin-static-linked.o" ]; then
    fail "matrix gnu|musl/static through [linker]" "no object was written"
elif ! grep -q -- "-static -o " "$tmp/o"; then
    fail "matrix gnu|musl/static through [linker]" "the linker was not spawned: $(cat "$tmp/o")"
else
    ok "matrix gnu|musl/static through [linker] -> object + linker, no refusal"
    sed 's|^|  |' "$tmp/o"
fi

# ---- the same two axes from the single-file CLI ----
# --libc=, --interp= and --link= mirror the three keys exactly, so that a source
# does not have to become a project to say which libc it is for. --backend= is
# what makes this reachable from a macOS host: it names the writer, and the
# flags then describe the image that writer produces.
cli_case() {                             # name, flags, output, pattern
    total=$((total + 1))
    rm -f "$tmp/$3"
    if ! "$mc" --backend=elf-exe $2 "$dir/lin-libc.mc" -o "$tmp/$3" > "$tmp/o" 2>&1; then
        fail "$1" "$(cat "$tmp/o")"
    elif [ -z "$readelf" ]; then
        ok "$1 (built; no llvm-readelf here, headers not read)"
    elif ! "$readelf" -l -d "$tmp/$3" 2>&1 | grep -qF "$4"; then
        fail "$1" "no '$4' in the image"
    else
        ok "$1 -> $4"
    fi
}

cli_case "cli --libc=gnu" --libc=gnu cli-gnu "Shared library: [libc.so.6]"
cli_case "cli --libc=musl" --libc=musl cli-musl "Shared library: [libc.so]"
cli_case "cli --interp=/opt/ld.so overrides the family" \
    "--libc=gnu --interp=/opt/ld.so" cli-ov "interpreter: /opt/ld.so"
cli_case "cli --libc=gnu --libc=musl (the last one wins)" \
    "--libc=gnu --libc=musl" cli-last "Shared library: [libc.so]"

# the refusals, on the CLI road: no config, so no file:line:col -- the same
# message with `mc: ` in front, which is what die() writes.
cli_refuse() {                           # name, flags, expected last line
    total=$((total + 1))
    "$mc" --backend=elf-exe $2 "$dir/lin-libc.mc" -o "$tmp/refused" > "$tmp/o" 2>&1
    rc=$?
    got=$(tail -1 "$tmp/o")
    if [ "$rc" != "1" ]; then
        fail "$1" "exit $rc, expected 1"
    elif [ "$got" != "$3" ]; then
        fail "$1" "got '$got', expected '$3'"
    else
        ok "$1"
        echo "  $got"
    fi
}

cli_refuse "cli --link=static with an import" --link=static \
    "mc: static link with a libc needs [linker]: see docs/build.md -- static linking (M46)"
cli_refuse "cli --libc=uclibc" --libc=uclibc "mc: --libc must be gnu or musl: uclibc"
cli_refuse "cli --link=half" --link=half "mc: --link must be dynamic or static: half"

# and the flag on a host that is not Linux, with no --backend= to say otherwise:
# the single-file CLI writes for the HOST there, and a --libc it would then
# ignore is worse than a --libc it refuses. On a Linux host the flag is exactly
# what it is for, so the case only exists off Linux.
if [ "$("$mc" --host | sed -n 's|^os ||p')" != "linux" ]; then
    total=$((total + 1))
    "$mc" --exe --libc=gnu "$dir/lin-libc.mc" -o "$tmp/refused" > "$tmp/o" 2>&1
    rc=$?
    got=$(tail -1 "$tmp/o")
    if [ "$rc" != "1" ]; then
        fail "cli --libc on a non-linux host" "exit $rc, expected 1"
    elif [ "$got" != "mc: --libc applies to a linux target" ]; then
        fail "cli --libc on a non-linux host" "got '$got'"
    else
        ok "cli --libc on a non-linux host"
        echo "  $got"
    fi
fi

# ---- diagnostics ----
# name, config path, config body, expected LAST line of output (CFG = config path).
# The error is always the last thing printed: a step line may come first.
#
# M39.5: the three [target] cases below write their config into tests/proj/build
# and name the entry as `../app.mc`, so the source EXISTS. Since M39.5 the
# (os, arch) pair is resolved after `user_init()` -- late enough for a target a
# module registered to count -- which is after the entry has been opened and
# lexed. With an unreachable entry the first error would be `cannot open`, and
# the [target] diagnostic under test would never be reached. The messages
# themselves are unchanged, and so is the rule that the error is the last line.
#
# `diag_cmd` is the subcommand under test: `build` for all of them but the two
# `sysroot stub` cases at the end, which have to produce the SAME two messages.
# It is deliberately unquoted below -- `sysroot stub` is two arguments.
diag_cmd="build"
diag() {
    total=$((total + 1))
    printf '%s' "$3" > "$2"
    "$mc" $diag_cmd "$dir" --config "$2" > "$tmp/o" 2>&1
    rc=$?
    got=$(tail -1 "$tmp/o")
    want=$(printf '%s' "$4" | sed "s|CFG|$2|")
    if [ "$rc" != "1" ]; then
        fail "$1" "exit $rc, expected 1"
    elif [ "$got" != "$want" ]; then
        fail "$1" "got '$got', expected '$want'"
    else
        ok "$1"
        echo "  $got"
    fi
}

diag "diag [target].os" "$dir/build/d.toml" \
    '[project]
entry = "../app.mc"
out   = "build/x"

[target]
os = "haiku"
' \
    'CFG:6:6: only macos, linux and windows (see docs/build.md): target.os'

# the other half of the pair: a known os with an architecture it was never
# registered with. The list is the one the registry holds FOR THAT OS, which is
# why it is `only aarch64` and not the full set.
diag "diag [target].arch" "$dir/build/d.toml" \
    '[project]
entry = "../app.mc"
out   = "build/x"

[target]
os   = "macos"
arch = "sparc"
' \
    'CFG:7:8: only aarch64 (see docs/build.md): target.arch'

# M19: the same for Windows -- valid os, no direct executable, and the message
# names the operating system the file asked for.
diag "diag [target].os windows without [linker]" "$dir/build/d.toml" \
    '[project]
entry = "../app.mc"
out   = "build/x"

[target]
os = "windows"
' \
    'CFG:6:6: windows requires [linker]: there is no direct executable: target.os'

# post-M42 patch: the refused cells of the matrix. `link = "static"` against a
# program that imports a libc symbol is the important one -- it is the cell mc
# cannot write, and the message names the road (an external linker) and the
# milestone that would remove the need for it. The position is the KEY's, and
# the check that it is the key's is that the refusal comes from the WRITER,
# which has never heard of TOML (src/objmodel.mc, dyn_die).
diag "diag [target].link static with an import" "$dir/build/d.toml" \
    '[project]
entry = "../lin-libc.mc"
out   = "build/x"

[target]
os   = "linux"
arch = "aarch64"
link = "static"
' \
    'CFG:8:8: static link with a libc needs [linker]: see docs/build.md -- static linking (M46): target.link'

# a soname where a family belongs -- the shape M42 accepted, refused now, with
# the migration in the message itself
diag "diag [target].libc as a soname" "$dir/build/d.toml" \
    '[project]
entry = "../lin-libc.mc"
out   = "build/x"

[target]
os   = "linux"
libc = "libc.so.6"
' \
    'CFG:7:8: libc must be gnu or musl (a soname is not a value: gnu is libc.so.6, musl is libc.so): target.libc'

diag "diag [target].link bad value" "$dir/build/d.toml" \
    '[project]
entry = "../lin-libc.mc"
out   = "build/x"

[target]
os   = "linux"
link = "half"
' \
    'CFG:7:8: link must be dynamic or static: target.link'

# the three keys describe a Linux dynamic image and there is no such thing on
# another target: a Mach-O names /usr/lib/dyld and libSystem and reads none of
# them. Ignored would be worse than refused.
diag "diag [target].libc off linux" "$dir/build/d.toml" \
    '[project]
entry = "../lin-libc.mc"
out   = "build/x"

[target]
os   = "macos"
libc = "gnu"
' \
    'CFG:7:8: libc applies to a linux target: target.libc'

diag "diag missing project.entry" "$tmp/d.toml" \
    '[project]
out = "build/x"
' \
    'CFG: missing key: project.entry'

diag "diag bad project.kind" "$tmp/d.toml" \
    '[project]
entry = "app.mc"
out   = "build/x"
kind  = "lib"
' \
    'CFG:4:9: must be exe or obj: project.kind'

# the same program with no [include].paths: `#include "db.mc"` has nowhere left to
# resolve. The config goes inside build/ so that `entry` still points at app.mc.
diag "diag [include].paths missing" "$dir/build/noinc.toml" \
    '[project]
entry = "../app.mc"
out   = "noinc-out"
' \
    'mc: cannot open: tests/proj/db.mc'

# M39.5: `mc sysroot stub` is the front half of a build -- it parses the entry
# and writes one import file per library, with no backend anywhere in sight. It
# reaches drv_parse without going through drv_compile, so until this batch the
# [target] resolution never ran on that path and a foreign os came out of the
# stub writer as `no stub writer for: haiku: a static libc is code, not a name
# list`. The two cases below are the same two configs as the [target] cases
# above, through the other subcommand: same message, same file:line:col, same
# exit 1.
diag_cmd="sysroot stub"

diag "diag stub [target].os" "$dir/build/d.toml" \
    '[project]
entry = "../app.mc"
out   = "build/x"

[target]
os = "haiku"
' \
    'CFG:6:6: only macos, linux and windows (see docs/build.md): target.os'

diag "diag stub [target].arch" "$dir/build/d.toml" \
    '[project]
entry = "../app.mc"
out   = "build/x"

[target]
os   = "macos"
arch = "sparc"
' \
    'CFG:7:8: only aarch64 (see docs/build.md): target.arch'

diag_cmd="build"

rm -rf "$tmp"
echo "$((total - fails))/$total mc build checks passed"
[ "$fails" -eq 0 ]
