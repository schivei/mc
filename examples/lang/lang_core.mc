// lang_core.mc — the modules of `src/core.mc` this taught compiler is built
// from, with `src/main.mc` replaced by `lang_main.mc` and three files left out:
// `bundle_data.mc`, `bundle.mc` and `backend_elf.mc`. `limits.mc` (M23) IS
// here: `src/driver.mc` calls into it, and it reaches the bundle through the
// lexer's function pointer, so leaving `bundle.mc` out costs only the
// pre-scan of `<name>` includes -- which this compiler cannot have anyway.
//
// `mc.toml` points `[compiler].core` here instead of letting `mc build` take
// the core from the binary's own bundle (`<mc/core>`). The reason is the
// compiler's 32 MiB arena and is measured in lang_main.mc's header: the
// published core plus this module does not fit, this core plus this module
// does. Nothing else changes -- `mc build`, `--exe`, `#dylib` and the whole
// Tier 1/2/3 surface are the same code as `src/`.
//
// M23 removed the CAUSE of that measurement -- the arena now maps one more
// chunk instead of dying -- so this list is no longer forced. It is kept as it
// was verified; dropping `[compiler].core` from `mc.toml` is a change for
// whoever revisits the example, not for the merge that brought M23 in.
//
// The list is duplicated from `src/core.mc`: a module added there has to be
// added here too. That duplication is the price of the workaround and is
// reported as a core gap.

#include "../../src/arena.mc"
#include "../../src/lz.mc"
#include "../../src/macho.mc"
#include "../../src/lex.mc"
#include "../../src/ast.mc"
#include "../../src/parse.mc"
#include "../../src/gen_arm64.mc"
#include "../../src/sha256.mc"
#include "../../src/backend_exe.mc"
#include "../../src/hooks.mc"
#include "../../src/toml.mc"
#include "../../src/driver.mc"
#include "../../src/limits.mc"
#include "lang_main.mc"
