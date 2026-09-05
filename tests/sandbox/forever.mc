// sandbox-report: killed: cpu limit (2 s)
// sandbox-exit: 124
// The CPU cap (§ 4): RLIMIT_CPU is soft = hard = --time, so the kernel sends
// SIGXCPU at the soft limit and the default action ends the process. It burns
// CPU rather than sleeping on purpose -- the wall clock is a different case
// and sleeper.mc is that one.
i64 spin = 0;

i64 main() {
    loop {
        spin = spin + 1;
    }
    return 0;
}
