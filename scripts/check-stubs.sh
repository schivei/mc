#!/bin/sh
# check-stubs.sh [MC] — M25: the stub writers (src/stubs.mc). `mc` writes the
# import files a link needs from the program's own `extern`s, so a machine with
# a linker and nothing else can still link.
#
#   1. write     `mc sysroot stub` on tests/proj/stub.toml writes
#                build/stubs/libSystem.tbd and libsqlite3.tbd, each listing
#                exactly the symbols that program declares for that library, and
#                the libSystem one also carrying dyld_stub_binder -- which no
#                program declares and every lazily-bound image needs.
#   2. link+run  the same config built with a PATH that holds ONE program,
#                ld64.lld: no xcrun, no SDK, no -lSystem. The binary links, runs
#                and prints `sqlite ok`, and `otool -L` shows both install names.
#                This is M25's acceptance 1.
#   3. windows   the mirror: build/stubs/{kernel32,user32}.def, llvm-dlltool
#                over each, and lld-link resolving MessageBoxA against the
#                synthesized user32.lib. Cross-compiled, NOT executed -- there is
#                no Windows machine here (docs/ci.md).
#   4. linux     there is no stub writer for a static libc, and saying so is
#                the behaviour: `no stub writer for: linux`.
#
# Cases 2 and 3 skip themselves, with the reason, when their linker is missing;
# case 1 and case 4 need nothing but `mc`.
#
# Run from the repository root, as `make check-stubs` does.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

fails=0
total=0
tmp="${TMPDIR:-/tmp}/check-stubs.$$"
mkdir -p "$tmp/bin"
cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM

ok()   { printf '%s\n' "ok $1"; }
fail() { printf '%s\n' "FAIL $1"; shift; for l in "$@"; do printf '%s\n' "     $l"; done; fails=$((fails + 1)); }

# Homebrew keeps the LLVM binutils out of the default PATH, the same place
# scripts/sysroot-windows.sh looks for them.
findtool() {
    p=$(command -v "$1" 2>/dev/null)
    if [ -z "$p" ]; then
        for c in "/opt/homebrew/opt/llvm/bin/$1" "/usr/local/opt/llvm/bin/$1" /usr/lib/llvm-*/bin/"$1"; do
            if [ -x "$c" ]; then p="$c"; break; fi
        done
    fi
    [ -n "$p" ] && printf '%s\n' "$p"
}

stubs=tests/proj/build/stubs
rm -rf "$stubs"

# ---- 1. the .tbd writer ----
total=$((total + 1))
if ! out=$("$mc" sysroot stub tests/proj --config tests/proj/stub.toml 2>&1); then
    fail "mc sysroot stub" "$out"
elif [ ! -f "$stubs/libSystem.tbd" ] || [ ! -f "$stubs/libsqlite3.tbd" ]; then
    fail "mc sysroot stub" "expected libSystem.tbd and libsqlite3.tbd in $stubs" "$(ls "$stubs" 2>&1)"
else
    ok "mc sysroot stub -> $(echo "$out" | tr -d '\n')"
    for want in "tbd-version: 4" "install-name: '/usr/lib/libSystem.B.dylib'" \
                "_write" "dyld_stub_binder"; do
        total=$((total + 1))
        if grep -qF -- "$want" "$stubs/libSystem.tbd"; then
            ok "libSystem.tbd carries $want"
        else
            fail "libSystem.tbd" "missing: $want" "$(cat "$stubs/libSystem.tbd")"
        fi
    done
    # each symbol belongs to ONE library: the [externs] pattern moved the
    # sqlite3 names out of libSystem and nothing else went with them
    total=$((total + 1))
    if grep -q "sqlite3" "$stubs/libSystem.tbd"; then
        fail "libSystem.tbd" "a sqlite3 symbol leaked into it" "$(cat "$stubs/libSystem.tbd")"
    elif ! grep -qF -- "_sqlite3_libversion" "$stubs/libsqlite3.tbd"; then
        fail "libsqlite3.tbd" "missing _sqlite3_libversion" "$(cat "$stubs/libsqlite3.tbd")"
    elif ! grep -qF -- "install-name: '/usr/lib/libsqlite3.dylib'" "$stubs/libsqlite3.tbd"; then
        fail "libsqlite3.tbd" "wrong install-name" "$(cat "$stubs/libsqlite3.tbd")"
    else
        ok "the externs are split by library ([libs] + [externs], no #dylib)"
    fi
fi

# ---- 2. link with ld64.lld against the stubs, no xcrun on PATH, and RUN ----
lld=$(findtool ld64.lld)
if [ -z "$lld" ]; then
    echo "check-stubs: SKIPPED case 2 (ld64.lld not found; brew install lld)"
else
    total=$((total + 1))
    ln -sf "$lld" "$tmp/bin/ld64.lld"
    rm -f tests/proj/build/app-stub
    # PATH holds exactly one program. `xcrun` is not on it, so {sdk} could not
    # work even if the config asked for it -- which is the whole point.
    if ! out=$(PATH="$tmp/bin" "$mc" build tests/proj --config tests/proj/stub.toml 2>&1); then
        fail "stub.toml build" "$out"
    elif ! got=$(tests/proj/build/app-stub 2>&1); then
        fail "stub.toml run" "exit $?" "$got"
    elif [ "$got" != "sqlite ok" ]; then
        fail "stub.toml run" "stdout '$got', expected 'sqlite ok'"
    else
        ok "ld64.lld + build/stubs/*.tbd, PATH without xcrun -> runs, 'sqlite ok'"
        echo "$out" | sed 's/^/  /'
        if command -v otool > /dev/null 2>&1; then
            otool -L tests/proj/build/app-stub | sed 's/^/  /'
        fi
    fi
fi

# ---- 3. the .def writer, llvm-dlltool and lld-link ----
lldlink=$(findtool lld-link)
dlltool=$(findtool llvm-dlltool)
if [ -z "$lldlink" ] || [ -z "$dlltool" ]; then
    echo "check-stubs: SKIPPED case 3 (lld-link or llvm-dlltool not found; brew install lld llvm)"
else
    total=$((total + 1))
    ln -sf "$lldlink" "$tmp/bin/lld-link"
    ln -sf "$dlltool" "$tmp/bin/llvm-dlltool"
    rm -f tests/proj/build/win-stub.exe
    if ! out=$("$mc" --backend=coff-obj-arm64 lib/sys_windows_start.mc \
                     -o tests/proj/build/winstart.obj 2>&1); then
        fail "winstart.obj" "$out"
    elif ! out=$(PATH="$tmp/bin:$PATH" "$mc" build tests/proj \
                     --config tests/proj/stub-windows.toml 2>&1); then
        fail "stub-windows.toml build" "$out"
    elif [ ! -f tests/proj/build/win-stub.exe ]; then
        fail "stub-windows.toml build" "no win-stub.exe" "$out"
    elif ! grep -qF "MessageBoxA" "$stubs/user32.def"; then
        fail "user32.def" "$(cat "$stubs/user32.def" 2>&1)"
    else
        ok "lld-link + llvm-dlltool over the synthesized .def -> win-stub.exe"
        echo "$out" | sed 's/^/  /'
        readobj=$(findtool llvm-readobj)
        if [ -n "$readobj" ]; then
            "$readobj" --coff-imports tests/proj/build/win-stub.exe |
                grep -E "Name:|Symbol:" | sed 's/^/  /'
        fi
    fi
fi

# ---- 4. no stub writer for linux ----
total=$((total + 1))
out=$("$mc" sysroot stub tests/proj --config tests/proj/sysroot-cache.toml 2>&1)
rc=$?
case "$out" in
    *"no stub writer for"*"linux"*)
        if [ "$rc" = "1" ]; then
            ok "linux -> $out"
        else
            fail "linux stub" "exit $rc, expected 1"
        fi ;;
    *) fail "linux stub" "expected 'no stub writer for: linux'" "$out" ;;
esac

if [ "$fails" -eq 0 ]; then
    echo "$total/$total stub checks passed"
    exit 0
fi
echo "$fails stub check(s) failed"
exit 1
