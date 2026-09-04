#!/bin/sh
# check-docs.sh [MC] — M26: the documentation set is checked against the real
# compiler, not against a memory of it. Three checks, in this order:
#
#   1. coverage  every public symbol, CLI flag, TOML key and directive that
#                exists in src/ appears in docs/reference/. The lists are
#                extracted from src/*.mc, never written down here, so a new
#                p_*/syntax*/sec_*/gen_* function or a new --flag fails this
#                check until it is documented.
#   2. samples   every fenced ```mc block under docs/ is compiled by MC. A block
#                that declares `// expect-exit:` or `// expect-stdout:` is built
#                with --exe and RUN, and its output compared; one that declares
#                `// expect-error:` must fail to compile with that text on
#                stderr. Everything else is compiled to an object.
#   3. links     every relative markdown link under docs/ resolves to a file
#                that exists.
#
# Fence attributes, written after the language tag (```mc taught=examples/lang):
#
#   taught=DIR        DIR holds an mc.toml with a [compiler] section: the sample
#                     is compiled by the taught compiler `mc build DIR` produces.
#                     The sample file is written to DIR/build/, so a relative
#                     include inside it reads `../lib/x`.
#   taught=FILE.mc    FILE.mc is a compiler source (core + modules + user_init):
#                     it is built with `MC --exe` and used for the sample.
#   ext=EXT           extension of the written sample (default mc); examples/lang
#                     wants lx.
#   backend=NAME      compile with --backend=NAME instead of the default object
#                     backend, and do not run.
#
# Run from the repository root, as `make check-docs` does.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

fails=0
total=0
tmp="${TMPDIR:-/tmp}/check-docs.$$"
mkdir -p "$tmp" build/docs

cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM

fail() {
    printf '%s\n' "FAIL $1"
    shift
    for line in "$@"; do printf '%s\n' "     $line"; done
    fails=$((fails + 1))
}

# ---------------------------------------------------------------- 1. coverage
# The reference tree is one blob: a symbol may be documented on any page of it.
refs="$tmp/refs"
cat docs/reference/*.md > "$refs" 2>/dev/null || { echo "FAIL: docs/reference/ is empty"; exit 1; }

# Public API: the definitions in src/*.mc whose name is one of the families the
# spec names -- p_*, syntax*, type_alias, pass, backend*, machine*, sec_*, sym_*,
# reloc_add, gen_* -- plus on_*, the M21.5 hook family the spec's literal list
# predates (on_stmt fits none of the other prefixes and was uncovered), and
# decl_*, the M31 family that answers about a declaration the parser already read. A symbol counts as documented when the reference mentions it
# as a call (`name(`), which is how every entry in hooks.md and objects.md is
# written; a bare word in prose is not enough.
grep -hoE '^(void|i64|uptr|u8|u16|u32|u64) +(p_|syntax|type_alias|pass|backend|machine|sec_|sym_|reloc_add|gen_|on_|decl_)[A-Za-z_0-9]*\(' src/*.mc \
    | sed -E 's/^[a-z0-9]+ +//; s/\($//' | sort -u > "$tmp/syms"

missing=""
while read -r s; do
    [ -n "$s" ] || continue
    total=$((total + 1))
    if ! grep -qF "$s(" "$refs"; then missing="$missing $s"; fi
done < "$tmp/syms"
nsym=$(grep -c . "$tmp/syms")
if [ -n "$missing" ]; then
    fail "undocumented public symbols" $missing
else
    echo "ok coverage: $nsym public symbols documented in docs/reference/"
fi

# CLI: every long option and `-o`, taken from the string literals the driver
# compares argv against.
grep -hoE '"--[a-z][a-z-]*=?"' src/*.mc | tr -d '"' | sort -u > "$tmp/flags"
echo "-o" >> "$tmp/flags"
missing=""
while read -r f; do
    [ -n "$f" ] || continue
    total=$((total + 1))
    if ! grep -qF -- "$f" docs/reference/cli.md; then missing="$missing $f"; fi
done < "$tmp/flags"
nflag=$(grep -c . "$tmp/flags")
if [ -n "$missing" ]; then
    fail "undocumented CLI flags" $missing
else
    echo "ok coverage: $nflag CLI flags documented in docs/reference/cli.md"
fi

# TOML: every key the driver looks up by name, plus the two table prefixes it
# walks the flat table for ([libs] and [externs] have user-chosen key names).
grep -hoE 'toml_(get|get_array|count|int|bp|err_key)\("[a-z_.]+"' src/*.mc \
    | sed -E 's/.*"([a-z_.]+)"/\1/' | sort -u > "$tmp/tomlkeys"
grep -hoE 'opt_val\(toml_path_at\(i\), "[a-z_]+\."' src/*.mc \
    | sed -E 's/.*"([a-z_]+)\."/\1/' | sort -u >> "$tmp/tomlkeys"
sort -u "$tmp/tomlkeys" -o "$tmp/tomlkeys"
missing=""
while read -r k; do
    [ -n "$k" ] || continue
    total=$((total + 1))
    if ! grep -qF -- "$k" docs/reference/toml.md; then missing="$missing $k"; fi
done < "$tmp/tomlkeys"
nkey=$(grep -c . "$tmp/tomlkeys")
if [ -n "$missing" ]; then
    fail "undocumented TOML keys" $missing
else
    echo "ok coverage: $nkey TOML keys documented in docs/reference/toml.md"
fi

# Directives: the names in lex.mc's dir_index(), which IS the table.
grep -oE 'mem_eq\("[a-z]+", s,' src/lex.mc | sed -E 's/.*"([a-z]+)".*/\1/' | sort -u > "$tmp/dirs"
missing=""
while read -r d; do
    [ -n "$d" ] || continue
    total=$((total + 1))
    if ! grep -qF -- "#$d" docs/reference/directives.md; then missing="$missing #$d"; fi
done < "$tmp/dirs"
ndir=$(grep -c . "$tmp/dirs")
if [ -n "$missing" ]; then
    fail "undocumented directives" $missing
else
    echo "ok coverage: $ndir directives documented in docs/reference/directives.md"
fi

# ----------------------------------------------------------------- 2. samples
# Extract every fenced ```mc block, in file order, into $tmp/NNN.txt with one
# manifest line each: source file, line of the fence, fence attributes.
: > "$tmp/manifest"
find docs -name '*.md' | sort > "$tmp/mdfiles"
fno=0
while read -r md; do
    fno=$((fno + 1))
    awk -v out="$tmp" -v mf="$tmp/manifest" -v src="$md" -v pfx="$fno" '
        /^```mc$/ || /^```mc / {
            if (!inb) {
                inb = 1
                n++
                attrs = substr($0, 6)
                f = sprintf("%s/b%s_%03d.txt", out, pfx, n)
                printf "" > f
                print src "\t" NR "\t" f "\t" attrs >> mf
                next
            }
        }
        inb && /^```[ \t]*$/ { inb = 0; close(f); next }
        inb { print >> f }
    ' "$md"
done < "$tmp/mdfiles"

# `mc build DIR` prints `compiler <src> -> <out>`; that is where the taught
# compiler lands, relative to DIR. Built at most once per project.
taught_build() {
    _dir="$1"
    _key=$(echo "$_dir" | tr '/.' '__')
    if [ -f "$tmp/taught_$_key" ]; then
        _c=$(cat "$tmp/taught_$_key")
        [ -n "$_c" ] || return 1
        echo "$_c"
        return 0
    fi
    if [ -d "$_dir" ]; then
        if ! _o=$("$mc" build "$_dir" 2>&1); then
            echo "" > "$tmp/taught_$_key"
            echo "ERROR $_o" >&2
            return 1
        fi
        _rel=$(echo "$_o" | sed -n 's/^compiler .* -> //p' | head -1)
        if [ -z "$_rel" ]; then echo "" > "$tmp/taught_$_key"; return 1; fi
        _bin="$_dir/$_rel"
    else
        _base=$(basename "$_dir" .mc)
        _bin="build/docs/mc-$_base"
        rm -f "$_bin"
        if ! _o=$("$mc" --exe "$_dir" -o "$_bin" 2>&1); then
            echo "" > "$tmp/taught_$_key"
            echo "ERROR $_o" >&2
            return 1
        fi
    fi
    echo "$_bin" > "$tmp/taught_$_key"
    echo "$_bin"
}

while IFS="	" read -r md line blk attrs; do
    total=$((total + 1))
    name="$md:$line"

    taught=""
    ext="mc"
    backend=""
    for a in $attrs; do
        case "$a" in
            taught=*)  taught="${a#taught=}" ;;
            ext=*)     ext="${a#ext=}" ;;
            backend=*) backend="${a#backend=}" ;;
            *)         fail "$name" "unknown fence attribute: $a"; continue 2 ;;
        esac
    done

    comp="$mc"
    dir="build/docs"
    if [ -n "$taught" ]; then
        if ! comp=$(taught_build "$taught" 2>"$tmp/terr"); then
            fail "$name" "cannot build the taught compiler $taught" "$(cat "$tmp/terr")"
            continue
        fi
        [ -d "$taught" ] && dir="$taught/build"
    fi

    want_exit=$(sed -n 's|^// expect-exit: *||p' "$blk" | head -1)
    want_out=$(sed -n 's|^// expect-stdout: *||p' "$blk")
    has_out=$(grep -c '^// expect-stdout:' "$blk")
    want_err=$(sed -n 's|^// expect-error: *||p' "$blk" | head -1)

    base=$(basename "$blk" .txt)
    src="$dir/docs-$base.$ext"
    mkdir -p "$dir"
    cp "$blk" "$src"

    if [ -n "$want_err" ]; then
        if msg=$("$comp" "$src" -o "$dir/docs-$base.o" 2>&1); then
            fail "$name" "expected the compiler to reject the sample" "$msg"
            continue
        fi
        case "$msg" in
            *"$want_err"*) printf '%s\n' "ok $name (rejected: $want_err)" ;;
            *) fail "$name" "expected error containing: $want_err" "got: $msg" ;;
        esac
        continue
    fi

    if [ -z "$want_exit" ] && [ "$has_out" = "0" ]; then
        b="${backend:-}"
        if [ -n "$b" ]; then set -- --backend="$b"; else set -- ; fi
        if ! msg=$("$comp" "$@" "$src" -o "$dir/docs-$base.o" 2>&1); then
            fail "$name" "compilation: $msg"
            continue
        fi
        echo "ok $name (compiles)"
        continue
    fi

    exe="$dir/docs-$base"
    rm -f "$exe"
    if ! msg=$("$comp" --exe "$src" -o "$exe" 2>&1); then
        fail "$name" "compilation: $msg"
        continue
    fi
    got_out=$("$exe" 2>/dev/null)
    got_exit=$?
    bad=0
    if [ -n "$want_exit" ] && [ "$got_exit" != "$want_exit" ]; then
        fail "$name" "exit $got_exit, expected $want_exit"
        bad=1
    fi
    if [ "$has_out" != "0" ] && [ "$got_out" != "$want_out" ]; then
        fail "$name" "stdout:" "$got_out" "expected:" "$want_out"
        bad=1
    fi
    [ "$bad" = "0" ] && echo "ok $name (runs)"
done < "$tmp/manifest"

nblocks=$(grep -c . "$tmp/manifest")
echo "ok samples: $nblocks fenced mc blocks"

# ------------------------------------------------------------------- 3. links
# Relative markdown links only; http(s) and bare anchors are out of scope.
while read -r md; do
    d=$(dirname "$md")
    grep -oE '\]\([^)]+\)' "$md" | sed -E 's/^\]\(//; s/\)$//' | while read -r target; do
        case "$target" in
            http://*|https://*|mailto:*|"#"*) continue ;;
        esac
        path="${target%%#*}"
        [ -n "$path" ] || continue
        case "$path" in
            /*) p="$path" ;;
            *)  p="$d/$path" ;;
        esac
        if [ ! -e "$p" ]; then echo "$md -> $target" >> "$tmp/badlinks"; fi
    done
done < "$tmp/mdfiles"
nlinks=$(grep -rhoE '\]\([^)]+\)' docs --include='*.md' | grep -cv 'http' || true)
if [ -f "$tmp/badlinks" ]; then
    fail "unresolved links" "$(cat "$tmp/badlinks")"
else
    echo "ok links: $nlinks relative links resolve"
fi

# ------------------------------------------------------------------- verdict
if [ "$fails" -eq 0 ]; then
    echo "docs ok: $nsym symbols, $nflag flags, $nkey toml keys, $ndir directives, $nblocks samples, $nlinks links"
    exit 0
fi
echo "$fails documentation check(s) failed"
exit 1
