// 094-continue-level.mc — `continue N`, the mirror of `break N`.
//
// It lives in tests/mc/ and not in tests/ for the reason every file here lives
// here: the frozen `stage0/parse.c` reads `continue` and then demands a
// semicolon, so `continue 2;` is `expected ; after continue` there, and the
// four cross-checks that compare mc0 against mc1 over tests/*.mc would report
// that as a failure.
//
// Portable to all five targets: the only thing outside the language is `write`,
// declared here rather than through <sys>, so the file has no include at all.
// It runs on macOS (scripts/check-mc.sh, object + --exe), on linux/aarch64 and
// linux/x86_64 (scripts/test-linux.sh) and on windows/arm64 and windows/x86_64
// (scripts/test-windows.sh).
//
// What it proves: the shape the consumer asked for -- a one-iteration inner
// `loop` used as a switch, with `continue 2` restarting the OUTER loop from an
// arm of it. The outer loop has to ADVANCE (its step ran before the switch) and
// the statement after the switch has to be skipped.
// expect-exit: 0
// expect-stdout: 69 3 5

extern i64 write(i64 fd, uptr buf, i64 n);

u8 nbuf[24];

void puti(i64 v) {
    i64 i = 24;
    u64 u = v;
    loop {
        i = i - 1;
        st8(nbuf + i, '0' + u % 10);
        u = u / 10;
        if (u == 0) break;
    }
    write(1, nbuf + i, 24 - i);
}

void sp() { write(1, " ", 1); }

i64 main() {
    i64 i = 0;
    i64 sum = 0;
    i64 fell = 0;              // how many times the switch fell through
    loop {
        if (i >= 5) break;
        i = i + 1;             // the outer step, BEFORE the switch
        loop {                 // one iteration: every arm leaves it
            if (i == 2) { sum = sum + 20; continue 2; }
            if (i == 4) { sum = sum + 40; continue 2; }
            sum = sum + i;
            break;
        }
        fell = fell + 1;       // only reached when the switch fell through
    }
    puti(sum);                 // 1 + 20 + 3 + 40 + 5 = 69
    sp(); puti(fell);          // 3: i = 1, 3, 5
    sp(); puti(i);             // 5: the outer loop did advance and did end
    write(1, "\n", 1);
    return 0;
}
