// i128.mc — a 128-bit integer taught to `mc` from outside the compiler.
//
// It exists to prove the SECOND half of M24's generality claim: `<float>` could
// have been special-cased, a 16-byte integer cannot. Nothing in `src/` was
// touched for it -- `git diff src/` between this module's commit and the one
// before it is empty -- and the mechanisms it uses are the same eight:
//
//   type_new("i128", 16, 16, TK_WIDE)   the width is what gives it a 16-byte
//                                       frame slot (M5), a 16-byte global and a
//                                       16-byte array element
//   syntax_lit                          `123i` is read here; a 128-bit value does
//                                       not fit in MTASK_CONST's i64, so the
//                                       literal becomes a module-private GLOBAL
//                                       whose initializer is an N_BLOB, and the
//                                       node returned is a load from it
//   walk_depth_type                     what tells the machine a depth is wide
//   machine_tab / machine_slot          the derived machine below
//
// **The value lives in ONE depth, backed by a 16-byte slot.** A value spanning
// two depths would collide with gen_binary's `depth + 1` and gen_call's
// `depth + i` -- it would change the walker's own arithmetic, which is what
// MTASK_DEPTH_SPAN would be for and why docs/specs/M24.md defers it. Memory
// residency is the price, and carry survives it: `ldr`/`str` do not touch NZCV.
//
// AArch64 only. A second instruction set is a second derived machine and no
// change here; the module says what it was built for rather than pretending to
// a CPU-feature model the compiler does not have.

i64 ty_i128 = 0;

#define IW_LO 0                       // the two halves, little-endian in memory
#define IW_HI 8

uptr iw_tab;
uptr iw_orig;
i64  iw_ngrn = 0;                     // AAPCS64 counters, per function
i64  iw_pstk = 0;
i64  iw_slot[MAXDEPTH];               // the 16-byte slot of each wide depth
i64  iw_nlit = 0;                     // module-private literal globals, numbered

uptr iw_of(i64 task) { return ld64(iw_orig + task * 8); }

i64  iw_slot_at(i64 d)          { return ld64(iw_slot + d * 8); }
void set_iw_slot_at(i64 d, i64 v) { st64(iw_slot + d * 8, v); }

i64 iw_is(i64 t) { return t == ty_i128; }

// the frame slot a wide depth lives in, asked for once per function
i64 iw_depth(i64 d) {
    if (iw_slot_at(d) == 0) set_iw_slot_at(d, slot_new(16));
    return iw_slot_at(d);
}

// load one half of a wide depth into an integer register
i64 iw_half(i64 d, i64 half, i64 reg) {
    em(I_LDR, reg, REG_FRAME, 0 - iw_depth(d) + half);
    return reg;
}

void iw_put(i64 d, i64 half, i64 reg) {
    em(I_STR, reg, REG_FRAME, 0 - iw_depth(d) + half);
}

// ---- the literal: `<digits>i`, up to 2^128 - 1 ----
// The bytes go into a module-private global, because MTASK_CONST carries one
// i64 and an N_INT's val is one i64. The initializer is an N_BLOB (M21.5), the
// one node kind that puts arbitrary bytes into a section -- glob_place writes
// width 1/2/4 and otherwise buf_u64, so a 16-byte element could not be one
// N_INT even if the value fitted.
u64 iw_dig[40];                       // the decimal digits, most significant first
u8  iw_bytes[16];

i64 iw_isdig(i64 c) { return c >= '0' && c <= '9'; }

// lo and hi of the decimal string, by repeated multiply-add in 32-bit limbs
u64 iw_l0 = 0;
u64 iw_l1 = 0;
u64 iw_l2 = 0;
u64 iw_l3 = 0;

void iw_reset() { iw_l0 = 0; iw_l1 = 0; iw_l2 = 0; iw_l3 = 0; }

void iw_muladd(u64 m, u64 add) {      // value = value * m + add, 128 bits
    u64 c = add;
    u64 p = iw_l0 * m + c;  iw_l0 = p & 0xffffffff;  c = p >> 32;
    p = iw_l1 * m + c;      iw_l1 = p & 0xffffffff;  c = p >> 32;
    p = iw_l2 * m + c;      iw_l2 = p & 0xffffffff;  c = p >> 32;
    p = iw_l3 * m + c;      iw_l3 = p & 0xffffffff;
}

i64 iw_lit() {
    uptr s = p_start();
    uptr e = p_src_end();
    if (s >= e || !iw_isdig(ld8(s))) return 0;
    uptr q = s;
    iw_reset();
    loop {
        if (q >= e || !iw_isdig(ld8(q))) break;
        iw_muladd(10, ld8(q) - '0');
        q = q + 1;
    }
    if (q >= e || ld8(q) != 'i') return 0;        // `123i` and nothing else
    if (q + 1 < e && (is_alnum(ld8(q + 1)))) return 0;
    i64 line = p_line();
    uptr fl = p_file();
    q = q + 1;
    p_take_lit(q);

    u64 lo = iw_l0 | (iw_l1 << 32);
    u64 hi = iw_l2 | (iw_l3 << 32);
    uptr b = xalloc(16);
    i64 i = 0;
    loop {                                        // little-endian, byte by byte
        if (i >= 8) break;
        st8(b + i, (lo >> (i * 8)) & 0xff);
        st8(b + 8 + i, (hi >> (i * 8)) & 0xff);
        i = i + 1;
    }
    // one global per literal, with an N_BLOB initializer. The name carries `$`,
    // which the lexer never forms into an identifier, so it cannot collide with
    // anything the program wrote (the M10 gensym argument).
    u8 nb[24];
    i64 nn = 0;
    i64 v = iw_nlit;
    iw_nlit = iw_nlit + 1;
    loop {
        st8(nb + nn, '0' + v % 10);
        v = v / 10;
        nn = nn + 1;
        if (v == 0) break;
    }
    uptr name = xalloc(8 + nn);
    mem_copy(name, "$i128_", 6);
    i64 k = 0;
    loop {
        if (k >= nn) break;
        st8(name + 6 + k, ld8(nb + nn - 1 - k));
        k = k + 1;
    }
    i64 blob = node_new(N_BLOB, line, fl);
    set_nd_name(blob, b);
    set_nd_val(blob, 16);
    i64 g = node_new(N_GLOBAL, line, fl);
    set_nd_type(g, ty_i128);
    set_nd_name(g, name);
    set_nd_val(g, 0);
    set_nd_a(g, blob);
    top_add(g);
    i64 id = node_new(N_IDENT, line, fl);         // the expression is the global
    set_nd_name(id, name);
    set_nd_type(id, ty_i128);
    p_next();
    return id;
}

// ---- the derived machine ----
// Nine slots replaced; everything else delegates. New opcodes above every I_*
// the bundled machine uses, with their own encoder, sizer and dump, so
// `--dump-asm` shows `adds`/`adc` and not a raw word.
#define WI_BASE   200
#define WI_ADDS   200
#define WI_ADC    201
#define WI_SUBS   202
#define WI_SBC    203
#define WI_SBCS   204
#define WI_UMULH  205
#define WI_ASR63  206
#define WI_CMPZ   207                 // subs xzr, rn, rm  -- the low half of a compare
#define WI_SBCZ   208                 // sbcs xzr, rn, rm  -- and the high half
#define WI_MAXOP  209

u32 wi_base[] = { 0xAB000000, 0x9A000000, 0xEB000000, 0xDA000000, 0xFA000000,
                  0x9BC07C00, 0x937FFC00, 0xEB00001F, 0xFA00001F };
uptr wi_name[] = { "adds", "adc", "subs", "sbc", "sbcs", "umulh", "asr", "subs", "sbcs" };
i64  wi_ops[]  = { 3, 3, 3, 3, 3, 3, 2, 9, 9 };   // operands: 3, 2, or 9 = xzr form

i64  wi_base_at(i64 i) { return ld32(wi_base + i * 4); }
uptr wi_name_at(i64 i) { return ld64(wi_name + i * 8); }
i64  wi_ops_at(i64 i)  { return ld64(wi_ops + i * 8); }

void wi_prologue() {
    i64 d = 0;
    loop {
        if (d >= MAXDEPTH) break;
        set_iw_slot_at(d, 0);
        d = d + 1;
    }
    iw_ngrn = 0;
    iw_pstk = 0;
    callp(iw_of(MTASK_PROLOGUE));
}

// a + b and a - b: two halves, and the carry survives the loads and stores
// between them because ldr/str do not touch NZCV
void wi_addsub(i64 d, i64 d2, i64 first, i64 second) {
    iw_half(d, IW_LO, REG_S1);
    iw_half(d2, IW_LO, REG_S2);
    e3(first, REG_TMP, REG_S1, REG_S2);
    iw_half(d, IW_HI, REG_S1);
    iw_half(d2, IW_HI, REG_S2);
    e3(second, REG_S1, REG_S1, REG_S2);
    iw_put(d, IW_HI, REG_S1);
    iw_put(d, IW_LO, REG_TMP);
}

// (hi:lo) = (hi1:lo1) * (hi2:lo2), the school product with the top half dropped:
// lo = lo1*lo2, hi = umulh(lo1,lo2) + lo1*hi2 + hi1*lo2. Every load happens
// before the two stores, so an in-place multiply cannot read what it wrote.
void wi_mul(i64 d, i64 d2) {
    iw_half(d, IW_LO, REG_S1);
    iw_half(d2, IW_LO, REG_S2);
    e3(WI_UMULH, REG_TMP, REG_S1, REG_S2);
    iw_half(d, IW_LO, REG_S1);
    iw_half(d2, IW_HI, REG_S2);
    e3(I_MUL, REG_S1, REG_S1, REG_S2);
    e3(I_ADD, REG_TMP, REG_TMP, REG_S1);
    iw_half(d, IW_HI, REG_S1);
    iw_half(d2, IW_LO, REG_S2);
    e3(I_MUL, REG_S1, REG_S1, REG_S2);
    e3(I_ADD, REG_TMP, REG_TMP, REG_S1);
    iw_half(d, IW_LO, REG_S1);
    iw_half(d2, IW_LO, REG_S2);
    e3(I_MUL, REG_S1, REG_S1, REG_S2);
    iw_put(d, IW_HI, REG_TMP);
    iw_put(d, IW_LO, REG_S1);
}

void wi_bin(i64 op, i64 d, i64 d2) {
    if (!iw_is(walk_depth_type(d))) { callp(iw_of(MTASK_BIN), op, d, d2); return; }
    if (op == MOP_ADD) { wi_addsub(d, d2, WI_ADDS, WI_ADC); return; }
    if (op == MOP_SUB) { wi_addsub(d, d2, WI_SUBS, WI_SBC); return; }
    if (op == MOP_MUL) { wi_mul(d, d2); return; }
    die("i128: only + - * are taught (docs/specs/M24.md defers the rest)");
}

// `subs` on the low halves and `sbcs` on the high ones leaves N and V exactly as
// a 128-bit subtraction would, so `lt` and `ge` read straight off the flags.
// Z does NOT: it only reflects the high half, so equality is computed
// separately -- (lo1 ^ lo2) | (hi1 ^ hi2) -- and `>` and `<=` are built from the
// two, `gt = ge && !eq` and `le = lt || eq`. That is the one place a 128-bit
// compare is not just "the 64-bit one twice", and getting it wrong is a wrong
// ANSWER rather than a diagnostic.
//
// x8 carries the equality flag across the subs/sbcs pair: nothing between them
// writes it, and neither `ldr` nor `str` touches NZCV.
void wi_eqflag(i64 d, i64 d2, i64 cc) {
    iw_half(d, IW_LO, REG_S1);
    iw_half(d2, IW_LO, REG_S2);
    e3(I_EOR, REG_S1, REG_S1, REG_S2);
    iw_half(d, IW_HI, REG_TMP);
    iw_half(d2, IW_HI, REG_S2);
    e3(I_EOR, REG_S2, REG_TMP, REG_S2);
    e3(I_ORR, REG_S1, REG_S1, REG_S2);
    ei(I_CMPI, 0, REG_S1, 0);
    ins_add(I_CSET, REG_TMP, 0, 0, cc, 0, 0);
}

void wi_cmp(i64 cond, i64 d, i64 d2) {
    if (!iw_is(walk_depth_type(d))) { callp(iw_of(MTASK_CMP), cond, d, d2); return; }
    if (cond == MCOND_EQ || cond == MCOND_NE) {
        i64 c = C_EQ;
        if (cond == MCOND_NE) c = C_NE;
        wi_eqflag(d, d2, c);
        i64 rd = dst_reg(d);
        e2(I_MOV, rd, REG_TMP);
        dst_done(d, rd);
        return;
    }
    // `>` needs "not equal" and `<=` needs "equal", both computed BEFORE the
    // subtraction that sets the flags they are combined with
    i64 need = 0;
    if (cond == MCOND_GT) { wi_eqflag(d, d2, C_NE); need = 1; }
    if (cond == MCOND_LE) { wi_eqflag(d, d2, C_EQ); need = 2; }
    iw_half(d, IW_LO, REG_S1);
    iw_half(d2, IW_LO, REG_S2);
    e3(WI_CMPZ, 0, REG_S1, REG_S2);
    iw_half(d, IW_HI, REG_S1);
    iw_half(d2, IW_HI, REG_S2);
    e3(WI_SBCZ, 0, REG_S1, REG_S2);
    i64 base = cond;
    if (cond == MCOND_GT) base = MCOND_GE;        // gt = ge && !eq
    if (cond == MCOND_LE) base = MCOND_LT;        // le = lt || eq
    i64 rd = dst_reg(d);
    ins_add(I_CSET, rd, 0, 0, cond_arm_at(base), 0, 0);
    if (need == 1) e3(I_AND, rd, rd, REG_TMP);
    if (need == 2) e3(I_ORR, rd, rd, REG_TMP);
    dst_done(d, rd);
}

void wi_copy(i64 dst_off, i64 dst_base, i64 src_off, i64 src_base) {
    em(I_LDR, REG_S1, src_base, src_off);
    em(I_STR, REG_S1, dst_base, dst_off);
    em(I_LDR, REG_S1, src_base, src_off + 8);
    em(I_STR, REG_S1, dst_base, dst_off + 8);
}

void wi_local_load(i64 ty, i64 d, i64 off) {
    if (!iw_is(ty)) { callp(iw_of(MTASK_LOCAL_LOAD), ty, d, off); return; }
    wi_copy(0 - iw_depth(d), REG_FRAME, 0 - off, REG_FRAME);
}

void wi_local_store(i64 ty, i64 d, i64 off) {
    if (!iw_is(ty)) { callp(iw_of(MTASK_LOCAL_STORE), ty, d, off); return; }
    wi_copy(0 - off, REG_FRAME, 0 - iw_depth(d), REG_FRAME);
}

void wi_global_load(i64 ty, i64 d, i64 sym) {
    if (!iw_is(ty)) { callp(iw_of(MTASK_GLOBAL_LOAD), ty, d, sym); return; }
    gen_gaddr(REG_S2, sym);
    wi_copy(0 - iw_depth(d), REG_FRAME, 0, REG_S2);
}

void wi_global_store(i64 ty, i64 d, i64 sym) {
    if (!iw_is(ty)) { callp(iw_of(MTASK_GLOBAL_STORE), ty, d, sym); return; }
    gen_gaddr(REG_S2, sym);
    wi_copy(0, REG_S2, 0 - iw_depth(d), REG_FRAME);
}

// AAPCS64 passes a 16-byte integer in an EVEN-numbered register pair, which is
// the one rule a positional ABI would get wrong
void wi_param(i64 ty, i64 i, i64 off) {
    if (!iw_is(ty)) {
        if (iw_ngrn < REG_ARGS) {
            em(mem_op(ty, 1), iw_ngrn, REG_FRAME, 0 - off);
            iw_ngrn = iw_ngrn + 1;
            return;
        }
        em(I_LDR, REG_S1, REG_FP, 16 + iw_pstk * 8);
        em(mem_op(ty, 1), REG_S1, REG_FRAME, 0 - off);
        iw_pstk = iw_pstk + 1;
        return;
    }
    if (iw_ngrn % 2) iw_ngrn = iw_ngrn + 1;       // the even-pair rule
    if (iw_ngrn + 1 < REG_ARGS) {
        em(I_STR, iw_ngrn, REG_FRAME, 0 - off);
        em(I_STR, iw_ngrn + 1, REG_FRAME, 0 - off + 8);
        iw_ngrn = iw_ngrn + 2;
        return;
    }
    if (iw_pstk % 2) iw_pstk = iw_pstk + 1;
    em(I_LDR, REG_S1, REG_FP, 16 + iw_pstk * 8);
    em(I_STR, REG_S1, REG_FRAME, 0 - off);
    em(I_LDR, REG_S1, REG_FP, 16 + iw_pstk * 8 + 8);
    em(I_STR, REG_S1, REG_FRAME, 0 - off + 8);
    iw_pstk = iw_pstk + 2;
}

void wi_call(i64 d, i64 na, i64 sym) {
    i64 wide = 0;
    i64 i = 0;
    loop {
        if (i >= na) break;
        if (iw_is(walk_depth_type(d + i))) wide = 1;
        i = i + 1;
    }
    if (!wide && !iw_is(walk_ret_type())) { callp(iw_of(MTASK_CALL), d, na, sym); return; }
    save_live(d);
    i64 ngrn = 0;
    i = 0;
    loop {
        if (i >= na) break;
        if (iw_is(walk_depth_type(d + i))) {
            if (ngrn % 2) ngrn = ngrn + 1;
            if (ngrn + 1 >= REG_ARGS) die("i128: too many arguments for the register pairs");
            iw_half(d + i, IW_LO, ngrn);
            iw_half(d + i, IW_HI, ngrn + 1);
            ngrn = ngrn + 2;
        } else {
            if (ngrn >= REG_ARGS) die("i128: too many arguments");
            arg_to_reg(ngrn, d + i);
            ngrn = ngrn + 1;
        }
        i = i + 1;
    }
    ins_add(I_BL, 0, 0, 0, 0, 0, sym);
    restore_live(d);
    if (iw_is(walk_ret_type())) {                 // x0:x1 back into the depth's slot
        iw_put(d, IW_LO, 0);
        iw_put(d, IW_HI, 1);
        return;
    }
    i64 rd = dst_reg(d);
    e2(I_MOV, rd, 0);
    dst_done(d, rd);
}

void wi_ret(i64 d) {
    if (!iw_is(walk_depth_type(d))) { callp(iw_of(MTASK_RET), d); return; }
    iw_half(d, IW_LO, 0);
    iw_half(d, IW_HI, 1);
}

void wi_cast(i64 ty, i64 d) {
    i64 src = walk_depth_type(d);
    if (!iw_is(src) && !iw_is(ty)) { callp(iw_of(MTASK_CAST), ty, d); return; }
    if (src == ty) return;
    if (iw_is(src)) {                             // i128 -> integer: the low half
        i64 rd = dst_reg(d);
        em(I_LDR, rd, REG_FRAME, 0 - iw_depth(d));
        gen_cast(rd, ty);
        dst_done(d, rd);
        return;
    }
    i64 r = val_reg(d, REG_S1);                   // integer -> i128, sign-extended
    iw_put(d, IW_LO, r);
    if (src == TY_I64) e2(WI_ASR63, REG_S2, r);
    else               ei(I_MOVZ, REG_S2, 0, 0);
    iw_put(d, IW_HI, REG_S2);
}

// ---- the two readers, as intrinsics ----
void wi_lo(i64 d, i64 na) {
    i64 rd = dst_reg(d);
    em(I_LDR, rd, REG_FRAME, 0 - iw_depth(d));
    dst_done(d, rd);
}

void wi_hi(i64 d, i64 na) {
    i64 rd = dst_reg(d);
    em(I_LDR, rd, REG_FRAME, 0 - iw_depth(d) + 8);
    dst_done(d, rd);
}

// ---- encoding, sizing and the dump ----
i64 wi_ins_size(uptr e) {
    if (ins_op(e) >= WI_BASE) return 4;
    return callp(iw_of(MTASK_INS_SIZE), e);
}

i64 wi_reloc_kind(uptr e) {
    if (ins_op(e) >= WI_BASE) return 0 - 1;
    return callp(iw_of(MTASK_RELOC_KIND), e);
}

void wi_encode(uptr e, i64 pc, uptr lab, uptr b) {
    if (ins_op(e) < WI_BASE) { callp(iw_of(MTASK_ENCODE), e, pc, lab, b); return; }
    i64 i = ins_op(e) - WI_BASE;
    i64 w = wi_base_at(i);
    if (wi_ops_at(i) == 2) buf_u32(b, w | (ins_rn(e) << 5) | ins_rd(e));
    else if (wi_ops_at(i) == 9) buf_u32(b, w | (ins_rm(e) << 16) | (ins_rn(e) << 5));
    else buf_u32(b, w | (ins_rm(e) << 16) | (ins_rn(e) << 5) | ins_rd(e));
}

void wi_dump(uptr in) {
    if (ins_op(in) < WI_BASE) { callp(iw_of(MTASK_DUMP), in); return; }
    i64 i = ins_op(in) - WI_BASE;
    out_str(1, "  ");
    out_str(1, wi_name_at(i));
    out_str(1, " ");
    if (wi_ops_at(i) == 9) {
        out_str(1, "xzr, x"); out_num(1, ins_rn(in));
        out_str(1, ", x");    out_num(1, ins_rm(in));
        out_str(1, "\n");
        return;
    }
    out_str(1, "x"); out_num(1, ins_rd(in));
    out_str(1, ", x"); out_num(1, ins_rn(in));
    if (wi_ops_at(i) == 2) { out_str(1, ", #63\n"); return; }
    out_str(1, ", x"); out_num(1, ins_rm(in));
    out_str(1, "\n");
}

void i128_init() {
    ty_i128 = type_new("i128", 16, 16, TK_WIDE);
    syntax_lit(&iw_lit);
    intrinsic("i128_lo", 1, TY_U64, &wi_lo);
    intrinsic("i128_hi", 1, TY_U64, &wi_hi);
    iw_tab  = xalloc(MTASK_COUNT * 8);
    iw_orig = xalloc(MTASK_COUNT * 8);
    uptr src = machine_tab("arm64");
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(iw_tab  + t * 8, ld64(src + t * 8));
        st64(iw_orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(iw_tab, MTASK_PROLOGUE,     &wi_prologue);
    machine_slot(iw_tab, MTASK_PARAM,        &wi_param);
    machine_slot(iw_tab, MTASK_BIN,          &wi_bin);
    machine_slot(iw_tab, MTASK_CMP,          &wi_cmp);
    machine_slot(iw_tab, MTASK_CAST,         &wi_cast);
    machine_slot(iw_tab, MTASK_LOCAL_LOAD,   &wi_local_load);
    machine_slot(iw_tab, MTASK_LOCAL_STORE,  &wi_local_store);
    machine_slot(iw_tab, MTASK_GLOBAL_LOAD,  &wi_global_load);
    machine_slot(iw_tab, MTASK_GLOBAL_STORE, &wi_global_store);
    machine_slot(iw_tab, MTASK_CALL,         &wi_call);
    machine_slot(iw_tab, MTASK_RET,          &wi_ret);
    machine_slot(iw_tab, MTASK_INS_SIZE,     &wi_ins_size);
    machine_slot(iw_tab, MTASK_ENCODE,       &wi_encode);
    machine_slot(iw_tab, MTASK_DUMP,         &wi_dump);
    machine_slot(iw_tab, MTASK_RELOC_KIND,   &wi_reloc_kind);
    machine("arm64", iw_tab);
}
