// core_pkg.mc — `mc pkg` and `mc update`: resolving, fetching and locking a
// dependency (M44 § 7, D12, D21).
//
//   core_build.mc  the part this one extends -- and the once-only #include is
//                  what lets an entry name `<mc/core_pkg>` alone and get the
//                  driver with it
//   pkg.mc         the index, MVS, the lock writer, the archive fetch, vendor,
//                  add, list, verify, hash and the registry gate check
//
// The split is the M41 debloat argument applied to packages. The READ side --
// `[deps]`, `mc.lock`, the tree hash, `#include <pack/file.mc>`, the refusals --
// is src/deps.mc, inside <mc/core_build>: a compiler with `mc build` and
// without this part still builds a project from its lock and its `deps/` tree,
// which is the CI and consumer shape, and it is what makes "`mc build` never
// downloads" a property of the code. Leave THIS part out and the two usage
// lines below disappear with it, because the usage IS the subcommand table.

#include "core_build.mc"
#include "pkg.mc"

// `update` is top-level and not `mc pkg update` (D21): the user-facing verbs
// read like `mc build`, and the package-author and maintenance ones stay under
// `mc pkg`. It lives here rather than in <mc/core_build> because raising a
// minimum needs the index and MVS, which are this part's.
void mc_pkg_init() {
    subcommand("pkg", &pkg_cmd,
        "       mc pkg sync|add|list|vendor|verify [DIR] [--yes] [--registry URL|DIR] [--libs-dir DIR]\n       mc pkg hash DIR | check INDEX.toml [--yes]\n");
    subcommand("update", &update_cmd,
        "       mc update [NAME] [DIR] [--yes] [--registry URL|DIR] [--libs-dir DIR]\n");
}
