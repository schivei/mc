// sandbox-report: killed: wall clock (5 s)
// sandbox-exit: 124
// The wall clock (§ 4 Time): a program that uses no CPU at all and never ends.
// `sleep` comes from the libc the box binds at /lib, which is also what makes
// this the dynamic-loader case of the isolation set: the binary the compiler
// wrote inside the box has a PT_INTERP and finds it through the bind mounts and
// nothing else of the host.
extern i64 sleep(i64 seconds);

i64 main() {
    sleep(60);
    return 0;
}
