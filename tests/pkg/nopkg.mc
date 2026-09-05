// nopkg.mc -- a compiler with every part of `mc` EXCEPT <mc/core_pkg>: the
// CI and consumer shape of M44 D12.
//
// It reads a lock, finds each package in `deps/` or under <libs>, rehashes it
// and compiles -- all of that is <mc/core_build>'s src/deps.mc -- and it has no
// fetcher, no registry, no MVS and no lock writer at all. `mc pkg` and
// `mc update` are not refusals it has to keep true: the two subcommands do not
// exist in it, so the usage prints two lines fewer and the word `pkg` on its
// command line is an ordinary file name (src/hooks.mc: the usage IS the
// subcommand table).
//
// scripts/check-pkg.sh builds it, checks both of those, and then builds the
// vendored project with it.
#include <mc/host>
#include <mc/core_min>
#include <mc/core_machines>
#include <mc/core_writers>
#include <mc/core_build>
#include <mc/core_bundle>
#include <user_default>

i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    mc_machines_init();
    mc_writers_init();
    mc_bundle_init();
    mc_build_init();
    return mc_main(argc, argv, envp);
}
