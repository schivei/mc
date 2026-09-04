// avx.mc — ONE AVX instruction, named by its encoding, applied to two values the
// register allocator placed. The third generality proof of M24
// (docs/specs/M24.md § Generality), and the one that answers "a new hardware
// instruction on a specific CPU" rather than "a new number format".
//
// Nothing in `src/` knows any of this. What it uses is the same eight
// mechanisms:
//
//   type_new("v8f32", 32, 32, TK_OPAQUE)   thirty-two byte globals, array
//                                          elements and frame slots, from the
//                                          width alone
//   intrinsic("vaddps", 2, ...)            the instruction, by name, with its
//                                          operands already lowered to depths
//   val_reg / dst_reg / dst_done           where the allocator put them --
//                                          contract version 3's published trio
//   machine_tab / machine_slot             a derived x86-64 machine that encodes,
//                                          sizes and dumps the new opcodes
//
// **Why this needs `intrinsic` and `#opcode` will not do it**: `#opcode` folds
// its arguments to constants and names fixed registers, so an operand would have
// to HAPPEN to sit in one, inside a whole leaf function; and `emit()` is exactly
// 32 bits, while `vaddps ymm, ymm, ymm` is five bytes in its VEX3 form. A
// module's own machine has no such limit -- x86_put already writes one to ten
// bytes -- which is the whole of docs/specs/M24.md's "M7 reaches them; only
// emit()/#opcode from a source file stay 4-byte-bound".
//
// Register plan: v8f32 depths 0..5 in ymm0..ymm5, spilled from 6 into 32-byte
// frame slots. The frame is 16-byte aligned (src/gen_walk.mc), so a 32-byte
// aligned spill is unreachable and the machine uses the UNALIGNED move --
// which is what it would use anyway.
//
// x86-64 only, and it says so: there is no CPU-feature model in `mc` and there
// should not be one. A program built with this module runs on a machine with
// AVX and nowhere else.

i64 ty_v8f32 = 0;

#define AV_BASE   240
#define AV_ADDPS  240                 // vaddps ymm, ymm, ymm     VEX.256.0F.WIG 58 /r
#define AV_MULPS  241                 // vmulps                   ...             59 /r
#define AV_LOADU  242                 // vmovups ymm, [r]         VEX.256.0F.WIG 10 /r
#define AV_STOREU 243                 // vmovups [r], ymm         ...             11 /r
#define AV_MAXOP  244

i64  av_opc[]  = { 0x58, 0x59, 0x10, 0x11 };
uptr av_name[] = { "vaddps", "vmulps", "vmovups", "vmovups" };
i64  av_mem[]  = { 0, 0, 1, 2 };      // 0 = three registers, 1 = load, 2 = store

i64  av_opc_at(i64 i)  { return ld64(av_opc + i * 8); }
uptr av_name_at(i64 i) { return ld64(av_name + i * 8); }
i64  av_mem_at(i64 i)  { return ld64(av_mem + i * 8); }

#define AV_REG_MAX 5                  // ymm0..ymm5 carry depths 0..5
#define AV_S1      6                  // ymm6, ymm7: spill scratch
#define AV_S2      7

uptr av_tab;
uptr av_orig;
i64  av_slot[MAXDEPTH];

uptr av_of(i64 task) { return ld64(av_orig + task * 8); }

i64  av_slot_at(i64 d)            { return ld64(av_slot + d * 8); }
void set_av_slot_at(i64 d, i64 v) { st64(av_slot + d * 8, v); }

i64 av_is(i64 t) { return t == ty_v8f32; }

i64 av_depth(i64 d) {
    if (av_slot_at(d) == 0) set_av_slot_at(d, slot_new(32));
    return av_slot_at(d);
}

i64 av_in_reg(i64 d) { return d <= AV_REG_MAX; }

i64 av_val_reg(i64 d, i64 scratch) {
    if (av_in_reg(d)) return d;
    em(AV_LOADU, scratch, XR_RBP, 0 - av_depth(d));
    return scratch;
}

i64 av_dst_reg(i64 d) {
    if (av_in_reg(d)) return d;
    return AV_S1;
}

void av_dst_done(i64 d, i64 rd) {
    if (!av_in_reg(d)) em(AV_STOREU, rd, XR_RBP, 0 - av_depth(d));
}

// ---- the VEX prefix ----
// Two bytes when nothing outside the low eight registers is named and the map is
// 0F with W = 0, three otherwise. llvm-mc picks the same rule, which is what
// makes the re-assembly sweep in examples/avx/test.sh an equality and not an
// approximation.
//
//   C5 [ ~R vvvv~ L pp ]
//   C4 [ ~R ~X ~B mmmmm ] [ W vvvv~ L pp ]
//
// L = 1 (256-bit), pp = 0 (no mandatory prefix), mmmmm = 1 (the 0F map).
void av_vex(uptr o, i64 reg, i64 rm, i64 vvvv) {
    i64 r = 0;
    if (reg >= 8) r = 1;
    i64 b = 0;
    if (rm >= 8) b = 1;
    if (!r && !b) {
        buf_u8(o, 0xc5);
        buf_u8(o, ((1 - r) << 7) | (((~vvvv) & 0xf) << 3) | 4);
        return;
    }
    buf_u8(o, 0xc4);
    buf_u8(o, ((1 - r) << 7) | (1 << 6) | ((1 - b) << 5) | 1);
    buf_u8(o, (((~vvvv) & 0xf) << 3) | 4);
}

void av_put(uptr e, i64 pc, uptr lab, uptr o) {
    i64 op = ins_op(e);
    if (op < AV_BASE) { callp(av_of(MTASK_ENCODE), e, pc, lab, o); return; }
    i64 i = op - AV_BASE;
    i64 kind = av_mem_at(i);
    if (kind == 0) {                              // vaddps rd, rn, rm
        av_vex(o, ins_rd(e), ins_rm(e), ins_rn(e));
        buf_u8(o, av_opc_at(i));
        x86_modrm_rr(o, ins_rd(e), ins_rm(e));
        return;
    }
    av_vex(o, ins_rd(e), ins_rn(e), 0);           // vvvv unused: 1111 after the ~
    buf_u8(o, av_opc_at(i));
    x86_modrm_m(o, ins_rd(e), ins_rn(e), ins_imm(e));
}

i64 av_ins_size(uptr e) {
    if (ins_op(e) < AV_BASE) return callp(av_of(MTASK_INS_SIZE), e);
    set_buf_len(x86_tmp, 0);
    av_put(e, 0, 0, x86_tmp);
    return buf_len(x86_tmp);
}

i64 av_reloc_kind(uptr e) {
    if (ins_op(e) >= AV_BASE) return 0 - 1;
    return callp(av_of(MTASK_RELOC_KIND), e);
}

void av_dump(uptr in) {
    i64 op = ins_op(in);
    if (op < AV_BASE) { callp(av_of(MTASK_DUMP), in); return; }
    i64 i = op - AV_BASE;
    i64 kind = av_mem_at(i);
    out_str(1, "  ");
    out_str(1, av_name_at(i));
    out_str(1, " ");
    if (kind == 2) {
        out_str(1, "ymmword ptr [r"); out_num(1, ins_rn(in));
        if (ins_imm(in)) { out_str(1, " + "); out_num(1, ins_imm(in)); }
        out_str(1, "], ymm"); out_num(1, ins_rd(in)); out_str(1, "\n");
        return;
    }
    out_str(1, "ymm"); out_num(1, ins_rd(in));
    if (kind == 1) {
        out_str(1, ", ymmword ptr [r"); out_num(1, ins_rn(in));
        if (ins_imm(in)) { out_str(1, " + "); out_num(1, ins_imm(in)); }
        out_str(1, "]\n");
        return;
    }
    out_str(1, ", ymm"); out_num(1, ins_rn(in));
    out_str(1, ", ymm"); out_num(1, ins_rm(in));
    out_str(1, "\n");
}

// ---- the tasks ----
void av_prologue() {
    i64 d = 0;
    loop {
        if (d >= MAXDEPTH) break;
        set_av_slot_at(d, 0);
        d = d + 1;
    }
    callp(av_of(MTASK_PROLOGUE));
}

void av_local_load(i64 ty, i64 d, i64 off) {
    if (!av_is(ty)) { callp(av_of(MTASK_LOCAL_LOAD), ty, d, off); return; }
    i64 rd = av_dst_reg(d);
    em(AV_LOADU, rd, XR_RBP, 0 - off);
    av_dst_done(d, rd);
}

void av_local_store(i64 ty, i64 d, i64 off) {
    if (!av_is(ty)) { callp(av_of(MTASK_LOCAL_STORE), ty, d, off); return; }
    em(AV_STOREU, av_val_reg(d, AV_S1), XR_RBP, 0 - off);
}

void av_global_load(i64 ty, i64 d, i64 sym) {
    if (!av_is(ty)) { callp(av_of(MTASK_GLOBAL_LOAD), ty, d, sym); return; }
    ins_add(X_LEARIP, XR_RAX, 0, 0, 0, 0, sym);
    i64 rd = av_dst_reg(d);
    em(AV_LOADU, rd, XR_RAX, 0);
    av_dst_done(d, rd);
}

void av_global_store(i64 ty, i64 d, i64 sym) {
    if (!av_is(ty)) { callp(av_of(MTASK_GLOBAL_STORE), ty, d, sym); return; }
    i64 r = av_val_reg(d, AV_S1);
    ins_add(X_LEARIP, XR_RAX, 0, 0, 0, 0, sym);
    em(AV_STOREU, r, XR_RAX, 0);
}

// ---- the intrinsics ----
void av_i_addps(i64 d, i64 na)  { av_bin(d, AV_ADDPS); }
void av_i_mulps(i64 d, i64 na)  { av_bin(d, AV_MULPS); }

void av_bin(i64 d, i64 op) {
    i64 rl = av_val_reg(d, AV_S1);
    i64 rr = av_val_reg(d + 1, AV_S2);
    i64 rd = av_dst_reg(d);
    ins_add(op, rd, rl, rr, 0, 0, 0);
    av_dst_done(d, rd);
}

void av_i_loadu(i64 d, i64 na) {                  // vloadu(p): p is an integer depth
    i64 rn = x86_val_reg(d, XREG_S1);
    i64 rd = av_dst_reg(d);
    em(AV_LOADU, rd, rn, 0);
    av_dst_done(d, rd);
}

void av_i_storeu(i64 d, i64 na) {                 // vstoreu(p, v)
    i64 rv = av_val_reg(d + 1, AV_S1);
    i64 rn = x86_val_reg(d, XREG_S1);
    em(AV_STOREU, rv, rn, 0);
}

void avx_init() {
    ty_v8f32 = type_new("v8f32", 32, 32, TK_OPAQUE);
    intrinsic("vaddps",  2, ty_v8f32, &av_i_addps);
    intrinsic("vmulps",  2, ty_v8f32, &av_i_mulps);
    intrinsic("vloadu",  1, ty_v8f32, &av_i_loadu);
    intrinsic("vstoreu", 2, TY_VOID,  &av_i_storeu);
    av_tab  = xalloc(MTASK_COUNT * 8);
    av_orig = xalloc(MTASK_COUNT * 8);
    uptr src = machine_tab("x86_64");
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(av_tab  + t * 8, ld64(src + t * 8));
        st64(av_orig + t * 8, ld64(src + t * 8));
        t = t + 1;
    }
    machine_slot(av_tab, MTASK_PROLOGUE,     &av_prologue);
    machine_slot(av_tab, MTASK_LOCAL_LOAD,   &av_local_load);
    machine_slot(av_tab, MTASK_LOCAL_STORE,  &av_local_store);
    machine_slot(av_tab, MTASK_GLOBAL_LOAD,  &av_global_load);
    machine_slot(av_tab, MTASK_GLOBAL_STORE, &av_global_store);
    machine_slot(av_tab, MTASK_INS_SIZE,     &av_ins_size);
    machine_slot(av_tab, MTASK_ENCODE,       &av_put);
    machine_slot(av_tab, MTASK_DUMP,         &av_dump);
    machine_slot(av_tab, MTASK_RELOC_KIND,   &av_reloc_kind);
    machine("x86_64", av_tab);
}
