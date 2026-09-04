// machine_x86_64_float.mc — the x86-64 machine of `<float>` (SSE2), derived from
// the bundled `x86_64` and `x86_64-win` ones (M24).
//
// Same shape as lib/machine_arm64_float.mc and for the same reason: the walker
// says which TYPE is at each depth, so this file decides the register file, the
// instruction and the ABI slot, and delegates everything else through a pristine
// copy of the table it was derived from. Two machines come out of one set of
// functions, exactly as the bundled file produces `x86_64` and `x86_64-win`.
//
// Register plan:
//
//   SysV   float depths 0..5  xmm8..xmm13, scratch xmm14/xmm15
//          float arguments    xmm0..xmm7, integer rdi rsi rdx rcx r8 r9
//   Win64  float depths 0..5  xmm0..xmm5, scratch xmm14/xmm15
//          float arguments    xmm0..xmm3, SLOT-SHARED with rcx rdx r8 r9: it is
//                             the argument's POSITION that picks the register,
//                             not how many floats came before it
//
// xmm6..xmm15 are callee-saved on Win64, which is why the Win64 depths start at
// xmm0 and not at xmm8; on SysV every xmm is call-clobbered, so the depths sit
// out of the argument registers' way. Both spill from depth 6.
//
// Everything below the depth registers is the bundled machine's: rax/rcx/rdx as
// integer scratch, r8..r11 as integer depths, [rbp - off] for locals.

#define XF_S1 14                      // xmm14/xmm15: float spill scratch
#define XF_S2 15
#define XF_ARGS_SYSV 8
#define XF_ARGS_WIN  4
#define XF_DEPTH_MAX 5

// ---- the SSE2 opcodes, above every X_* the bundled machine uses ----
#define FX_BASE     100
#define FX_ADD_D    100
#define FX_SUB_D    101
#define FX_MUL_D    102
#define FX_DIV_D    103
#define FX_MIN_D    104
#define FX_MAX_D    105
#define FX_SQRT_D   106
#define FX_MOV_DD   107               // movsd xmm, xmm
#define FX_ADD_S    108
#define FX_SUB_S    109
#define FX_MUL_S    110
#define FX_DIV_S    111
#define FX_MIN_S    112
#define FX_MAX_S    113
#define FX_SQRT_S   114
#define FX_MOV_SS   115
#define FX_UCOMI_D  116               // ucomisd
#define FX_UCOMI_S  117
#define FX_XOR_D    118               // xorpd  (sign flip)
#define FX_XOR_S    119
#define FX_AND_D    120               // andpd  (absolute value)
#define FX_AND_S    121
#define FX_CVTSI_D  122               // cvtsi2sd xmm, r64
#define FX_CVTSI_S  123
#define FX_CVTT_D   124               // cvttsd2si r64, xmm
#define FX_CVTT_S   125
#define FX_CVT_DS   126               // cvtss2sd xmm, xmm
#define FX_CVT_SD   127               // cvtsd2ss
#define FX_MOVQ_XR  128               // movq xmm, r64
#define FX_MOVQ_RX  129               // movq r64, xmm
#define FX_LD_D     130               // movsd xmm, [m]
#define FX_ST_D     131               // movsd [m], xmm
#define FX_LD_S     132               // movss xmm, [m]
#define FX_ST_S     133
#define FX_MAXOP    134

// one row per opcode: form, REX.W, opcode (0x1NN = a 0x0F escape), prefix, and
// the letters the dump uses for rd and rn. x86_put's own five-column descriptor
// cannot be extended from outside src/, so this is the same idea in the module,
// encoded through the SAME x86_rex / x86_op / x86_modrm_* helpers -- the bytes
// come out of one code path and the dump reads one table.
#define FXR_X 0                       // an integer register
#define FXR_M 1                       // an xmm register

i64 fx_form[] = {
    XF_RD, XF_RD, XF_RD, XF_RD, XF_RD, XF_RD, XF_RD, XF_RD,
    XF_RD, XF_RD, XF_RD, XF_RD, XF_RD, XF_RD, XF_RD, XF_RD,
    XF_RD, XF_RD,
    XF_RD, XF_RD, XF_RD, XF_RD,
    XF_RD, XF_RD, XF_RD, XF_RD, XF_RD, XF_RD,
    XF_RD, XF_RS,
    XF_LD, XF_ST, XF_LD, XF_ST };
i64 fx_w[] = {
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0,
    0, 0, 0, 0,
    1, 1, 1, 1, 0, 0,
    1, 1,
    0, 0, 0, 0 };
i64 fx_opc[] = {
    0x158, 0x15c, 0x159, 0x15e, 0x15d, 0x15f, 0x151, 0x110,
    0x158, 0x15c, 0x159, 0x15e, 0x15d, 0x15f, 0x151, 0x110,
    0x12e, 0x12e,
    0x157, 0x157, 0x154, 0x154,
    0x12a, 0x12a, 0x12c, 0x12c, 0x15a, 0x15a,
    0x16e, 0x17e,
    0x110, 0x111, 0x110, 0x111 };
i64 fx_pre[] = {
    0xf2, 0xf2, 0xf2, 0xf2, 0xf2, 0xf2, 0xf2, 0xf2,
    0xf3, 0xf3, 0xf3, 0xf3, 0xf3, 0xf3, 0xf3, 0xf3,
    0x66, 0,
    0x66, 0, 0x66, 0,
    0xf2, 0xf3, 0xf2, 0xf3, 0xf3, 0xf2,
    0x66, 0x66,
    0xf2, 0xf2, 0xf3, 0xf3 };
uptr fx_name[] = {
    "addsd", "subsd", "mulsd", "divsd", "minsd", "maxsd", "sqrtsd", "movsd",
    "addss", "subss", "mulss", "divss", "minss", "maxss", "sqrtss", "movss",
    "ucomisd", "ucomiss",
    "xorpd", "xorps", "andpd", "andps",
    "cvtsi2sd", "cvtsi2ss", "cvttsd2si", "cvttss2si", "cvtss2sd", "cvtsd2ss",
    "movq", "movq",
    "movsd", "movsd", "movss", "movss" };
i64 fx_rdk[] = {
    FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M,
    FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M,
    FXR_M, FXR_M,
    FXR_M, FXR_M, FXR_M, FXR_M,
    FXR_M, FXR_M, FXR_X, FXR_X, FXR_M, FXR_M,
    FXR_M, FXR_X,
    FXR_M, FXR_M, FXR_M, FXR_M };
i64 fx_rnk[] = {
    FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M,
    FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M, FXR_M,
    FXR_M, FXR_M,
    FXR_M, FXR_M, FXR_M, FXR_M,
    FXR_X, FXR_X, FXR_M, FXR_M, FXR_M, FXR_M,
    FXR_X, FXR_M,
    FXR_X, FXR_X, FXR_X, FXR_X };

i64  fx_form_at(i64 i) { return ld64(fx_form + i * 8); }
i64  fx_w_at(i64 i)    { return ld64(fx_w + i * 8); }
i64  fx_opc_at(i64 i)  { return ld64(fx_opc + i * 8); }
i64  fx_pre_at(i64 i)  { return ld64(fx_pre + i * 8); }
uptr fx_name_at(i64 i) { return ld64(fx_name + i * 8); }
i64  fx_rdk_at(i64 i)  { return ld64(fx_rdk + i * 8); }
i64  fx_rnk_at(i64 i)  { return ld64(fx_rnk + i * 8); }

uptr fx_tab;                          // SysV: the table the walker drives
uptr fx_tab_win;
uptr fx_orig;                         // the pristine SysV copy, delegated to
uptr fx_orig_win;
uptr fx_cur = 0;                      // whichever pristine copy is in force
i64  fx_base_reg = 8;                 // xmm8 on SysV, xmm0 on Win64
i64  fx_nargs = 8;                    // xmm argument registers
i64  fx_slotshare = 0;                // Win64: the position picks the register
i64  fx_ngrn = 0;
i64  fx_nsrn = 0;
i64  fx_pstk = 0;
u8   fx_tmp[BUF_SIZE];

uptr fx_of(i64 task) { return ld64(fx_cur + task * 8); }

// the KIND, not the id -- see lib/machine_arm64_float.mc for why
i64 fx_is_float(i64 t) { return type_kind(t) == TK_FLOAT; }
i64 fx_single(i64 t)   { return type_width(t) == 4; }

void fx_need_ds(i64 t) {
    i64 w = type_width(t);
    if (w != 4 && w != 8) die("this float width has no arithmetic here: use its module's own");
}

// the single-precision sibling of a double opcode
i64 fx_w2(i64 dop, i64 ty) {
    if (!fx_single(ty)) return dop;
    if (dop >= FX_ADD_D && dop <= FX_MOV_DD) return dop + 8;
    if (dop == FX_UCOMI_D)  return FX_UCOMI_S;
    if (dop == FX_XOR_D)    return FX_XOR_S;
    if (dop == FX_AND_D)    return FX_AND_S;
    if (dop == FX_CVTSI_D)  return FX_CVTSI_S;
    if (dop == FX_CVTT_D)   return FX_CVTT_S;
    if (dop == FX_LD_D)     return FX_LD_S;
    if (dop == FX_ST_D)     return FX_ST_S;
    return dop;
}

i64 fx_in_reg(i64 d) { return d <= XF_DEPTH_MAX; }

i64 fx_val_reg(i64 d, i64 scratch) {
    if (fx_in_reg(d)) return fx_base_reg + d;
    em(FX_LD_D, scratch, XR_RBP, 0 - x86_slot_depth(d));
    return scratch;
}

i64 fx_dst_reg(i64 d) {
    if (fx_in_reg(d)) return fx_base_reg + d;
    return XF_S1;
}

void fx_dst_done(i64 d, i64 rd) {
    if (!fx_in_reg(d)) em(FX_ST_D, rd, XR_RBP, 0 - x86_slot_depth(d));
}

void fx_movf(i64 ty, i64 rd, i64 rn) { if (rd != rn) e2(fx_w2(FX_MOV_DD, ty), rd, rn); }

void fx_save_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth) break;
        if (fx_is_float(walk_depth_type(d))) {
            if (fx_in_reg(d)) em(FX_ST_D, fx_base_reg + d, XR_RBP, 0 - x86_slot_depth(d));
        } else {
            if (x86_in_reg(d)) em(X_ST64, XREG_BASE + d, XR_RBP, 0 - x86_slot_depth(d));
        }
        d = d + 1;
    }
}

void fx_restore_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth) break;
        if (fx_is_float(walk_depth_type(d))) {
            if (fx_in_reg(d)) em(FX_LD_D, fx_base_reg + d, XR_RBP, 0 - x86_slot_depth(d));
        } else {
            if (x86_in_reg(d)) em(X_LD64, XREG_BASE + d, XR_RBP, 0 - x86_slot_depth(d));
        }
        d = d + 1;
    }
}

// ---- the tasks ----
// the four <float> intrinsic lowerings are claimed here, for the same reason
// lib/machine_arm64_float.mc claims them in its own prologue: they belong to the
// machine in effect, and one compiler carries both.
void fx_claim() {
    flh_ldf  = &fx_ldf;
    flh_stf  = &fx_stf;
    flh_un1  = &fx_un1;
    flh_bin2 = &fx_bin2;
}

void fx_prologue_sysv() {
    fx_claim();
    fx_cur = fx_orig;
    fx_base_reg = 8;
    fx_nargs = XF_ARGS_SYSV;
    fx_slotshare = 0;
    fx_ngrn = 0; fx_nsrn = 0; fx_pstk = 0;
    callp(ld64(fx_orig + MTASK_PROLOGUE * 8));
}

void fx_prologue_win() {
    fx_claim();
    fx_cur = fx_orig_win;
    fx_base_reg = 0;                              // xmm6..xmm15 are callee-saved
    fx_nargs = XF_ARGS_WIN;
    fx_slotshare = 1;
    fx_ngrn = 0; fx_nsrn = 0; fx_pstk = 0;
    callp(ld64(fx_orig_win + MTASK_PROLOGUE * 8));
}

// the xmm register argument `i` travels in. On Win64 the slot is SHARED with the
// integer registers -- argument 2 is rdx or xmm2 depending on its type, never
// "the first float" -- which is one line here and the whole difference.
i64 fx_argslot(i64 pos, i64 nsrn) {
    if (fx_slotshare) return pos;
    return nsrn;
}

void fx_param(i64 ty, i64 i, i64 off) {
    if (fx_is_float(ty)) {
        i64 st = fx_w2(FX_ST_D, ty);
        i64 slot = fx_argslot(i, fx_nsrn);
        if (slot < fx_nargs) {
            em(st, slot, XR_RBP, 0 - off);
            fx_nsrn = fx_nsrn + 1;
            if (fx_slotshare) fx_ngrn = fx_ngrn + 1;
            return;
        }
        em(FX_LD_D, XF_S1, XR_RBP, 16 + x86_shadow + fx_pstk * 8);
        em(st, XF_S1, XR_RBP, 0 - off);
        fx_pstk = fx_pstk + 1;
        return;
    }
    i64 slot = fx_ngrn;
    if (fx_slotshare) slot = i;
    if (slot < x86_nargreg) {
        em(x86_mem_op(ty, 1), x86_argreg_at(slot), XR_RBP, 0 - off);
        fx_ngrn = fx_ngrn + 1;
        if (fx_slotshare) fx_nsrn = fx_nsrn + 1;
        return;
    }
    em(X_LD64, XR_RAX, XR_RBP, 16 + x86_shadow + fx_pstk * 8);
    em(x86_mem_op(ty, 1), XR_RAX, XR_RBP, 0 - off);
    fx_pstk = fx_pstk + 1;
}

void fx_const(i64 d, i64 imm) {
    i64 ty = walk_depth_type(d);
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_CONST), d, imm); return; }
    i64 rd = fx_dst_reg(d);
    if (fx_single(ty)) ei(X_MOVI, XR_RAX, 0, imm & 0xffffffff);
    else               ei(X_MOVI, XR_RAX, 0, imm);
    e2(FX_MOVQ_XR, rd, XR_RAX);
    fx_dst_done(d, rd);
}

void fx_bin(i64 op, i64 d, i64 d2) {
    i64 ty = walk_depth_type(d);
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_BIN), op, d, d2); return; }
    fx_need_ds(ty);
    i64 fop = 0 - 1;
    if (op == MOP_ADD) fop = FX_ADD_D;
    if (op == MOP_SUB) fop = FX_SUB_D;
    if (op == MOP_MUL) fop = FX_MUL_D;
    if (op == MOP_SDIV || op == MOP_UDIV) fop = FX_DIV_D;
    if (op == MOP_SMOD || op == MOP_UMOD) die("no float remainder");
    if (fop < 0) die("no bitwise or shift operator on a float");
    i64 rl = fx_val_reg(d, XF_S1);
    i64 rr = fx_val_reg(d2, XF_S2);
    i64 rd = fx_dst_reg(d);
    fx_movf(ty, rd, rl);                          // SSE2 is two-operand
    e2(fx_w2(fop, ty), rd, rr);
    fx_dst_done(d, rd);
}

// `ucomisd a, b` sets ZF, PF and CF, and an UNORDERED compare sets ALL THREE.
// So `a`(7) and `ae`(3) -- which want CF clear -- are false for a NaN, while
// `b`(2) and `be`(6) are true. That is why `<` and `<=` are not encoded as `b`
// and `be` here: the operands are SWAPPED and the same `a`/`ae` are used, which
// is one register move fewer than masking with the parity flag and cannot be got
// wrong. `==` and `!=` still need the mask, because ZF alone does not
// distinguish "equal" from "unordered".
//
// MCOND_EQ NE LT LE GT GE, after the swap: e(4) ne(5) a(7) ae(3) a(7) ae(3).
i64 fx_cond[] = { 4, 5, 7, 3, 7, 3 };
i64 fx_cond_at(i64 i) { return ld64(fx_cond + i * 8); }

// setcc writes ONE byte, so its destination is zeroed first -- rcx included,
// which the parity mask below uses
void fx_setcc(i64 rd, i64 cc) {
    ei(X_MOVI, rd, 0, 0);
    ins_add(X_SETCC, rd, 0, 0, cc, 0, 0);
}

void fx_cmp(i64 cond, i64 d, i64 d2) {
    i64 ty = walk_depth_type(d);
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_CMP), cond, d, d2); return; }
    fx_need_ds(ty);
    i64 rl = fx_val_reg(d, XF_S1);
    i64 rr = fx_val_reg(d2, XF_S2);
    if (cond == MCOND_LT || cond == MCOND_LE) { i64 t = rl; rl = rr; rr = t; }
    e2(fx_w2(FX_UCOMI_D, ty), rl, rr);
    i64 rd = x86_dst_reg(d);
    fx_setcc(rd, fx_cond_at(cond));
    if (cond == MCOND_EQ) {                       // unordered is not equal
        fx_setcc(XR_RCX, 11);                     // setnp
        e2(X_AND, rd, XR_RCX);
    }
    if (cond == MCOND_NE) {                       // ...and IS not-equal
        fx_setcc(XR_RCX, 10);                     // setp
        e2(X_OR, rd, XR_RCX);
    }
    x86_dst_done(d, rd);
}

// -x and fabs(x) are a sign-bit flip and a sign-bit clear: the mask goes through
// an integer register and xmm14, because SSE2 has no immediate form
void fx_mask(i64 ty, i64 rd, i64 op, u64 dm, u64 sm) {
    u64 m = dm;
    if (fx_single(ty)) m = sm;
    ei(X_MOVI, XR_RAX, 0, m);
    e2(FX_MOVQ_XR, XF_S2, XR_RAX);
    e2(fx_w2(op, ty), rd, XF_S2);
}

void fx_un(i64 op, i64 d) {
    i64 ty = walk_depth_type(d);
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_UN), op, d); return; }
    fx_need_ds(ty);
    if (op == MUN_NOT) die("no bitwise complement on a float");
    if (op == MUN_NEG) {
        i64 r = fx_val_reg(d, XF_S1);
        i64 rd = fx_dst_reg(d);
        fx_movf(ty, rd, r);
        fx_mask(ty, rd, FX_XOR_D, 0x8000000000000000, 0x80000000);
        fx_dst_done(d, rd);
        return;
    }
    i64 r = fx_val_reg(d, XF_S1);                 // !x  ->  x == 0.0
    ei(X_MOVI, XR_RAX, 0, 0);
    e2(FX_MOVQ_XR, XF_S2, XR_RAX);
    e2(fx_w2(FX_UCOMI_D, ty), r, XF_S2);
    i64 rd = x86_dst_reg(d);
    fx_setcc(rd, 4);                              // sete
    fx_setcc(XR_RCX, 11);                         // setnp: a NaN is not equal
    e2(X_AND, rd, XR_RCX);
    x86_dst_done(d, rd);
}

void fx_bool(i64 d) {
    i64 ty = walk_depth_type(d);
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_BOOL), d); return; }
    i64 r = fx_val_reg(d, XF_S1);
    ei(X_MOVI, XR_RAX, 0, 0);
    e2(FX_MOVQ_XR, XF_S2, XR_RAX);
    e2(fx_w2(FX_UCOMI_D, ty), r, XF_S2);
    i64 rd = x86_dst_reg(d);
    fx_setcc(rd, 5);                              // setne
    fx_setcc(XR_RCX, 10);                         // setp: unordered counts as != 0
    e2(X_OR, rd, XR_RCX);
    x86_dst_done(d, rd);
}

// u64 -> float, the halving trick: SSE2 only converts SIGNED integers, so a
// value with the top bit set is halved (keeping the low bit as a sticky, so the
// rounding is the same), converted, and doubled back.
void fx_u2f(i64 ty, i64 rd, i64 rs) {
    nlabels = nlabels + 1;
    i64 lbig = nlabels;
    nlabels = nlabels + 1;
    i64 lend = nlabels;
    e2(X_TEST, rs, rs);
    ins_add(X_JCC, 0, 0, 0, 8, lbig, 0);          // js lbig
    e2(fx_w2(FX_CVTSI_D, ty), rd, rs);
    el(X_JMP, lend);
    el(I_LABEL, lbig);
    x86_mov(XR_RCX, rs);
    ei(X_MOVI, XR_RDX, 0, 1);
    e2(X_AND, XR_RCX, XR_RDX);                    // the sticky low bit
    x86_mov(XR_RDX, rs);
    ei(X_MOVI, XR_RAX, 0, 1);
    x86_mov(XREG_S2, XR_RAX);
    e2(X_SHR, XR_RDX, 0);                         // shr rdx, cl (cl == 1)
    e2(X_OR, XR_RDX, XR_RCX);
    e2(fx_w2(FX_CVTSI_D, ty), rd, XR_RDX);
    e2(fx_w2(FX_ADD_D, ty), rd, rd);
    el(I_LABEL, lend);
}

void fx_cast(i64 ty, i64 d) {
    i64 src = walk_depth_type(d);
    if (!fx_is_float(src) && !fx_is_float(ty)) { callp(fx_of(MTASK_CAST), ty, d); return; }
    if (src == ty) return;
    if (fx_is_float(src)) fx_need_ds(src);
    if (fx_is_float(ty))  fx_need_ds(ty);
    if (fx_is_float(src) && fx_is_float(ty)) {
        i64 r = fx_val_reg(d, XF_S1);
        i64 rd = fx_dst_reg(d);
        if (fx_single(ty)) e2(FX_CVT_SD, rd, r);
        else               e2(FX_CVT_DS, rd, r);
        fx_dst_done(d, rd);
        return;
    }
    if (fx_is_float(src)) {
        i64 r = fx_val_reg(d, XF_S1);
        i64 rd = x86_dst_reg(d);
        if (ty == ty_f64raw) e2(FX_MOVQ_RX, rd, r);
        else {
            e2(fx_w2(FX_CVTT_D, src), rd, r);
            x86_cast(ty, d);                      // the core's narrowing, in place
            x86_dst_done(d, rd);
            return;
        }
        x86_dst_done(d, rd);
        return;
    }
    i64 r = x86_val_reg(d, XREG_S1);
    i64 rd = fx_dst_reg(d);
    if (src == ty_f64raw)                      e2(FX_MOVQ_XR, rd, r);
    else if (src == TY_U64 || src == TY_UPTR)  fx_u2f(ty, rd, r);
    else                                       e2(fx_w2(FX_CVTSI_D, ty), rd, r);
    fx_dst_done(d, rd);
}

void fx_local_load(i64 ty, i64 d, i64 off) {
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_LOCAL_LOAD), ty, d, off); return; }
    i64 rd = fx_dst_reg(d);
    em(fx_w2(FX_LD_D, ty), rd, XR_RBP, 0 - off);
    fx_dst_done(d, rd);
}

void fx_local_store(i64 ty, i64 d, i64 off) {
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_LOCAL_STORE), ty, d, off); return; }
    em(fx_w2(FX_ST_D, ty), fx_val_reg(d, XF_S1), XR_RBP, 0 - off);
}

void fx_global_load(i64 ty, i64 d, i64 sym) {
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_GLOBAL_LOAD), ty, d, sym); return; }
    ins_add(X_LEARIP, XR_RAX, 0, 0, 0, 0, sym);
    i64 rd = fx_dst_reg(d);
    em(fx_w2(FX_LD_D, ty), rd, XR_RAX, 0);
    fx_dst_done(d, rd);
}

void fx_global_store(i64 ty, i64 d, i64 sym) {
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_GLOBAL_STORE), ty, d, sym); return; }
    i64 r = fx_val_reg(d, XF_S2);
    ins_add(X_LEARIP, XR_RAX, 0, 0, 0, 0, sym);
    em(fx_w2(FX_ST_D, ty), r, XR_RAX, 0);
}

// the caller side. Two counters on SysV, one shared position on Win64; the
// stack half reuses the bundled push sequence's shape -- push in reverse order,
// then the shadow space Win64 asks for.
i64 fx_push_args(i64 dbase, i64 na) {
    i64 ngrn = 0;
    i64 nsrn = 0;
    i64 np = 0;
    i64 i = 0;
    loop {                                        // how many overflow
        if (i >= na) break;
        i64 ty = walk_depth_type(dbase + i);
        if (fx_slotshare) { if (i >= x86_nargreg) np = np + 1; }
        else if (fx_is_float(ty)) { if (nsrn >= fx_nargs) np = np + 1; else nsrn = nsrn + 1; }
        else                      { if (ngrn >= x86_nargreg) np = np + 1; else ngrn = ngrn + 1; }
        i = i + 1;
    }
    i64 bytes = 8 * np;
    if (np % 2) { ei(X_SPSUB, 0, 0, 8); bytes = bytes + 8; }
    ngrn = 0;
    nsrn = 0;
    i64 j = 0;
    i64 over[16];                                 // the overflow depths, in order
    i = 0;
    loop {
        if (i >= na) break;
        i64 ty = walk_depth_type(dbase + i);
        i64 o = 0;
        if (fx_slotshare) { if (i >= x86_nargreg) o = 1; }
        else if (fx_is_float(ty)) { if (nsrn >= fx_nargs) o = 1; else nsrn = nsrn + 1; }
        else                      { if (ngrn >= x86_nargreg) o = 1; else ngrn = ngrn + 1; }
        if (o) { st64(over + j * 8, dbase + i); j = j + 1; }
        i = i + 1;
    }
    i = j - 1;
    loop {                                        // pushed last argument first
        if (i < 0) break;
        i64 d = ld64(over + i * 8);
        if (fx_is_float(walk_depth_type(d))) {
            em(FX_ST_D, fx_val_reg(d, XF_S1), XR_RSP, 0 - 8);
            ei(X_SPSUB, 0, 0, 8);
        } else {
            if (x86_in_reg(d)) e2(X_PUSH, XREG_BASE + d, 0);
            else               em(X_PUSHM, 0, XR_RBP, 0 - x86_slot_depth(d));
        }
        i = i - 1;
    }
    if (x86_shadow) { ei(X_SPSUB, 0, 0, x86_shadow); bytes = bytes + x86_shadow; }
    return bytes;
}

void fx_reg_args(i64 dbase, i64 na) {
    i64 ngrn = 0;
    i64 nsrn = 0;
    i64 i = 0;
    loop {
        if (i >= na) break;
        i64 ty = walk_depth_type(dbase + i);
        i64 d = dbase + i;
        if (fx_is_float(ty)) {
            i64 slot = fx_argslot(i, nsrn);
            if (slot < fx_nargs) fx_movf(ty, slot, fx_val_reg(d, XF_S1));
            nsrn = nsrn + 1;
            if (fx_slotshare) ngrn = ngrn + 1;
        } else {
            i64 slot = ngrn;
            if (fx_slotshare) slot = i;
            if (slot < x86_nargreg) x86_arg_to(x86_argreg_at(slot), d);
            ngrn = ngrn + 1;
            if (fx_slotshare) nsrn = nsrn + 1;
        }
        i = i + 1;
    }
}

void fx_result(i64 d) {
    i64 ty = walk_ret_type();
    if (fx_is_float(ty)) {
        i64 rd = fx_dst_reg(d);
        fx_movf(ty, rd, 0);                       // xmm0
        fx_dst_done(d, rd);
        return;
    }
    i64 rd = x86_dst_reg(d);
    x86_mov(rd, XR_RAX);
    x86_dst_done(d, rd);
}

void fx_call(i64 d, i64 na, i64 sym) {
    fx_save_live(d);
    i64 back = fx_push_args(d, na);
    fx_reg_args(d, na);
    ins_add(X_CALL, 0, 0, 0, 0, 0, sym);
    if (back) ei(X_SPADD, 0, 0, back);
    fx_restore_live(d);
    fx_result(d);
}

void fx_callp(i64 d, i64 na) {
    fx_save_live(d);
    x86_arg_to(XR_RAX, d);
    i64 back = fx_push_args(d + 1, na - 1);
    fx_reg_args(d + 1, na - 1);
    e2(X_CALLR, XR_RAX, 0);
    if (back) ei(X_SPADD, 0, 0, back);
    fx_restore_live(d);
    fx_result(d);
}

void fx_ret(i64 d) {
    i64 ty = walk_depth_type(d);
    if (!fx_is_float(ty)) { callp(fx_of(MTASK_RET), d); return; }
    fx_movf(ty, 0, fx_val_reg(d, XF_S1));
}

void fx_jcond(i64 d, i64 l, i64 cc) {
    i64 ty = walk_depth_type(d);
    i64 r = fx_val_reg(d, XF_S1);
    ei(X_MOVI, XR_RAX, 0, 0);
    e2(FX_MOVQ_XR, XF_S2, XR_RAX);
    e2(fx_w2(FX_UCOMI_D, ty), r, XF_S2);
    i64 t = x86_dst_reg(d);
    fx_setcc(t, 5);                               // setne: nonzero, NaN included
    fx_setcc(XR_RCX, 10);                         // setp
    e2(X_OR, t, XR_RCX);
    e2(X_TEST, t, t);
    ins_add(X_JCC, 0, 0, 0, cc, l, 0);
}

void fx_jz(i64 d, i64 l) {
    if (!fx_is_float(walk_depth_type(d))) { callp(fx_of(MTASK_JZ), d, l); return; }
    fx_jcond(d, l, 4);                            // je
}

void fx_jnz(i64 d, i64 l) {
    if (!fx_is_float(walk_depth_type(d))) { callp(fx_of(MTASK_JNZ), d, l); return; }
    fx_jcond(d, l, 5);                            // jne
}

// ---- encoding, sizing and the dump ----
void fx_put(uptr e, i64 pc, uptr lab, uptr o) {
    i64 op = ins_op(e);
    if (op < FX_BASE) { callp(fx_of(MTASK_ENCODE), e, pc, lab, o); return; }
    i64 i = op - FX_BASE;
    i64 f = fx_form_at(i);
    i64 pre = fx_pre_at(i);
    i64 reg = ins_rd(e);
    i64 rm = ins_rn(e);
    if (f == XF_RS) { reg = ins_rn(e); rm = ins_rd(e); }
    if (pre) buf_u8(o, pre);
    x86_rex(o, fx_w_at(i), reg, rm, 0);
    x86_op(o, fx_opc_at(i));
    if (f == XF_LD || f == XF_ST) x86_modrm_m(o, reg, ins_rn(e), ins_imm(e));
    else                          x86_modrm_rr(o, reg, rm);
}

i64 fx_ins_size(uptr e) {
    if (ins_op(e) < FX_BASE) return callp(fx_of(MTASK_INS_SIZE), e);
    set_buf_len(fx_tmp, 0);
    fx_put(e, 0, 0, fx_tmp);
    return buf_len(fx_tmp);
}

i64 fx_reloc_kind(uptr e) {
    if (ins_op(e) >= FX_BASE) return 0 - 1;
    return callp(fx_of(MTASK_RELOC_KIND), e);
}

void fx_dreg(i64 k, i64 r) {
    if (k == FXR_M) { out_str(1, "xmm"); out_num(1, r); return; }
    out_str(1, "r");
    out_num(1, r);
}

void fx_dump(uptr in) {
    i64 op = ins_op(in);
    if (op < FX_BASE) { callp(fx_of(MTASK_DUMP), in); return; }
    i64 i = op - FX_BASE;
    i64 f = fx_form_at(i);
    out_str(1, "  ");
    out_str(1, fx_name_at(i));
    out_str(1, " ");
    if (f == XF_ST) {
        out_str(1, "[r");
        out_num(1, ins_rn(in));
        if (ins_imm(in)) { out_str(1, " + "); out_num(1, ins_imm(in)); }
        out_str(1, "], ");
        fx_dreg(FXR_M, ins_rd(in));
        out_str(1, "\n");
        return;
    }
    fx_dreg(fx_rdk_at(i), ins_rd(in));
    out_str(1, ", ");
    if (f == XF_LD) {
        out_str(1, "[r");
        out_num(1, ins_rn(in));
        if (ins_imm(in)) { out_str(1, " + "); out_num(1, ins_imm(in)); }
        out_str(1, "]\n");
        return;
    }
    fx_dreg(fx_rnk_at(i), ins_rn(in));
    out_str(1, "\n");
}

// ---- the intrinsics <float> names, in this instruction set ----
void fx_ldf(i64 d, i64 w) {
    i64 rn = x86_val_reg(d, XREG_S1);
    i64 rd = fx_dst_reg(d);
    i64 op = FX_LD_D;
    if (w == 4) op = FX_LD_S;
    em(op, rd, rn, 0);
    fx_dst_done(d, rd);
}

void fx_stf(i64 d, i64 w) {
    i64 rv = fx_val_reg(d + 1, XF_S1);
    i64 rn = x86_val_reg(d, XREG_S1);
    i64 op = FX_ST_D;
    if (w == 4) op = FX_ST_S;
    em(op, rv, rn, 0);
}

void fx_un1(i64 d, i64 which) {
    i64 ty = walk_depth_type(d);
    i64 r = fx_val_reg(d, XF_S1);
    i64 rd = fx_dst_reg(d);
    if (which) {
        fx_movf(ty, rd, r);
        fx_mask(ty, rd, FX_AND_D, 0x7fffffffffffffff, 0x7fffffff);
    } else {
        e2(fx_w2(FX_SQRT_D, ty), rd, r);
    }
    fx_dst_done(d, rd);
}

void fx_bin2(i64 d, i64 which) {
    i64 ty = walk_depth_type(d);
    i64 rl = fx_val_reg(d, XF_S1);
    i64 rr = fx_val_reg(d + 1, XF_S2);
    i64 rd = fx_dst_reg(d);
    i64 op = FX_MIN_D;
    if (which) op = FX_MAX_D;
    fx_movf(ty, rd, rl);
    e2(fx_w2(op, ty), rd, rr);
    fx_dst_done(d, rd);
}

// ---- registration ----
void fx_fill(uptr tab, uptr orig, uptr src, uptr prologue) {
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(tab  + t * 8, ld64(src + t * 8));
        st64(orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(tab, MTASK_PROLOGUE,     prologue);
    machine_slot(tab, MTASK_PARAM,        &fx_param);
    machine_slot(tab, MTASK_CONST,        &fx_const);
    machine_slot(tab, MTASK_BIN,          &fx_bin);
    machine_slot(tab, MTASK_CMP,          &fx_cmp);
    machine_slot(tab, MTASK_UN,           &fx_un);
    machine_slot(tab, MTASK_BOOL,         &fx_bool);
    machine_slot(tab, MTASK_CAST,         &fx_cast);
    machine_slot(tab, MTASK_LOCAL_LOAD,   &fx_local_load);
    machine_slot(tab, MTASK_LOCAL_STORE,  &fx_local_store);
    machine_slot(tab, MTASK_GLOBAL_LOAD,  &fx_global_load);
    machine_slot(tab, MTASK_GLOBAL_STORE, &fx_global_store);
    machine_slot(tab, MTASK_CALL,         &fx_call);
    machine_slot(tab, MTASK_CALLP,        &fx_callp);
    machine_slot(tab, MTASK_RET,          &fx_ret);
    machine_slot(tab, MTASK_JZ,           &fx_jz);
    machine_slot(tab, MTASK_JNZ,          &fx_jnz);
    machine_slot(tab, MTASK_INS_SIZE,     &fx_ins_size);
    machine_slot(tab, MTASK_ENCODE,       &fx_put);
    machine_slot(tab, MTASK_DUMP,         &fx_dump);
    machine_slot(tab, MTASK_RELOC_KIND,   &fx_reloc_kind);
}

void machine_x86_64_float_init() {
    fx_tab      = xalloc(MTASK_COUNT * 8);
    fx_orig     = xalloc(MTASK_COUNT * 8);
    fx_tab_win  = xalloc(MTASK_COUNT * 8);
    fx_orig_win = xalloc(MTASK_COUNT * 8);
    fx_fill(fx_tab, fx_orig, machine_tab("x86_64"), &fx_prologue_sysv);
    fx_fill(fx_tab_win, fx_orig_win, machine_tab("x86_64-win"), &fx_prologue_win);
    fx_cur = fx_orig;
    machine("x86_64", fx_tab);
    machine("x86_64-win", fx_tab_win);
}
