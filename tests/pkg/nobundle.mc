// nobundle.mc -- a compiler with every part of `mc` EXCEPT <mc/core_bundle>.
//
// It exists to make the third step of M44's resolution order reachable from a
// test: a full binary answers `<mc/core>` out of its own blob and never gets
// that far, so the only honest way to exercise the installed-package road today
// is a compiler that has no blob to answer with. `bopen_fn` is never
// registered, every bundled name misses, and `lopen_fn` -- which
// mc_build_init() registers -- is what answers.
//
// This is also, line for line, what M44 § B2's `mc-slim` will be once the empty
// bundle and its glue are checked in; until then the file is a fixture and is
// built by scripts/check-pkg.sh alone.
#include <mc/host>
#include <mc/core_min>
#include <mc/core_machines>
#include <mc/core_writers>
#include <mc/core_build>
#include <user_default>

i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    mc_machines_init();
    mc_writers_init();
    mc_build_init();
    return mc_main(argc, argv, envp);
}
