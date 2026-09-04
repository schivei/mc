#!/bin/sh
# check-inert.sh PRE POST — M24 (the M17 step-A proof, kept as a script).
#
# A step of M24 is INERT when the compiler from before it and the compiler after
# it produce byte-identical objects for everything that registers nothing: the
# whole tests/ corpus, the compiler's own source, and -- through the taught
# compiler each of them BUILDS -- the four examples that do register something,
# but nothing this milestone adds.
#
# PRE is a copy of build/mc1 taken before the first edit of the step
# (`cp build/mc1 build/mc1.pre`), POST the one built from the edited tree.
pre="$1"
post="$2"
if [ ! -x "$pre" ] || [ ! -x "$post" ]; then
    echo "usage: check-inert.sh PRE POST   (both must be executable)"
    exit 1
fi

d="${TMPDIR:-/tmp}/check-inert.$$"
rm -rf "$d"; mkdir -p "$d"
cleanup() { rm -rf "$d"; return 0; }
trap cleanup EXIT INT TERM

fails=0
n=0

one() {                                   # label, then the compiler arguments
    lbl="$1"; shift
    "$pre"  "$@" -o "$d/a.o" > /dev/null 2> "$d/ae" || {
        echo "FAIL $lbl (pre)"; sed -n 1,3p "$d/ae"; fails=$((fails + 1)); return 0; }
    "$post" "$@" -o "$d/b.o" > /dev/null 2> "$d/be" || {
        echo "FAIL $lbl (post)"; sed -n 1,3p "$d/be"; fails=$((fails + 1)); return 0; }
    n=$((n + 1))
    cmp -s "$d/a.o" "$d/b.o" || { echo "DIFF $lbl"; fails=$((fails + 1)); }
}

for f in tests/*.mc; do
    [ -f "$f" ] || continue
    one "$f" "$f"
done
one src/mc.mc src/mc.mc
echo "ok   $n objects identical (tests/*.mc and src/mc.mc)"

# Each taught compiler is BUILT by the compiler under test and then asked to
# compile its own program, through `mc build --entry-only` so that the config's
# [include] roots, [libs] and [externs] apply exactly as they do in a real
# build. A difference here would mean the surface moved even though the core's
# own output did not.
taught() {                                # dir, output, then extra config args
    dir="$1"; out="$2"; shift 2
    for side in pre post; do
        eval c="\$$side"
        cc=$("$c" build "$dir" --compiler-only "$@" 2> "$d/e" | tail -1) || {
            echo "FAIL taught $dir ($side, compiler)"; sed -n 1,3p "$d/e"
            fails=$((fails + 1)); return 0; }
        rm -f "$dir/$out"
        "$cc" build "$dir" --entry-only "$@" > /dev/null 2> "$d/e" || {
            echo "FAIL taught $dir ($side, entry)"; sed -n 1,3p "$d/e"
            fails=$((fails + 1)); return 0; }
        cp "$dir/$out" "$d/o-$side"
    done
    if cmp -s "$d/o-pre" "$d/o-post"; then echo "ok   taught $dir -> $out"
    else echo "DIFF taught $dir -> $out"; fails=$((fails + 1)); fi
}

taught examples/api     build/api
taught examples/lang    build/lang-demo
taught examples/conc    build/conc-demo
taught examples/desktop build/desktop-ui --config examples/desktop/ui.toml

if [ "$fails" != 0 ]; then
    echo "check-inert: $fails differences"
    exit 1
fi
echo "check-inert: everything identical"
