// f16.mc — half precision taught to `mc` from outside the compiler.
//
// The third generality proof of M24, and the one that is almost free: it needs
// no core line that `<float>` did not already need, and the only thing it adds
// to `<float>`'s machine is what the hardware itself adds -- two `fcvt`s and a
// 16-bit load and store.
//
//   type_new("f16", 2, 2, TK_FLOAT)
//
// The WIDTH is what does the work. It drives glob_place (a global array of eight
// occupies sixteen bytes), the array-bounds arithmetic, and -- through M5 --
// a two-byte frame slot; `MTASK_LOCAL_LOAD` and `MTASK_GLOBAL_LOAD` already
// carry `ty`, so `ldr h` / `str h` needed no task of their own.
//
// f16 is a STORAGE type here, deliberately: AArch64 can add two halves directly
// (FEAT_FP16), most targets cannot, and a module that promised `h1 + h2`
// everywhere would be promising a CPU-feature model this compiler does not have
// and should not grow. Arithmetic goes through f32:
//
//   f32 s = f16_to_f32(h);   ...;   h = f32_to_f16(s);
//
// Those two are `intrinsic` registrations, one instruction each on AArch64. On
// any other machine they are NOT registered, and the identically-named ordinary
// functions in <f16_rt> are called instead -- which works because an intrinsic
// shadows a function of the same name and nothing else does
// (docs/reference/hooks.md § intrinsic). The same source compiles either way.
//
// Depends on <float> being loaded first: f32 is where a half goes to be
// arithmetic.

i64 ty_f16 = 0;

#define HI_BASE    160
#define HI_CVT_SH  160                // fcvt s, h
#define HI_CVT_HS  161                // fcvt h, s
#define HI_LDR_H   162
#define HI_STR_H   163

u32 hi_base[] = { 0x1EE24000, 0x1E23C000, 0x7D400000, 0x7D000000 };
uptr hi_name[] = { "fcvt", "fcvt", "ldr", "str" };
i64  hi_mem[]  = { 0, 0, 1, 1 };

i64  hi_base_at(i64 i) { return ld32(hi_base + i * 4); }
uptr hi_name_at(i64 i) { return ld64(hi_name + i * 8); }
i64  hi_mem_at(i64 i)  { return ld64(hi_mem + i * 8); }

uptr hi_tab;
uptr hi_orig;

uptr hi_of(i64 task) { return ld64(hi_orig + task * 8); }

i64 hi_is(i64 t) { return t == ty_f16; }

void hi_local_load(i64 ty, i64 d, i64 off) {
    if (!hi_is(ty)) { callp(hi_of(MTASK_LOCAL_LOAD), ty, d, off); return; }
    i64 rd = fa_dst_reg(d);
    em(HI_LDR_H, rd, REG_FRAME, 0 - off);
    fa_dst_done(d, rd);
}

void hi_local_store(i64 ty, i64 d, i64 off) {
    if (!hi_is(ty)) { callp(hi_of(MTASK_LOCAL_STORE), ty, d, off); return; }
    em(HI_STR_H, fa_val_reg(d, FREG_S1), REG_FRAME, 0 - off);
}

void hi_global_load(i64 ty, i64 d, i64 sym) {
    if (!hi_is(ty)) { callp(hi_of(MTASK_GLOBAL_LOAD), ty, d, sym); return; }
    gen_gaddr(REG_S1, sym);
    i64 rd = fa_dst_reg(d);
    em(HI_LDR_H, rd, REG_S1, 0);
    fa_dst_done(d, rd);
}

void hi_global_store(i64 ty, i64 d, i64 sym) {
    if (!hi_is(ty)) { callp(hi_of(MTASK_GLOBAL_STORE), ty, d, sym); return; }
    i64 r = fa_val_reg(d, FREG_S2);
    gen_gaddr(REG_S1, sym);
    em(HI_STR_H, r, REG_S1, 0);
}

// `fcvt s, h` rounds nothing (every half is exactly a single) and `fcvt h, s`
// rounds to NEAREST, TIES TO EVEN -- which is the case tests/f16 pins down.
void hi_to_f32(i64 d, i64 na) {
    i64 r = fa_val_reg(d, FREG_S1);
    i64 rd = fa_dst_reg(d);
    e2(HI_CVT_SH, rd, r);
    fa_dst_done(d, rd);
}

void hi_from_f32(i64 d, i64 na) {
    i64 r = fa_val_reg(d, FREG_S1);
    i64 rd = fa_dst_reg(d);
    e2(HI_CVT_HS, rd, r);
    fa_dst_done(d, rd);
}

// the two accessors, so a half can be read out of and written into memory the
// way <float>'s ldf32/stf32 do
void hi_ldf(i64 d, i64 na) {
    i64 rn = val_reg(d, REG_S1);
    i64 rd = fa_dst_reg(d);
    em(HI_LDR_H, rd, rn, 0);
    fa_dst_done(d, rd);
}

void hi_stf(i64 d, i64 na) {
    i64 rn = val_reg(d, REG_S1);
    i64 rv = fa_val_reg(d + 1, FREG_S1);
    em(HI_STR_H, rv, rn, 0);
}

i64 hi_ins_size(uptr e) {
    if (ins_op(e) >= HI_BASE && ins_op(e) < HI_BASE + 4) return 4;
    return callp(hi_of(MTASK_INS_SIZE), e);
}

i64 hi_reloc_kind(uptr e) {
    if (ins_op(e) >= HI_BASE && ins_op(e) < HI_BASE + 4) return 0 - 1;
    return callp(hi_of(MTASK_RELOC_KIND), e);
}

void hi_encode(uptr e, i64 pc, uptr lab, uptr b) {
    i64 op = ins_op(e);
    if (op < HI_BASE || op >= HI_BASE + 4) { callp(hi_of(MTASK_ENCODE), e, pc, lab, b); return; }
    i64 i = op - HI_BASE;
    i64 w = hi_base_at(i);
    if (hi_mem_at(i)) {
        if (ins_imm(e) < 0 || ins_imm(e) % 2 != 0 || ins_imm(e) / 2 > 4095)
            die("f16 memory offset out of range");
        buf_u32(b, w | ((ins_imm(e) / 2) << 10) | (ins_rn(e) << 5) | ins_rd(e));
        return;
    }
    buf_u32(b, w | (ins_rn(e) << 5) | ins_rd(e));
}

void hi_dump(uptr in) {
    i64 op = ins_op(in);
    if (op < HI_BASE || op >= HI_BASE + 4) { callp(hi_of(MTASK_DUMP), in); return; }
    i64 i = op - HI_BASE;
    out_str(1, "  ");
    out_str(1, hi_name_at(i));
    out_str(1, " ");
    if (hi_mem_at(i)) {
        out_str(1, "h"); out_num(1, ins_rd(in));
        out_str(1, ", [");
        fa_dreg(FR_X, ins_rn(in));               // prints `sp` for x31, as the core does
        if (ins_imm(in)) { out_str(1, ", #"); out_num(1, ins_imm(in)); }
        out_str(1, "]\n");
        return;
    }
    if (i == 0) { out_str(1, "s"); out_num(1, ins_rd(in)); out_str(1, ", h"); }
    else        { out_str(1, "h"); out_num(1, ins_rd(in)); out_str(1, ", s"); }
    out_num(1, ins_rn(in));
    out_str(1, "\n");
}

// Registered on top of whatever machine is named `arm64` at this point -- which,
// with <float> loaded first, is <float>'s. Composition is by DERIVATION and it
// is ordered: risk 4 of docs/specs/M24.md says machine registration is
// last-wins, so a module that stacks on another one copies it rather than the
// bundled table, and says which one it needs.
void f16_init() {
    ty_f16 = type_new("f16", 2, 2, TK_FLOAT);
    hi_tab  = xalloc(MTASK_COUNT * 8);
    hi_orig = xalloc(MTASK_COUNT * 8);
    uptr src = machine_tab("arm64");
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(hi_tab  + t * 8, ld64(src + t * 8));
        st64(hi_orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(hi_tab, MTASK_LOCAL_LOAD,   &hi_local_load);
    machine_slot(hi_tab, MTASK_LOCAL_STORE,  &hi_local_store);
    machine_slot(hi_tab, MTASK_GLOBAL_LOAD,  &hi_global_load);
    machine_slot(hi_tab, MTASK_GLOBAL_STORE, &hi_global_store);
    machine_slot(hi_tab, MTASK_INS_SIZE,     &hi_ins_size);
    machine_slot(hi_tab, MTASK_ENCODE,       &hi_encode);
    machine_slot(hi_tab, MTASK_DUMP,         &hi_dump);
    machine_slot(hi_tab, MTASK_RELOC_KIND,   &hi_reloc_kind);
    machine("arm64", hi_tab);
    intrinsic("f16_to_f32", 1, ty_f32, &hi_to_f32);
    intrinsic("f32_to_f16", 1, ty_f16, &hi_from_f32);
    intrinsic("ldf16", 1, ty_f16, &hi_ldf);
    intrinsic("stf16", 2, TY_VOID, &hi_stf);
}
