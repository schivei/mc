// machine_arm64.mc — the AArch64 machine: instruction selection, the register
// and spill policy, the encoders and the `--dump-asm` text (M17 step A,
// docs/specs/M17.md; the contract is docs/reference/machine.md).
//
// This half was inside src/gen_arm64.mc until M17. What it owns now is
// everything the walker refuses to know:
//
//   * the register partition — depth 0..6 in x9..x15, x8 for the remainder,
//     x16/x17 as spill scratch, x29/x30 the frame record. It is written down
//     and tested in docs/reference/objects.md § 4;
//   * the SPILL: a depth past x15 lives in a frame slot the machine asks
//     gen_walk.mc's slot_new() for, one slot per depth, at most once;
//   * the fictitious base REG_FRAME with a negative offset from x29 that
//     fix_frame() swaps for sp at the end of the function — which is why the
//     frame size can be decided last;
//   * the I_* opcodes, their encoders and their dump.
//
// The walker reaches all of it through ONE table of `&fn`, registered with
// `machine("arm64", m_arm64)` (src/hooks.mc) and called with `callp`. Every task
// takes DEPTH INDICES; nothing above this file mentions a register.
//
// Depends on gen_walk.mc (the Ins buffer, ins_add/e0/e2/e3/ei/el/elr/em,
// slot_new, ins_base, the MTASK_/MOP_/MUN_/MCOND_ vocabulary and MAXDEPTH),
// on arena.mc (buf_u32, out_str, out_num, die) and on macho.mc (sym_name,
// sym_at, R_*).

// registers: depth 0..6 in x9..x15; above that the value lives in the frame
#define REG_BASE   9
#define REG_MAX    6
#define REG_TMP    8                  // scratch for the remainder (%)
#define REG_S1    16                  // spill scratch: left/destination
#define REG_S2    17                  // spill scratch: right
#define REG_FP    29
#define REG_LR    30
#define REG_SP    31
#define REG_FRAME 32                  // fictitious base swapped for sp in fix_frame

// ---- full plan enum; the encoder only implements what it uses.
// I_LABEL (0) belongs to gen_walk.mc: it is the one opcode the walker itself
// has to recognise, and it generates no word. ----
#define I_MOVZ     1
#define I_MOVK     2
#define I_MOVN     3
#define I_MOV      4
#define I_MOVW     5
#define I_ADD      6
#define I_SUB      7
#define I_MUL      8
#define I_SDIV     9
#define I_UDIV    10
#define I_MSUB    11
#define I_AND     12
#define I_ORR     13
#define I_EOR     14
#define I_MVN     15
#define I_NEG     16
#define I_LSLV    17
#define I_LSRV    18
#define I_ASRV    19
#define I_CMP     20
#define I_CMPI    21
#define I_CSET    22
#define I_ANDI    23
#define I_ADDI    24
#define I_SUBI    25
#define I_STP_PRE 26
#define I_LDP_POST 27
#define I_RET     28
#define I_B       29
#define I_BCOND   30
#define I_CBZ     31
#define I_CBNZ    32
#define I_BL      33
#define I_ADRP    34
#define I_ADDLO   35
#define I_LDR     36
#define I_STR     37
#define I_LDRB    38
#define I_STRB    39
#define I_LDRH    40
#define I_STRH    41
#define I_LDRW    42
#define I_STRW    43
#define I_EMIT    44
#define I_NOP     45                  // erased in the frame fixup, generates no word
#define I_BLR     46                  // blr xN: callp's indirect call

// AArch64 conditions used by M1
#define C_EQ  0
#define C_NE  1
#define C_GE 10
#define C_LT 11
#define C_GT 12
#define C_LE 13

i64 dslot[MAXDEPTH];                  // slot for the depth: save (<=6) or spill (>=7)
uptr m_arm64[MTASK_COUNT];            // the task table the walker drives
i64 a64_isub = 0;                     // the prologue's `sub sp, sp, #F`, patched last
i64 a64_iadd = 0;                     // and the epilogue's `add sp, sp, #F`

i64  dslot_at(i64 i)      { return ld64(dslot + i * 8); }
void set_dslot_at(i64 i, i64 v) { st64(dslot + i * 8, v); }

// ---- depth, register and spill ----
i64 slot_depth(i64 d) {
    if (dslot_at(d) == 0) set_dslot_at(d, slot_new(8));
    return dslot_at(d);
}

i64 in_reg(i64 depth) { return depth <= REG_MAX; }

// register holding the depth's value; loads from the frame into scratch if spilled
i64 val_reg(i64 depth, i64 scratch) {
    if (in_reg(depth)) return REG_BASE + depth;
    em(I_LDR, scratch, REG_FRAME, 0 - slot_depth(depth));
    return scratch;
}

i64 dst_reg(i64 depth) {
    if (in_reg(depth)) return REG_BASE + depth;
    return REG_S1;
}

void dst_done(i64 depth, i64 rd) {
    if (!in_reg(depth)) em(I_STR, rd, REG_FRAME, 0 - slot_depth(depth));
}

// ---- instruction tables (dump and the encoder read the same ones) ----
// three register-register operands: same shape, only the base changes
i64 rrr_ins[] = { I_ADD, I_SUB, I_MUL, I_SDIV, I_UDIV, I_AND, I_ORR, I_EOR,
                  I_LSLV, I_LSRV, I_ASRV, 0 };
u32 rrr_base[] = { 0x8B000000, 0xCB000000, 0x9B007C00, 0x9AC00C00, 0x9AC00800,
                   0x8A000000, 0xAA000000, 0xCA000000,
                   0x9AC02000, 0x9AC02400, 0x9AC02800 };
uptr rrr_name[] = { "add", "sub", "mul", "sdiv", "udiv", "and", "orr", "eor",
                    "lsl", "lsr", "asr" };
// memory: load/store pairs by width, from widest to narrowest
i64 mem_ins[] = { I_LDR, I_STR, I_LDRW, I_STRW, I_LDRH, I_STRH, I_LDRB, I_STRB, 0 };
u32 mem_base[] = { 0xF9400000, 0xF9000000, 0xB9400000, 0xB9000000,
                   0x79400000, 0x79000000, 0x39400000, 0x39000000 };
i64 mem_scale[] = { 8, 8, 4, 4, 2, 2, 1, 1 };
uptr mem_name[] = { "ldr", "str", "ldr", "str", "ldrh", "strh", "ldrb", "strb" };
// the MOP_* / MCOND_* vocabulary, in its own order, spelled in AArch64
i64 bin_rrr[] = { I_ADD, I_SUB, I_MUL, I_SDIV, I_UDIV, I_SDIV, I_UDIV,
                  I_AND, I_ORR, I_EOR, I_LSLV, I_LSRV, I_ASRV };
i64 cond_arm[] = { C_EQ, C_NE, C_LT, C_LE, C_GT, C_GE };

i64  rrr_ins_at(i64 i)   { return ld64(rrr_ins + i * 8); }
i64  rrr_base_at(i64 i)  { return ld32(rrr_base + i * 4); }
uptr rrr_name_at(i64 i)  { return ld64(rrr_name + i * 8); }
i64  mem_ins_at(i64 i)   { return ld64(mem_ins + i * 8); }
i64  mem_base_at(i64 i)  { return ld32(mem_base + i * 4); }
i64  mem_scale_at(i64 i) { return ld64(mem_scale + i * 8); }
uptr mem_name_at(i64 i)  { return ld64(mem_name + i * 8); }
i64  bin_rrr_at(i64 i)   { return ld64(bin_rrr + i * 8); }
i64  cond_arm_at(i64 i)  { return ld64(cond_arm + i * 8); }

i64 mem_slot(i64 op) {                // -1 if it is not a memory access
    i64 i = 0;
    loop {
        if (mem_ins_at(i) == 0) break;
        if (op == mem_ins_at(i)) return i;
        i = i + 1;
    }
    return -1;
}

// access of width t; the even positions are load, the odd ones store
i64 mem_op(i64 t, i64 store) {
    i64 i = 0;
    if (t == TY_U8)       i = 6;
    else if (t == TY_U16) i = 4;
    else if (t == TY_U32) i = 2;
    if (store) return mem_ins_at(i + 1);
    return mem_ins_at(i);
}

// 64-bit immediate in up to 4 instructions: movz of the low word + movk of the rest
void gen_imm(i64 rd, u64 v) {
    ins_add(I_MOVZ, rd, 0, 0, v & 0xffff, 0, 0);
    i64 hw = 1;
    loop {
        if (hw >= 4) break;
        u64 part = (v >> (16 * hw)) & 0xffff;
        if (part) ins_add(I_MOVK, rd, hw, 0, part, 0, 0);
        hw = hw + 1;
    }
}

void gen_cast(i64 rd, i64 ty) {
    if (ty == TY_U8)       ei(I_ANDI, rd, rd, 0xff);
    else if (ty == TY_U16) ei(I_ANDI, rd, rd, 0xffff);
    else if (ty == TY_U32) e2(I_MOVW, rd, rd);        // mov wd, wn zeroes the top half
}

// address of a symbol: adrp of the page + add of the offset
void gen_gaddr(i64 rd, i64 sym) {
    ins_add(I_ADRP,  rd, 0,  0, 0, 0, sym);
    ins_add(I_ADDLO, rd, rd, 0, 0, 0, sym);
}

// saves the live depths (the ones in a register) before a call
void save_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth || !in_reg(d)) break;
        em(I_STR, REG_BASE + d, REG_FRAME, 0 - slot_depth(d));
        d = d + 1;
    }
}
void restore_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth || !in_reg(d)) break;
        em(I_LDR, REG_BASE + d, REG_FRAME, 0 - slot_depth(d));
        d = d + 1;
    }
}
// moves depth d into register r (the ABI one, or callp's x16)
void arg_to_reg(i64 r, i64 d) {
    if (in_reg(d)) e2(I_MOV, r, REG_BASE + d);
    else           em(I_LDR, r, REG_FRAME, 0 - slot_depth(d));
}

// swaps the frame's fictitious base for sp: address = x29 - off = sp + (frame - off)
void fix_frame(i64 frame) {
    i64 i = ins_base;
    loop {
        if (i >= nins) break;
        uptr e = ins_at(i);
        if (ins_rn(e) == REG_FRAME) {
            set_ins_rn(e, REG_SP);
            set_ins_imm(e, ins_imm(e) + frame);
        }
        i = i + 1;
    }
}

// ---- the tasks ----
// The frame record is unconditional (a stack walk depends on it) and the frame
// reserve is a placeholder until a64_frame_fix knows the size.
void a64_prologue() {
    i64 d = 0;
    loop {
        if (d >= MAXDEPTH) break;
        set_dslot_at(d, 0);
        d = d + 1;
    }
    ins_add(I_STP_PRE, REG_FP, REG_SP, REG_LR, 0 - 16, 0, 0);
    ei(I_ADDI, REG_FP, REG_SP, 0);               // mov x29, sp
    a64_isub = nins;
    ei(I_SUBI, REG_SP, REG_SP, 0);               // frame only at the end
}

// parameter i arrives in xi and goes to its slot, without the prologue ever
// writing an argument register (docs/reference/objects.md § 4)
void a64_param(i64 ty, i64 i, i64 off) {
    em(mem_op(ty, 1), i, REG_FRAME, 0 - off);
}

void a64_epilogue() {
    a64_iadd = nins;
    ei(I_ADDI, REG_SP, REG_SP, 0);
    ins_add(I_LDP_POST, REG_FP, REG_SP, REG_LR, 16, 0, 0);
    e0(I_RET);
}

void a64_frame_fix(i64 frame) {
    set_ins_imm(ins_at(a64_isub), frame);
    set_ins_imm(ins_at(a64_iadd), frame);
    if (frame == 0) { set_ins_op(ins_at(a64_isub), I_NOP); set_ins_op(ins_at(a64_iadd), I_NOP); }
    fix_frame(frame);
}

void a64_const(i64 d, i64 imm) {
    i64 rd = dst_reg(d);
    gen_imm(rd, imm);
    dst_done(d, rd);
}

void a64_bin(i64 op, i64 d, i64 d2) {
    i64 rl = val_reg(d, REG_S1);
    i64 rr = val_reg(d2, REG_S2);
    i64 rd = dst_reg(d);
    if (op == MOP_SMOD || op == MOP_UMOD) {        // rd = rl - (rl / rr) * rr
        e3(bin_rrr_at(op), REG_TMP, rl, rr);
        ins_add(I_MSUB, rd, REG_TMP, rr, rl, 0, 0);
    } else {
        e3(bin_rrr_at(op), rd, rl, rr);
    }
    dst_done(d, rd);
}

void a64_cmp(i64 cond, i64 d, i64 d2) {
    i64 rl = val_reg(d, REG_S1);
    i64 rr = val_reg(d2, REG_S2);
    i64 rd = dst_reg(d);
    e3(I_CMP, 0, rl, rr);
    ins_add(I_CSET, rd, 0, 0, cond_arm_at(cond), 0, 0);
    dst_done(d, rd);
}

void a64_un(i64 op, i64 d) {
    i64 rd = val_reg(d, REG_S1);                 // operates in place
    if (op == MUN_NEG)      e2(I_NEG, rd, rd);
    else if (op == MUN_NOT) e2(I_MVN, rd, rd);
    else { ei(I_CMPI, 0, rd, 0); ins_add(I_CSET, rd, 0, 0, C_EQ, 0, 0); }
    dst_done(d, rd);
}

void a64_bool(i64 d) {
    i64 rd = dst_reg(d);
    ei(I_CMPI, 0, val_reg(d, REG_S1), 0);
    ins_add(I_CSET, rd, 0, 0, C_NE, 0, 0);
    dst_done(d, rd);
}

void a64_cast(i64 ty, i64 d) {
    i64 rd = val_reg(d, REG_S1);
    gen_cast(rd, ty);
    dst_done(d, rd);
}

void a64_load(i64 ty, i64 d) {
    i64 rp = val_reg(d, REG_S1);
    i64 rd = dst_reg(d);
    em(mem_op(ty, 0), rd, rp, 0);                // zero-extended by construction
    dst_done(d, rd);
}

void a64_store(i64 ty, i64 d) {
    i64 rp = val_reg(d, REG_S1);
    i64 rv = val_reg(d + 1, REG_S2);
    em(mem_op(ty, 1), rv, rp, 0);
}

void a64_local_addr(i64 d, i64 off) {
    i64 rd = dst_reg(d);
    ei(I_ADDI, rd, REG_FRAME, 0 - off);
    dst_done(d, rd);
}

void a64_local_load(i64 ty, i64 d, i64 off) {
    i64 rd = dst_reg(d);
    em(mem_op(ty, 0), rd, REG_FRAME, 0 - off);
    dst_done(d, rd);
}

void a64_local_store(i64 ty, i64 d, i64 off) {
    em(mem_op(ty, 1), val_reg(d, REG_S2), REG_FRAME, 0 - off);
}

void a64_sym_addr(i64 d, i64 sym) {
    i64 rd = dst_reg(d);
    gen_gaddr(rd, sym);
    dst_done(d, rd);
}

void a64_global_load(i64 ty, i64 d, i64 sym) {
    i64 rd = dst_reg(d);
    gen_gaddr(rd, sym);
    em(mem_op(ty, 0), rd, rd, 0);
    dst_done(d, rd);
}

// x16 is free here: the value is already lowered and nothing else is live in it
void a64_global_store(i64 ty, i64 d, i64 sym) {
    gen_gaddr(REG_S1, sym);
    em(mem_op(ty, 1), val_reg(d, REG_S2), REG_S1, 0);
}

// bl: the arguments go to x0.., the live depths below `d` go to the frame, the
// result comes back from x0
void a64_call(i64 d, i64 na, i64 sym) {
    save_live(d);                                // live: the depths below
    i64 i = 0;
    loop {
        if (i >= na) break;
        arg_to_reg(i, d + i);
        i = i + 1;
    }
    ins_add(I_BL, 0, 0, 0, 0, 0, sym);
    restore_live(d);
    i64 rd = dst_reg(d);
    e2(I_MOV, rd, 0);
    dst_done(d, rd);
}

// callp(p, a1..a7): the pointer (argument 0) goes to x16, outside the ABI, and
// the rest to x0..x6 — one fewer than a direct call, because x16 is taken
void a64_callp(i64 d, i64 na) {
    save_live(d);
    i64 i = 0;
    loop {
        if (i >= na) break;
        i64 r = REG_S1;
        if (i) r = i - 1;
        arg_to_reg(r, d + i);
        i = i + 1;
    }
    ins_add(I_BLR, REG_S1, 0, 0, 0, 0, 0);
    restore_live(d);
    i64 rd = dst_reg(d);
    e2(I_MOV, rd, 0);
    dst_done(d, rd);
}

void a64_ret(i64 d)          { e2(I_MOV, 0, val_reg(d, REG_S1)); }
void a64_jump(i64 l)         { el(I_B, l); }
void a64_jz(i64 d, i64 l)    { elr(I_CBZ, val_reg(d, REG_S1), l); }
void a64_jnz(i64 d, i64 l)   { elr(I_CBNZ, val_reg(d, REG_S1), l); }
void a64_label(i64 l)        { el(I_LABEL, l); }
void a64_word(i64 w)         { ins_add(I_EMIT, 0, 0, 0, w, 0, 0); }

// AArch64 is fixed width: everything is one word, except what generates none
i64 a64_ins_size(uptr e) {
    i64 op = ins_op(e);
    if (op == I_LABEL || op == I_NOP) return 0;
    return 4;
}

// AArch64 is fixed width and every relocation patches the whole word, so the
// field always starts where the instruction does
i64 a64_reloc_off(uptr e) { return 0; }

// the three instructions that always carry a relocation of their own
i64 a64_reloc_kind(uptr e) {
    i64 op = ins_op(e);
    if (op == I_BL)    return R_BRANCH26;
    if (op == I_ADRP)  return R_PAGE21;
    if (op == I_ADDLO) return R_PAGEOFF12;
    return -1;
}

// ---- text dump ----
void d_reg(i64 r) {
    if (r == REG_SP) { out_str(1, "sp"); return; }
    out_str(1, "x");
    out_num(1, r);
}

void d_head(uptr m) { out_str(1, "  "); out_str(1, m); out_str(1, " "); }

void d_3(uptr m, i64 rd, i64 rn, i64 rm) {
    d_head(m); d_reg(rd); out_str(1, ", "); d_reg(rn); out_str(1, ", "); d_reg(rm); out_str(1, "\n");
}

void d_2(uptr m, i64 rd, i64 rn) {
    d_head(m); d_reg(rd); out_str(1, ", "); d_reg(rn); out_str(1, "\n");
}

void d_i(uptr m, i64 rd, i64 rn, i64 imm) {
    d_head(m); d_reg(rd); out_str(1, ", "); d_reg(rn); out_str(1, ", #"); out_num(1, imm); out_str(1, "\n");
}

void d_lab(uptr m, i64 label) {
    d_head(m); out_str(1, "L"); out_num(1, label); out_str(1, "\n");
}

// ldr/str: 32-bit register for the narrow widths, base and offset between []
void d_mem(uptr m, i64 wreg, i64 rt, i64 rn, i64 off) {
    d_head(m);
    if (wreg) { out_str(1, "w"); out_num(1, rt); } else d_reg(rt);
    out_str(1, ", ["); d_reg(rn);
    if (off) { out_str(1, ", #"); out_num(1, off); }
    out_str(1, "]\n");
}

// raw word always with all 8 hex digits, so the dump is stable
void d_word(u64 w) {
    u8 c[1];
    out_str(1, "  .word 0x");
    i64 i = 7;
    loop {
        if (i < 0) break;
        st8(c, ld8("0123456789abcdef" + ((w >> (4 * i)) & 15)));
        out_bytes(1, c, 1);
        i = i - 1;
    }
    out_str(1, "\n");
}

uptr cond_name(i64 c) {
    if (c == C_EQ) return "eq";
    if (c == C_NE) return "ne";
    if (c == C_GE) return "ge";
    if (c == C_LT) return "lt";
    if (c == C_GT) return "gt";
    if (c == C_LE) return "le";
    return "??";
}

void dump_ins(uptr in) {
    i64 op = ins_op(in);
    if (op == I_NOP) return;
    if (op == I_LABEL) { out_str(1, "L"); out_num(1, ins_label(in)); out_str(1, ":\n"); return; }
    if (op == I_MOVZ || op == I_MOVK) {
        if (op == I_MOVZ) d_head("movz");
        else              d_head("movk");
        d_reg(ins_rd(in)); out_str(1, ", #"); out_num(1, ins_imm(in));
        if (ins_rn(in)) { out_str(1, ", lsl #"); out_num(1, 16 * ins_rn(in)); }
        out_str(1, "\n");
        return;
    }
    i64 i = 0;
    loop {                                                // the 11 with 3 operands
        if (rrr_ins_at(i) == 0) break;
        if (op == rrr_ins_at(i)) { d_3(rrr_name_at(i), ins_rd(in), ins_rn(in), ins_rm(in)); return; }
        i = i + 1;
    }
    i64 mi = mem_slot(op);
    if (mi >= 0) { d_mem(mem_name_at(mi), mi >= 2, ins_rd(in), ins_rn(in), ins_imm(in)); return; }
    if (op == I_MOV)  { d_2("mov", ins_rd(in), ins_rn(in)); return; }
    if (op == I_MOVW) { d_head("mov"); out_str(1, "w"); out_num(1, ins_rd(in));
                        out_str(1, ", w"); out_num(1, ins_rn(in)); out_str(1, "\n"); return; }
    if (op == I_MSUB) { d_head("msub"); d_reg(ins_rd(in)); out_str(1, ", "); d_reg(ins_rn(in));
                        out_str(1, ", "); d_reg(ins_rm(in)); out_str(1, ", ");
                        d_reg(ins_imm(in)); out_str(1, "\n"); return; }
    if (op == I_MVN)  { d_2("mvn", ins_rd(in), ins_rn(in)); return; }
    if (op == I_NEG)  { d_2("neg", ins_rd(in), ins_rn(in)); return; }
    if (op == I_CMP)  { d_head("cmp"); d_reg(ins_rn(in)); out_str(1, ", "); d_reg(ins_rm(in));
                        out_str(1, "\n"); return; }
    if (op == I_CMPI) { d_head("cmp"); d_reg(ins_rn(in)); out_str(1, ", #"); out_num(1, ins_imm(in));
                        out_str(1, "\n"); return; }
    if (op == I_CSET) { d_head("cset"); d_reg(ins_rd(in)); out_str(1, ", ");
                        out_str(1, cond_name(ins_imm(in))); out_str(1, "\n"); return; }
    if (op == I_ANDI) { d_i("and", ins_rd(in), ins_rn(in), ins_imm(in)); return; }
    if (op == I_ADDI) { if (ins_imm(in) == 0) d_2("mov", ins_rd(in), ins_rn(in));
                        else d_i("add", ins_rd(in), ins_rn(in), ins_imm(in)); return; }
    if (op == I_SUBI) { d_i("sub", ins_rd(in), ins_rn(in), ins_imm(in)); return; }
    if (op == I_BL)   { d_head("bl"); out_str(1, sym_name(sym_at(ins_sym(in)))); out_str(1, "\n"); return; }
    if (op == I_ADRP) { d_head("adrp"); d_reg(ins_rd(in)); out_str(1, ", ");
                        out_str(1, sym_name(sym_at(ins_sym(in))));
                        out_str(1, "@PAGE\n"); return; }
    if (op == I_ADDLO){ d_head("add"); d_reg(ins_rd(in)); out_str(1, ", "); d_reg(ins_rn(in));
                        out_str(1, ", "); out_str(1, sym_name(sym_at(ins_sym(in))));
                        out_str(1, "@PAGEOFF\n"); return; }
    if (op == I_STP_PRE)  { out_str(1, "  stp x29, x30, [sp, #-16]!\n"); return; }
    if (op == I_LDP_POST) { out_str(1, "  ldp x29, x30, [sp], #16\n");  return; }
    if (op == I_RET)  { out_str(1, "  ret\n"); return; }
    if (op == I_B)    { d_lab("b", ins_label(in)); return; }
    if (op == I_BCOND){ d_head("b."); out_str(1, cond_name(ins_imm(in))); out_str(1, " L");
                        out_num(1, ins_label(in)); out_str(1, "\n"); return; }
    if (op == I_CBZ || op == I_CBNZ) {
                        if (op == I_CBZ) d_head("cbz"); else d_head("cbnz");
                        d_reg(ins_rd(in));
                        out_str(1, ", L"); out_num(1, ins_label(in)); out_str(1, "\n"); return; }
    if (op == I_EMIT) { d_word((u32) ins_imm(in)); return; }
    if (op == I_BLR)  { d_head("blr"); d_reg(ins_rd(in)); out_str(1, "\n"); return; }
    die("instruction with no dump");
}

// ---- encoders ----
// always checks against the 19-bit range (the smallest of the three): conservative and uniform
i64 br_off(i64 target, i64 pc, i64 line_ok) {
    i64 d = (target - pc) / 4;
    if (line_ok && (d > 0x1ffff || d < 0 - 0x20000)) die("branch too far");
    return (u32) d;
}

// ldr/str with an unsigned scaled offset (0..4095 * width)
i64 enc_mem(uptr in, i64 i) {
    i64 scale = mem_scale_at(i);
    if (ins_imm(in) < 0 || ins_imm(in) % scale != 0 || ins_imm(in) / scale > 4095)
        die("memory offset out of range");
    return mem_base_at(i) | ((ins_imm(in) / scale) << 10) | (ins_rn(in) << 5) | ins_rd(in);
}

i64 encode(uptr in, i64 pc, uptr lab) {
    i64 op = ins_op(in);
    i64 rd = ins_rd(in);
    i64 rn = ins_rn(in);
    i64 rm = ins_rm(in);
    i64 im = (u32) ins_imm(in);
    i64 i = 0;
    loop {                                                // the 11 with 3 operands rd, rn, rm
        if (rrr_ins_at(i) == 0) break;
        if (op == rrr_ins_at(i)) return rrr_base_at(i) | (rm << 16) | (rn << 5) | rd;
        i = i + 1;
    }
    i64 mi = mem_slot(op);
    if (mi >= 0) return enc_mem(in, mi);
    if (op == I_MOVZ) return 0xD2800000 | (rn << 21) | ((im & 0xffff) << 5) | rd;
    if (op == I_MOVK) return 0xF2800000 | (rn << 21) | ((im & 0xffff) << 5) | rd;
    if (op == I_MOV)  return 0xAA0003E0 | (rn << 16) | rd;      // orr rd, xzr, rn
    if (op == I_MOVW) return 0x2A0003E0 | (rn << 16) | rd;      // orr wd, wzr, wn
    if (op == I_MSUB) return 0x9B008000 | (rm << 16) | ((im & 0x1f) << 10)
                             | (rn << 5) | rd;                  // ra = imm
    if (op == I_MVN)  return 0xAA2003E0 | (rn << 16) | rd;
    if (op == I_NEG)  return 0xCB0003E0 | (rn << 16) | rd;
    if (op == I_CMP)  return 0xEB00001F | (rm << 16) | (rn << 5);
    if (op == I_CMPI) {
        if (ins_imm(in) < 0 || ins_imm(in) > 4095) die("cmp immediate out of 12 bits");
        return 0xF100001F | ((im & 0xfff) << 10) | (rn << 5);
    }
    if (op == I_CSET) return 0x9A9F07E0 | (((ins_imm(in) ^ 1) & 0xf) << 12) | rd;
    if (op == I_ANDI) {                        // 2^k-1 mask: N=1, immr=0, imms=k-1
        u64 m = ins_imm(in);
        i64 k = 0;
        loop {
            if (k >= 64) break;
            if (((m >> k) & 1) == 0) break;
            k = k + 1;
        }
        if (k == 0 || k == 64 || (m >> k) != 0) die("immediate and mask not supported");
        return 0x92400000 | ((k - 1) << 10) | (rn << 5) | rd;
    }
    if (op == I_ADDI || op == I_SUBI) {
        if (ins_imm(in) < 0 || ins_imm(in) > 4095) die("add/sub immediate out of 12 bits");
        i64 base = 0xD1000000;
        if (op == I_ADDI) base = 0x91000000;
        return base | ((im & 0xfff) << 10) | (rn << 5) | rd;
    }
    if (op == I_STP_PRE)  return 0xA9800000 | (((ins_imm(in) / 8) & 0x7f) << 15)
                                 | (rm << 10) | (rn << 5) | rd;
    if (op == I_LDP_POST) return 0xA8C00000 | (((ins_imm(in) / 8) & 0x7f) << 15)
                                 | (rm << 10) | (rn << 5) | rd;
    if (op == I_RET)   return 0xD65F03C0;
    if (op == I_B)     return 0x14000000 | (br_off(ivec_at(lab, ins_label(in)), pc, 1) & 0x3ffffff);
    if (op == I_BCOND) return 0x54000000 | ((br_off(ivec_at(lab, ins_label(in)), pc, 1) & 0x7ffff) << 5)
                              | (im & 0xf);
    if (op == I_CBZ || op == I_CBNZ) {                    // bit 24 distinguishes cbz from cbnz
        i64 base = 0xB5000000;
        if (op == I_CBZ) base = 0xB4000000;
        return base | ((br_off(ivec_at(lab, ins_label(in)), pc, 1) & 0x7ffff) << 5) | rd;
    }
    // the offset for these three comes from the relocation registered in gen_encode
    if (op == I_BL)    return 0x94000000;
    if (op == I_ADRP)  return 0x90000000 | rd;
    if (op == I_ADDLO) return 0x91000000 | (rn << 5) | rd;
    if (op == I_EMIT)  return im;
    if (op == I_BLR)   return 0xD63F0000 | (rd << 5);
    die("instruction with no encoder");
    return 0;
}

// one instruction into the section's buffer. Written as a task rather than as
// "return the word" so a variable-length machine can put out as many bytes as
// its encoding needs.
void a64_encode(uptr e, i64 pc, uptr lab, uptr b) {
    buf_u32(b, encode(e, pc, lab));
}

// ---- registration ----
void machine_task(i64 task, uptr fn) { st64(m_arm64 + task * 8, fn); }

void machine_arm64_init() {
    machine_task(MTASK_PROLOGUE,     &a64_prologue);
    machine_task(MTASK_PARAM,        &a64_param);
    machine_task(MTASK_EPILOGUE,     &a64_epilogue);
    machine_task(MTASK_FRAME_FIX,    &a64_frame_fix);
    machine_task(MTASK_CONST,        &a64_const);
    machine_task(MTASK_BIN,          &a64_bin);
    machine_task(MTASK_CMP,          &a64_cmp);
    machine_task(MTASK_UN,           &a64_un);
    machine_task(MTASK_BOOL,         &a64_bool);
    machine_task(MTASK_CAST,         &a64_cast);
    machine_task(MTASK_LOAD,         &a64_load);
    machine_task(MTASK_STORE,        &a64_store);
    machine_task(MTASK_LOCAL_ADDR,   &a64_local_addr);
    machine_task(MTASK_LOCAL_LOAD,   &a64_local_load);
    machine_task(MTASK_LOCAL_STORE,  &a64_local_store);
    machine_task(MTASK_SYM_ADDR,     &a64_sym_addr);
    machine_task(MTASK_GLOBAL_LOAD,  &a64_global_load);
    machine_task(MTASK_GLOBAL_STORE, &a64_global_store);
    machine_task(MTASK_CALL,         &a64_call);
    machine_task(MTASK_CALLP,        &a64_callp);
    machine_task(MTASK_RET,          &a64_ret);
    machine_task(MTASK_JUMP,         &a64_jump);
    machine_task(MTASK_JZ,           &a64_jz);
    machine_task(MTASK_JNZ,          &a64_jnz);
    machine_task(MTASK_LABEL,        &a64_label);
    machine_task(MTASK_WORD,         &a64_word);
    machine_task(MTASK_INS_SIZE,     &a64_ins_size);
    machine_task(MTASK_ENCODE,       &a64_encode);
    machine_task(MTASK_DUMP,         &dump_ins);
    machine_task(MTASK_RELOC_KIND,   &a64_reloc_kind);
    machine_task(MTASK_RELOC_OFF,    &a64_reloc_off);
    machine("arm64", m_arm64);
}
