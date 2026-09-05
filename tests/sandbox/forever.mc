// sandbox-report: killed: cpu limit (2 s)
// sandbox-exit: 124
// The CPU cap (§ 4): RLIMIT_CPU is soft = hard = --time. With the two equal
// the kernel sends SIGKILL, not SIGXCPU (measured in step B: SIGXCPU is the
// soft-limit warning, and here the hard limit is reached at the same instant),
// and J names it from the rusage. It burns CPU rather than sleeping on purpose
// -- the wall clock is a different case and sleeper.mc is that one.
i64 spin = 0;

i64 main() {
    loop {
        spin = spin + 1;
    }
    return 0;
}
