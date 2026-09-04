#!/bin/sh
# check-sysroots.sh [MC] — M25: the pinned sysroot table and its documentation
# say the same thing, and `mc sysroot list` is the same text on every host.
#
# Two checks:
#
#   1. table   every row of src/sysroots.mc (target, host, url, sha256, size,
#              strip) appears in the table of docs/reference/sysroot.md § 7, and
#              the two have the same number of rows. Both sides are EXTRACTED at
#              run time, never written down here, so a pin that moves in the
#              code and not in the docs -- or the other way round -- fails.
#   2. list    `mc sysroot list` matches tests/golden/sysroot-list.txt byte for
#              byte. That output is a walk of the target registry crossed with
#              the source table and touches no file, which is what makes one
#              golden valid on macOS, Linux and Windows alike.
#
# What this script does NOT do is reach the network. A dead URL is a maintenance
# issue for a scheduled job, not a red pull request (docs/specs/M25.md § Risks).
#
# Run from the repository root, as `make check-sysroots` does.
mc="${1:-build/mc1}"

if [ ! -x "$mc" ]; then
    echo "FAIL: compiler '$mc' not found or not executable"
    exit 1
fi

fails=0
tmp="${TMPDIR:-/tmp}/check-sysroots.$$"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) tmp=$(cygpath -m "$tmp") ;; esac
mkdir -p "$tmp"
cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT INT TERM

# ---- 1. the table ----
# One line per row: target|host|url|sha|size|strip. `sysroot_src(` calls span
# several lines, so the whole registration function is joined into one stream
# first and then split on the call boundary.
tr '\n' ' ' < src/sysroots.mc |
sed 's/sysroot_src(/\
/g' |
sed -n '2,$p' |
awk '
    {
        line = $0
        i = index(line, ");")             # the call ends here; a `)` inside a
        if (i > 0) line = substr(line, 1, i - 1)   # kind string does not
        sub(/^[ \t]+/, "", line)
        if (substr(line, 1, 1) != "\"") next      # the prototype, not a row
        n = 0
        rest = line
        while (n < 8) {
            sub(/^[ \t,]+/, "", rest)
            if (substr(rest, 1, 1) == "\"") {
                rest = substr(rest, 2)
                i = index(rest, "\"")
                f[++n] = substr(rest, 1, i - 1)
                rest = substr(rest, i + 1)
            } else {
                i = index(rest, ",")
                if (i == 0) i = length(rest) + 1
                v = substr(rest, 1, i - 1)
                gsub(/[ \t]/, "", v)
                f[++n] = v
                rest = substr(rest, i)
            }
        }
        host = f[2]; if (host == "") host = "any"
        url = f[4]; sha = f[5]; size = f[6]; strip = f[7]
        if (url == "0") { url = "-"; sha = "-"; size = "-"; strip = "-" }
        print f[1] "|" host "|" url "|" sha "|" size "|" strip
    }
' > "$tmp/code"

# the same six columns out of the markdown table: rows whose first cell is a
# quoted target name
sed -n 's/^| `\([a-z0-9]*-[a-z0-9_]*\)` *|/\1|/p' docs/reference/sysroot.md |
sed 's/`//g; s/ *| */|/g; s/|$//' > "$tmp/docs"

ncode=$(grep -c . "$tmp/code")
ndocs=$(grep -c . "$tmp/docs")
if [ "$ncode" != "$ndocs" ]; then
    echo "FAIL table: src/sysroots.mc has $ncode rows, docs/reference/sysroot.md has $ndocs"
    fails=$((fails + 1))
elif ! diff -u "$tmp/docs" "$tmp/code" > "$tmp/d"; then
    echo "FAIL table: src/sysroots.mc and docs/reference/sysroot.md disagree"
    sed 's/^/     /' "$tmp/d"
    fails=$((fails + 1))
else
    echo "ok table: $ncode pinned rows, code and docs identical"
fi

# ---- 2. mc sysroot list ----
"$mc" sysroot list > "$tmp/list" 2>&1
if ! diff -u tests/golden/sysroot-list.txt "$tmp/list" > "$tmp/dl"; then
    echo "FAIL list: mc sysroot list does not match tests/golden/sysroot-list.txt"
    sed 's/^/     /' "$tmp/dl"
    fails=$((fails + 1))
else
    echo "ok list: matches tests/golden/sysroot-list.txt ($(grep -c . "$tmp/list") lines)"
fi

if [ "$fails" -eq 0 ]; then
    echo "sysroots ok: $ncode rows, list golden"
    exit 0
fi
echo "$fails sysroot check(s) failed"
exit 1
