// kernel_syntax.mc — the Tier 3 half of examples/kernel: three words a
// bare-metal source wants and the core language does not have (M39,
// docs/surface.md § Tier 3).
//
//   mmio UART_BASE 0x10000000;    a named address        (syntax, top level)
//   csrw mtvec, &trap_entry;      write a control CSR    (syntax_stmt)
//   csrr(mcause)                  read one               (syntax_expr)
//   yield;                        hand the CPU over      (syntax_stmt)
//
// None of the four is a code generator: each one produces ORDINARY nodes --
// `mmio` a `#define`, the other three a call to a wrapper that
// examples/kernel/lib/sys_bare.mc writes with `#opcode`. What the module adds
// over writing those calls by hand is the CSR NAME: `csrw mtvec, x` names the
// register in the source, and `csrw mtimecmp, x` is a diagnostic at the point
// of use instead of an undefined symbol at the end of the build.
//
// Depends on parse.mc's public API (p_next/p_ident/p_expect/p_accept/p_line/
// p_file, parse_expr, node_new, def_add) and on hooks.mc (syntax,
// syntax_stmt, syntax_expr).

// The control registers this kernel touches, and the wrapper that reaches each
// one. A machine-mode CSR is a 12-bit number baked into the instruction, so a
// wrapper per register is not a limitation of the sugar -- it is what `#opcode`
// being a compile-time template means.
uptr ks_csr[]   = { "mstatus", "mtvec", "mepc", "mcause", 0 };
uptr ks_csr_w[] = { "csrw_mstatus", "csrw_mtvec", "csrw_mepc", "csrw_mcause" };
uptr ks_csr_r[] = { "csrr_mstatus", "csrr_mtvec", "csrr_mepc", "csrr_mcause" };

uptr ks_csr_at(i64 i)   { return ld64(ks_csr + i * 8); }
uptr ks_csr_w_at(i64 i) { return ld64(ks_csr_w + i * 8); }
uptr ks_csr_r_at(i64 i) { return ld64(ks_csr_r + i * 8); }

i64 ks_csr_find(uptr name) {
    i64 i = 0;
    while (ks_csr_at(i) != 0) {
        if (str_eq(ks_csr_at(i), name)) return i;
        i = i + 1;
    }
    return -1;
}

// a call by name, with the argument list already chained through nd_next
i64 ks_call(uptr name, i64 args, i64 line, uptr fl) {
    i64 n = node_new(N_CALL, line, fl);
    set_nd_name(n, name);
    set_nd_a(n, args);
    set_nd_type(n, TY_I64);
    return n;
}

i64 ks_exprstmt(i64 call, i64 line, uptr fl) {
    i64 n = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(n, call);
    return n;
}

// ---- mmio NAME ADDR;  (syntax, top-level) ----
// The same effect a `#define` has, said in the vocabulary of the thing: the
// name of a device register, its address, and a full stop. It produces no
// declaration at all -- the handler never calls top_add, and parse_top returns
// 0 -- so the whole effect is the entry in the #define table.
void ks_mmio() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `mmio` word
    uptr name = p_ident();
    i64 e = parse_expr(0);
    if (nd_kind(e) != N_INT) err_at(fl, line, "mmio expects a constant address");
    p_expect(K_SEMI, "expected ; after mmio");
    def_add(name, nd_val(e), line, fl);          // rejects an already-defined name
}

// ---- csrw NAME, expr;  (syntax_stmt) ----
i64 ks_csrw() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `csrw` word
    uptr name = p_ident();
    i64 k = ks_csr_find(name);
    if (k < 0) err_at(fl, line, "unknown control register");
    p_expect(K_COMMA, "expected , after the control register");
    i64 v = parse_expr(0);
    p_expect(K_SEMI, "expected ; after csrw");
    return ks_exprstmt(ks_call(ks_csr_w_at(k), v, line, fl), line, fl);
}

// ---- csrr(NAME)  (syntax_expr) ----
i64 ks_csrr() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `csrr` word
    p_expect(K_LPAR, "expected ( after csrr");
    uptr name = p_ident();
    i64 k = ks_csr_find(name);
    if (k < 0) err_at(fl, line, "unknown control register");
    p_expect(K_RPAR, "expected ) after the control register");
    return ks_call(ks_csr_r_at(k), 0, line, fl);
}

// ---- yield;  (syntax_stmt) ----
// The word is reserved by the registration, which is why the function it calls
// is `yield_now` (examples/kernel/lib/sched.mc): a source cannot both teach
// `yield` and declare a function of that name.
i64 ks_yield() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `yield` word
    p_expect(K_SEMI, "expected ; after yield");
    return ks_exprstmt(ks_call("yield_now", 0, line, fl), line, fl);
}

void kernel_syntax_init() {
    syntax("mmio", &ks_mmio);
    syntax_stmt("csrw", &ks_csrw);
    syntax_expr("csrr", &ks_csrr);
    syntax_stmt("yield", &ks_yield);
}
