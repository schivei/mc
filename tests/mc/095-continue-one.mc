// 095-continue-one.mc — `continue 1;` is `continue;`, and `continue 3` reaches
// the outermost of three loops.
//
// In tests/mc/ for the same reason as 094: the frozen seed answers
// `expected ; after continue` at the level.
//
// Portable to all five targets; no include, `write` declared here.
//
// What it proves: the level a plain `continue;` means is 1 -- the two halves
// run the same code and print the same number -- and that a level counts
// enclosing LOOPS and not enclosing blocks, since the `continue 3` sits inside
// two `if` blocks that are not loops.
// expect-exit: 0
// expect-stdout: 25 25 7

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

// sum of the odd numbers below 10, skipping the even ones with a bare continue
i64 bare() {
    i64 i = 0;
    i64 s = 0;
    loop {
        if (i >= 10) break;
        i = i + 1;
        if (i % 2 == 0) continue;
        s = s + i;
    }
    return s;
}

// the same function with the level written out
i64 one() {
    i64 i = 0;
    i64 s = 0;
    loop {
        if (i >= 10) break;
        i = i + 1;
        if (i % 2 == 0) continue 1;
        s = s + i;
    }
    return s;
}

// three nested loops, the innermost restarting the outermost from inside two
// `if` blocks: a block is not a loop and does not count as a level
i64 three() {
    i64 a = 0;
    i64 n = 0;
    loop {
        if (a >= 3) break;
        a = a + 1;
        i64 b = 0;
        loop {
            if (b >= 3) break;
            b = b + 1;
            loop {
                n = n + 1;                   // once per (a, b) pair reached
                if (a == 2) {
                    if (b == 1) continue 3;  // abandon the whole middle loop
                }
                break;
            }
        }
    }
    // a = 1 runs b = 1, 2, 3 (n = 3); a = 2 leaves at b = 1 through
    // `continue 3` (n = 4); a = 3 runs b = 1, 2, 3 again (n = 7)
    return n;
}

i64 main() {
    puti(bare());
    sp(); puti(one());
    // a = 1: b = 1, 2, 3, the innermost breaking each time (n = 3); a = 2:
    // b = 1 reaches `continue 3`, which abandons the middle loop and restarts
    // the outer one (n = 4); a = 3: b = 1, 2, 3 again (n = 7). Then a >= 3
    // ends the outer loop. n = 7 -- it would be 9 if `continue 3` restarted
    // the MIDDLE loop (a = 2 would then run b = 2 and b = 3 as well), and the
    // program would not terminate at all if it restarted the innermost one.
    sp(); puti(three());
    write(1, "\n", 1);
    return 0;
}
