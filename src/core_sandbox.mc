// core_sandbox.mc — `mc sandbox`: compile and run an arbitrary program in
// isolation (M43, docs/specs/M43.md, docs/reference/sandbox.md).
//
//   sandbox.mc   the subcommand: `run`, `exec`, `check`, the option parser,
//                and -- from step B -- the supervisor, the box and the report
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

#include "sandbox.mc"

void mc_sandbox_init() {
    subcommand("sandbox", &sandbox_cmd,
        "       mc sandbox run|exec [OPTS] PATH [--] [ARGS]\n       mc sandbox check\n");
}
