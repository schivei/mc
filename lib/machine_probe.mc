// machine_probe.mc — M24: a DERIVED machine that changes no instruction and
// asserts the depth-type contract on every task, over whatever it compiles.
//
// It is the acceptance instrument for M4 (`walk_depth_type` / `walk_ret_type`,
// docs/reference/machine.md § 3): a stale or garbage depth type is wrong code,
// not a diagnostic, so the only check that can settle it is one that runs over
// a large real program -- src/mc.mc, ~1000 functions -- and still produces the
// byte-for-byte object the bundled machine produces.
//
// It is also the smallest complete example of M8: `machine_tab("arm64")` is the
// table to copy FROM, `machine_slot` writes the copy the module owns, and every
// wrapper delegates through the pointer it copied, so not one line of integer
// instruction selection is reimplemented here.
//
// What it asserts, at every task that names a depth:
//
//   * the depth is inside 0..MAXDEPTH-1 and its type is a REGISTERED id
//     (0 <= t < type_count()), so an uninitialised or overwritten entry fires;
//   * walk_ret_type() is a registered id too;
//   * at MTASK_CAST(ty, d) the type that is ABOUT to land equals the task's own
//     `ty` argument -- which cross-checks the announcement machinery itself
//     against the one task that carries the answer;
//   * with `--backend=macho-probe-core`, every depth type is a CORE type
//     (below TY_MAX), which is what an untaught program must produce.
//
// Usage: build/mc-probe --backend=macho-probe src/mc.mc -o x.o
// The backend prints `probe: N tasks, M depths` on stderr when it is done, so
// the check can tell "the probe ran and found nothing" from "the probe never
// ran".

uptr pr_tab;                          // the copy this module owns, patched
uptr pr_orig;                         // ...and a PRISTINE copy to delegate to
i64  pr_tasks  = 0;                   // tasks seen
i64  pr_depths = 0;                   // depth arguments checked
i64  pr_core   = 0;                   // 1 = every depth type must be a core type

// The delegation target is the pristine copy, NOT the table the machine drives:
// reading the patched one would make every wrapper call itself. That is the one
// trap in deriving a machine, and it costs eight bytes per slot to avoid.
uptr pr_of(i64 task) { return ld64(pr_orig + task * 8); }

void pr_bad(uptr what, i64 v) {
    out_str(2, "probe: ");
    out_str(2, what);
    out_str(2, " ");
    out_num(2, v);
    out_str(2, "\n");
    die("probe: the depth-type contract does not hold");
}

void pr_ty(i64 t) {
    if (t < 0 || t >= type_count()) pr_bad("type id out of the registry:", t);
    if (pr_core && t >= TY_MAX)     pr_bad("a taught type in an untaught program:", t);
}

// one depth argument of one task
void pr_d(i64 d) {
    pr_depths = pr_depths + 1;
    if (d < 0 || d >= 64) pr_bad("depth out of range:", d);
    pr_ty(walk_depth_type(d));
}

void pr_task() {
    pr_tasks = pr_tasks + 1;
    pr_ty(walk_ret_type());
}

// ---- the wrappers: assert, then delegate through the copied pointer ----
void pr_const(i64 d, i64 imm)          { pr_task(); pr_d(d); callp(pr_of(MTASK_CONST), d, imm); }
void pr_bin(i64 op, i64 d, i64 d2)     { pr_task(); pr_d(d); pr_d(d2);
                                         callp(pr_of(MTASK_BIN), op, d, d2); }
void pr_cmp(i64 c, i64 d, i64 d2)      { pr_task(); pr_d(d); pr_d(d2);
                                         callp(pr_of(MTASK_CMP), c, d, d2); }
void pr_un(i64 op, i64 d)              { pr_task(); pr_d(d); callp(pr_of(MTASK_UN), op, d); }
void pr_bool(i64 d)                    { pr_task(); pr_d(d); callp(pr_of(MTASK_BOOL), d); }
// the one task that carries the answer: what is about to land at d IS `ty`
void pr_cast(i64 ty, i64 d) {
    pr_task(); pr_d(d);
    if (walk_ret_type() != ty) pr_bad("walk_ret_type disagrees with MTASK_CAST:", ty);
    callp(pr_of(MTASK_CAST), ty, d);
}
void pr_load(i64 ty, i64 d)            { pr_task(); pr_d(d); callp(pr_of(MTASK_LOAD), ty, d); }
void pr_store(i64 ty, i64 d)           { pr_task(); pr_d(d); pr_d(d + 1);
                                         callp(pr_of(MTASK_STORE), ty, d); }
void pr_laddr(i64 d, i64 off)          { pr_task(); pr_d(d); callp(pr_of(MTASK_LOCAL_ADDR), d, off); }
void pr_lload(i64 ty, i64 d, i64 off)  { pr_task(); pr_d(d);
                                         callp(pr_of(MTASK_LOCAL_LOAD), ty, d, off); }
void pr_lstore(i64 ty, i64 d, i64 off) { pr_task(); pr_d(d);
                                         callp(pr_of(MTASK_LOCAL_STORE), ty, d, off); }
void pr_saddr(i64 d, i64 sym)          { pr_task(); pr_d(d); callp(pr_of(MTASK_SYM_ADDR), d, sym); }
void pr_gload(i64 ty, i64 d, i64 sym)  { pr_task(); pr_d(d);
                                         callp(pr_of(MTASK_GLOBAL_LOAD), ty, d, sym); }
void pr_gstore(i64 ty, i64 d, i64 sym) { pr_task(); pr_d(d);
                                         callp(pr_of(MTASK_GLOBAL_STORE), ty, d, sym); }
// a call checks EVERY argument depth: this is the half the float ABI reads
void pr_call(i64 d, i64 na, i64 sym) {
    pr_task();
    i64 i = 0;
    loop {
        if (i >= na) break;
        pr_d(d + i);
        i = i + 1;
    }
    callp(pr_of(MTASK_CALL), d, na, sym);
}
void pr_callp(i64 d, i64 na) {
    pr_task();
    i64 i = 0;
    loop {
        if (i >= na) break;
        pr_d(d + i);
        i = i + 1;
    }
    callp(pr_of(MTASK_CALLP), d, na);
}
void pr_ret(i64 d)                     { pr_task(); pr_d(d); callp(pr_of(MTASK_RET), d); }
void pr_jz(i64 d, i64 l)               { pr_task(); pr_d(d); callp(pr_of(MTASK_JZ), d, l); }
void pr_jnz(i64 d, i64 l)              { pr_task(); pr_d(d); callp(pr_of(MTASK_JNZ), d, l); }

void pr_init() {
    pr_tab  = xalloc(MTASK_COUNT * 8);
    pr_orig = xalloc(MTASK_COUNT * 8);
    uptr src = machine_tab("arm64");             // M24 (M8): the table to copy FROM
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(pr_tab  + t * 8, ld64(src + t * 8)); // every slot delegates by default
        st64(pr_orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(pr_tab, MTASK_CONST,        &pr_const);
    machine_slot(pr_tab, MTASK_BIN,          &pr_bin);
    machine_slot(pr_tab, MTASK_CMP,          &pr_cmp);
    machine_slot(pr_tab, MTASK_UN,           &pr_un);
    machine_slot(pr_tab, MTASK_BOOL,         &pr_bool);
    machine_slot(pr_tab, MTASK_CAST,         &pr_cast);
    machine_slot(pr_tab, MTASK_LOAD,         &pr_load);
    machine_slot(pr_tab, MTASK_STORE,        &pr_store);
    machine_slot(pr_tab, MTASK_LOCAL_ADDR,   &pr_laddr);
    machine_slot(pr_tab, MTASK_LOCAL_LOAD,   &pr_lload);
    machine_slot(pr_tab, MTASK_LOCAL_STORE,  &pr_lstore);
    machine_slot(pr_tab, MTASK_SYM_ADDR,     &pr_saddr);
    machine_slot(pr_tab, MTASK_GLOBAL_LOAD,  &pr_gload);
    machine_slot(pr_tab, MTASK_GLOBAL_STORE, &pr_gstore);
    machine_slot(pr_tab, MTASK_CALL,         &pr_call);
    machine_slot(pr_tab, MTASK_CALLP,        &pr_callp);
    machine_slot(pr_tab, MTASK_RET,          &pr_ret);
    machine_slot(pr_tab, MTASK_JZ,           &pr_jz);
    machine_slot(pr_tab, MTASK_JNZ,          &pr_jnz);
    machine("arm64-probe", pr_tab);
}

void pr_report() {
    out_str(2, "probe: ");
    out_num(2, pr_tasks);
    out_str(2, " tasks, ");
    out_num(2, pr_depths);
    out_str(2, " depths\n");
}

// the same three calls backend_macho makes, with the probe machine in effect
void pr_backend(i64 unit, uptr out) {
    machine_use("arm64-probe");
    gen_lower(unit);
    gen_encode_all();
    macho_write(out);
    pr_report();
}

void pr_backend_core(i64 unit, uptr out) {
    pr_core = 1;
    pr_backend(unit, out);
}
