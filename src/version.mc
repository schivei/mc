// version.mc — the version this binary reports, and the only place it is written.
//
// M44 (docs/specs/M44.md § C, decision D20). Until now the compiler carried no
// version at all: `docs/ci.md` § Versioning says the git tags are the only
// source of truth, and the `VERSION` file that used to exist was deleted so
// that there would not be two. That still holds for RELEASES — what changed is
// that the binary has to be able to answer `mc --version`, and (from the later
// steps of M44) to name the directory its own package lives in,
// `~/.mc/libs/mc/v<version>/`. A constant is not a second source of truth: in
// the working tree it is the SENTINEL `0.0.0-dev` and never a version.
//
// The road from the tag to the string is one script:
//
//   scripts/set-version.sh 0.14.1     # rewrites the return below, runs `make bundle`
//
// which `.github/workflows/release.yml` runs after `make mc1` and before every
// binary it builds, and which never commits. The checked-in tree always says
// `0.0.0-dev`; `scripts/check-bundle.sh` fails `make check` if it does not, so a
// release build cannot be committed by accident (docs/ci.md § Versioning).
//
// Two consequences worth writing down:
//
//   * It is bundled as `mc/version` and included by <mc/core_min>, so a TAUGHT
//     compiler — one a release binary builds out of its own blob — reports the
//     same version as the binary that built it. A version outside the bundle
//     would make it say `0.0.0-dev` and look in the wrong libs directory.
//   * It is not the commit hash. A hash would move src/bundle_data.mc,
//     build/mc2.o and all five goldens on every commit; the goldens are recorded
//     for the dev tree and must not move per release (tests/golden/README.md).
//
// For ordering, `0.0.0-dev` compares as `0.0.0`: every release is newer.

uptr mc_version() { return "0.0.0-dev"; }
