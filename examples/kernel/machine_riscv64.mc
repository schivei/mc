// machine_riscv64.mc — the RISC-V 64 (RV64IM) machine, written entirely
// OUTSIDE the compiler (M39, docs/specs/M39.md; the contract is
// docs/reference/machine.md).
//
// It fills the same thirty-one slots src/machine_arm64.mc and
// src/machine_x86_64.mc fill, so src/gen_walk.mc never learns a third
// instruction set — and this file lives under examples/, which is the whole
// point of the milestone: an architecture is a module, not a compiler change.
//
// What differs from the two machines in src/:
//
//   * depths 0..3 in t3..t6 (x28..x31) and the rest spilled — those four are
//     what is left once the callee-saved half (s1..s11) and the argument
//     registers are off the table, the same rule that produced x9..x15 on
//     AArch64 and r8..r11 on x86-64;
//   * three scratch registers: t0 (left/destination, and callp's pointer),
//     t1 (right) and t2, which materialises an address and NOTHING else — it
//     is the register the four big-offset fallbacks below borrow;
//   * locals at [s0 - off], correct from the first instruction, and an
//     epilogue that starts with `mv sp, s0`, so MTASK_FRAME_FIX patches ONE
//     instruction and the epilogue is never patched at all;
//   * RV's store/load displacement is a SIGNED 12-bit field and reaches 2047,
//     where the walker's language-wide frame limit is 4095 (an AArch64
//     UNSIGNED 12-bit). docs/specs/M39.md § G7 decides that the limit stays
//     uniform and the MACHINE pays: above 2047 the offset is materialised in
//     t2 and added. That is why V_ADDI, the eight memory opcodes and V_FRAME
//     are variable-length, and why MTASK_INS_SIZE runs the real encoder over a
//     scratch buffer (rv_put) instead of a switch that could disagree with it.
//
// Two relocation kinds are private to this module (docs/specs/M39.md D6,
// following src/machine_x86_64.mc:52's precedent): 32 for the fused
// `auipc rd,0 + addi rd,rd,0` pair that materialises a symbol's address, and 33
// for the fused `auipc ra,0 + jalr ra,ra,0` pair that calls one. Each pair is
// ONE 8-byte Ins carrying ONE relocation at offset 0, which is what keeps the
// walker's "one implicit relocation per instruction" rule intact (M39 § G3).
// examples/kernel/image.mc is what resolves them.
//
// Depends on gen_walk.mc (the Ins buffer, ins_add/e0/e2/e3/ei/el/elr/em,
// slot_new, the MTASK_/MOP_/MUN_/MCOND_ vocabulary and MAXDEPTH), on arena.mc
// (buf_*, out_str, out_num, die) and on macho.mc (sym_name, sym_at).

// ---- registers, by their RISC-V encoding number ----
#define RV_ZERO 0
#define RV_RA   1
#define RV_SP   2
#define RV_S0   8                     // the frame pointer; every local hangs off it

#define RVREG_BASE 28                 // depths 0..3 in t3..t6
#define RVREG_MAX   3
#define RVREG_S1    5                 // t0: left / destination, and callp's pointer
#define RVREG_S2    6                 // t1: right
#define RVREG_TMP   7                 // t2: address materialisation, nothing else
#define RVREG_A0   10                 // a0..a7 are x10..x17
#define RV_ARGS     8                 // arguments 1..8 in registers, 9..12 on the stack

// relocation kinds this machine produces. They travel in the same Reloc record
// as the Mach-O ones, so their numbers only have to avoid R_UNSIGNED..R_ADDEND
// (0..4 and 10) and machine_x86_64.mc's 16/17.
#define RVK_PCREL_LA   32             // auipc rd,0 + addi rd,rd,0
#define RVK_PCREL_CALL 33             // auipc ra,0 + jalr ra,ra,0

// ---- opcodes. 0 is I_LABEL and belongs to the walker, so these start at 1.
// The numbers overlap the other two machines' on purpose: only one machine ever
// encodes an Ins buffer, and the vocabularies never meet. ----
#define V_NOP    1                    // erased by the frame fixup, no bytes
#define V_LI     2                    // li rd, imm            1..8 words
#define V_ADD    3
#define V_SUB    4
#define V_MUL    5
#define V_DIV    6
#define V_DIVU   7
#define V_REM    8
#define V_REMU   9
#define V_AND   10
#define V_OR    11
#define V_XOR   12
#define V_SLL   13
#define V_SRL   14
#define V_SRA   15
#define V_SLT   16
#define V_SLTU  17
#define V_ADDI  18                    // addi rd, rn, imm      (t2 fallback above 2047)
#define V_XORI  19
#define V_SLTIU 20
#define V_ANDI  21
#define V_SLLI  22
#define V_SRLI  23
#define V_LBU   24                    // the eight memory forms: rd value, rn base, imm off
#define V_LHU   25
#define V_LWU   26
#define V_LD    27
#define V_SB    28
#define V_SH    29
#define V_SW    30
#define V_SD    31
#define V_LA    32                    // auipc + addi, 8 bytes, reloc RVK_PCREL_LA
#define V_CALL  33                    // auipc + jalr, 8 bytes, reloc RVK_PCREL_CALL
#define V_JALR  34                    // jalr ra, rd, 0        callp's indirect call
#define V_RET   35                    // jalr zero, ra, 0
#define V_J     36                    // jal zero, L
#define V_JZ    37                    // bne rd,zero,+8 ; jal zero,L    8 bytes
#define V_JNZ   38                    // beq rd,zero,+8 ; jal zero,L    8 bytes
#define V_FRAME 39                    // addi sp,sp,-imm       (t2 fallback above 2048)
#define V_EMIT  40                    // one raw 32-bit word
// M45: the signed halves. A TK_SINT load sign-extends (lb/lh/lw against
// lbu/lhu/lwu) and a cast to one fills the bytes above its width with the sign
// -- a shift pair at 1 and 2 bytes, and `sext.w` (addiw rd, rn, 0) at 4.
#define V_SRAI  41                    // srai rd, rn, shamt    (funct6 0x10)
#define V_ADDIW 42                    // addiw rd, rn, imm     opcode 0x1b
#define V_LB    43
#define V_LH    44
#define V_LW    45
#define V_COUNT 46

// ---- the instruction tables. The encoder and the dump read the same ones. ----
// R-type, three registers: rd, rn, rm
i64  rv_rop[]   = { V_ADD, V_SUB, V_MUL, V_DIV, V_DIVU, V_REM, V_REMU, V_AND,
                    V_OR, V_XOR, V_SLL, V_SRL, V_SRA, V_SLT, V_SLTU, 0 };
i64  rv_rf7[]   = { 0, 0x20, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0x20, 0, 0 };
i64  rv_rf3[]   = { 0, 0, 0, 4, 5, 6, 7, 7, 6, 4, 1, 5, 5, 2, 3 };
uptr rv_rname[] = { "add", "sub", "mul", "div", "divu", "rem", "remu", "and",
                    "or", "xor", "sll", "srl", "sra", "slt", "sltu" };
// I-type, register + 12-bit immediate
// M45 adds a funct6 column, 0 for every row that existed: srai is srli with
// 0x10 in the high SIX bits of the immediate field. RV64I's shift-immediate
// forms take a 6-bit shamt (bits 25:20), so the differentiator above it is a
// funct6 at bits 31:26 -- not the funct7 the REGISTER forms (sll/srl/sra) carry
// at 31:25. The single value used lands on bit 30 either way, so the encoding
// was right when this column was called funct7 and shifted by 5; a multi-bit
// value would not have been, which is why the column now says what it is.
i64  rv_iop[]   = { V_ADDI, V_XORI, V_SLTIU, V_ANDI, V_SLLI, V_SRLI, V_SRAI, 0 };
i64  rv_if3[]   = { 0, 4, 3, 7, 1, 5, 5 };
i64  rv_if6[]   = { 0, 0, 0, 0, 0, 0, 0x10 };
uptr rv_iname[] = { "addi", "xori", "sltiu", "andi", "slli", "srli", "srai" };
// memory, widest to narrowest, load then store at each width; M45 appends the
// three SIGNED loads, each sharing the store of its width
i64  rv_mop[]   = { V_LD, V_SD, V_LWU, V_SW, V_LHU, V_SH, V_LBU, V_SB,
                    V_LW, V_SW, V_LH, V_SH, V_LB, V_SB, 0 };
i64  rv_mf3[]   = { 3, 3, 6, 2, 5, 1, 4, 0,
                    2, 2, 1, 1, 0, 0 };
i64  rv_mstore[] = { 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1 };
uptr rv_mname[] = { "ld", "sd", "lwu", "sw", "lhu", "sh", "lbu", "sb",
                    "lw", "sw", "lh", "sh", "lb", "sb" };
// the MOP_* vocabulary, in its own order, spelled in RV64IM. Every one of the
// thirteen is a single R-type instruction: no msub, no cqo/idiv, no special case.
i64 rv_binop[] = { V_ADD, V_SUB, V_MUL, V_DIV, V_DIVU, V_REM, V_REMU,
                   V_AND, V_OR, V_XOR, V_SLL, V_SRL, V_SRA };
// arguments 1..8
i64 rv_argreg[] = { 10, 11, 12, 13, 14, 15, 16, 17 };

uptr rv_regname[] = { "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
                      "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
                      "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
                      "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6" };

uptr m_rv64[MTASK_COUNT];             // the task table the walker drives
u8   rv_tmp[BUF_SIZE];                // scratch the size task encodes into
i64  rvdslot[MAXDEPTH];               // frame slot of a depth: 0 = not asked for yet
i64  rv_ires = 0;                     // the prologue's reserve, patched last
i64  rv_out  = 0;                     // bytes of OUTGOING stack arguments

i64  rv_rop_at(i64 i)    { return ld64(rv_rop + i * 8); }
i64  rv_rf7_at(i64 i)    { return ld64(rv_rf7 + i * 8); }
i64  rv_rf3_at(i64 i)    { return ld64(rv_rf3 + i * 8); }
uptr rv_rname_at(i64 i)  { return ld64(rv_rname + i * 8); }
i64  rv_iop_at(i64 i)    { return ld64(rv_iop + i * 8); }
i64  rv_if3_at(i64 i)    { return ld64(rv_if3 + i * 8); }
i64  rv_if6_at(i64 i)    { return ld64(rv_if6 + i * 8); }
uptr rv_iname_at(i64 i)  { return ld64(rv_iname + i * 8); }
i64  rv_mop_at(i64 i)    { return ld64(rv_mop + i * 8); }
i64  rv_mf3_at(i64 i)    { return ld64(rv_mf3 + i * 8); }
i64  rv_mstore_at(i64 i) { return ld64(rv_mstore + i * 8); }
uptr rv_mname_at(i64 i)  { return ld64(rv_mname + i * 8); }
i64  rv_binop_at(i64 i)  { return ld64(rv_binop + i * 8); }
i64  rv_argreg_at(i64 i) { return ld64(rv_argreg + i * 8); }
uptr rv_regname_at(i64 i) { return ld64(rv_regname + i * 8); }
i64  rvdslot_at(i64 i)   { return ld64(rvdslot + i * 8); }
void set_rvdslot_at(i64 i, i64 v) { st64(rvdslot + i * 8, v); }

// index into the R/I/memory tables, or -1
i64 rv_rslot(i64 op) {
    i64 i = 0;
    while (rv_rop_at(i) != 0) {
        if (rv_rop_at(i) == op) return i;
        i = i + 1;
    }
    return -1;
}

i64 rv_islot(i64 op) {
    i64 i = 0;
    while (rv_iop_at(i) != 0) {
        if (rv_iop_at(i) == op) return i;
        i = i + 1;
    }
    return -1;
}

i64 rv_mslot(i64 op) {
    i64 i = 0;
    while (rv_mop_at(i) != 0) {
        if (rv_mop_at(i) == op) return i;
        i = i + 1;
    }
    return -1;
}

// access of width t; the even positions are load, the odd ones store
// M45: by WIDTH and, for a load, by KIND -- never by the id (contract v4).
i64 rv_mem_op(i64 t, i64 store) {
    i64 w = type_width(t);
    i64 i = 0;                            // 8 bytes, and any width with no form here
    if (w == 4)      i = 2;
    else if (w == 2) i = 4;
    else if (w == 1) i = 6;
    if (store) return rv_mop_at(i + 1);
    if (i && type_kind(t) == TK_SINT) i = i + 6;
    return rv_mop_at(i);
}

// ---- depth, register and spill ----
i64 rv_slot_depth(i64 d) {
    if (rvdslot_at(d) == 0) set_rvdslot_at(d, slot_new(8));
    return rvdslot_at(d);
}

i64 rv_in_reg(i64 depth) { return depth <= RVREG_MAX; }

// the register holding the depth's value; a spilled one is loaded into scratch
i64 rv_val_reg(i64 depth, i64 scratch) {
    if (rv_in_reg(depth)) return RVREG_BASE + depth;
    em(V_LD, scratch, RV_S0, 0 - rv_slot_depth(depth));
    return scratch;
}

i64 rv_dst_reg(i64 depth) {
    if (rv_in_reg(depth)) return RVREG_BASE + depth;
    return RVREG_S1;
}

void rv_dst_done(i64 depth, i64 rd) {
    if (!rv_in_reg(depth)) em(V_SD, rd, RV_S0, 0 - rv_slot_depth(depth));
}

// t3..t6 are caller-saved, so the live depths go to the frame around a call
void rv_save_live(i64 depth) {
    i64 d = 0;
    while (d < depth && rv_in_reg(d)) {
        em(V_SD, RVREG_BASE + d, RV_S0, 0 - rv_slot_depth(d));
        d = d + 1;
    }
}

void rv_restore_live(i64 depth) {
    i64 d = 0;
    while (d < depth && rv_in_reg(d)) {
        em(V_LD, RVREG_BASE + d, RV_S0, 0 - rv_slot_depth(d));
        d = d + 1;
    }
}

void rv_mv(i64 rd, i64 rn) { if (rd != rn) ei(V_ADDI, rd, rn, 0); }

// moves depth d into register r (an ABI one, or callp's t0)
void rv_arg_to(i64 r, i64 d) {
    if (rv_in_reg(d)) { rv_mv(r, RVREG_BASE + d); return; }
    em(V_LD, r, RV_S0, 0 - rv_slot_depth(d));
}

// ---- the tasks ----
// The frame record is unconditional (a stack walk depends on it) and the
// reserve is a placeholder until rv_frame_fix knows the size:
//
//     addi sp, sp, -16
//     sd   ra, 8(sp)
//     sd   s0, 0(sp)
//     mv   s0, sp          <- s0 = entry sp - 16, so [s0+16] is the caller's sp
//     addi sp, sp, -F      <- V_FRAME, patched last, erased when F == 0
void rv_prologue() {
    i64 d = 0;
    while (d < MAXDEPTH) {
        set_rvdslot_at(d, 0);
        d = d + 1;
    }
    rv_out = 0;
    ei(V_ADDI, RV_SP, RV_SP, 0 - 16);
    em(V_SD, RV_RA, RV_SP, 8);
    em(V_SD, RV_S0, RV_SP, 0);
    ei(V_ADDI, RV_S0, RV_SP, 0);
    rv_ires = nins;
    ins_add(V_FRAME, 0, 0, 0, 0, 0, 0);
}

// parameter i arrives in a_i and goes to its slot, without the prologue ever
// writing an argument register (docs/reference/objects.md § 4 -- this machine's
// half of it is examples/kernel/README.md § The ABI). Parameters 9..12 did not
// arrive in a register at all: the caller left them at its own [sp + 8*(i-8)],
// which is [s0 + 16 + 8*(i-8)] here because the prologue's `addi sp,sp,-16` is
// what moved sp by 16.
//
// t0 carries a stack parameter, never t2: the store into the slot may itself
// need t2 for a frame offset past 2047.
void rv_param(i64 ty, i64 i, i64 off) {
    if (i < RV_ARGS) { em(rv_mem_op(ty, 1), rv_argreg_at(i), RV_S0, 0 - off); return; }
    em(V_LD, RVREG_S1, RV_S0, 16 + (i - RV_ARGS) * 8);
    em(rv_mem_op(ty, 1), RVREG_S1, RV_S0, 0 - off);
}

// `mv sp, s0` releases the reserve whatever its size, so nothing here is ever
// patched -- which is also what makes a stack switch expressible: a function
// that swaps s0 with another task's returns onto that task's stack
// (examples/kernel/lib/sched.mc).
void rv_epilogue() {
    ei(V_ADDI, RV_SP, RV_S0, 0);
    em(V_LD, RV_RA, RV_SP, 8);
    em(V_LD, RV_S0, RV_SP, 0);
    ei(V_ADDI, RV_SP, RV_SP, 16);
    e0(V_RET);
}

// The outgoing-argument area is part of the frame, at its bottom, exactly as on
// AArch64: sp does not move inside the body, so [sp + 8*k] at the call is a
// fixed address and the callee reads it above its own record.
void rv_frame_fix(i64 frame) {
    i64 f = frame + rv_out;
    set_ins_imm(ins_at(rv_ires), f);
    if (f == 0) set_ins_op(ins_at(rv_ires), V_NOP);
}

void rv_const(i64 d, i64 imm) {
    i64 rd = rv_dst_reg(d);
    ins_add(V_LI, rd, 0, 0, imm, 0, 0);
    rv_dst_done(d, rd);
}

// every MOP_* is one R-type instruction; sll/srl/sra already mask the count
// modulo 64, which is mc's own rule
void rv_bin(i64 op, i64 d, i64 d2) {
    i64 rl = rv_val_reg(d, RVREG_S1);
    i64 rr = rv_val_reg(d2, RVREG_S2);
    i64 rd = rv_dst_reg(d);
    e3(rv_binop_at(op), rd, rl, rr);
    rv_dst_done(d, rd);
}

// slt/sltu give < directly; the other four are that plus one instruction
void rv_cmp(i64 cond, i64 d, i64 d2) {
    i64 rl = rv_val_reg(d, RVREG_S1);
    i64 rr = rv_val_reg(d2, RVREG_S2);
    i64 rd = rv_dst_reg(d);
    if (cond == MCOND_EQ) {
        e3(V_SUB, rd, rl, rr);
        ei(V_SLTIU, rd, rd, 1);                  // seqz
    } else if (cond == MCOND_NE) {
        e3(V_SUB, rd, rl, rr);
        e3(V_SLTU, rd, RV_ZERO, rd);             // snez
    } else if (cond == MCOND_LT) {
        e3(V_SLT, rd, rl, rr);
    } else if (cond == MCOND_GT) {
        e3(V_SLT, rd, rr, rl);
    } else if (cond == MCOND_LE) {
        e3(V_SLT, rd, rr, rl);
        ei(V_XORI, rd, rd, 1);
    } else {
        e3(V_SLT, rd, rl, rr);                   // MCOND_GE
        ei(V_XORI, rd, rd, 1);
    }
    rv_dst_done(d, rd);
}

void rv_un(i64 op, i64 d) {
    i64 rd = rv_val_reg(d, RVREG_S1);            // operates in place
    if (op == MUN_NEG)      e3(V_SUB, rd, RV_ZERO, rd);
    else if (op == MUN_NOT) ei(V_XORI, rd, rd, 0 - 1);
    else                    ei(V_SLTIU, rd, rd, 1);
    rv_dst_done(d, rd);
}

void rv_bool(i64 d) {
    i64 rv = rv_val_reg(d, RVREG_S1);
    i64 rd = rv_dst_reg(d);
    e3(V_SLTU, rd, RV_ZERO, rv);
    rv_dst_done(d, rd);
}

// andi reaches 0xff; 0xffff and 0xffffffff do not fit a signed 12-bit field, so
// they are a shift pair
// M45: fill the bytes above the type's width -- zero for a TK_INT, the sign for
// a TK_SINT -- by width and kind, never by the id
void rv_cast(i64 ty, i64 d) {
    i64 rd = rv_val_reg(d, RVREG_S1);
    i64 w = type_width(ty);
    i64 sgn = type_kind(ty) == TK_SINT;
    if (w == 1) {
        if (sgn) { ei(V_SLLI, rd, rd, 56); ei(V_SRAI, rd, rd, 56); }
        else       ei(V_ANDI, rd, rd, 0xff);
    } else if (w == 2) {
        ei(V_SLLI, rd, rd, 48);
        if (sgn) ei(V_SRAI, rd, rd, 48);
        else     ei(V_SRLI, rd, rd, 48);
    } else if (w == 4) {
        if (sgn) ei(V_ADDIW, rd, rd, 0);             // sext.w
        else { ei(V_SLLI, rd, rd, 32); ei(V_SRLI, rd, rd, 32); }
    }
    rv_dst_done(d, rd);
}

void rv_load(i64 ty, i64 d) {
    i64 rp = rv_val_reg(d, RVREG_S1);
    i64 rd = rv_dst_reg(d);
    em(rv_mem_op(ty, 0), rd, rp, 0);             // lbu/lhu/lwu/ld zero-extend already
    rv_dst_done(d, rd);
}

void rv_store(i64 ty, i64 d) {
    i64 rp = rv_val_reg(d, RVREG_S1);
    i64 rv = rv_val_reg(d + 1, RVREG_S2);
    em(rv_mem_op(ty, 1), rv, rp, 0);
}

void rv_local_addr(i64 d, i64 off) {
    i64 rd = rv_dst_reg(d);
    ei(V_ADDI, rd, RV_S0, 0 - off);
    rv_dst_done(d, rd);
}

void rv_local_load(i64 ty, i64 d, i64 off) {
    i64 rd = rv_dst_reg(d);
    em(rv_mem_op(ty, 0), rd, RV_S0, 0 - off);
    rv_dst_done(d, rd);
}

void rv_local_store(i64 ty, i64 d, i64 off) {
    em(rv_mem_op(ty, 1), rv_val_reg(d, RVREG_S2), RV_S0, 0 - off);
}

// pc-relative and fused: ONE 8-byte Ins, ONE relocation at offset 0
void rv_sym_addr(i64 d, i64 sym) {
    i64 rd = rv_dst_reg(d);
    ins_add(V_LA, rd, 0, 0, 0, 0, sym);
    rv_dst_done(d, rd);
}

void rv_global_load(i64 ty, i64 d, i64 sym) {
    i64 rd = rv_dst_reg(d);
    ins_add(V_LA, rd, 0, 0, 0, 0, sym);
    em(rv_mem_op(ty, 0), rd, rd, 0);
    rv_dst_done(d, rd);
}

// t0 is free here: the value is already lowered and nothing else lives in it
void rv_global_store(i64 ty, i64 d, i64 sym) {
    ins_add(V_LA, RVREG_S1, 0, 0, 0, 0, sym);
    em(rv_mem_op(ty, 1), rv_val_reg(d, RVREG_S2), RVREG_S1, 0);
}

// M38: arguments 9..12 travel on the stack, at [sp + 0], [sp + 8]... at the
// moment of the call, which is where the callee's rv_param reads them. The area
// is reserved at the BOTTOM of the frame (rv_frame_fix adds rv_out), never with
// an sp that moves inside the body: every local and every spill is addressed
// from s0, but the outgoing stores name sp, and sp is only stable if it does
// not move.
//
// The stores come BEFORE the argument registers are written: they read the
// depth registers t3..t6, which a0..a7 cannot clobber, and they may need t0 to
// carry a spilled depth.
void rv_stack_args(i64 dbase, i64 na) {
    if (na <= RV_ARGS) return;
    i64 need = ((na - RV_ARGS) * 8 + 15) & ~15;  // sp stays 16-byte aligned
    if (need > rv_out) rv_out = need;
    i64 i = RV_ARGS;
    while (i < na) {
        i64 d = dbase + i;
        i64 r = RVREG_S1;
        if (rv_in_reg(d)) r = RVREG_BASE + d;
        else              em(V_LD, RVREG_S1, RV_S0, 0 - rv_slot_depth(d));
        em(V_SD, r, RV_SP, (i - RV_ARGS) * 8);
        i = i + 1;
    }
}

void rv_reg_args(i64 dbase, i64 na) {
    i64 n = na;
    if (n > RV_ARGS) n = RV_ARGS;
    i64 i = 0;
    while (i < n) {
        rv_arg_to(rv_argreg_at(i), dbase + i);
        i = i + 1;
    }
}

void rv_call(i64 d, i64 na, i64 sym) {
    rv_save_live(d);
    rv_stack_args(d, na);
    rv_reg_args(d, na);
    ins_add(V_CALL, 0, 0, 0, 0, 0, sym);
    rv_restore_live(d);
    i64 rd = rv_dst_reg(d);
    rv_mv(rd, RVREG_A0);
    rv_dst_done(d, rd);
}

// callp(p, a1..a11): the pointer (argument 0) goes to t0, outside the ABI, and
// it moves LAST -- after a0..a7 are written. Its source is a depth register
// (t3..t6) or a frame slot, and neither can be clobbered by a write to an
// argument register, so moving it last is what makes the order safe.
void rv_callp(i64 d, i64 na) {
    rv_save_live(d);
    rv_stack_args(d + 1, na - 1);
    rv_reg_args(d + 1, na - 1);
    rv_arg_to(RVREG_S1, d);
    ins_add(V_JALR, RVREG_S1, 0, 0, 0, 0, 0);
    rv_restore_live(d);
    i64 rd = rv_dst_reg(d);
    rv_mv(rd, RVREG_A0);
    rv_dst_done(d, rd);
}

void rv_ret(i64 d)        { rv_mv(RVREG_A0, rv_val_reg(d, RVREG_S1)); }
void rv_jump(i64 l)       { el(V_J, l); }
void rv_jz(i64 d, i64 l)  { elr(V_JZ, rv_val_reg(d, RVREG_S1), l); }
void rv_jnz(i64 d, i64 l) { elr(V_JNZ, rv_val_reg(d, RVREG_S1), l); }
void rv_label(i64 l)      { el(I_LABEL, l); }
void rv_word(i64 w)       { ins_add(V_EMIT, 0, 0, 0, w, 0, 0); }

// the two fused pairs are the only instructions that always carry a relocation,
// and both carry it at offset 0 -- the auipc is the first word of the pair
i64 rv_reloc_kind(uptr e) {
    i64 op = ins_op(e);
    if (op == V_LA)   return RVK_PCREL_LA;
    if (op == V_CALL) return RVK_PCREL_CALL;
    return -1;
}

i64 rv_reloc_off(uptr e) { return 0; }

// ---- the encoder ----
// The six RISC-V instruction formats, each written field by field.
i64 rv_fits12(i64 v) { return v >= 0 - 2048 && v <= 2047; }

void rv_put_r(uptr o, i64 f7, i64 rs2, i64 rs1, i64 f3, i64 rd) {
    buf_u32(o, (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33);
}

void rv_put_i(uptr o, i64 opc, i64 imm, i64 rs1, i64 f3, i64 rd) {
    buf_u32(o, ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opc);
}

void rv_put_s(uptr o, i64 imm, i64 rs2, i64 rs1, i64 f3) {
    buf_u32(o, (((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15)
               | (f3 << 12) | ((imm & 0x1f) << 7) | 0x23);
}

void rv_put_b(uptr o, i64 imm, i64 rs2, i64 rs1, i64 f3) {
    buf_u32(o, (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3f) << 25)
               | (rs2 << 20) | (rs1 << 15) | (f3 << 12)
               | (((imm >> 1) & 0xf) << 8) | (((imm >> 11) & 1) << 7) | 0x63);
}

void rv_put_u(uptr o, i64 opc, i64 hi20, i64 rd) {
    buf_u32(o, ((hi20 & 0xfffff) << 12) | (rd << 7) | opc);
}

void rv_put_j(uptr o, i64 imm, i64 rd) {
    buf_u32(o, (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3ff) << 21)
               | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xff) << 12)
               | (rd << 7) | 0x6f);
}

// A 64-bit constant, the standard RV64 recursion: peel off the signed low 12
// bits, build the rest, shift it up and add them back. `v - lo` always has its
// low twelve bits clear, so the arithmetic shift is exact and the recursion
// loses a byte per step -- at most six levels for a full 64-bit value.
void rv_put_li(uptr o, i64 rd, i64 v) {
    if (rv_fits12(v)) { rv_put_i(o, 0x13, v, RV_ZERO, 0, rd); return; }
    if (v >= 0 - 0x80000000 && v <= 0x7fffffff) {
        i64 lo = v & 0xfff;
        if (lo >= 0x800) lo = lo - 0x1000;       // the addi's field is signed
        i64 hi = (v - lo) >> 12;
        rv_put_u(o, 0x37, hi, rd);               // lui
        if (lo != 0) rv_put_i(o, 0x13, lo, rd, 0, rd);
        return;
    }
    i64 lo = v & 0xfff;
    if (lo >= 0x800) lo = lo - 0x1000;
    rv_put_li(o, rd, (v - lo) >> 12);
    rv_put_i(o, 0x13, 12, rd, 1, rd);            // slli rd, rd, 12
    if (lo != 0) rv_put_i(o, 0x13, lo, rd, 0, rd);
}

// the address of a frame slot or of a big displacement, materialised in t2 --
// the one register this machine reserves for exactly this
void rv_put_big_base(uptr o, i64 rn, i64 imm) {
    rv_put_li(o, RVREG_TMP, imm);
    rv_put_r(o, 0, RVREG_TMP, rn, 0, RVREG_TMP);
}

// a label's offset, or 0 while measuring: both branch forms are fixed width, so
// the size does not depend on the answer
i64 rv_target(uptr lab, i64 l) {
    if (lab == 0) return 0;
    return ivec_at(lab, l);
}

// jal's immediate is a SIGNED 21-bit displacement with its low bit implied: it
// reaches 1 MiB backwards and 1 MiB minus two bytes forwards, and rv_put_j masks
// whatever it is given into the field. A jump past that would come out silently
// truncated -- a plausible image that boots and lands in the middle of an
// instruction, which is the exact failure src/machine_arm64.mc spends br_off()
// on. Only the ENCODE pass can check it: MTASK_INS_SIZE runs with no label
// vector, so `real` is `lab != 0` and the measuring pass sees a placeholder 0.
i64 rv_jal_off(i64 target, i64 pc, i64 real) {
    i64 d = target - pc;
    if (real && (d > 1048574 || d < 0 - 1048576)) die("riscv jal out of range");
    return d;
}

// THE encoder. MTASK_ENCODE calls it with the section buffer, MTASK_INS_SIZE
// with a scratch one, so the size the label pass reserves is by construction
// the number of bytes that will be written. RV64 is fixed width almost
// everywhere and a switch on the opcode would be tempting -- but V_LI, V_FRAME
// and the eight memory forms are not, and a one-byte disagreement would move
// every later branch and produce a plausible image that jumps into the middle
// of an instruction.
void rv_put(uptr e, i64 pc, uptr lab, uptr o) {
    i64 op = ins_op(e);
    i64 rd = ins_rd(e);
    i64 rn = ins_rn(e);
    i64 rm = ins_rm(e);
    i64 im = ins_imm(e);
    if (op == I_LABEL || op == V_NOP) return;
    i64 k = rv_rslot(op);
    if (k >= 0) { rv_put_r(o, rv_rf7_at(k), rm, rn, rv_rf3_at(k), rd); return; }
    k = rv_islot(op);
    if (k >= 0) {
        if (op == V_ADDI && !rv_fits12(im)) {     // the t2 fallback
            rv_put_big_base(o, rn, im);
            rv_put_i(o, 0x13, 0, RVREG_TMP, 0, rd);
            return;
        }
        if (!rv_fits12(im)) die("riscv immediate out of 12 bits");
        rv_put_i(o, 0x13, im | (rv_if6_at(k) << 6), rn, rv_if3_at(k), rd);
        return;
    }
    if (op == V_ADDIW) {                          // M45: sext.w is addiw rd, rn, 0
        if (!rv_fits12(im)) die("riscv immediate out of 12 bits");
        rv_put_i(o, 0x1b, im, rn, 0, rd);
        return;
    }
    k = rv_mslot(op);
    if (k >= 0) {
        i64 base = rn;
        if (!rv_fits12(im)) { rv_put_big_base(o, rn, im); base = RVREG_TMP; im = 0; }
        if (rv_mstore_at(k)) rv_put_s(o, im, rd, base, rv_mf3_at(k));
        else                 rv_put_i(o, 0x03, im, base, rv_mf3_at(k), rd);
        return;
    }
    if (op == V_LI)   { rv_put_li(o, rd, im); return; }
    if (op == V_LA)   {                          // auipc rd,0 ; addi rd,rd,0
        rv_put_u(o, 0x17, 0, rd);
        rv_put_i(o, 0x13, 0, rd, 0, rd);
        return;
    }
    if (op == V_CALL) {                          // auipc ra,0 ; jalr ra,ra,0
        rv_put_u(o, 0x17, 0, RV_RA);
        rv_put_i(o, 0x67, 0, RV_RA, 0, RV_RA);
        return;
    }
    if (op == V_JALR) { rv_put_i(o, 0x67, 0, rd, 0, RV_RA); return; }
    if (op == V_RET)  { rv_put_i(o, 0x67, 0, RV_RA, 0, RV_ZERO); return; }
    if (op == V_J)    { rv_put_j(o, rv_jal_off(rv_target(lab, ins_label(e)), pc, lab != 0), RV_ZERO); return; }
    if (op == V_JZ || op == V_JNZ) {
        i64 f3 = 1;                              // bne: skip the jal when non-zero
        if (op == V_JNZ) f3 = 0;                 // beq: skip it when zero
        rv_put_b(o, 8, RV_ZERO, rd, f3);
        rv_put_j(o, rv_jal_off(rv_target(lab, ins_label(e)), pc + 4, lab != 0), RV_ZERO);
        return;
    }
    if (op == V_FRAME) {
        if (0 - im >= 0 - 2048) { rv_put_i(o, 0x13, 0 - im, RV_SP, 0, RV_SP); return; }
        rv_put_li(o, RVREG_TMP, 0 - im);
        rv_put_r(o, 0, RVREG_TMP, RV_SP, 0, RV_SP);
        return;
    }
    if (op == V_EMIT) { buf_u32(o, im); return; }
    die("riscv instruction with no encoder");
}

// the same encoder over a scratch buffer whose length is reset, not its capacity
i64 rv_ins_size(uptr e) {
    set_buf_len(rv_tmp, 0);
    rv_put(e, 0, 0, rv_tmp);
    return buf_len(rv_tmp);
}

// ---- text dump ----
void rvd_reg(i64 r)   { out_str(1, rv_regname_at(r)); }
void rvd_head(uptr m) { out_str(1, "  "); out_str(1, m); out_str(1, " "); }

void rvd_num(i64 v) {
    if (v < 0) { out_str(1, "-"); out_num(1, 0 - v); return; }
    out_num(1, v);
}

void rvd_mem(uptr m, i64 rd, i64 rn, i64 off) {
    rvd_head(m);
    rvd_reg(rd); out_str(1, ", "); rvd_num(off);
    out_str(1, "("); rvd_reg(rn); out_str(1, ")\n");
}

// One line per Ins, the shape src/machine_arm64.mc and src/machine_x86_64.mc
// print. V_LI, V_FRAME and a memory form with an offset past 2047 come out as
// one logical line and more than one word -- `li` is a pseudo-instruction on
// this target and the offset fallback is the same idea; the byte-level oracle
// is examples/kernel/test.sh's llvm-mc sweep over the image, not this text.
void rv_dump(uptr in) {
    i64 op = ins_op(in);
    i64 rd = ins_rd(in);
    i64 rn = ins_rn(in);
    i64 rm = ins_rm(in);
    i64 im = ins_imm(in);
    if (op == V_NOP) return;
    if (op == I_LABEL) { out_str(1, "L"); out_num(1, ins_label(in)); out_str(1, ":\n"); return; }
    i64 k = rv_rslot(op);
    if (k >= 0) {
        rvd_head(rv_rname_at(k));
        rvd_reg(rd); out_str(1, ", "); rvd_reg(rn); out_str(1, ", "); rvd_reg(rm);
        out_str(1, "\n");
        return;
    }
    k = rv_islot(op);
    if (k >= 0) {
        if (op == V_ADDI && im == 0) {           // the canonical `mv`
            rvd_head("mv"); rvd_reg(rd); out_str(1, ", "); rvd_reg(rn); out_str(1, "\n");
            return;
        }
        rvd_head(rv_iname_at(k));
        rvd_reg(rd); out_str(1, ", "); rvd_reg(rn); out_str(1, ", "); rvd_num(im);
        out_str(1, "\n");
        return;
    }
    if (op == V_ADDIW) {                          // M45: the canonical `sext.w`
        if (im == 0) { rvd_head("sext.w"); rvd_reg(rd); out_str(1, ", "); rvd_reg(rn);
                       out_str(1, "\n"); return; }
        rvd_head("addiw"); rvd_reg(rd); out_str(1, ", "); rvd_reg(rn); out_str(1, ", ");
        rvd_num(im); out_str(1, "\n");
        return;
    }
    k = rv_mslot(op);
    if (k >= 0) { rvd_mem(rv_mname_at(k), rd, rn, im); return; }
    if (op == V_LI)   { rvd_head("li"); rvd_reg(rd); out_str(1, ", "); rvd_num(im);
                        out_str(1, "\n"); return; }
    if (op == V_LA)   { rvd_head("la"); rvd_reg(rd); out_str(1, ", ");
                        out_str(1, sym_name(sym_at(ins_sym(in)))); out_str(1, "\n"); return; }
    if (op == V_CALL) { rvd_head("call"); out_str(1, sym_name(sym_at(ins_sym(in))));
                        out_str(1, "\n"); return; }
    if (op == V_JALR) { rvd_head("jalr"); rvd_reg(rd); out_str(1, "\n"); return; }
    if (op == V_RET)  { out_str(1, "  ret\n"); return; }
    if (op == V_J)    { rvd_head("j"); out_str(1, "L"); out_num(1, ins_label(in));
                        out_str(1, "\n"); return; }
    if (op == V_JZ)   { rvd_head("beqz"); rvd_reg(rd); out_str(1, ", L");
                        out_num(1, ins_label(in)); out_str(1, "\n"); return; }
    if (op == V_JNZ)  { rvd_head("bnez"); rvd_reg(rd); out_str(1, ", L");
                        out_num(1, ins_label(in)); out_str(1, "\n"); return; }
    if (op == V_FRAME) { rvd_head("addi"); out_str(1, "sp, sp, "); rvd_num(0 - im);
                         out_str(1, "\n"); return; }
    if (op == V_EMIT) {
        u8 c[1];
        out_str(1, "  .word 0x");
        i64 i = 7;
        while (i >= 0) {
            st8(c, ld8("0123456789abcdef" + ((im >> (4 * i)) & 15)));
            out_bytes(1, c, 1);
            i = i - 1;
        }
        out_str(1, "\n");
        return;
    }
    die("riscv instruction with no dump");
}

// ---- registration ----
// Its OWN two-line setter. `machine_task` (src/machine_arm64.mc) writes into
// `m_arm64` BY NAME, so a module that follows the recipe
// docs/reference/hooks.md used to publish would corrupt the AArch64 table
// instead of filling its own; that page is corrected in this milestone
// (docs/specs/M39.md § G9, D7).
void rv_task(i64 task, uptr fn) { st64(m_rv64 + task * 8, fn); }

void machine_riscv64_init() {
    rv_task(MTASK_PROLOGUE,     &rv_prologue);
    rv_task(MTASK_PARAM,        &rv_param);
    rv_task(MTASK_EPILOGUE,     &rv_epilogue);
    rv_task(MTASK_FRAME_FIX,    &rv_frame_fix);
    rv_task(MTASK_CONST,        &rv_const);
    rv_task(MTASK_BIN,          &rv_bin);
    rv_task(MTASK_CMP,          &rv_cmp);
    rv_task(MTASK_UN,           &rv_un);
    rv_task(MTASK_BOOL,         &rv_bool);
    rv_task(MTASK_CAST,         &rv_cast);
    rv_task(MTASK_LOAD,         &rv_load);
    rv_task(MTASK_STORE,        &rv_store);
    rv_task(MTASK_LOCAL_ADDR,   &rv_local_addr);
    rv_task(MTASK_LOCAL_LOAD,   &rv_local_load);
    rv_task(MTASK_LOCAL_STORE,  &rv_local_store);
    rv_task(MTASK_SYM_ADDR,     &rv_sym_addr);
    rv_task(MTASK_GLOBAL_LOAD,  &rv_global_load);
    rv_task(MTASK_GLOBAL_STORE, &rv_global_store);
    rv_task(MTASK_CALL,         &rv_call);
    rv_task(MTASK_CALLP,        &rv_callp);
    rv_task(MTASK_RET,          &rv_ret);
    rv_task(MTASK_JUMP,         &rv_jump);
    rv_task(MTASK_JZ,           &rv_jz);
    rv_task(MTASK_JNZ,          &rv_jnz);
    rv_task(MTASK_LABEL,        &rv_label);
    rv_task(MTASK_WORD,         &rv_word);
    rv_task(MTASK_INS_SIZE,     &rv_ins_size);
    rv_task(MTASK_ENCODE,       &rv_put);
    rv_task(MTASK_DUMP,         &rv_dump);
    rv_task(MTASK_RELOC_KIND,   &rv_reloc_kind);
    rv_task(MTASK_RELOC_OFF,    &rv_reloc_off);
    machine("riscv64", m_rv64);
}
