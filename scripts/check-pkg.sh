#!/bin/sh
# check-pkg.sh [MC] — the acceptance criteria of M44 step 2 that are reachable
# without a fetcher: the resolution model, the lock, the tree hash, the closure
# rule and the [package].files boundary. Nothing here touches the network, and
# a `curl`/`wget` shim that FAILS if it is invoked sits on PATH for the whole
# run -- `mc build` must be proved never to download, not just documented
# (M44 § Acceptance, architect's addition (a)).
#
# The fixtures are tests/pkg/:
#
#   src/mathx-1.0.0   a library, no dependencies
#   src/geo-1.2.0     a library that depends on mathx; `lib = "geo.mc"`
#   src/geo-1.0.0     the version the lock does NOT name
#   src/teach-1.0.0   a COMPILER-MODULE package (`unless`, through syntax_stmt)
#   src/bad-1.0.0     reads one file above its own tree, twice over
#   src/float-1.3.0   a copy of lib/float.mc + float_rt.mc where putf64 writes
#                     a `!`: a registry package carrying a BUNDLED name (§ A5)
#   app/ app-float/ app-bad/ app-extra/ std/    the consumers
#
# `<libs>` is populated from those trees by this script, with one cache manifest
# per installed version -- the file `mc pkg sync` will write in step 3, produced
# here by scripts/pkg-hash.sh, which is a SECOND implementation of the tree hash
# in shell. Every lock hash checked into tests/pkg is compared against it, so a
# divergence between src/deps.mc and the specification is a red `make check`.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi
here=$(pwd)
mc=$(cd "$(dirname "$mc")" && pwd)/$(basename "$mc")

tmp="${TMPDIR:-/tmp}/check-pkg.$$"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
rm -rf "$tmp"
mkdir -p "$tmp/libs" "$tmp/libs2" "$tmp/empty" "$tmp/bin" "$tmp/out"
cleanup() {
    rm -rf "$tmp"
    rm -rf "$here/tests/pkg/app/build" "$here/tests/pkg/app/deps" \
           "$here/tests/pkg/app-float/build" "$here/tests/pkg/app-bad/build" \
           "$here/tests/pkg/app-extra/build" "$here/tests/pkg/std/build"
}
trap cleanup EXIT INT TERM

fails=0
total=0
ok()   { total=$((total + 1)); echo "ok $1"; }
fail() { total=$((total + 1)); echo "FAIL $1: $2"; fails=$((fails + 1)); }

# ---- the no-network shim ----
# Every downloader mc knows about (src/host_*.mc host_downloader/_alt), plus the
# archive tool, refusing loudly. Anything that reaches for the network in this
# script fails the run instead of silently succeeding on a developer's machine.
for t in curl wget tar; do
    cat > "$tmp/bin/$t" <<EOF
#!/bin/sh
echo "check-pkg: $t was invoked -- mc build must never download" >&2
exit 97
EOF
    chmod +x "$tmp/bin/$t"
done
PATH="$tmp/bin:$PATH"
export PATH

# ---- <libs>, populated by hand: this is what `mc pkg sync` will write ----
install_pkg() {                       # install_pkg SRCDIR NAME VERSION LIBSDIR
    d="$4/$2/v$3"
    mkdir -p "$d"
    cp -R "$1/." "$d/"
    {
        echo '[source]'
        echo "name = \"$2\""
        echo "version = \"$3\""
        echo "sha256 = \"$(sh scripts/pkg-hash.sh "$1")\""
        sh scripts/pkg-hash.sh --files "$1" | while read -r h f; do
            echo
            echo '[[file]]'
            echo "path = \"$f\""
            echo "sha256 = \"$h\""
        done
    } > "$4/$2/v$3.toml"
}

for L in "$tmp/libs" "$tmp/libs2"; do
    install_pkg tests/pkg/src/mathx-1.0.0 mathx 1.0.0 "$L"
    install_pkg tests/pkg/src/geo-1.2.0   geo   1.2.0 "$L"
    install_pkg tests/pkg/src/teach-1.0.0 teach 1.0.0 "$L"
    install_pkg tests/pkg/src/bad-1.0.0   bad   1.0.0 "$L"
    install_pkg tests/pkg/src/float-1.3.0 float 1.3.0 "$L"
done
# the version no lock names, in ONE of the two installations only
install_pkg tests/pkg/src/geo-1.0.0 geo 1.0.0 "$tmp/libs"
cp tests/pkg/app-bad/outside.mc "$tmp/libs/outside.mc"
cp tests/pkg/app-bad/outside.mc "$tmp/libs2/outside.mc"

# ---- 1. the two implementations of the tree hash agree with the locks ----
lock_hash() { sed -n "/name *= *\"$2\"/,/^$/p" "$1" | sed -n 's/^sha256 *= *"\(.*\)"/\1/p' | head -1; }
check_hash() {                        # check_hash LOCK NAME SRCDIR
    want=$(lock_hash "$1" "$2")
    got=$(sh scripts/pkg-hash.sh "$3")
    if [ "$want" = "$got" ]; then ok "tree hash $2: mc.lock and scripts/pkg-hash.sh agree"
    else fail "tree hash $2" "lock says $want, pkg-hash.sh says $got"
    fi
}
check_hash tests/pkg/app/mc.lock       geo   tests/pkg/src/geo-1.2.0
check_hash tests/pkg/app/mc.lock       mathx tests/pkg/src/mathx-1.0.0
check_hash tests/pkg/app/mc.lock       teach tests/pkg/src/teach-1.0.0
check_hash tests/pkg/app-float/mc.lock float tests/pkg/src/float-1.3.0
check_hash tests/pkg/app-bad/mc.lock   bad   tests/pkg/src/bad-1.0.0

# ---- helpers ----
cc="$mc"                              # which compiler `build` drives
build() {                             # build DIR CONFIG LIBSDIR -> $tmp/o, $rc
    rm -rf "$1/build"
    if [ -n "$2" ]; then
        "$cc" build "$1" --config "$2" --libs-dir "$3" > "$tmp/o" 2>&1
    else
        "$cc" build "$1" --libs-dir "$3" > "$tmp/o" 2>&1
    fi
    rc=$?
}
want_exit() {                         # want_exit LABEL CODE
    if [ "$rc" = "$2" ]; then return 0; fi
    fail "$1" "exit $rc, expected $2 -- $(tail -2 "$tmp/o" | tr '\n' ' ')"
    return 1
}
want_msg() {                          # want_msg LABEL TEXT
    if grep -q "$2" "$tmp/o"; then ok "$1: $(grep -m1 "$2" "$tmp/o")"
    else fail "$1" "no '$2' in: $(cat "$tmp/o")"
    fi
}

# ---- 2. the chain builds and runs (acceptance 5) ----
build tests/pkg/app "" "$tmp/libs"
if want_exit "app builds" 0; then
    out=$(tests/pkg/app/build/app 2>/dev/null); arc=$?
    if [ "$arc" = 42 ] && [ "$out" = "geo 120" ]; then
        ok "<geo/geo.mc> + <geo> + <mathx/mathx.mc> + <teach/mc_teach.mc>: exit 42, 'geo 120'"
    else
        fail "app runs" "exit $arc, stdout '$out'"
    fi
fi

# ---- 3. an unlocked version beside the locked one is never opened ----
build tests/pkg/app tests/pkg/app/obj.toml "$tmp/libs"
want_exit "app object (libs with geo v1.0.0 present)" 0 && cp tests/pkg/app/build/app.o "$tmp/out/a1.o"
build tests/pkg/app tests/pkg/app/obj.toml "$tmp/libs2"
if want_exit "app object (libs2, only v1.2.0)" 0; then
    if cmp -s "$tmp/out/a1.o" tests/pkg/app/build/app.o; then
        ok "geo v1.0.0 beside v1.2.0 changes nothing: the two objects are identical"
    else
        fail "unlocked version" "the objects differ"
    fi
fi

# ---- 4. two independent installations give the same bytes ----
# (that is the same comparison as 3 read the other way round: libs and libs2
# were populated separately, from the same sources.)

# ---- 5. the lock refuses a tampered source (acceptance 7) ----
cp "$tmp/libs/geo/v1.2.0/vec.mc" "$tmp/out/vec.mc"
printf 'x' >> "$tmp/libs/geo/v1.2.0/vec.mc"
build tests/pkg/app tests/pkg/app/obj.toml "$tmp/libs"
want_exit "tampered vec.mc" 2 && want_msg "tampered vec.mc" "geo 1.2.0: vec.mc does not match mc.lock"
# restore, and prove the refusal was the byte and not the road
cp "$tmp/out/vec.mc" "$tmp/libs/geo/v1.2.0/vec.mc"
build tests/pkg/app tests/pkg/app/obj.toml "$tmp/libs"
want_exit "restored vec.mc" 0 && ok "restored: the same tree builds again"

# ---- 6. the files list itself is hashed (acceptance 7, second half) ----
cp "$tmp/libs/geo/v1.2.0/mc.toml" "$tmp/out/geo-mc.toml"
sed 's/^files *=.*/files = ["geo.mc"]/' "$tmp/out/geo-mc.toml" > "$tmp/libs/geo/v1.2.0/mc.toml"
build tests/pkg/app tests/pkg/app/obj.toml "$tmp/libs"
want_exit "tampered geo mc.toml" 2 && want_msg "tampered geo mc.toml" "geo 1.2.0: mc.toml does not match mc.lock"
cp "$tmp/out/geo-mc.toml" "$tmp/libs/geo/v1.2.0/mc.toml"

# ---- 7. stale lock and unfetched package (acceptance 8) ----
sed 's/^geo   = "1.2.0"/geo   = "1.9.0"/' tests/pkg/app/obj.toml > "$tmp/out/stale.toml"
cp "$tmp/out/stale.toml" tests/pkg/app/stale.toml
build tests/pkg/app tests/pkg/app/stale.toml "$tmp/libs"
want_exit "stale lock" 2 && want_msg "stale lock" "mc.lock is stale"
rm -f tests/pkg/app/stale.toml
mv "$tmp/libs/mathx" "$tmp/out/mathx-away"
build tests/pkg/app tests/pkg/app/obj.toml "$tmp/libs"
want_exit "unfetched package" 2 && want_msg "unfetched package" "mathx 1.0.0 is not fetched"
grep -q "mc pkg sync --yes" "$tmp/o" && ok "the refusal carries its run: line" \
    || fail "unfetched package" "no run: line"
mv "$tmp/out/mathx-away" "$tmp/libs/mathx"

# ---- 8. vendoring is the offline road (acceptance 9) ----
rm -rf tests/pkg/app/deps
mkdir -p tests/pkg/app/deps
cp -R tests/pkg/src/geo-1.2.0   tests/pkg/app/deps/geo
cp -R tests/pkg/src/mathx-1.0.0 tests/pkg/app/deps/mathx
cp -R tests/pkg/src/teach-1.0.0 tests/pkg/app/deps/teach
build tests/pkg/app tests/pkg/app/obj.toml "$tmp/empty"
if want_exit "vendored build with an EMPTY libs dir" 0; then
    if cmp -s "$tmp/out/a1.o" tests/pkg/app/build/app.o; then
        ok "deps/ wins and gives the same object as the cache road, byte for byte"
    else
        fail "vendored object" "differs from the cache road's"
    fi
fi
rm -rf tests/pkg/app/deps

# ---- 9. a package is closed (acceptance 10) ----
build tests/pkg/app-bad "" "$tmp/libs"
want_exit "closure, #include" 1 && want_msg "closure, #include" "package bad reaches outside its tree"
build tests/pkg/app-bad tests/pkg/app-bad/embed.toml "$tmp/libs"
want_exit "closure, #embed" 1 && want_msg "closure, #embed" "package bad reaches outside its tree"

# ---- 10. [package].files is a boundary (acceptance 10, third half) ----
cat > "$tmp/libs/geo/v1.2.0/extra.mc" <<'EOF'
i64 geo_extra() { return 5; }
EOF
build tests/pkg/app-extra "" "$tmp/libs"
want_exit "undeclared file" 1 && want_msg "undeclared file" "not declared in geo's \[package\].files"
rm -f "$tmp/libs/geo/v1.2.0/extra.mc"

# ---- 11. names (acceptance 11) ----
name_case() {                         # name_case LABEL LINE EXPECT
    cat > tests/pkg/app/names.toml <<EOF
[project]
name  = "app"
entry = "main.mc"
out   = "build/x.o"
kind  = "obj"

[deps]
$2
EOF
    build tests/pkg/app tests/pkg/app/names.toml "$tmp/libs"
    got=$(tail -1 "$tmp/o")
    if [ "$rc" != 1 ]; then fail "$1" "exit $rc, expected 1"
    elif ! printf '%s' "$got" | grep -q "$3"; then fail "$1" "got '$got'"
    else ok "$1: $got"
    fi
    rm -f tests/pkg/app/names.toml
}
name_case "reserved name mc"  'mc = "1.0.0"'  'reserved package name: deps.mc'
name_case "invalid name Geo"  'Geo = "1.0.0"' 'invalid package name: deps.Geo'
name_case "reserved name deps" 'deps = "1.0.0"' 'reserved package name: deps.deps'

# ---- 12. a bundled name pinned in [deps] (acceptance 18) ----
build tests/pkg/app-float "" "$tmp/libs"
if want_exit "float override builds" 0; then
    out=$(tests/pkg/app-float/build/appf 2>/dev/null); arc=$?
    if [ "$arc" = 42 ] && [ "$out" = "1.500000!" ]; then
        ok "<float> and <float/float_rt.mc> come from the locked tree ('1.500000!')"
    else
        fail "float override runs" "exit $arc, stdout '$out'"
    fi
fi
build tests/pkg/app-float tests/pkg/app-float/obj.toml "$tmp/libs"
want_exit "float override object" 0 && cp tests/pkg/app-float/build/appf.o "$tmp/out/f1.o"
rm -rf tests/pkg/app-float/deps
mkdir -p tests/pkg/app-float/deps
cp -R tests/pkg/src/float-1.3.0 tests/pkg/app-float/deps/float
build tests/pkg/app-float tests/pkg/app-float/obj.toml "$tmp/empty"
if want_exit "float override, vendored" 0; then
    cmp -s "$tmp/out/f1.o" tests/pkg/app-float/build/appf.o \
        && ok "the override is the same object vendored or installed" \
        || fail "float override" "vendored and installed objects differ"
fi
rm -rf tests/pkg/app-float/deps
printf 'x' >> "$tmp/libs/float/v1.3.0/float_rt.mc"
build tests/pkg/app-float tests/pkg/app-float/obj.toml "$tmp/libs"
want_exit "tampered float_rt.mc" 2 && want_msg "tampered float_rt.mc" "float 1.3.0: float_rt.mc does not match mc.lock"
install_pkg tests/pkg/src/float-1.3.0 float 1.3.0 "$tmp/libs"
# and with the [deps] line gone the bundle answers again, whatever is installed
build tests/pkg/app-float tests/pkg/app-float/nodeps.toml "$tmp/libs"
want_exit "no [deps] float, libs populated" 0 && cp tests/pkg/app-float/build/nodeps.o "$tmp/out/n1.o"
build tests/pkg/app-float tests/pkg/app-float/nodeps.toml "$tmp/empty"
if want_exit "no [deps] float, empty libs" 0; then
    cmp -s "$tmp/out/n1.o" tests/pkg/app-float/build/nodeps.o \
        && ok "with no [deps] the installed float cannot change a byte" \
        || fail "no [deps] float" "the two objects differ"
fi
if cmp -s "$tmp/out/f1.o" "$tmp/out/n1.o"; then
    fail "the override" "the overridden object equals the bundled one -- it changed nothing"
else
    ok "the override does change the object, and removing it puts it back"
fi

# ---- 13. never the working directory ----
cat > "$tmp/out/float.mc" <<'EOF'
i64 shadow() { return 1; }
EOF
cp "$tmp/out/float.mc" tests/pkg/app-float/float.mc
build tests/pkg/app-float tests/pkg/app-float/nodeps.toml "$tmp/empty"
if want_exit "a float.mc next to the entry" 0; then
    cmp -s "$tmp/out/n1.o" tests/pkg/app-float/build/nodeps.o \
        && ok "a float.mc beside the entry does not shadow <float_rt>" \
        || fail "shadowing" "the object moved"
fi
rm -f tests/pkg/app-float/float.mc

# ---- 14. the single-file CLI has no lock and therefore no step 1 ----
cat > "$tmp/out/nolock.mc" <<'EOF'
#include <geo/geo.mc>
i64 main() { return 0; }
EOF
msg=$("$mc" "$tmp/out/nolock.mc" -o "$tmp/out/nolock.o" 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$msg" | grep -q "unknown bundled include: geo/geo"; then
    ok "the single-file CLI refuses <geo/geo.mc>: $msg"
else
    fail "single-file CLI" "exit $rc: $msg"
fi

# ---- 15. step 3 of the resolution order: the installed `mc` package ----
# A full binary answers every one of these names out of its own blob and never
# reaches step 3, so the probe is a compiler with every part BUT <mc/core_bundle>
# (tests/pkg/nobundle.mc). That is, line for line, what `mc-slim` will be.
probe="$tmp/bin/nobundle"
if "$mc" --exe tests/pkg/nobundle.mc -o "$probe" > "$tmp/o" 2>&1; then
    ok "the bundle-less probe compiler builds"
    mcd="$tmp/libs/mc/v$("$mc" --version | sed 's/^mc //')"
    mkdir -p "$mcd"
    cp tools/bundle.list "$mcd/bundle.list"
    while IFS="$(printf '\t')" read -r n p; do
        [ -n "$p" ] || continue
        mkdir -p "$mcd/$(dirname "$p")"
        cp "$p" "$mcd/$p"
    done < tools/bundle.list
    # bundle_data.mc is the ONE name the blob cannot carry (it would contain
    # itself); on disk it is an ordinary file that src/core.mc includes by path.
    cp src/bundle_data.mc "$mcd/src/bundle_data.mc"
    cc="$probe"
    build tests/pkg/std "" "$tmp/libs"
    if want_exit "the probe compiles <mc/core> from disk" 0; then
        "$mc" src/mc.mc -o "$tmp/out/ref.o" 2> /dev/null
        if cmp -s tests/pkg/std/build/def.o "$tmp/out/ref.o"; then
            ok "<mc/host> + <mc/core> + <user_default> served from <libs>/mc/v... == src/mc.mc, byte for byte"
        else
            fail "installed mc package" "the object differs from src/mc.mc's"
        fi
    fi
    # the same probe with no installed package says so, with the bundle's words
    build tests/pkg/std "" "$tmp/empty"
    want_exit "the probe with no installed package" 1 \
        && want_msg "the probe with no installed package" "unknown bundled include: mc/host"
    cc="$mc"
else
    fail "the bundle-less probe compiler" "$(cat "$tmp/o")"
fi

# ---- 16. check-standalone under the shim, plus <float> ----
if sh scripts/check-standalone.sh build/mc-exe build/mc2.o > "$tmp/o" 2>&1; then
    ok "check-standalone is green with curl/wget/tar refusing to run"
else
    fail "check-standalone under the shim" "$(tail -3 "$tmp/o")"
fi

cd "$here" || exit 1
echo "check-pkg: $((total - fails))/$total"
[ "$fails" -eq 0 ]
