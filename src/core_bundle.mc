// core_bundle.mc — `#include <name>`: the standard library carried inside the
// binary (M15, docs/reference/bundle.md).
//
//   bundle_data.mc GENERATED (tools/bundle.mc): lib/ and the core, LZ-compressed
//   bundle.mc      the reader: bundle_find/bundle_read/bundle_open/bundle_emit
//
// This is the expensive part: the blob is most of a compiler's __data. A
// recreated compiler either leaves it out -- and its programs then use relative
// includes, as examples/kernel/lib already does -- or ships its OWN blob, which
// costs no core line at all: generate a bundle_data.mc from your own manifest
// with the four-file tool tools/bundle.mc is, and include that file plus
// <mc/bundle> instead of this part (docs/reference/bundle.md § Your own bundle).

#include "bundle_data.mc"
#include "bundle.mc"

// M15/M37: the lexer's one door into the bundle. `<mc/host>` is not an entry of
// its own -- it is the name of THIS compiler's host file, which is what makes a
// generated taught compiler (src/driver.mc, drv_gen_compiler) portable: the
// same two lines produce a macOS compiler on a macOS host and a Linux one on a
// Linux host. Every other name goes straight through.
//
// It lives here and not in src/bundle.mc because host_include() is the host
// layer's, and tools/bundle.mc includes src/bundle.mc with no host layer at all.
uptr host_bundle_open(uptr name, i64 base, uptr pcanon, uptr plen) {
    if (str_eq(name, "mc/host")) name = host_include();
    return bundle_open(name, base, pcanon, plen);
}

// M15: the lexer only reaches the bundle through this pointer, so
// src/lexdump.mc and src/astdump.mc keep compiling without src/bundle.mc.
// Registered before any lex_init -- including the one inside `mc build`, which
// goes through the same main().
void mc_bundle_init() { lex_set_bundle(&host_bundle_open); }
