// avr_syntax.mc — the Tier 3 half of examples/avr: four words a register-poking
// source wants and the core language does not have (M40, docs/surface.md
// § Tier 3, and examples/kernel/kernel_syntax.mc one architecture over).
//
//   sfr UCSR0A 0xC0;      a named special function register  (syntax, top level)
//   sbi DDRB, 5;          set one bit of one register        (syntax_stmt)
//   cbi PORTB, 5;         clear one                          (syntax_stmt)
//   if (bit(UCSR0A, 5))   read one                           (syntax_expr)
//
// None of the four is a code generator: each produces ORDINARY nodes -- `sfr` a
// `#define`, the other three an `ld8`/`st8` over constants. What the module adds
// over writing those by hand is that the register and the bit are named at the
// point of use, and that a mistyped register is a diagnostic there rather than a
// number that happens to parse.
//
// An AVR has `sbi`/`cbi` instructions for exactly this, and they reach only the
// low 32 I/O registers -- so these words deliberately do NOT promise them: they
// are a read-modify-write through `ld8`/`st8`, which reaches the whole data
// space including the UART at 0xC0. The machine is free to pattern-match them
// later; nothing in the source has to change if it does.
//
// Depends on parse.mc's public API (p_next/p_ident/p_expect/p_line/p_file,
// parse_expr, node_new, def_add, err_at) and on hooks.mc (syntax, syntax_stmt,
// syntax_expr).

#include "../../lib/prelude.mc"

// a call by name, with the argument list already chained through nd_next
i64 as_call(uptr name, i64 args, i64 line, uptr fl) {
    i64 n = node_new(N_CALL, line, fl);
    set_nd_name(n, name);
    set_nd_a(n, args);
    set_nd_type(n, TY_I64);
    return n;
}

i64 as_int(i64 v, i64 line, uptr fl) {
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 as_bin(i64 op, i64 a, i64 b, i64 line, uptr fl) {
    i64 n = node_new(N_BINARY, line, fl);
    set_nd_op(n, op);
    set_nd_a(n, a);
    set_nd_b(n, b);
    return n;
}

i64 as_exprstmt(i64 e, i64 line, uptr fl) {
    i64 n = node_new(N_EXPRSTMT, line, fl);
    set_nd_a(n, e);
    return n;
}

// A register address and a bit number, both constants: `sfr` made the register
// a #define, so what arrives here is already an N_INT. Anything else is a
// diagnostic at the word, not a pointer arithmetic surprise at run time.
i64 as_const(uptr what) {
    i64 line = p_line();
    uptr fl = p_file();
    i64 e = parse_expr(0);
    if (nd_kind(e) != N_INT) err_at(fl, line, what);
    return nd_val(e);
}

// ---- sfr NAME ADDR;  (syntax, top level) ----
void as_sfr() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `sfr` word
    uptr name = p_ident();
    i64 addr = as_const("sfr expects a constant data address");
    if (addr < 0 || addr > 0xffff) err_at(fl, line, "sfr address outside the data space");
    p_expect(K_SEMI, "expected ; after sfr");
    def_add(name, addr, line, fl);               // rejects an already-defined name
}

// ---- sbi REG, BIT;  /  cbi REG, BIT;  (syntax_stmt) ----
// st8(REG, ld8(REG) | (1 << BIT)) and the same with & ~(1 << BIT), with both
// masks folded here: the source says which bit, the AST says which byte.
i64 as_bitop(i64 set) {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `sbi` / `cbi` word
    i64 reg = as_const("sbi/cbi expects a constant register");
    p_expect(K_COMMA, "expected , after the register");
    i64 bit = as_const("sbi/cbi expects a constant bit number");
    if (bit < 0 || bit > 7) err_at(fl, line, "a bit number is 0..7");
    p_expect(K_SEMI, "expected ; after sbi/cbi");
    i64 mask = 1 << bit;
    i64 op = K_OR;
    if (!set) {
        op = K_AND;
        mask = 0xff - mask;
    }
    i64 rd = as_call("ld8", as_int(reg, line, fl), line, fl);
    i64 val = as_bin(op, rd, as_int(mask, line, fl), line, fl);
    i64 addr = as_int(reg, line, fl);
    set_nd_next(addr, val);
    return as_exprstmt(as_call("st8", addr, line, fl), line, fl);
}

i64 as_sbi() { return as_bitop(1); }
i64 as_cbi() { return as_bitop(0); }

// ---- bit(REG, N)  (syntax_expr) ----
// (ld8(REG) >> N) & 1 -- a real 0 or 1, so it composes with `!` and with a
// comparison and not only with an `if`.
i64 as_bit() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `bit` word
    p_expect(K_LPAR, "expected ( after bit");
    i64 reg = as_const("bit expects a constant register");
    p_expect(K_COMMA, "expected , after the register");
    i64 n = as_const("bit expects a constant bit number");
    if (n < 0 || n > 7) err_at(fl, line, "a bit number is 0..7");
    p_expect(K_RPAR, "expected ) after bit");
    i64 rd = as_call("ld8", as_int(reg, line, fl), line, fl);
    return as_bin(K_AND, as_bin(K_SHR, rd, as_int(n, line, fl), line, fl),
                  as_int(1, line, fl), line, fl);
}

void avr_syntax_init() {
    syntax("sfr", &as_sfr);
    syntax_stmt("sbi", &as_sbi);
    syntax_stmt("cbi", &as_cbi);
    syntax_expr("bit", &as_bit);
}
