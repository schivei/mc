// core_sandbox.mc — `mc sandbox`: compile and run an arbitrary program in
// isolation (M43, docs/specs/M43.md, docs/reference/sandbox.md).
//
//   toml.mc      the TOML subset mc.toml is written in (M14). `mc sandbox run
//                DIR` has to know which file `mc build` is about to write, and
//                that is [project].out. The #include is once-only, so naming it
//                here costs nothing when <mc/core_build> already brought it and
//                makes this part stand on its own when it did not -- the same
//                argument core_build.mc makes about sha256.mc.
//   sandbox_profiles.mc  GENERATED (scripts/sandbox-trace.sh): the system calls
//                each step is allowed to make, measured with strace on every
//                architecture and every C library
//   sandbox.mc   P: the subcommand `run`/`exec`/`check`, the option parser, the
//                plan, the supervisor, the report and the exit codes
//   seccomp.mc   the two walls: the Landlock ruleset and the seccomp filter C
//                installs, and the notification channel P answers on
//   sandbox_box.mc  I, J and C: the namespaces, the mount tree, the caps and
//                the steps -- everything that runs inside the box
//
// This is the sixth part of the composable core (docs/reference/bundle.md
// § The parts). It is the same shape <mc/core_build> has: one file, one
// *_init() that registers what the part adds, and no line anywhere else in the
// core that knows it exists. A compiler that leaves it out is `mc` without the
// `sandbox` subcommand -- `mc` with no argument prints one usage line fewer,
// and `mc sandbox` there falls through to the ordinary "unknown option"
// handling, which is exactly what scripts/check-parts.sh measures.
//
// It stands on <mc/core_min> alone: everything it needs from the operating
// system it is running on comes from the host file, through host_syscall6(),
// host_sysno() and host_sandbox_supported() (M37's rule -- the host layer is
// where "can you issue system call N?" belongs).

#include "toml.mc"
#include "sandbox_profiles.mc"
#include "sandbox.mc"
#include "seccomp.mc"
#include "sandbox_box.mc"

void mc_sandbox_init() {
    subcommand("sandbox", &sandbox_cmd,
        "       mc sandbox run|exec [OPTS] PATH [--] [ARGS]\n       mc sandbox check\n");
}
