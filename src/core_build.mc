// core_build.mc — `mc build`, `mc limits` and `mc sysroot`: the project driver.
//
//   toml.mc     the TOML subset mc.toml is written in (M14)
//   driver.mc   `mc build`: reads mc.toml and drives the whole build (M14)
//   sysroots.mc the pinned list of downloadable sysroots (M25)
//   sysroot.mc  where a cross link finds its files, and `mc sysroot` (M25)
//   stubs.mc    .tbd and .def stubs written from the program (M25)
//   limits.mc   the estimate, the reserve and `mc limits` (M23)
//
// sha256.mc comes in because `mc sysroot fetch` verifies a checksum; the
// #include is once-only, so naming it here costs nothing when <mc/core_writers>
// already brought it, and makes this part stand on its own when it did not.
//
// mc_build_init() is the three subcommand() registrations -- which is also what
// makes `mc` with no argument print one usage line per subcommand -- plus the
// pinned sysroot table and the on_plan hook that pre-sizes the compiler's own
// tables (M23). A compiler without this part is a LEAF: it compiles a source
// file, it does not read a project, and its tables grow from the seeds in
// src/arena.mc instead of from an estimate.

#include "sha256.mc"
#include "toml.mc"
#include "driver.mc"
#include "sysroots.mc"
#include "sysroot.mc"
#include "stubs.mc"
#include "limits.mc"

// M23: the pre-scan, behind the hook src/cli.mc calls. With no mc.toml there is
// no tolerance to read, so the default 0.25 applies and the arena stays the
// static heap[] -- exactly what main() did inline before M41.
void mc_plan(uptr src, uptr label) { lim_plan(src, lim_tol, 0, label); }

void mc_build_init() {
    // M25: the pinned rows `mc sysroot list|fetch` reads. Data only -- no I/O
    // and no network until `fetch --yes` (src/sysroots.mc).
    sysroots_init();
    // M14/M23/M25: the three subcommands, each carrying the exact usage text
    // `mc` with no argument prints for it. `sysroot` carries two lines.
    subcommand("build", &drv_build,
        "usage: mc build [DIR] [--config FILE] [--compiler-only] [--limits|--fix-limits] [--sysroot-dir DIR]\n");
    subcommand("limits", &drv_limits,
        "       mc limits [DIR|FILE.mc]\n");
    subcommand("sysroot", &sysroot_cmd,
        "       mc sysroot list|path <target>|fetch <target> [--yes] [--sysroot-dir DIR]\n       mc sysroot stub [DIR] [--config FILE]\n");
    on_plan(&mc_plan);
}
