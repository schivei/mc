// atomic.mc -- the atomic words of the concurrency runtime, taught to the
// compiler with `#opcode` and nothing else.
//
// `#opcode` folds constants only (`#opcode argument not constant`,
// src/gen_arm64.mc), so an atomic cannot take an expression: it has to be a
// whole FUNCTION whose operands happen to already sit in x0..x7. That is the
// lib/sys_svc.mc pattern -- the prologue writes the parameters to the frame
// without touching the ABI registers, and a function with no `return` ends in
// an epilogue that leaves x0 alone (docs/reference/objects.md section 4).
//
// The three encodings, as Apple's disassembler prints them back:
//
//     ldaddal x1, x0, [x2]        // x0 = *x2 ; *x2 = *x2 + x1
//     casal   x0, x1, [x2]        // if (*x2 == x0) *x2 = x1 ; x0 = old *x2
//     dmb     ish
//
// LDADDAL and CASAL are ARMv8.1 (FEAT_LSE). A retry loop of `ldaxr`/`stlxr`
// split across two one-word `#opcode` functions is NOT an alternative: the
// frame store and the `ret` between the two halves may clear the exclusive
// monitor, and it happens to pass on Apple silicon, which makes it a silent
// portability trap. Until M24's `#machine` this runtime is LSE-only and
// conc_boot() below says so at startup rather than dying with SIGILL.

#opcode movx(rd, rm)         0xAA0003E0 | (rm << 16) | rd     // orr rd, xzr, rm
#opcode ldaddal(rs, rt, rn)  0xF8E00000 | (rs << 16) | (rn << 5) | rt
#opcode casal(rs, rt, rn)    0xC8E0FC00 | (rs << 16) | (rn << 5) | rt
#opcode dmb_ish()            0xD5033BBF

// *p += v, returning the value *p had before. p arrives in x0 and v in x1;
// movx copies p to x2 BEFORE ldaddal overwrites x0 with the old value.
i64 a_add(uptr p, i64 v) {
    movx(2, 0);
    ldaddal(1, 0, 2);
}

// compare-and-swap: if *p == e then *p = n. Returns the value observed, so the
// swap succeeded exactly when the answer is `e`. e is in x0, n in x1, p in x2;
// casal writes the observed value back into x0, which movx keeps there.
i64 a_cas(i64 e, i64 n, uptr p) {
    casal(0, 1, 2);
    movx(0, 0);
}

// a full barrier, inner shareable. The -AL variants above already carry the
// acquire/release pair, so this is only for the plain ld64/st64 around them.
void a_fence() {
    dmb_ish();
}

// the two plain accesses, fenced: enough for a flag that is written once and
// polled, which is all this runtime uses them for
i64 a_get(uptr p) {
    a_fence();
    return ld64(p);
}

void a_put(uptr p, i64 v) {
    st64(p, v);
    a_fence();
}
