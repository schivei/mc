// machine_arm64_float.mc — the AArch64 machine of `<float>`, derived from the
// bundled `arm64` one (M24, docs/reference/machine.md § 3).
//
// It is the whole answer to "how does a second register file get taught": the
// walker says which TYPE is at each depth (`walk_depth_type`), so this file
// decides, per task, whether the operand lives in `x9..x15` or in `v16..v23`,
// which instruction to select, and where an argument goes under AAPCS64. Not one
// line of `src/` knows any of it, and not one integer instruction is
// reimplemented: every task that is not a float task delegates through the
// pristine copy of the table it was derived from.
//
// Register plan, AAPCS64:
//
//   float depths 0..7      v16..v23   (never v8..v15: those are callee-saved)
//   float spill scratch    v24, v25
//   float arguments        v0..v7     (NSRN), integer arguments x0..x7 (NGRN)
//   float return           v0
//   overflow               the outgoing area at the bottom of the frame, in
//                          argument order, exactly where a64_param reads it
//
// A float depth past 7 spills to the same eight-byte frame slot the integer
// machine would have used (`slot_depth`), with `str d`/`ldr d`: the low 64 bits
// of a V register are the whole value for both f32 and f64.

#define FREG_BASE 16                  // v16..v23 carry float depths 0..7
#define FREG_MAX   7
#define FREG_S1   24                  // spill scratch: left/destination
#define FREG_S2   25                  // spill scratch: right
#define FREG_ARGS  8                  // v0..v7

// ---- the float opcodes, above every I_* the bundled machine uses ----
#define FI_BASE     100
#define FI_ADD_D    100
#define FI_SUB_D    101
#define FI_MUL_D    102
#define FI_DIV_D    103
#define FI_MIN_D    104
#define FI_MAX_D    105
#define FI_ADD_S    106
#define FI_SUB_S    107
#define FI_MUL_S    108
#define FI_DIV_S    109
#define FI_MIN_S    110
#define FI_MAX_S    111
#define FI_NEG_D    112
#define FI_ABS_D    113
#define FI_SQRT_D   114
#define FI_MOV_DD   115
#define FI_NEG_S    116
#define FI_ABS_S    117
#define FI_SQRT_S   118
#define FI_MOV_SS   119
#define FI_CMP_D    120
#define FI_CMP_S    121
#define FI_CMP0_D   122
#define FI_CMP0_S   123
#define FI_MOV_DX   124               // fmov d, x   (bit move)
#define FI_MOV_XD   125               // fmov x, d
#define FI_MOV_SW   126
#define FI_MOV_WS   127
#define FI_CVT_DS   128               // fcvt d, s
#define FI_CVT_SD   129
#define FI_SCVTF_D  130               // scvtf d, x
#define FI_UCVTF_D  131
#define FI_SCVTF_S  132
#define FI_UCVTF_S  133
#define FI_FCVTZS_D 134               // fcvtzs x, d
#define FI_FCVTZU_D 135
#define FI_FCVTZS_S 136
#define FI_FCVTZU_S 137
#define FI_LDR_D    138
#define FI_STR_D    139
#define FI_LDR_S    140
#define FI_STR_S    141
#define FI_MAXOP    142

// operand shapes
#define FF_2    0                     // rd, rn
#define FF_3    1                     // rd, rn, rm
#define FF_CMP  2                     // rn, rm
#define FF_CMP0 3                     // rn, #0.0
#define FF_MEM  4                     // rt, [rn, #imm]

// register letters, for the dump
#define FR_X 0
#define FR_D 1
#define FR_S 2
#define FR_W 3

// one row per opcode, in FI_* order: encoding base, mnemonic, shape, the letter
// of rd and of rn/rm, and the memory scale. The encoder and --dump-asm read the
// SAME table, so a mnemonic and its bytes cannot drift apart.
u32 fa_base[] = {
    0x1E602800, 0x1E603800, 0x1E600800, 0x1E601800, 0x1E605800, 0x1E604800,
    0x1E202800, 0x1E203800, 0x1E200800, 0x1E201800, 0x1E205800, 0x1E204800,
    0x1E614000, 0x1E60C000, 0x1E61C000, 0x1E604000,
    0x1E214000, 0x1E20C000, 0x1E21C000, 0x1E204000,
    0x1E602000, 0x1E202000, 0x1E602008, 0x1E202008,
    0x9E670000, 0x9E660000, 0x1E270000, 0x1E260000,
    0x1E22C000, 0x1E624000,
    0x9E620000, 0x9E630000, 0x1E220000, 0x1E230000,
    0x9E780000, 0x9E790000, 0x9E380000, 0x9E390000,
    0xFD400000, 0xFD000000, 0xBD400000, 0xBD000000 };
uptr fa_name[] = {
    "fadd", "fsub", "fmul", "fdiv", "fmin", "fmax",
    "fadd", "fsub", "fmul", "fdiv", "fmin", "fmax",
    "fneg", "fabs", "fsqrt", "fmov",
    "fneg", "fabs", "fsqrt", "fmov",
    "fcmp", "fcmp", "fcmp", "fcmp",
    "fmov", "fmov", "fmov", "fmov",
    "fcvt", "fcvt",
    "scvtf", "ucvtf", "scvtf", "ucvtf",
    "fcvtzs", "fcvtzu", "fcvtzs", "fcvtzu",
    "ldr", "str", "ldr", "str" };
i64 fa_form[] = {
    FF_3, FF_3, FF_3, FF_3, FF_3, FF_3,
    FF_3, FF_3, FF_3, FF_3, FF_3, FF_3,
    FF_2, FF_2, FF_2, FF_2,
    FF_2, FF_2, FF_2, FF_2,
    FF_CMP, FF_CMP, FF_CMP0, FF_CMP0,
    FF_2, FF_2, FF_2, FF_2,
    FF_2, FF_2,
    FF_2, FF_2, FF_2, FF_2,
    FF_2, FF_2, FF_2, FF_2,
    FF_MEM, FF_MEM, FF_MEM, FF_MEM };
i64 fa_rdk[] = {
    FR_D, FR_D, FR_D, FR_D, FR_D, FR_D,
    FR_S, FR_S, FR_S, FR_S, FR_S, FR_S,
    FR_D, FR_D, FR_D, FR_D,
    FR_S, FR_S, FR_S, FR_S,
    FR_D, FR_S, FR_D, FR_S,
    FR_D, FR_X, FR_S, FR_W,
    FR_D, FR_S,
    FR_D, FR_D, FR_S, FR_S,
    FR_X, FR_X, FR_X, FR_X,
    FR_D, FR_D, FR_S, FR_S };
i64 fa_rnk[] = {
    FR_D, FR_D, FR_D, FR_D, FR_D, FR_D,
    FR_S, FR_S, FR_S, FR_S, FR_S, FR_S,
    FR_D, FR_D, FR_D, FR_D,
    FR_S, FR_S, FR_S, FR_S,
    FR_D, FR_S, FR_D, FR_S,
    FR_X, FR_D, FR_W, FR_S,
    FR_S, FR_D,
    FR_X, FR_X, FR_X, FR_X,
    FR_D, FR_D, FR_S, FR_S,
    FR_X, FR_X, FR_X, FR_X };
i64 fa_scale[] = {
    0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0,
    0, 0, 0, 0,  0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    8, 8, 4, 4 };

i64  fa_base_at(i64 i)  { return ld32(fa_base + i * 4); }
uptr fa_name_at(i64 i)  { return ld64(fa_name + i * 8); }
i64  fa_form_at(i64 i)  { return ld64(fa_form + i * 8); }
i64  fa_rdk_at(i64 i)   { return ld64(fa_rdk + i * 8); }
i64  fa_rnk_at(i64 i)   { return ld64(fa_rnk + i * 8); }
i64  fa_scale_at(i64 i) { return ld64(fa_scale + i * 8); }

uptr fa_tab;                          // the table the walker drives
uptr fa_orig;                         // the pristine copy every slot delegates to
i64  fa_ngrn = 0;                     // AAPCS64 counters, per function (params)
i64  fa_nsrn = 0;
i64  fa_pstk = 0;

uptr fa_of(i64 task) { return ld64(fa_orig + task * 8); }

// ---- the float half of the depth stack ----
// The test is the KIND, not the id: that is what `kind` is for
// (docs/reference/language.md § 2), and it is what lets this one machine carry
// f64, f32 and a half somebody else registers -- the register file, the spill,
// the ABI and the return position are the same for all three, and only the
// widths that have their own instructions differ. lib/f16.mc is exactly that
// module, and it adds four slots to a copy of this table and nothing else.
i64 fa_is_float(i64 t) { return type_kind(t) == TK_FLOAT; }
i64 fa_single(i64 t)   { return type_width(t) == 4; }

// arithmetic exists for the two widths this machine has instructions for; a
// third one is its module's business and says so rather than doing the wrong
// thing quietly
void fa_need_ds(i64 t) {
    i64 w = type_width(t);
    if (w != 4 && w != 8) die("this float width has no arithmetic here: use its module's own");
}

// the FI_* opcode of a widthed operation: `d` is the double one, and the single
// one is a fixed distance away in the table above
i64 fa_w(i64 dop, i64 ty) {
    if (fa_single(ty)) {
        if (dop >= FI_ADD_D && dop <= FI_MAX_D) return dop + 6;
        if (dop >= FI_NEG_D && dop <= FI_MOV_DD) return dop + 4;
        if (dop == FI_CMP_D)   return FI_CMP_S;
        if (dop == FI_CMP0_D)  return FI_CMP0_S;
        if (dop == FI_LDR_D)   return FI_LDR_S;
        if (dop == FI_STR_D)   return FI_STR_S;
    }
    return dop;
}

i64 fa_in_reg(i64 d) { return d <= FREG_MAX; }

i64 fa_val_reg(i64 d, i64 scratch) {
    if (fa_in_reg(d)) return FREG_BASE + d;
    em(FI_LDR_D, scratch, REG_FRAME, 0 - slot_depth(d));
    return scratch;
}

i64 fa_dst_reg(i64 d) {
    if (fa_in_reg(d)) return FREG_BASE + d;
    return FREG_S1;
}

void fa_dst_done(i64 d, i64 rd) {
    if (!fa_in_reg(d)) em(FI_STR_D, rd, REG_FRAME, 0 - slot_depth(d));
}

// v16..v23 are call-clobbered, so a live float depth goes to the frame around a
// call exactly as a live integer depth does. One walk covers both files.
void fa_save_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth) break;
        if (fa_is_float(walk_depth_type(d))) {
            if (fa_in_reg(d)) em(FI_STR_D, FREG_BASE + d, REG_FRAME, 0 - slot_depth(d));
        } else {
            if (in_reg(d)) em(I_STR, REG_BASE + d, REG_FRAME, 0 - slot_depth(d));
        }
        d = d + 1;
    }
}

void fa_restore_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth) break;
        if (fa_is_float(walk_depth_type(d))) {
            if (fa_in_reg(d)) em(FI_LDR_D, FREG_BASE + d, REG_FRAME, 0 - slot_depth(d));
        } else {
            if (in_reg(d)) em(I_LDR, REG_BASE + d, REG_FRAME, 0 - slot_depth(d));
        }
        d = d + 1;
    }
}

// ---- the tasks ----
void fa_prologue() {
    // the four <float> intrinsic lowerings belong to the machine IN EFFECT, and
    // a single compiler carries two of them (a taught compiler cross-compiles).
    // The prologue is where a machine takes over for a function, so it is where
    // they are claimed -- an intrinsic is only ever lowered inside a body.
    flh_ldf  = &fa_ldf;
    flh_stf  = &fa_stf;
    flh_un1  = &fa_un1;
    flh_bin2 = &fa_bin2;
    fa_ngrn = 0;
    fa_nsrn = 0;
    fa_pstk = 0;
    callp(fa_of(MTASK_PROLOGUE));
}

// AAPCS64: two independent counters, and whatever overflows either of them is
// read from the caller's outgoing area in ARGUMENT order -- which is what
// fa_pstk counts.
void fa_param(i64 ty, i64 i, i64 off) {
    if (fa_is_float(ty)) {
        i64 st = FI_STR_D;
        if (fa_single(ty)) st = FI_STR_S;
        if (fa_nsrn < FREG_ARGS) {
            em(st, fa_nsrn, REG_FRAME, 0 - off);
            fa_nsrn = fa_nsrn + 1;
            return;
        }
        em(FI_LDR_D, FREG_S1, REG_FP, 16 + fa_pstk * 8);
        em(st, FREG_S1, REG_FRAME, 0 - off);
        fa_pstk = fa_pstk + 1;
        return;
    }
    if (fa_ngrn < REG_ARGS) {
        em(mem_op(ty, 1), fa_ngrn, REG_FRAME, 0 - off);
        fa_ngrn = fa_ngrn + 1;
        return;
    }
    em(I_LDR, REG_S1, REG_FP, 16 + fa_pstk * 8);
    em(mem_op(ty, 1), REG_S1, REG_FRAME, 0 - off);
    fa_pstk = fa_pstk + 1;
}

// a float constant is its BIT PATTERN, materialised into an integer scratch and
// moved across. No literal pool, no relocation, no new task: that is what the
// N_INT decision of docs/specs/M24.md buys.
void fa_const(i64 d, i64 imm) {
    i64 ty = walk_depth_type(d);
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_CONST), d, imm); return; }
    i64 rd = fa_dst_reg(d);
    if (fa_single(ty)) {
        gen_imm(REG_S1, imm & 0xffffffff);
        e2(FI_MOV_SW, rd, REG_S1);
    } else {
        gen_imm(REG_S1, imm);
        e2(FI_MOV_DX, rd, REG_S1);
    }
    fa_dst_done(d, rd);
}

void fa_bin(i64 op, i64 d, i64 d2) {
    i64 ty = walk_depth_type(d);
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_BIN), op, d, d2); return; }
    fa_need_ds(ty);
    i64 fop = 0 - 1;
    if (op == MOP_ADD) fop = FI_ADD_D;
    if (op == MOP_SUB) fop = FI_SUB_D;
    if (op == MOP_MUL) fop = FI_MUL_D;
    if (op == MOP_SDIV || op == MOP_UDIV) fop = FI_DIV_D;
    if (op == MOP_SMOD || op == MOP_UMOD) die("no float remainder");
    if (fop < 0) die("no bitwise or shift operator on a float");
    i64 rl = fa_val_reg(d, FREG_S1);
    i64 rr = fa_val_reg(d2, FREG_S2);
    i64 rd = fa_dst_reg(d);
    e3(fa_w(fop, ty), rd, rl, rr);
    fa_dst_done(d, rd);
}

// the six ordered predicates. The AArch64 condition after FCMP is chosen so that
// UNORDERED (a NaN on either side) makes all six false: mi/ls/gt/ge/eq are all
// false when N=0, Z=0, C=1, V=1, and `ne` is the only one that is true -- which
// is exactly the IEEE rule that `x != x` holds for a NaN.
i64 fa_cond[] = { C_EQ, C_NE, 4, 9, 12, 10 };     // eq ne mi ls gt ge
i64 fa_cond_at(i64 i) { return ld64(fa_cond + i * 8); }

void fa_cmp(i64 cond, i64 d, i64 d2) {
    i64 ty = walk_depth_type(d);
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_CMP), cond, d, d2); return; }
    fa_need_ds(ty);
    i64 rl = fa_val_reg(d, FREG_S1);
    i64 rr = fa_val_reg(d2, FREG_S2);
    e3(fa_w(FI_CMP_D, ty), 0, rl, rr);
    i64 rd = dst_reg(d);                          // the RESULT is an i64
    ins_add(I_CSET, rd, 0, 0, fa_cond_at(cond), 0, 0);
    dst_done(d, rd);
}

void fa_un(i64 op, i64 d) {
    i64 ty = walk_depth_type(d);
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_UN), op, d); return; }
    fa_need_ds(ty);
    if (op == MUN_NOT) die("no bitwise complement on a float");
    if (op == MUN_NEG) {
        i64 r = fa_val_reg(d, FREG_S1);
        e2(fa_w(FI_NEG_D, ty), r, r);
        fa_dst_done(d, r);
        return;
    }
    e2(fa_w(FI_CMP0_D, ty), 0, fa_val_reg(d, FREG_S1));   // !x
    i64 rd = dst_reg(d);
    ins_add(I_CSET, rd, 0, 0, C_EQ, 0, 0);
    dst_done(d, rd);
}

void fa_bool(i64 d) {
    i64 ty = walk_depth_type(d);
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_BOOL), d); return; }
    e2(fa_w(FI_CMP0_D, ty), 0, fa_val_reg(d, FREG_S1));
    i64 rd = dst_reg(d);
    ins_add(I_CSET, rd, 0, 0, C_NE, 0, 0);
    dst_done(d, rd);
}

// every conversion the two type families can ask for, in one place. `f64raw` is
// the reinterpretation: the same eight bytes seen as an integer, which is one
// `fmov` and not a numeric conversion.
void fa_cast(i64 ty, i64 d) {
    i64 src = walk_depth_type(d);
    if (!fa_is_float(src) && !fa_is_float(ty)) { callp(fa_of(MTASK_CAST), ty, d); return; }
    if (src == ty) return;
    if (fa_is_float(src)) fa_need_ds(src);
    if (fa_is_float(ty))  fa_need_ds(ty);
    if (fa_is_float(src) && fa_is_float(ty)) {           // f32 <-> f64
        i64 r = fa_val_reg(d, FREG_S1);
        i64 rd = fa_dst_reg(d);
        if (fa_single(ty)) e2(FI_CVT_SD, rd, r);
        else               e2(FI_CVT_DS, rd, r);
        fa_dst_done(d, rd);
        return;
    }
    if (fa_is_float(src)) {                              // float -> integer
        i64 r = fa_val_reg(d, FREG_S1);
        i64 rd = dst_reg(d);
        if (ty == ty_f64raw)          e2(FI_MOV_XD, rd, r);       // a bit move
        else if (ty == TY_I64)        e2(fa_w(FI_FCVTZS_D, src), rd, r);
        else {
            e2(fa_w(FI_FCVTZU_D, src), rd, r);
            gen_cast(rd, ty);                            // then narrow, as the core does
        }
        dst_done(d, rd);
        return;
    }
    i64 r = val_reg(d, REG_S1);                          // integer -> float
    i64 rd = fa_dst_reg(d);
    if (src == ty_f64raw)    e2(FI_MOV_DX, rd, r);
    else if (src == TY_I64)  e2(fa_w(FI_SCVTF_D, ty), rd, r);
    else                     e2(fa_w(FI_UCVTF_D, ty), rd, r);
    fa_dst_done(d, rd);
}

void fa_local_load(i64 ty, i64 d, i64 off) {
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_LOCAL_LOAD), ty, d, off); return; }
    i64 rd = fa_dst_reg(d);
    em(fa_w(FI_LDR_D, ty), rd, REG_FRAME, 0 - off);
    fa_dst_done(d, rd);
}

void fa_local_store(i64 ty, i64 d, i64 off) {
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_LOCAL_STORE), ty, d, off); return; }
    em(fa_w(FI_STR_D, ty), fa_val_reg(d, FREG_S1), REG_FRAME, 0 - off);
}

void fa_global_load(i64 ty, i64 d, i64 sym) {
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_GLOBAL_LOAD), ty, d, sym); return; }
    gen_gaddr(REG_S1, sym);
    i64 rd = fa_dst_reg(d);
    em(fa_w(FI_LDR_D, ty), rd, REG_S1, 0);
    fa_dst_done(d, rd);
}

void fa_global_store(i64 ty, i64 d, i64 sym) {
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_GLOBAL_STORE), ty, d, sym); return; }
    i64 r = fa_val_reg(d, FREG_S2);
    gen_gaddr(REG_S1, sym);
    em(fa_w(FI_STR_D, ty), r, REG_S1, 0);
}

// the whole caller side of the ABI, out of walk_depth_type: two counters, the
// overflow in argument order, and the stack stores BEFORE any argument register
// is written -- exactly the reason the bundled machine orders them that way.
void fa_args(i64 dbase, i64 na) {
    i64 ngrn = 0;
    i64 nsrn = 0;
    i64 nstk = 0;
    i64 i = 0;
    loop {                                        // pass 1: the overflow, on the stack
        if (i >= na) break;
        i64 ty = walk_depth_type(dbase + i);
        i64 over = 0;
        if (fa_is_float(ty)) { if (nsrn >= FREG_ARGS) over = 1; else nsrn = nsrn + 1; }
        else                 { if (ngrn >= REG_ARGS)  over = 1; else ngrn = ngrn + 1; }
        if (over) {
            i64 d = dbase + i;
            if (fa_is_float(ty)) {
                em(FI_STR_D, fa_val_reg(d, FREG_S1), REG_SP, nstk * 8);
            } else {
                i64 r = REG_S1;
                if (in_reg(d)) r = REG_BASE + d;
                else           em(I_LDR, REG_S1, REG_FRAME, 0 - slot_depth(d));
                em(I_STR, r, REG_SP, nstk * 8);
            }
            nstk = nstk + 1;
        }
        i = i + 1;
    }
    if (nstk) {
        i64 need = (nstk * 8 + 15) & ~15;
        if (need > a64_out) a64_out = need;
    }
    ngrn = 0;
    nsrn = 0;
    i = 0;
    loop {                                        // pass 2: the register arguments
        if (i >= na) break;
        i64 ty = walk_depth_type(dbase + i);
        i64 d = dbase + i;
        if (fa_is_float(ty)) {
            if (nsrn < FREG_ARGS) {
                i64 r = fa_val_reg(d, FREG_S1);
                if (r != nsrn) e2(fa_w(FI_MOV_DD, ty), nsrn, r);
                nsrn = nsrn + 1;
            }
        } else {
            if (ngrn < REG_ARGS) {
                arg_to_reg(ngrn, d);
                ngrn = ngrn + 1;
            }
        }
        i = i + 1;
    }
}

// the result comes back in v0 or in x0, and walk_ret_type() is what says which:
// by now depth d holds ARGUMENT 0, not the call's own value.
void fa_result(i64 d) {
    i64 ty = walk_ret_type();
    if (fa_is_float(ty)) {
        i64 rd = fa_dst_reg(d);
        if (rd != 0) e2(fa_w(FI_MOV_DD, ty), rd, 0);
        fa_dst_done(d, rd);
        return;
    }
    i64 rd = dst_reg(d);
    e2(I_MOV, rd, 0);
    dst_done(d, rd);
}

void fa_call(i64 d, i64 na, i64 sym) {
    fa_save_live(d);
    fa_args(d, na);
    ins_add(I_BL, 0, 0, 0, 0, 0, sym);
    fa_restore_live(d);
    fa_result(d);
}

void fa_callp(i64 d, i64 na) {
    fa_save_live(d);
    fa_args(d + 1, na - 1);
    arg_to_reg(REG_S1, d);                        // the pointer, outside the ABI
    ins_add(I_BLR, REG_S1, 0, 0, 0, 0, 0);
    fa_restore_live(d);
    fa_result(d);
}

void fa_ret(i64 d) {
    i64 ty = walk_depth_type(d);
    if (!fa_is_float(ty)) { callp(fa_of(MTASK_RET), d); return; }
    i64 r = fa_val_reg(d, FREG_S1);
    if (r != 0) e2(fa_w(FI_MOV_DD, ty), 0, r);
}

// `if (x)` on a float: compare against zero and branch on the flag through an
// integer scratch, so no new branch opcode is needed
void fa_jcond(i64 d, i64 l, i64 op, i64 cond) {
    e2(fa_w(FI_CMP0_D, walk_depth_type(d)), 0, fa_val_reg(d, FREG_S1));
    ins_add(I_CSET, REG_S1, 0, 0, cond, 0, 0);
    elr(op, REG_S1, l);
}

void fa_jz(i64 d, i64 l) {
    if (!fa_is_float(walk_depth_type(d))) { callp(fa_of(MTASK_JZ), d, l); return; }
    fa_jcond(d, l, I_CBNZ, C_EQ);                 // branch when the value IS zero
}

void fa_jnz(i64 d, i64 l) {
    if (!fa_is_float(walk_depth_type(d))) { callp(fa_of(MTASK_JNZ), d, l); return; }
    fa_jcond(d, l, I_CBNZ, C_NE);
}

// ---- encoding, sizing and the dump: the float opcodes, then delegate ----
i64 fa_ins_size(uptr e) {
    if (ins_op(e) >= FI_BASE) return 4;
    return callp(fa_of(MTASK_INS_SIZE), e);
}

i64 fa_reloc_kind(uptr e) {
    if (ins_op(e) >= FI_BASE) return 0 - 1;
    return callp(fa_of(MTASK_RELOC_KIND), e);
}

i64 fa_enc(uptr in) {
    i64 i = ins_op(in) - FI_BASE;
    i64 b = fa_base_at(i);
    i64 f = fa_form_at(i);
    if (f == FF_3)    return b | (ins_rm(in) << 16) | (ins_rn(in) << 5) | ins_rd(in);
    if (f == FF_2)    return b | (ins_rn(in) << 5) | ins_rd(in);
    if (f == FF_CMP)  return b | (ins_rm(in) << 16) | (ins_rn(in) << 5);
    if (f == FF_CMP0) return b | (ins_rn(in) << 5);
    i64 sc = fa_scale_at(i);
    if (ins_imm(in) < 0 || ins_imm(in) % sc != 0 || ins_imm(in) / sc > 4095)
        die("float memory offset out of range");
    return b | ((ins_imm(in) / sc) << 10) | (ins_rn(in) << 5) | ins_rd(in);
}

void fa_encode(uptr e, i64 pc, uptr lab, uptr b) {
    if (ins_op(e) >= FI_BASE) { buf_u32(b, fa_enc(e)); return; }
    callp(fa_of(MTASK_ENCODE), e, pc, lab, b);
}

void fa_dreg(i64 k, i64 r) {
    if (k == FR_X) { if (r == REG_SP) { out_str(1, "sp"); return; } out_str(1, "x"); }
    if (k == FR_D) out_str(1, "d");
    if (k == FR_S) out_str(1, "s");
    if (k == FR_W) out_str(1, "w");
    out_num(1, r);
}

void fa_dump(uptr in) {
    if (ins_op(in) < FI_BASE) { callp(fa_of(MTASK_DUMP), in); return; }
    i64 i = ins_op(in) - FI_BASE;
    i64 f = fa_form_at(i);
    out_str(1, "  ");
    out_str(1, fa_name_at(i));
    out_str(1, " ");
    if (f == FF_CMP || f == FF_CMP0) {
        fa_dreg(fa_rnk_at(i), ins_rn(in));
        if (f == FF_CMP) { out_str(1, ", "); fa_dreg(fa_rnk_at(i), ins_rm(in)); }
        else               out_str(1, ", #0.0");
        out_str(1, "\n");
        return;
    }
    fa_dreg(fa_rdk_at(i), ins_rd(in));
    if (f == FF_MEM) {
        out_str(1, ", [");
        fa_dreg(FR_X, ins_rn(in));
        if (ins_imm(in)) { out_str(1, ", #"); out_num(1, ins_imm(in)); }
        out_str(1, "]\n");
        return;
    }
    out_str(1, ", ");
    fa_dreg(fa_rnk_at(i), ins_rn(in));
    if (f == FF_3) { out_str(1, ", "); fa_dreg(fa_rnk_at(i), ins_rm(in)); }
    out_str(1, "\n");
}

// ---- the intrinsics <float> names, in this instruction set ----
void fa_ldf(i64 d, i64 w) {                       // ldf32/ldf64: the address is at d
    i64 rn = val_reg(d, REG_S1);
    i64 rd = fa_dst_reg(d);
    i64 op = FI_LDR_D;
    if (w == 4) op = FI_LDR_S;
    em(op, rd, rn, 0);
    fa_dst_done(d, rd);
}

void fa_stf(i64 d, i64 w) {                       // stf32/stf64: address at d, value at d+1
    i64 rn = val_reg(d, REG_S1);
    i64 rv = fa_val_reg(d + 1, FREG_S1);
    i64 op = FI_STR_D;
    if (w == 4) op = FI_STR_S;
    em(op, rv, rn, 0);
}

void fa_un1(i64 d, i64 which) {                   // sqrt_f64 / fabs
    i64 ty = walk_depth_type(d);
    i64 r = fa_val_reg(d, FREG_S1);
    i64 rd = fa_dst_reg(d);
    i64 op = FI_SQRT_D;
    if (which) op = FI_ABS_D;
    e2(fa_w(op, ty), rd, r);
    fa_dst_done(d, rd);
}

void fa_bin2(i64 d, i64 which) {                  // fmin / fmax
    i64 ty = walk_depth_type(d);
    i64 rl = fa_val_reg(d, FREG_S1);
    i64 rr = fa_val_reg(d + 1, FREG_S2);
    i64 rd = fa_dst_reg(d);
    i64 op = FI_MIN_D;
    if (which) op = FI_MAX_D;
    e3(fa_w(op, ty), rd, rl, rr);
    fa_dst_done(d, rd);
}

// ---- registration ----
void machine_arm64_float_init() {
    fa_tab  = xalloc(MTASK_COUNT * 8);
    fa_orig = xalloc(MTASK_COUNT * 8);
    uptr src = machine_tab("arm64");
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(fa_tab  + t * 8, ld64(src + t * 8));
        st64(fa_orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(fa_tab, MTASK_PROLOGUE,     &fa_prologue);
    machine_slot(fa_tab, MTASK_PARAM,        &fa_param);
    machine_slot(fa_tab, MTASK_CONST,        &fa_const);
    machine_slot(fa_tab, MTASK_BIN,          &fa_bin);
    machine_slot(fa_tab, MTASK_CMP,          &fa_cmp);
    machine_slot(fa_tab, MTASK_UN,           &fa_un);
    machine_slot(fa_tab, MTASK_BOOL,         &fa_bool);
    machine_slot(fa_tab, MTASK_CAST,         &fa_cast);
    machine_slot(fa_tab, MTASK_LOCAL_LOAD,   &fa_local_load);
    machine_slot(fa_tab, MTASK_LOCAL_STORE,  &fa_local_store);
    machine_slot(fa_tab, MTASK_GLOBAL_LOAD,  &fa_global_load);
    machine_slot(fa_tab, MTASK_GLOBAL_STORE, &fa_global_store);
    machine_slot(fa_tab, MTASK_CALL,         &fa_call);
    machine_slot(fa_tab, MTASK_CALLP,        &fa_callp);
    machine_slot(fa_tab, MTASK_RET,          &fa_ret);
    machine_slot(fa_tab, MTASK_JZ,           &fa_jz);
    machine_slot(fa_tab, MTASK_JNZ,          &fa_jnz);
    machine_slot(fa_tab, MTASK_INS_SIZE,     &fa_ins_size);
    machine_slot(fa_tab, MTASK_ENCODE,       &fa_encode);
    machine_slot(fa_tab, MTASK_DUMP,         &fa_dump);
    machine_slot(fa_tab, MTASK_RELOC_KIND,   &fa_reloc_kind);
    machine("arm64", fa_tab);                     // shadows the bundled one (D5)
}
