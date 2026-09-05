#!/bin/sh
# ci-sandbox-cell.sh CELL MC — one cell of the `sandbox` CI job (M43 step D,
# docs/specs/M43.md § 8, acceptance 10; docs/ci.md § M43).
#
#   sh scripts/ci-sandbox-cell.sh unprivileged build/mc-linux-arm64-gnu
#   sudo sh scripts/ci-sandbox-cell.sh root     build/mc-linux-arm64-gnu
#
# It runs scripts/test-sandbox.sh and then asserts what only a runner can be
# held to. On a developer's machine that script is allowed to give up with one
# printed reason -- no Lima, no Docker, a kernel without seccomp notification --
# and `make check` stays green. Here it is not: this runner has the kernel the
# milestone claims, so
#
#   * the guard may not skip the whole run,
#   * an isolation case may not be skipped (every one of them is meant to run
#     on every supported kernel; only tests/*.mc carry `// skip-` headers),
#   * `exec`, the project and the overhead may not be skipped either -- a
#     missing readelf or a `date` without nanoseconds is a runner that lost a
#     tool, not a fact about the sandbox,
#   * and the summary must say `0 failed`.
#
# Everything it prints comes from the suite; what is added is the verdict.
set -eu

cell="${1:?usage: ci-sandbox-cell.sh CELL MC}"
mc="${2:?usage: ci-sandbox-cell.sh CELL MC}"

log="build/sandbox-$cell.log"
mkdir -p build
rc=0
sh scripts/test-sandbox.sh "$mc" > "$log" 2>&1 || rc=$?
cat "$log"

echo "-- the $cell cell's verdict"
bad=0

if grep -q '^test-sandbox: SKIPPED' "$log"; then
    echo "::error::the sandbox suite skipped itself on a runner that must be able to run it"
    bad=1
fi

# every `skip` line outside the suite block: the suite's own skips are the
# `// skip-linux:` / `// skip-<arch>:` headers of tests/*.mc, and those are a
# property of the test, not of the sandbox.
outside=$(awk '/^-- the suite through/ {inside = 1}
               /^-- mc sandbox exec/  {inside = 0}
               /^skip /               {if (!inside) print}' "$log")
if [ -n "$outside" ]; then
    echo "::error::a case that must run on this runner was skipped:"
    printf '%s\n' "$outside" | sed 's/^/     /'
    bad=1
fi

summary=$(grep '^== test-sandbox:' "$log" || true)
if [ -z "$summary" ]; then
    echo "::error::the suite printed no summary line"
    bad=1
else
    echo "$summary"
    case "$summary" in
        *", 0 failed,"*) ;;
        *) echo "::error::$summary"; bad=1 ;;
    esac
fi

[ "$rc" = 0 ] || { echo "::error::test-sandbox.sh exited $rc"; bad=1; }
[ "$bad" = 0 ] || exit 1
echo "ok   the $cell cell"
exit 0
