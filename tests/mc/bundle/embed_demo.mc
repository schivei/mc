// embed_demo.mc — a BUNDLED module that uses #embed.
//
// It is here, and not in lib/, because scripts/check-asm.sh compiles every
// lib/*.mc and src/*.mc with BOTH mc0 and mc1 and requires identical output:
// `#embed` does not exist in the frozen seed, so a lib/ file using it would
// make that cross-check fail by design. tests/mc/ is outside those globs, and
// tests/mc/bundle/ is outside scripts/check-mc.sh's own `tests/mc/*.mc` glob.
//
// tools/bundle.list carries this file AND its payload, so both are served from
// inside the binary. The point is the resolution: a virtual file has no
// directory, so "embed_demo.txt" has to reach the bundle, not the filesystem.
// See tests/mc/073-embed-bundle.mc.
#embed demo_payload "embed_demo.txt"
