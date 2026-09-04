#!/bin/sh
# check-parts.sh [MC] — M41: the core is composable, and what is left out of a
# compiler is measurably absent from it.
#
# Four proofs, in the order docs/specs/M41.md § Acceptance lists them:
#
#   1. THE PARTS ARE THE CORE. An object built from `<mc/host>` + the five parts
#      spelled out + `<mc/main>` + `<user_default>` is byte-identical to one
#      built from `<mc/host>` + `<mc/core>` + `<user_default>`. This is the
#      anti-drift proof: it fails the moment src/core.mc and the part files
#      disagree about a single file or its order.
#  1b. EACH PART STANDS ON ITS OWN -- <mc/core_min> + one part compiles. A part
#      that needs another part is not a part, and the full assembly hides it.
#   4. DEBLOAT IS MEASURED. A core_min-only compiler is built (with the probe
#      machine and the null writer of <user_core_min>) and its sections are
#      printed beside the full compiler's, in examples/minimal's style. Two
#      assertions: __data under the ceiling below (no bundle blob), and no
#      _macho_write / _elf_write / _coff_write / _bundle_open / _drv_build /
#      _m_arm64 anywhere in its symbol table.
#   5. REMOVAL IS PROVED BY REFUSAL. The same source `mc` compiles is refused by
#      a compiler that called intrinsic_disable("ld64"), and by one that called
#      type_disable(TY_U32), each with its exact message.
#   6. THE OVERRIDE IS PROVED. A compiler that called type_set_width(TY_UPTR, 2)
#      puts a `uptr` local in a two-byte frame slot and writes a `uptr[]`
#      initializer at two bytes per element; type_set_width(TY_U64, 2) is
#      refused at user_init, before any source is read.
#
# Every compiler below takes its CORE FROM THE BUNDLE, in
# scripts/check-standalone.sh's style: the entry files name `<mc/...>` for
# everything the compiler is made of, so what is checked is the parts as they
# ship and not the files in src/. The four probe modules are ordinary files in
# lib/ (they are fixtures, not library code, so they are not bundled) and the
# generated entry files sit in build/parts/ to reach them with a relative
# `#include`.
#
# Run from the repository root, as `make check-parts` does.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

# The ceiling, in check-minimal's style: a number in the script, raised on
# purpose or not at all. __data of a core_min-only compiler is its string
# literals and its static tables; the bundle blob alone is 350 KB, so anything
# near that means <mc/core_bundle> came back in by accident.
DATA_CEILING=16384

fails=0
tmp=build/parts
rm -rf "$tmp"; mkdir -p "$tmp"

fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# the `size=` of one section out of `mc --dump-syms`
secsize() { awk -v s="$2" '$1 == "section" && $2 == s { for (i = 3; i <= NF; i++) if ($i ~ /^size=/) { sub(/^size=/, "", $i); print $i; exit } }' "$1"; }

# ---------------------------------------------------------------- 1. the parts
cat > "$tmp/parts.mc" <<'EOF'
#include <mc/host>
#include <mc/core_min>
#include <mc/core_machines>
#include <mc/core_writers>
#include <mc/core_build>
#include <mc/core_bundle>
#include <mc/main>
#include <user_default>
EOF
cat > "$tmp/whole.mc" <<'EOF'
#include <mc/host>
#include <mc/core>
#include <user_default>
EOF
if ! msg=$("$mc" "$tmp/parts.mc" -o "$tmp/parts.o" 2>&1); then
    fail "compiling the five parts spelled out: $msg"
elif ! msg=$("$mc" "$tmp/whole.mc" -o "$tmp/whole.o" 2>&1); then
    fail "compiling <mc/core>: $msg"
elif ! cmp -s "$tmp/parts.o" "$tmp/whole.o"; then
    fail "the parts and <mc/core> produce different objects (src/core.mc has drifted)"
else
    echo "ok   the five parts + <mc/main> == <mc/core>, byte for byte ($(wc -c < "$tmp/parts.o" | tr -d ' ') bytes)"
fi

# ------------------------------------------------- 1b. each part on its own
# A part is only a part if it compiles on top of <mc/core_min> ALONE. This is
# what catches a cross-part dependency the full assembly hides -- a #define in
# another part's file, a helper that drifted into the driver -- and it is how
# three of them were found and fixed when M41 landed (tm_cat, tm_num_str,
# MODE_755, R_X86_PC32/R_X86_PLT32).
for p in core_machines core_writers core_build core_bundle; do
    case "$p" in
        core_machines) init=mc_machines_init ;;
        core_writers)  init=mc_writers_init ;;
        core_build)    init=mc_build_init ;;
        core_bundle)   init=mc_bundle_init ;;
    esac
    { echo '#include <mc/host>'
      echo '#include <mc/core_min>'
      echo "#include <mc/$p>"
      echo '#include "../../lib/user_core_min.mc"'
      echo 'i64 main(i64 argc, uptr argv, uptr envp) {'
      echo '    host_init(envp);'
      echo "    $init();"
      echo '    return mc_main(argc, argv, envp);'
      echo '}'
    } > "$tmp/only_$p.mc"
    if ! msg=$("$mc" "$tmp/only_$p.mc" -o "$tmp/only_$p.o" 2>&1); then
        fail "<mc/core_min> + <mc/$p> does not compile: $msg"
    else
        echo "ok   <mc/core_min> + <mc/$p> stands on its own"
    fi
done

# ------------------------------------------------------------- 4. the measure
cat > "$tmp/min.mc" <<'EOF'
#include <mc/host>
#include <mc/core_min>
#include "../../lib/user_core_min.mc"

// the five lines a recreated compiler writes instead of copying mc_main:
// <mc/core_min> carries the command line, not the entry point.
i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    return mc_main(argc, argv, envp);
}
EOF
if ! msg=$("$mc" --dump-syms "$tmp/min.mc" > "$tmp/min.syms" 2>&1); then
    fail "building the core_min-only compiler: $(head -2 "$tmp/min.syms")"
else
    rm -f "$tmp/mcmin"
    "$mc" --exe "$tmp/min.mc" -o "$tmp/mcmin" > /dev/null 2>&1
    "$mc" --dump-syms "$tmp/whole.mc" > "$tmp/whole.syms" 2>&1
    rm -f "$tmp/mcfull"
    "$mc" --exe "$tmp/whole.mc" -o "$tmp/mcfull" > /dev/null 2>&1
    mt=$(secsize "$tmp/min.syms" __TEXT,__text)
    mc_=$(secsize "$tmp/min.syms" __TEXT,__cstring)
    md=$(secsize "$tmp/min.syms" __DATA,__data)
    ft=$(secsize "$tmp/whole.syms" __TEXT,__text)
    fc=$(secsize "$tmp/whole.syms" __TEXT,__cstring)
    fd=$(secsize "$tmp/whole.syms" __DATA,__data)
    [ -n "$md" ] || md=0
    [ -n "$fd" ] || fd=0
    echo ""
    echo "compiler                      __text   __cstring     __data     on disk"
    echo "--------------------------------------------------------------------------"
    printf '%-28s %8s %11s %10s %11s\n' "core_min only (probe+null)" "$mt" "$mc_" "$md" "$(wc -c < "$tmp/mcmin" | tr -d ' ')"
    printf '%-28s %8s %11s %10s %11s\n' "the whole core (mc)" "$ft" "$fc" "$fd" "$(wc -c < "$tmp/mcfull" | tr -d ' ')"
    echo ""
    if [ "$md" -ge "$DATA_CEILING" ]; then
        fail "__data of the core_min-only compiler is $md, ceiling $DATA_CEILING (a bundle came back in?)"
    else
        echo "ok   core_min __data $md < $DATA_CEILING (no bundle blob)"
    fi
    # Absent from the small one, and PRESENT in the whole one -- otherwise a
    # renamed symbol would turn this assertion into a tautology.
    absent=""; missing=""
    for s in _macho_write _elf_write _coff_write _bundle_open _drv_build _m_arm64; do
        if grep -q " $s\$" "$tmp/min.syms";   then absent="$absent $s"; fi
        if ! grep -q " $s\$" "$tmp/whole.syms"; then missing="$missing $s"; fi
    done
    if [ -n "$missing" ]; then
        fail "not in the whole core either (renamed?):$missing"
    elif [ -n "$absent" ]; then
        fail "the core_min-only compiler still carries:$absent"
    else
        echo "ok   in mc and not in core_min: _macho_write _elf_write _coff_write _bundle_open _drv_build _m_arm64"
    fi
fi

# ------------------------------------------------------------- 5. the removals
cat > "$tmp/uses_ld64.mc" <<'EOF'
i64 main() {
    u8 buf[8];
    st64(buf, 42);
    return ld64(buf);
}
EOF
cat > "$tmp/uses_u32.mc" <<'EOF'
i64 main() {
    u32 x;
    x = 42;
    return x;
}
EOF
build_taught() {                          # basename of the lib/ probe module
    cat > "$tmp/$1.mc" <<EOF
#include <mc/host>
#include <mc/core>
#include "../../lib/$1.mc"
EOF
    rm -f "$tmp/$1"
    "$mc" --exe "$tmp/$1.mc" -o "$tmp/$1" 2>&1
}

for pair in "user_nold64 uses_ld64 ld64: removed by this compiler" \
            "user_nou32 uses_u32 u32: removed by this compiler"; do
    set -- $pair
    mod="$1"; src="$2"; shift 2; want="$*"
    if ! msg=$(build_taught "$mod"); then
        fail "building the $mod compiler: $msg"
        continue
    fi
    if ! "$mc" "$tmp/$src.mc" -o "$tmp/$src.o" > /dev/null 2>&1; then
        fail "$src.mc does not compile with the default compiler"
        continue
    fi
    msg=$("$tmp/$mod" "$tmp/$src.mc" -o "$tmp/x.o" 2>&1)
    if [ $? -eq 0 ]; then
        fail "the $mod compiler accepted $src.mc"
    elif ! printf '%s' "$msg" | grep -q "$want"; then
        fail "$mod: wrong message: $msg"
    else
        echo "ok   $mod refuses $src.mc: $msg"
    fi
done

# -------------------------------------------------------------- 6. the width
# Two probes, because they exercise different halves. The DATA one goes all the
# way to an object (glob_place writes the elements and the pointer relocation),
# and its functions have no locals, so the arm64 encoder is never asked for an
# unscaled offset. The LOCAL one stops at --dump-asm, which is where the frame
# is visible and where nothing is encoded: an arm64 `str x9, [sp, #2]` has no
# encoding, and that is the honest limit of putting a two-byte word on this
# machine (docs/reference/machine.md § 6).
cat > "$tmp/pdata.mc" <<'EOF'
uptr g[4] = { 1, 2, 3, 4 };
uptr s[2] = { "a", "b" };
i64 main() { return 0; }
EOF
cat > "$tmp/plocal.mc" <<'EOF'
i64 f() {
    uptr a;
    a = 1;
    return a;
}
i64 main() { return f(); }
EOF
if ! msg=$(build_taught user_uptr2); then
    fail "building the user_uptr2 compiler: $msg"
else
    "$mc" --dump-syms "$tmp/pdata.mc" > "$tmp/p8.syms" 2>&1
    "$tmp/user_uptr2" --dump-syms "$tmp/pdata.mc" > "$tmp/p2.syms" 2>&1
    d8=$(secsize "$tmp/p8.syms" __DATA,__data)
    d2=$(secsize "$tmp/p2.syms" __DATA,__data)
    # 8-byte word: g is 4 x 8 = 32 and s, padded to 16, is 2 x 8 = 16 -> 48.
    # 2-byte word: g is 4 x 2 = 8 and s, still padded to 16, is 2 x 2 = 4 -> 20.
    if [ "$d8" = "48" ] && [ "$d2" = "20" ]; then
        echo "ok   uptr[] initializers: __DATA,__data $d8 bytes at width 8, $d2 at width 2"
    else
        fail "uptr[] initializers: __data $d8 at width 8, $d2 at width 2 (expected 48 and 20)"
    fi
    # the pointer relocation follows the word: length 3 (8 bytes) or 1 (2 bytes)
    "$tmp/user_uptr2" "$tmp/pdata.mc" -o "$tmp/pdata2.o" > /dev/null 2>&1
    if command -v otool > /dev/null 2>&1; then
        rl=$(otool -r "$tmp/pdata2.o" | awk '/^00000/ { print $3 }' | sort -u | tr '\n' ' ')
        if [ "$rl" = "1 " ]; then
            echo "ok   the string-pointer relocation is length 1 (2 bytes) at width 2"
        else
            fail "the string-pointer relocation lengths at width 2 are '$rl', expected '1'"
        fi
    fi
    f8=$("$mc" --dump-asm "$tmp/plocal.mc" 2>/dev/null | grep -o 'sub sp, sp, #[0-9]*' | head -1)
    f2=$("$tmp/user_uptr2" --dump-asm "$tmp/plocal.mc" 2>/dev/null | grep -o 'sub sp, sp, #[0-9]*' | head -1)
    if [ "$f8" = "sub sp, sp, #16" ] && [ "$f2" = "sub sp, sp, #4" ]; then
        echo "ok   a uptr local: frame '$f8' at width 8, '$f2' at width 2"
    else
        fail "a uptr local: frame '$f8' at width 8, '$f2' at width 2 (expected #16 and #4)"
    fi
fi

msg=$(build_taught user_badwidth)
if [ $? -eq 0 ]; then
    msg=$("$tmp/user_badwidth" "$tmp/pdata.mc" -o "$tmp/y.o" 2>&1)
    if [ $? -eq 0 ]; then
        fail "type_set_width(TY_U64, 2) was accepted"
    elif ! printf '%s' "$msg" | grep -q "type_set_width only declares the width of uptr"; then
        fail "type_set_width(TY_U64, 2): wrong message: $msg"
    else
        echo "ok   type_set_width(TY_U64, 2) refused: $msg"
    fi
else
    fail "building the user_badwidth compiler: $msg"
fi

if [ "$fails" != 0 ]; then
    echo "check-parts: $fails failures"
    exit 1
fi
echo "check-parts: the parts are the core, and what is omitted is absent"
