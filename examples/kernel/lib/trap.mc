// trap.mc — machine-mode trap entry: catch one `ecall`, report it, resume
// (M39, docs/specs/M39.md § 4).
//
// Scope, and it is the whole scope: `mcause == 11` (environment call from
// M-mode) on one hart. No CLINT, no timer, no PMP, no S-mode, no MMU, no
// nesting. Anything else is fatal and says so.
//
// `trap_entry` is what `mtvec` points at. It is an ORDINARY mc function whose
// body is `#opcode` words, which works because of exactly two guarantees the
// RISC-V machine states (examples/kernel/README.md § The ABI):
//
//   * the prologue is `addi sp,sp,-16; sd ra,8(sp); sd s0,0(sp); mv s0,sp` and
//     the reserve, and it writes only sp and s0 -- so the interrupted a0..a7
//     and t0..t6 are still intact when the first word of this body runs, and
//     the interrupted ra and s0 are already saved on the stack;
//   * the epilogue starts with `mv sp, s0`, which is what the manual exit below
//     copies: it releases the frame whatever its size, so the exit does not
//     depend on this function having no locals.
//
// The last statement is a bare `mret`. The walker still emits its unconditional
// epilogue behind it -- four instructions and a `ret` that are never reached --
// so a non-`ret` exit needs no mechanism in the compiler at all.

#define RV_RA_N   1
#define RV_SP_N   2
#define RV_S0_N   8
#define TRAP_FRAME 128                   // 8 argument + 7 temporary registers, 16-aligned

// store, load and add with a 12-bit immediate: the three shapes this file needs
// and the language has no way to spell, because the register is fixed and the
// compiler allocates none.
#opcode op_sd(rs2, rs1, off)  0x00003023 | (((off >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | ((off & 0x1f) << 7)
#opcode op_ld(rd, rs1, off)   0x00003003 | ((off & 0xfff) << 20) | (rs1 << 15) | (rd << 7)
#opcode op_addi(rd, rs1, imm) 0x00000013 | ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7)
#opcode op_subi(rd, rs1, imm) 0x00000013 | (((0 - imm) & 0xfff) << 20) | (rs1 << 15) | (rd << 7)

// The C half of the handler: an ordinary function, called ordinarily.
void trap_handler() {
    i64 c = csrr(mcause);
    if (c == 11) {                               // environment call from M-mode
        uart_puts("trap\n");
        return;
    }
    uart_puts("unexpected trap, mcause=");
    uart_putn(c);
    uart_puts("\n");
    halt(2);
}

void trap_entry() {
    op_subi(RV_SP_N, RV_SP_N, TRAP_FRAME);
    op_sd(10, RV_SP_N, 0);                       // a0..a7
    op_sd(11, RV_SP_N, 8);
    op_sd(12, RV_SP_N, 16);
    op_sd(13, RV_SP_N, 24);
    op_sd(14, RV_SP_N, 32);
    op_sd(15, RV_SP_N, 40);
    op_sd(16, RV_SP_N, 48);
    op_sd(17, RV_SP_N, 56);
    op_sd(5, RV_SP_N, 64);                       // t0..t6
    op_sd(6, RV_SP_N, 72);
    op_sd(7, RV_SP_N, 80);
    op_sd(28, RV_SP_N, 88);
    op_sd(29, RV_SP_N, 96);
    op_sd(30, RV_SP_N, 104);
    op_sd(31, RV_SP_N, 112);

    trap_handler();

    // resume after the ecall, not on it. t0 is still saved at this point, which
    // is why the mepc arithmetic comes before the restore and not after.
    csrw mepc, csrr(mepc) + 4;

    op_ld(10, RV_SP_N, 0);
    op_ld(11, RV_SP_N, 8);
    op_ld(12, RV_SP_N, 16);
    op_ld(13, RV_SP_N, 24);
    op_ld(14, RV_SP_N, 32);
    op_ld(15, RV_SP_N, 40);
    op_ld(16, RV_SP_N, 48);
    op_ld(17, RV_SP_N, 56);
    op_ld(5, RV_SP_N, 64);
    op_ld(6, RV_SP_N, 72);
    op_ld(7, RV_SP_N, 80);
    op_ld(28, RV_SP_N, 88);
    op_ld(29, RV_SP_N, 96);
    op_ld(30, RV_SP_N, 104);
    op_ld(31, RV_SP_N, 112);

    op_addi(RV_SP_N, RV_S0_N, 0);                // the epilogue's own `mv sp, s0`
    op_ld(RV_RA_N, RV_SP_N, 8);                  // the interrupted ra and s0, which
    op_ld(RV_S0_N, RV_SP_N, 0);                  // the prologue put there
    op_addi(RV_SP_N, RV_SP_N, 16);
    op_mret();
}
