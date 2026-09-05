// sandbox-report: killed: wall clock (5 s)
// sandbox-exit: 124
// sandbox-opts: --allow=threads
// The wall clock (§ 4 Time): a program that uses no CPU at all and never ends.
// It runs with --allow=threads because sleeping is a thing the default profile
// does not allow: clock_nanosleep and nanosleep are in the threads delta,
// measured (scripts/sandbox-trace.sh), and without the flag this program would
// be refused at its `sleep` instead of being killed at its deadline.
// `sleep` comes from the libc the box binds at /lib, which is also what makes
// this the dynamic-loader case of the isolation set: the binary the compiler
// wrote inside the box has a PT_INTERP and finds it through the bind mounts and
// nothing else of the host.
extern i64 sleep(i64 seconds);

i64 main() {
    sleep(60);
    return 0;
}
