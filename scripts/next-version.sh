#!/bin/sh
# next-version.sh — the version arithmetic the release automation needs.
#
#   next-version.sh BASE BUMP    prints the version after BUMP is applied to BASE
#   next-version.sh --gt A B     exit 0 when A is strictly newer than B
#   next-version.sh --test       runs the assertions below and prints a summary
#
# BASE and the two comparands are `X.Y.Z`, with an optional leading `v` that is
# stripped (`v1.2.3` and `1.2.3` are the same input). BUMP is `major`, `minor`
# or `patch`. The output never carries the `v`; the caller adds it when it means
# a tag name.
#
#   next-version.sh 0.1.0 patch   -> 0.1.1
#   next-version.sh 0.1.9 minor   -> 0.2.0
#   next-version.sh v1.4.2 major  -> 2.0.0
#
# Pre-releases are deliberately not supported: `0.2.0-rc1` is rejected with a
# message that says so (docs/ci.md § Versioning). Leading zeros are rejected for
# the same reason semver rejects them -- `01.2.3` has no single meaning.
#
# Exit status: 0 on success, 1 when a comparison is false, 2 on bad input.
set -eu

nv_die() {
    printf 'next-version: %s\n' "$1" >&2
    exit 2
}

# Splits "$1" into nv_major/nv_minor/nv_patch. Returns 1 when the input is not
# a plain X.Y.Z, leaving the three variables untouched.
nv_parse() {
    nv_v="${1#v}"
    case "$nv_v" in
        '' | *[!0-9.]*) return 1 ;;
    esac
    nv_a="${nv_v%%.*}"
    nv_rest="${nv_v#*.}"
    case "$nv_rest" in
        *.*) : ;;
        *) return 1 ;;
    esac
    nv_b="${nv_rest%%.*}"
    nv_c="${nv_rest#*.}"
    case "$nv_c" in
        '' | *.*) return 1 ;;
    esac
    [ -n "$nv_a" ] && [ -n "$nv_b" ] || return 1
    # no leading zeros: "0" is fine, "00" and "01" are not
    for nv_f in "$nv_a" "$nv_b" "$nv_c"; do
        case "$nv_f" in
            0) : ;;
            0*) return 1 ;;
        esac
    done
    nv_major="$nv_a"
    nv_minor="$nv_b"
    nv_patch="$nv_c"
    return 0
}

# Prints the bumped version. Returns 1 on a bad BASE, 3 on a bad BUMP.
nv_next() {
    nv_parse "$1" || return 1
    case "$2" in
        major) printf '%s.0.0\n' "$((nv_major + 1))" ;;
        minor) printf '%s.%s.0\n' "$nv_major" "$((nv_minor + 1))" ;;
        patch) printf '%s.%s.%s\n' "$nv_major" "$nv_minor" "$((nv_patch + 1))" ;;
        *) return 3 ;;
    esac
    return 0
}

# 0 when $1 > $2, 1 when it is not, 2 when either side does not parse.
nv_gt() {
    nv_parse "$1" || return 2
    nv_a1="$nv_major"
    nv_a2="$nv_minor"
    nv_a3="$nv_patch"
    nv_parse "$2" || return 2
    if [ "$nv_a1" -ne "$nv_major" ]; then
        if [ "$nv_a1" -gt "$nv_major" ]; then return 0; else return 1; fi
    fi
    if [ "$nv_a2" -ne "$nv_minor" ]; then
        if [ "$nv_a2" -gt "$nv_minor" ]; then return 0; else return 1; fi
    fi
    if [ "$nv_a3" -gt "$nv_patch" ]; then return 0; fi
    return 1
}

# ------------------------------------------------------------------- --test
# The assertions are part of the script on purpose: the arithmetic is three
# lines, and three lines with no test is how a release ends up as 0.1.10 when
# 0.2.0 was meant. `scripts/next-version.sh --test` runs them anywhere, with no
# framework and no network.
nv_fails=0
nv_total=0

nv_expect() { # nv_expect WANT BASE BUMP
    nv_total=$((nv_total + 1))
    if nv_got=$(nv_next "$2" "$3" 2>/dev/null); then :; else nv_got="<error $?>"; fi
    if [ "$nv_got" = "$1" ]; then
        printf 'ok   %s %s -> %s\n' "$2" "$3" "$nv_got"
    else
        printf 'FAIL %s %s -> %s (wanted %s)\n' "$2" "$3" "$nv_got" "$1"
        nv_fails=$((nv_fails + 1))
    fi
}

nv_expect_bad() { # nv_expect_bad BASE BUMP -- must be rejected
    nv_total=$((nv_total + 1))
    if nv_got=$(nv_next "$1" "$2" 2>/dev/null); then
        printf 'FAIL %s %s -> %s (wanted a rejection)\n' "$1" "$2" "$nv_got"
        nv_fails=$((nv_fails + 1))
    else
        printf 'ok   %s %s rejected\n' "$1" "$2"
    fi
}

nv_expect_gt() { # nv_expect_gt WANT A B, WANT is yes/no/bad
    nv_total=$((nv_total + 1))
    nv_rc=0
    nv_gt "$1" "$2" || nv_rc=$?
    case "$nv_rc" in
        0) nv_got=yes ;;
        1) nv_got=no ;;
        *) nv_got=bad ;;
    esac
    if [ "$nv_got" = "$3" ]; then
        printf 'ok   %s > %s ? %s\n' "$1" "$2" "$nv_got"
    else
        printf 'FAIL %s > %s ? %s (wanted %s)\n' "$1" "$2" "$nv_got" "$3"
        nv_fails=$((nv_fails + 1))
    fi
}

nv_test() {
    # the three bumps, including the carries
    nv_expect 0.1.1 0.1.0 patch
    nv_expect 0.1.10 0.1.9 patch
    nv_expect 0.2.0 0.1.9 minor
    nv_expect 1.0.0 0.9.9 major
    nv_expect 2.0.0 1.4.2 major
    nv_expect 1.5.0 1.4.2 minor
    nv_expect 1.4.3 1.4.2 patch
    nv_expect 10.0.0 9.99.99 major
    # a bump never carries into a field above it
    nv_expect 0.1.0 0.0.9 minor
    nv_expect 0.0.10 0.0.9 patch
    # the leading v is stripped, and the output never has one
    nv_expect 0.1.1 v0.1.0 patch
    # rejected input
    nv_expect_bad 0.2.0-rc1 patch
    nv_expect_bad 1.2 patch
    nv_expect_bad 1.2.3.4 patch
    nv_expect_bad 01.2.3 patch
    nv_expect_bad 1.02.3 patch
    nv_expect_bad '' patch
    nv_expect_bad 1.2.x patch
    nv_expect_bad 0.1.0 nonsense
    # comparison
    nv_expect_gt 0.1.1 0.1.0 yes
    nv_expect_gt 0.1.0 0.1.0 no
    nv_expect_gt 0.1.0 0.1.1 no
    nv_expect_gt 0.2.0 0.1.99 yes
    nv_expect_gt 1.0.0 0.99.99 yes
    nv_expect_gt 0.9.9 1.0.0 no
    nv_expect_gt 0.1.10 0.1.9 yes
    nv_expect_gt v0.1.1 0.1.0 yes
    nv_expect_gt 0.2.0-rc1 0.1.0 bad
    # every bump is strictly newer than its base
    for nv_base in 0.0.1 0.1.9 1.4.2 9.99.99; do
        for nv_lvl in patch minor major; do
            nv_expect_gt "$(nv_next "$nv_base" "$nv_lvl")" "$nv_base" yes
        done
    done

    printf '\n%s assertions, %s failed\n' "$nv_total" "$nv_fails"
    [ "$nv_fails" = 0 ] || exit 1
    return 0
}

# ------------------------------------------------------------------ dispatch
case "${1:-}" in
    --test)
        nv_test
        exit 0
        ;;
    --gt)
        [ $# -eq 3 ] || nv_die "usage: next-version.sh --gt A B"
        nv_rc=0
        nv_gt "$2" "$3" || nv_rc=$?
        [ "$nv_rc" -ne 2 ] || nv_die "'$2' or '$3' is not a plain X.Y.Z version"
        exit "$nv_rc"
        ;;
    '' | -h | --help)
        printf 'usage: next-version.sh BASE BUMP | --gt A B | --test\n' >&2
        exit 2
        ;;
esac

[ $# -eq 2 ] || nv_die "usage: next-version.sh BASE BUMP"
case "$2" in
    major | minor | patch) : ;;
    *) nv_die "'$2' is not a bump level (major, minor or patch)" ;;
esac
nv_next "$1" "$2" || nv_die "'$1' is not a plain X.Y.Z version (no pre-release suffix, no leading zeros)"
