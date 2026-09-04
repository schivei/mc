// noobj.mc — a module whose only job is to register a target that has NO object
// backend: `target(os, arch, 0, exe)`.
//
// That shape is not a curiosity. It is what a board with no separable object
// step registers -- examples/kernel's `rv-image` fills BOTH roles because the
// flat image is the artefact -- and the moment a module can write a 0 into
// either slot, `mc build` can be asked for the role that is not there. The exe
// slot is `macho-exe`, a backend that really exists, so that the advice the
// diagnostic gives (`use kind = "exe"`) is a thing this same compiler can do:
// tests/proj/toy.toml is that build, and it runs.
//
// Used by tests/proj/noobj.toml and tests/proj/toy.toml
// (scripts/check-build.sh).
void user_init() {
    target("toy", "toy", 0, "macho-exe");
}
