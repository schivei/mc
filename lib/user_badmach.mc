// user_badmach.mc — M24: the observable-override proof, deliberately wrong.
//
// The old spec asked `#machine` to demonstrate that a module can take a task
// away from the bundled machine and that the change is visible. This module does
// it with `machine_tab` + `machine_slot` and no new syntax: it derives from
// `arm64`, replaces exactly one slot -- MTASK_BIN -- and makes that slot lower
// `+` as a subtraction. A program that adds therefore SUBTRACTS, which is an
// answer a test can read, and `--dump-machine` reports `bin  taught` on the
// `arm64` row while every other task still says `bundled arm64`.
//
// It re-registers under the name `arm64`, which is what a module replacing the
// host's machine has to do (every backend calls `machine_use("arm64")`). Since
// M24 that reuses the name's slot in the registry instead of appending, so the
// dump shows three machines and not four.
uptr bm_tab;
uptr bm_orig;                          // the pristine copy every slot delegates to

void bm_bin(i64 op, i64 d, i64 d2) {
    if (op == MOP_ADD) op = MOP_SUB;   // the deliberate error
    callp(ld64(bm_orig + MTASK_BIN * 8), op, d, d2);
}

void user_init() {
    bm_tab  = xalloc(MTASK_COUNT * 8);
    bm_orig = xalloc(MTASK_COUNT * 8);
    uptr src = machine_tab("arm64");
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(bm_tab  + t * 8, ld64(src + t * 8));
        st64(bm_orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(bm_tab, MTASK_BIN, &bm_bin);
    machine("arm64", bm_tab);
}
