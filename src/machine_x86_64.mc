// machine_x86_64.mc — the x86-64 machine, M17 step B (System V) and M20 (Win64).
// The task list, the register table and the verification are all in
// docs/reference/machine.md § The x86-64 implementation; what is here is the
// code, with only the reasons that are not obvious from it.
//
// It registers TWO machines, `x86_64` and `x86_64-win`, out of one set of
// functions: the calling convention lives in five places (the argument table,
// x86_param, x86_push_args, x86_reg_args and how much x86_call gives back) and
// nowhere else, so the Win64 table is the SysV table with MTASK_PROLOGUE
// replaced by the one that names the other ABI.
//
// It fills the same thirty-one slots src/machine_arm64.mc fills, so
// src/gen_walk.mc never learns a second instruction set. Four things differ
// from AArch64 and each one is marked below:
//
//   * depths 0..3 in r8..r11 and the rest spilled — those four are what is left
//     once the callee-saved half (rbx, r12..r15) and the argument registers are
//     off the table, for the same reason arm64 never writes x18..x28;
//   * three scratch registers, rax/rcx/rdx, because `idiv` writes rdx, `div`
//     needs it zeroed, and every shift takes its count in cl;
//   * locals at [rbp - off], correct from the first instruction, so
//     MTASK_FRAME_FIX only patches the prologue's `sub rsp`;
//   * one to ten bytes per instruction. x86_put is the ONE encoder: it writes
//     into the section buffer, and MTASK_INS_SIZE runs the same function over a
//     scratch buffer and returns the length. Size and encoding cannot disagree.
//
// Depends on gen_walk.mc (the Ins buffer, ins_add/e0/e2/ei/el/em, slot_new, the
// MTASK_/MOP_/MUN_/MCOND_ vocabulary and MAXDEPTH), on arena.mc (buf_*,
// out_str, out_num, die) and on macho.mc (sym_name, sym_at).

// ---- registers, by their x86 encoding number ----
#define XR_RAX 0
#define XR_RCX 1
#define XR_RDX 2
#define XR_RSP 4
#define XR_RBP 5
#define XR_RSI 6
#define XR_RDI 7

#define XREG_BASE 8                   // depths 0..3 in r8..r11
#define XREG_MAX  3
#define XREG_S1   XR_RAX              // spill scratch: left / destination
#define XREG_S2   XR_RCX              // spill scratch: right, and the shift count
#define XREG_TMP  XR_RDX              // the remainder of idiv/div

#define XC_E   4                      // condition codes: the low nibble of setcc/jcc
#define XC_NE  5

// relocation kinds this machine produces. They travel in the same Reloc record
// as the Mach-O ones, so their numbers only have to avoid R_UNSIGNED..R_ADDEND
// (0..4 and 10); src/backend_elf.mc maps them to R_X86_64_PC32 / PLT32.
#define R_X86_PC32   16
#define R_X86_PLT32  17

// ---- opcodes. 0 is I_LABEL and belongs to the walker, so these start at 1.
// The numbers overlap machine_arm64.mc's I_* on purpose: only one machine ever
// encodes an Ins buffer, and the two vocabularies never meet. ----
#define X_NOP      1                  // erased by the frame fixup, no bytes
#define X_PUSH     2                  // push rd
#define X_PUSHM    3                  // push [rn + imm]
#define X_LEAVE    4
#define X_RET      5
#define X_MOV      6                  // mov rd, rn             (64 bits)
#define X_MOV32    7                  // mov rd, rn             (32 bits, zero-extends)
#define X_MOVI     8                  // mov rd, imm
#define X_LEA      9                  // lea rd, [rn + imm]
#define X_LEARIP  10                  // lea rd, [rip + 0]      + reloc(sym)
#define X_ADD     11
#define X_SUB     12
#define X_AND     13
#define X_OR      14
#define X_XOR     15
#define X_IMUL    16
#define X_CQO     17                  // sign-extend rax into rdx:rax
#define X_ZEDX    18                  // xor edx, edx
#define X_IDIV    19                  // idiv rd
#define X_DIV     20                  // div rd
#define X_SHL     21                  // shl rd, cl
#define X_SHR     22
#define X_SAR     23
#define X_NEG     24
#define X_NOT     25
#define X_CMP     26                  // cmp rd, rn
#define X_TEST    27                  // test rd, rn
#define X_SETCC   28                  // setcc rd, imm = condition
#define X_MOVZXB  29                  // movzx rd, rn (byte)
#define X_MOVZXW  30                  // movzx rd, rn (word)
#define X_JMP     31
#define X_JCC     32                  // jcc label, imm = condition
#define X_CALL    33                  // call rel32             + reloc(sym)
#define X_CALLR   34                  // call rd
#define X_LD8     35
#define X_LD16    36
#define X_LD32    37
#define X_LD64    38
#define X_ST8     39
#define X_ST16    40
#define X_ST32    41
#define X_ST64    42
#define X_SPADD   43                  // add rsp, imm
#define X_SPSUB   44                  // sub rsp, imm
#define X_EMIT    45                  // one raw 32-bit word, little-endian
#define X_COUNT   46

// ---- how an opcode is encoded: the form decides which of five shapes, the
// other five columns fill it in. Everything not in a shape is XF_SPEC and has
// its own branch in x86_put. ----
#define XF_SPEC 0
#define XF_FIX  1                     // fixed bytes: opc, `dig` of them
#define XF_RS   2                     // opc /r, reg = rn (the source), rm = rd
#define XF_RD   3                     // opc /r, reg = rd, rm = rn
#define XF_RG   4                     // opc /r, reg = the `dig` extension, rm = rd
#define XF_LD   5                     // opc /r, reg = rd, memory [rn + imm]
#define XF_ST   6                     // the same bytes as XF_LD; only the dump differs
#define XF_MG   7                     // opc /r, reg = `dig`, memory [rn + imm]

#define XD_N 6                        // columns per opcode: form w opc dig pre rex

//                 form     w  opc     dig pre   rex
i64 x86_desc[] = {
    XF_SPEC,       0, 0,      0, 0,    0,        // 0  I_LABEL
    XF_SPEC,       0, 0,      0, 0,    0,        // 1  nop
    XF_SPEC,       0, 0,      0, 0,    0,        // 2  push r
    XF_MG,         0, 0xff,   6, 0,    0,        // 3  push [m]
    XF_FIX,        0, 0xc9,   1, 0,    0,        // 4  leave
    XF_FIX,        0, 0xc3,   1, 0,    0,        // 5  ret
    XF_RS,         1, 0x89,   0, 0,    0,        // 6  mov r, r
    XF_RS,         0, 0x89,   0, 0,    0,        // 7  mov rd, rd (32 bits)
    XF_SPEC,       0, 0,      0, 0,    0,        // 8  mov r, imm
    XF_LD,         1, 0x8d,   0, 0,    0,        // 9  lea
    XF_SPEC,       0, 0,      0, 0,    0,        // 10 lea [rip]
    XF_RS,         1, 0x01,   0, 0,    0,        // 11 add
    XF_RS,         1, 0x29,   0, 0,    0,        // 12 sub
    XF_RS,         1, 0x21,   0, 0,    0,        // 13 and
    XF_RS,         1, 0x09,   0, 0,    0,        // 14 or
    XF_RS,         1, 0x31,   0, 0,    0,        // 15 xor
    XF_RD,         1, 0x1af,  0, 0,    0,        // 16 imul
    XF_FIX,        0, 0x4899, 2, 0,    0,        // 17 cqo
    XF_FIX,        0, 0x31d2, 2, 0,    0,        // 18 xor edx, edx
    XF_RG,         1, 0xf7,   7, 0,    0,        // 19 idiv
    XF_RG,         1, 0xf7,   6, 0,    0,        // 20 div
    XF_RG,         1, 0xd3,   4, 0,    0,        // 21 shl by cl
    XF_RG,         1, 0xd3,   5, 0,    0,        // 22 shr by cl
    XF_RG,         1, 0xd3,   7, 0,    0,        // 23 sar by cl
    XF_RG,         1, 0xf7,   3, 0,    0,        // 24 neg
    XF_RG,         1, 0xf7,   2, 0,    0,        // 25 not
    XF_RS,         1, 0x39,   0, 0,    0,        // 26 cmp
    XF_RS,         1, 0x85,   0, 0,    0,        // 27 test
    XF_SPEC,       0, 0,      0, 0,    0,        // 28 setcc
    XF_RD,         1, 0x1b6,  0, 0,    0,        // 29 movzx r, r8
    XF_RD,         1, 0x1b7,  0, 0,    0,        // 30 movzx r, r16
    XF_SPEC,       0, 0,      0, 0,    0,        // 31 jmp
    XF_SPEC,       0, 0,      0, 0,    0,        // 32 jcc
    XF_SPEC,       0, 0,      0, 0,    0,        // 33 call rel32
    XF_RG,         0, 0xff,   2, 0,    0,        // 34 call r
    XF_LD,         1, 0x1b6,  0, 0,    0,        // 35 movzx r, byte [m]
    XF_LD,         1, 0x1b7,  0, 0,    0,        // 36 movzx r, word [m]
    XF_LD,         0, 0x8b,   0, 0,    0,        // 37 mov r32, [m]
    XF_LD,         1, 0x8b,   0, 0,    0,        // 38 mov r64, [m]
    XF_ST,         0, 0x88,   0, 0,    1,        // 39 mov [m], r8  (REX forced: sil/dil)
    XF_ST,         0, 0x89,   0, 0x66, 0,        // 40 mov [m], r16
    XF_ST,         0, 0x89,   0, 0,    0,        // 41 mov [m], r32
    XF_ST,         1, 0x89,   0, 0,    0,        // 42 mov [m], r64
    XF_SPEC,       0, 0,      0, 0,    0,        // 43 add rsp, imm
    XF_SPEC,       0, 0,      0, 0,    0,        // 44 sub rsp, imm
    XF_SPEC,       0, 0,      0, 0,    0         // 45 raw word
};

uptr x86_name[] = { "", "nop", "push", "push", "leave", "ret", "mov", "mov32",
    "mov", "lea", "lea", "add", "sub", "and", "or", "xor", "imul", "cqo",
    "xor32", "idiv", "div", "shl", "shr", "sar", "neg", "not", "cmp", "test",
    "set", "movzxb", "movzxw", "jmp", "j", "call", "call", "movzxb", "movzxw",
    "mov32", "mov", "mov8", "mov16", "mov32", "mov", "add", "sub", ".word" };

uptr m_x86_64[MTASK_COUNT];           // the task table the walker drives
uptr m_x86_64_win[MTASK_COUNT];       // the same thirty-one entries, Win64 prologue
u8   x86_tmp[BUF_SIZE];               // scratch the size task encodes into
i64  xdslot[MAXDEPTH];                // frame slot of a depth: 0 = not asked for yet
i64  x86_isub = 0;                    // the prologue's `sub rsp, N`, patched last

// M20: the two calling conventions, and the three things that tell them apart.
// The REGISTER PARTITION does not move -- rax, rcx, rdx and r8..r11 are volatile
// in both ABIs, so the depths stay in r8..r11 and the scratch stays rax/rcx/rdx.
// rdi and rsi are callee-saved on Win64 and this machine simply stops naming
// them: they appear only as SysV argument registers 0 and 1.
i64 x86_argreg[] = { XR_RDI, XR_RSI, XR_RDX, XR_RCX, 8, 9 };
i64 x86_argreg_win[] = { XR_RCX, XR_RDX, 8, 9 };

uptr x86_args    = 0;                 // the table in force: set by MTASK_PROLOGUE
i64  x86_nargreg = 0;                 // how many arguments travel in registers
i64  x86_shadow  = 0;                 // bytes the caller reserves below the args

i64 x86_cond[] = { 4, 5, 12, 14, 15, 13 };       // MCOND_EQ NE LT LE GT GE, signed
i64 x86_binop[] = { X_ADD, X_SUB, X_IMUL, 0, 0, 0, 0,   // MOP_*; the four divisions
                    X_AND, X_OR, X_XOR, X_SHL, X_SHR, X_SAR };   // go to x86_divmod
i64 x86_memop[] = { X_LD64, X_ST64, X_LD32, X_ST32, X_LD16, X_ST16, X_LD8, X_ST8 };

i64  x86_argreg_at(i64 i) { return ld64(x86_args + i * 8); }
i64  x86_cond_at(i64 i)   { return ld64(x86_cond + i * 8); }
i64  x86_binop_at(i64 i)  { return ld64(x86_binop + i * 8); }
i64  x86_memop_at(i64 i)  { return ld64(x86_memop + i * 8); }
uptr x86_name_at(i64 i)   { return ld64(x86_name + i * 8); }
i64  x86_d(i64 op, i64 c) { return ld64(x86_desc + (op * XD_N + c) * 8); }
i64  xdslot_at(i64 i)     { return ld64(xdslot + i * 8); }
void set_xdslot_at(i64 i, i64 v) { st64(xdslot + i * 8, v); }

i64 x86_form(i64 op) { return x86_d(op, 0); }

i64 x86_mem_op(i64 t, i64 store) {
    i64 i = 0;
    if (t == TY_U8)       i = 6;
    else if (t == TY_U16) i = 4;
    else if (t == TY_U32) i = 2;
    return x86_memop_at(i + store);
}

// ---- depth, register and spill ----
i64 x86_slot_depth(i64 d) {
    if (xdslot_at(d) == 0) set_xdslot_at(d, slot_new(8));
    return xdslot_at(d);
}

i64 x86_in_reg(i64 depth) { return depth <= XREG_MAX; }

// the register holding the depth's value; a spilled one is loaded into scratch
i64 x86_val_reg(i64 depth, i64 scratch) {
    if (x86_in_reg(depth)) return XREG_BASE + depth;
    em(X_LD64, scratch, XR_RBP, 0 - x86_slot_depth(depth));
    return scratch;
}

i64 x86_dst_reg(i64 depth) {
    if (x86_in_reg(depth)) return XREG_BASE + depth;
    return XREG_S1;
}

void x86_dst_done(i64 depth, i64 rd) {
    if (!x86_in_reg(depth)) em(X_ST64, rd, XR_RBP, 0 - x86_slot_depth(depth));
}

// r8..r11 are caller-saved, so the live depths go to the frame around a call
void x86_save_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth || !x86_in_reg(d)) break;
        em(X_ST64, XREG_BASE + d, XR_RBP, 0 - x86_slot_depth(d));
        d = d + 1;
    }
}

void x86_restore_live(i64 depth) {
    i64 d = 0;
    loop {
        if (d >= depth || !x86_in_reg(d)) break;
        em(X_LD64, XREG_BASE + d, XR_RBP, 0 - x86_slot_depth(d));
        d = d + 1;
    }
}

void x86_mov(i64 rd, i64 rn) { if (rd != rn) e2(X_MOV, rd, rn); }

// ---- the tasks ----
// The frame record is unconditional (a stack walk depends on it); the reserve is
// a placeholder until x86_frame_fix knows the size.
void x86_prologue_body() {
    i64 d = 0;
    loop {
        if (d >= MAXDEPTH) break;
        set_xdslot_at(d, 0);
        d = d + 1;
    }
    e2(X_PUSH, XR_RBP, 0);
    e2(X_MOV, XR_RBP, XR_RSP);
    x86_isub = nins;
    ei(X_SPSUB, 0, 0, 0);                        // the frame size only at the end
}

// The ABI is named by the prologue, which src/gen_walk.mc's gen_func always runs
// before the first MTASK_PARAM and before any MTASK_CALL, so the three globals
// can never be stale. That is also why the two conventions are two MACHINES and
// not a runtime flag: `--machine=x86_64-win` has to be able to dump the Win64
// sequence, and a flag the backend sets could not.
void x86_prologue() {
    x86_args = x86_argreg;
    x86_nargreg = 6;
    x86_shadow = 0;
    x86_prologue_body();
}

void x86_prologue_win() {
    x86_args = x86_argreg_win;
    x86_nargreg = 4;
    x86_shadow = 32;
    x86_prologue_body();
}

// parameter i goes to its slot without the prologue writing an argument
// register; the ones past the register table were pushed by the caller, above
// rbp -- past the saved rbp and the return address, and on Win64 past the
// 32 bytes of shadow space the caller reserved as well ([rbp+48] for the fifth).
void x86_param(i64 ty, i64 i, i64 off) {
    if (i < x86_nargreg) { em(x86_mem_op(ty, 1), x86_argreg_at(i), XR_RBP, 0 - off); return; }
    em(X_LD64, XR_RAX, XR_RBP, 16 + x86_shadow + (i - x86_nargreg) * 8);
    em(x86_mem_op(ty, 1), XR_RAX, XR_RBP, 0 - off);
}

// `leave` is `mov rsp, rbp; pop rbp`, so the epilogue needs no patching at all
void x86_epilogue() { e0(X_LEAVE); e0(X_RET); }

void x86_frame_fix(i64 frame) {
    set_ins_imm(ins_at(x86_isub), frame);
    if (frame == 0) set_ins_op(ins_at(x86_isub), X_NOP);
}

void x86_const(i64 d, i64 imm) {
    i64 rd = x86_dst_reg(d);
    ins_add(X_MOVI, rd, 0, 0, imm, 0, 0);
    x86_dst_done(d, rd);
}

// rax = rl, extend into rdx, divide, take the quotient or the remainder. rr is
// never rax or rdx: it is a depth register or XREG_S2 (rcx).
void x86_divmod(i64 op, i64 d, i64 d2) {
    i64 rl = x86_val_reg(d, XREG_S1);
    i64 rr = x86_val_reg(d2, XREG_S2);
    x86_mov(XR_RAX, rl);
    if (op == MOP_SDIV || op == MOP_SMOD) { e0(X_CQO); e2(X_IDIV, rr, 0); }
    else                                  { e0(X_ZEDX); e2(X_DIV, rr, 0); }
    i64 src = XR_RAX;
    if (op == MOP_SMOD || op == MOP_UMOD) src = XREG_TMP;
    i64 rd = x86_dst_reg(d);
    x86_mov(rd, src);
    x86_dst_done(d, rd);
}

// x86 is two-operand: the destination is also the left operand, which is what
// dst_reg and val_reg of the SAME depth already return.
void x86_bin(i64 op, i64 d, i64 d2) {
    if (op == MOP_SDIV || op == MOP_UDIV || op == MOP_SMOD || op == MOP_UMOD) {
        x86_divmod(op, d, d2);
        return;
    }
    i64 rd = x86_val_reg(d, XREG_S1);
    i64 rr = x86_val_reg(d2, XREG_S2);
    if (op == MOP_SHL || op == MOP_SHR || op == MOP_SAR) {
        x86_mov(XR_RCX, rr);                     // the count only comes from cl
        e2(x86_binop_at(op), rd, 0);
    } else {
        e2(x86_binop_at(op), rd, rr);
    }
    x86_dst_done(d, rd);
}

void x86_cmp(i64 cond, i64 d, i64 d2) {
    i64 rl = x86_val_reg(d, XREG_S1);
    i64 rr = x86_val_reg(d2, XREG_S2);
    i64 rd = x86_dst_reg(d);
    e2(X_CMP, rl, rr);
    ins_add(X_SETCC, rd, 0, 0, x86_cond_at(cond), 0, 0);
    e2(X_MOVZXB, rd, rd);                        // setcc writes one byte only
    x86_dst_done(d, rd);
}

void x86_un(i64 op, i64 d) {
    i64 rd = x86_val_reg(d, XREG_S1);            // operates in place
    if (op == MUN_NEG)      e2(X_NEG, rd, 0);
    else if (op == MUN_NOT) e2(X_NOT, rd, 0);
    else {
        e2(X_TEST, rd, rd);
        ins_add(X_SETCC, rd, 0, 0, XC_E, 0, 0);
        e2(X_MOVZXB, rd, rd);
    }
    x86_dst_done(d, rd);
}

void x86_bool(i64 d) {
    i64 rd = x86_val_reg(d, XREG_S1);
    e2(X_TEST, rd, rd);
    ins_add(X_SETCC, rd, 0, 0, XC_NE, 0, 0);
    e2(X_MOVZXB, rd, rd);
    x86_dst_done(d, rd);
}

void x86_cast(i64 ty, i64 d) {
    i64 rd = x86_val_reg(d, XREG_S1);
    if (ty == TY_U8)       e2(X_MOVZXB, rd, rd);
    else if (ty == TY_U16) e2(X_MOVZXW, rd, rd);
    else if (ty == TY_U32) e2(X_MOV32, rd, rd);  // a 32-bit mov zeroes the top half
    x86_dst_done(d, rd);
}

void x86_load(i64 ty, i64 d) {
    i64 rp = x86_val_reg(d, XREG_S1);
    i64 rd = x86_dst_reg(d);
    em(x86_mem_op(ty, 0), rd, rp, 0);            // zero-extended by construction
    x86_dst_done(d, rd);
}

void x86_store(i64 ty, i64 d) {
    i64 rp = x86_val_reg(d, XREG_S1);
    i64 rv = x86_val_reg(d + 1, XREG_S2);
    em(x86_mem_op(ty, 1), rv, rp, 0);
}

void x86_local_addr(i64 d, i64 off) {
    i64 rd = x86_dst_reg(d);
    em(X_LEA, rd, XR_RBP, 0 - off);
    x86_dst_done(d, rd);
}

void x86_local_load(i64 ty, i64 d, i64 off) {
    i64 rd = x86_dst_reg(d);
    em(x86_mem_op(ty, 0), rd, XR_RBP, 0 - off);
    x86_dst_done(d, rd);
}

void x86_local_store(i64 ty, i64 d, i64 off) {
    i64 rv = x86_val_reg(d, XREG_S2);
    em(x86_mem_op(ty, 1), rv, XR_RBP, 0 - off);
}

// rip-relative: one instruction, one R_X86_64_PC32 three bytes into it
void x86_sym_addr(i64 d, i64 sym) {
    i64 rd = x86_dst_reg(d);
    ins_add(X_LEARIP, rd, 0, 0, 0, 0, sym);
    x86_dst_done(d, rd);
}

void x86_global_load(i64 ty, i64 d, i64 sym) {
    i64 rd = x86_dst_reg(d);
    ins_add(X_LEARIP, rd, 0, 0, 0, 0, sym);
    em(x86_mem_op(ty, 0), rd, rd, 0);
    x86_dst_done(d, rd);
}

// rax is free here: the value is lowered already and nothing else is live in it
void x86_global_store(i64 ty, i64 d, i64 sym) {
    ins_add(X_LEARIP, XREG_S1, 0, 0, 0, 0, sym);
    i64 rv = x86_val_reg(d, XREG_S2);
    em(x86_mem_op(ty, 1), rv, XREG_S1, 0);
}

void x86_arg_to(i64 r, i64 d) {
    if (x86_in_reg(d)) { x86_mov(r, XREG_BASE + d); return; }
    em(X_LD64, r, XR_RBP, 0 - x86_slot_depth(d));
}

// The arguments past the register table go on the stack, at [rsp], [rsp + 8]...
// when the call happens. `push` takes its operand straight from memory, so no
// scratch register is spent; one extra 8 is reserved when the count is odd,
// because rsp has to be 16-byte aligned at the call. Returns how much to give
// back after.
//
// M20: the Win64 shadow space is the last thing subtracted, so it ends up
// BELOW the pushed arguments and the fifth argument lands at [rsp+32], which is
// where the callee's x86_param reads it from. The alignment rule is unchanged:
// 8*np + 32 is 0 mod 16 exactly when np is even. This is why the function has to
// return non-zero for a Win64 call with no stack arguments at all -- back is 32.
i64 x86_push_args(i64 dbase, i64 na) {
    i64 nr = x86_nargreg;
    i64 np = 0;
    if (na > nr) np = na - nr;
    i64 bytes = 8 * np;
    if (np % 2) { ei(X_SPSUB, 0, 0, 8); bytes = bytes + 8; }
    i64 i = na - 1;
    loop {
        if (i < nr) break;
        i64 d = dbase + i;
        if (x86_in_reg(d)) e2(X_PUSH, XREG_BASE + d, 0);
        else               em(X_PUSHM, 0, XR_RBP, 0 - x86_slot_depth(d));
        i = i - 1;
    }
    if (x86_shadow) { ei(X_SPSUB, 0, 0, x86_shadow); bytes = bytes + x86_shadow; }
    return bytes;
}

// The first ones in ABI order. Writing an argument register that is also a depth
// register cannot clobber a source still to be read, because the table is
// written in ASCENDING index and a depth register's own argument index is
// smaller than its position in the table. SysV: argreg[4] is r8 (depth 0), whose
// index is -dbase <= 0 < 4, and argreg[5] is r9 (depth 1), index 1 - dbase <= 1
// < 5. Win64: argreg[2] is r8, index -dbase <= 0 < 2, and argreg[3] is r9,
// index 1 - dbase <= 1 < 3. tests/windows/071-nested-args.mc is the executable
// proof of the Win64 half, where the margin is smallest.
void x86_reg_args(i64 dbase, i64 na) {
    i64 n = na;
    if (n > x86_nargreg) n = x86_nargreg;
    i64 i = 0;
    loop {
        if (i >= n) break;
        x86_arg_to(x86_argreg_at(i), dbase + i);
        i = i + 1;
    }
}

void x86_call(i64 d, i64 na, i64 sym) {
    x86_save_live(d);
    i64 back = x86_push_args(d, na);
    x86_reg_args(d, na);
    ins_add(X_CALL, 0, 0, 0, 0, 0, sym);
    if (back) ei(X_SPADD, 0, 0, back);
    x86_restore_live(d);
    i64 rd = x86_dst_reg(d);
    x86_mov(rd, XR_RAX);
    x86_dst_done(d, rd);
}

// callp(p, a1..a11): the pointer (argument 0) goes to rax, outside the ABI, and
// has to move BEFORE any argument register is written, because it may itself be
// living in r8..r11.
void x86_callp(i64 d, i64 na) {
    x86_save_live(d);
    x86_arg_to(XR_RAX, d);
    i64 back = x86_push_args(d + 1, na - 1);
    x86_reg_args(d + 1, na - 1);
    e2(X_CALLR, XR_RAX, 0);
    if (back) ei(X_SPADD, 0, 0, back);
    x86_restore_live(d);
    i64 rd = x86_dst_reg(d);
    x86_mov(rd, XR_RAX);
    x86_dst_done(d, rd);
}

void x86_ret(i64 d)  { x86_mov(XR_RAX, x86_val_reg(d, XREG_S1)); }
void x86_jump(i64 l) { el(X_JMP, l); }

void x86_jcond(i64 d, i64 l, i64 cc) {
    i64 rv = x86_val_reg(d, XREG_S1);
    e2(X_TEST, rv, rv);
    ins_add(X_JCC, 0, 0, 0, cc, l, 0);
}

void x86_jz(i64 d, i64 l)  { x86_jcond(d, l, XC_E); }
void x86_jnz(i64 d, i64 l) { x86_jcond(d, l, XC_NE); }
void x86_label(i64 l)      { el(I_LABEL, l); }
void x86_word(i64 w)       { ins_add(X_EMIT, 0, 0, 0, w, 0, 0); }

// the two instructions that always carry a relocation of their own, and how far
// into each one the four-byte field sits
i64 x86_reloc_kind(uptr e) {
    i64 op = ins_op(e);
    if (op == X_CALL)   return R_X86_PLT32;
    if (op == X_LEARIP) return R_X86_PC32;
    return -1;
}

i64 x86_reloc_off(uptr e) {
    i64 op = ins_op(e);
    if (op == X_CALL)   return 1;                // E8 | rel32
    if (op == X_LEARIP) return 3;                // REX.W 8D modrm | disp32
    return 0;
}

// ---- the encoder ----
// A REX prefix is needed for a 64-bit operand, for any register above 7, and for
// an 8-bit operand whose register could otherwise read as ah/ch/dh/bh.
void x86_rex(uptr o, i64 w, i64 r, i64 b, i64 force) {
    if (!w && !force && r < 8 && b < 8) return;
    i64 v = 0x40;
    if (w) v = v | 8;
    if (r >= 8) v = v | 4;
    if (b >= 8) v = v | 1;
    buf_u8(o, v);
}

void x86_op(uptr o, i64 op) {                    // > 0xff is a two-byte 0x0F opcode
    if (op > 0xff) buf_u8(o, 0x0f);
    buf_u8(o, op & 0xff);
}

void x86_modrm_rr(uptr o, i64 reg, i64 rm) { buf_u8(o, 0xc0 | ((reg & 7) << 3) | (rm & 7)); }

i64 x86_fits8(i64 v) { return v >= 0 - 128 && v <= 127; }

// [base] with no displacement byte at all — mod 00. Not available for rbp and
// r13: with mod 00 their slot means [rip + disp32], which is the form X_LEARIP
// uses.
i64 x86_mod0(i64 base, i64 disp) {
    if (disp != 0) return 0;
    if ((base & 7) == 5) return 0;
    return 1;
}

void x86_modrm_m(uptr o, i64 reg, i64 base, i64 disp) {
    i64 mod = 2;
    if (x86_mod0(base, disp))  mod = 0;
    else if (x86_fits8(disp))  mod = 1;
    buf_u8(o, (mod << 6) | ((reg & 7) << 3) | (base & 7));
    if ((base & 7) == 4) buf_u8(o, 0x24);        // SIB: base only, no index
    if (mod == 0) return;
    if (mod == 1) { buf_u8(o, disp & 0xff); return; }
    buf_u32(o, disp);
}

// mov r, imm in three shapes: 32-bit zero-extending, 32-bit sign-extending, full
void x86_put_movi(uptr o, i64 rd, i64 v) {
    if (v >= 0 && v <= 0xffffffff) {             // mov r32, imm32 zero-extends
        x86_rex(o, 0, 0, rd, 0);
        buf_u8(o, 0xb8 + (rd & 7));
        buf_u32(o, v);
        return;
    }
    if (v >= 0 - 0x80000000 && v < 0x80000000) { // mov r/m64, imm32 sign-extends
        x86_rex(o, 1, 0, rd, 0);
        buf_u8(o, 0xc7);
        x86_modrm_rr(o, 0, rd);
        buf_u32(o, v);
        return;
    }
    x86_rex(o, 1, 0, rd, 0);
    buf_u8(o, 0xb8 + (rd & 7));
    buf_u64(o, v);
}

void x86_put_spimm(uptr o, i64 dig, i64 v) {     // add/sub rsp, imm8 or imm32
    x86_rex(o, 1, 0, XR_RSP, 0);
    if (x86_fits8(v)) {
        buf_u8(o, 0x83);
        x86_modrm_rr(o, dig, XR_RSP);
        buf_u8(o, v & 0xff);
        return;
    }
    buf_u8(o, 0x81);
    x86_modrm_rr(o, dig, XR_RSP);
    buf_u32(o, v);
}

// a label's offset, or 0 while measuring: the two branch forms are fixed width,
// so the size does not depend on the answer
i64 x86_target(uptr lab, i64 l) {
    if (lab == 0) return 0;
    return ivec_at(lab, l);
}

// THE encoder. MTASK_ENCODE calls it with the section buffer, MTASK_INS_SIZE
// with a scratch one, so the size the label pass reserves is by construction the
// number of bytes that will be written.
void x86_put(uptr e, i64 pc, uptr lab, uptr o) {
    i64 op = ins_op(e);
    i64 rd = ins_rd(e);
    i64 rn = ins_rn(e);
    i64 im = ins_imm(e);
    i64 f  = x86_form(op);
    if (op == I_LABEL || op == X_NOP) return;
    if (f) {
        i64 w   = x86_d(op, 1);
        i64 opc = x86_d(op, 2);
        i64 dig = x86_d(op, 3);
        i64 pre = x86_d(op, 4);
        i64 rex = x86_d(op, 5);
        if (f == XF_FIX) {                       // `dig` bytes of `opc`, high first
            i64 i = dig;
            loop {
                if (i <= 0) break;
                i = i - 1;
                buf_u8(o, (opc >> (8 * i)) & 0xff);
            }
            return;
        }
        if (pre) buf_u8(o, pre);
        i64 reg = rd;                            // XF_RD, XF_LD, XF_ST
        i64 rm  = rn;
        if (f == XF_RS) { reg = rn; rm = rd; }
        if (f == XF_RG) { reg = dig; rm = rd; }
        if (f == XF_MG) { reg = dig; }
        x86_rex(o, w, reg, rm, rex);
        x86_op(o, opc);
        if (f == XF_RS || f == XF_RD || f == XF_RG) x86_modrm_rr(o, reg, rm);
        else                                        x86_modrm_m(o, reg, rn, im);
        return;
    }
    if (op == X_PUSH)  { x86_rex(o, 0, 0, rd, 0); buf_u8(o, 0x50 + (rd & 7)); return; }
    if (op == X_MOVI)  { x86_put_movi(o, rd, im); return; }
    if (op == X_LEARIP) {                        // mod 00, rm 101 is [rip + disp32]
        x86_rex(o, 1, rd, 0, 0);
        buf_u8(o, 0x8d);
        buf_u8(o, ((rd & 7) << 3) | 5);
        buf_u32(o, 0);                           // the linker fills it in
        return;
    }
    if (op == X_SETCC) { x86_rex(o, 0, 0, rd, 1); x86_op(o, 0x190 + im);
                         x86_modrm_rr(o, 0, rd); return; }
    if (op == X_JMP) {
        buf_u8(o, 0xe9);
        buf_u32(o, x86_target(lab, ins_label(e)) - (pc + 5));
        return;
    }
    if (op == X_JCC) {
        buf_u8(o, 0x0f);
        buf_u8(o, 0x80 + im);
        buf_u32(o, x86_target(lab, ins_label(e)) - (pc + 6));
        return;
    }
    if (op == X_CALL)  { buf_u8(o, 0xe8); buf_u32(o, 0); return; }  // the reloc carries -4
    if (op == X_SPADD) { x86_put_spimm(o, 0, im); return; }
    if (op == X_SPSUB) { x86_put_spimm(o, 5, im); return; }
    if (op == X_EMIT)  { buf_u32(o, im); return; }
    die("x86 instruction with no encoder");
}

// the same encoder over a scratch buffer whose length is reset, not its capacity
i64 x86_ins_size(uptr e) {
    set_buf_len(x86_tmp, 0);
    x86_put(e, 0, 0, x86_tmp);
    return buf_len(x86_tmp);
}

// ---- text dump ----
uptr x86_rname[] = { "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
                     "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };

uptr x86_rname_at(i64 i) { return ld64(x86_rname + i * 8); }
void xd_reg(i64 r)  { out_str(1, x86_rname_at(r)); }
void xd_head(uptr m) { out_str(1, "  "); out_str(1, m); out_str(1, " "); }

void xd_num(i64 v) {
    if (v < 0) { out_str(1, "-"); out_num(1, 0 - v); return; }
    out_num(1, v);
}

void xd_mem(i64 base, i64 off) {
    out_str(1, "[");
    xd_reg(base);
    if (off >= 0) { out_str(1, "+"); out_num(1, off); }
    else          { out_str(1, "-"); out_num(1, 0 - off); }
    out_str(1, "]");
}

uptr xd_cond(i64 c) {
    if (c == 4)  return "e";
    if (c == 5)  return "ne";
    if (c == 12) return "l";
    if (c == 13) return "ge";
    if (c == 14) return "le";
    if (c == 15) return "g";
    return "??";
}

void xd_word(u64 w) {
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

// the same descriptor table decides the operand shape here
void x86_dump(uptr in) {
    i64 op = ins_op(in);
    i64 rd = ins_rd(in);
    i64 rn = ins_rn(in);
    i64 im = ins_imm(in);
    i64 f  = x86_form(op);
    uptr m = x86_name_at(op);
    if (op == X_NOP) return;
    if (op == I_LABEL) { out_str(1, "L"); out_num(1, ins_label(in)); out_str(1, ":\n"); return; }
    if (f == XF_FIX) { out_str(1, "  "); out_str(1, m); out_str(1, "\n"); return; }
    if (f == XF_RS || f == XF_RD) { xd_head(m); xd_reg(rd); out_str(1, ", ");
                                    xd_reg(rn); out_str(1, "\n"); return; }
    if (f == XF_RG) { xd_head(m); xd_reg(rd);
                      if (op == X_SHL || op == X_SHR || op == X_SAR) out_str(1, ", cl");
                      out_str(1, "\n"); return; }
    if (f == XF_LD) { xd_head(m); xd_reg(rd); out_str(1, ", "); xd_mem(rn, im);
                      out_str(1, "\n"); return; }
    if (f == XF_ST) { xd_head(m); xd_mem(rn, im); out_str(1, ", "); xd_reg(rd);
                      out_str(1, "\n"); return; }
    if (f == XF_MG) { xd_head(m); xd_mem(rn, im); out_str(1, "\n"); return; }
    if (op == X_PUSH)   { xd_head(m); xd_reg(rd); out_str(1, "\n"); return; }
    if (op == X_MOVI)   { xd_head(m); xd_reg(rd); out_str(1, ", "); xd_num(im);
                          out_str(1, "\n"); return; }
    if (op == X_LEARIP) { xd_head(m); xd_reg(rd); out_str(1, ", [rip+");
                          out_str(1, sym_name(sym_at(ins_sym(in)))); out_str(1, "]\n"); return; }
    if (op == X_SETCC)  { out_str(1, "  "); out_str(1, m); out_str(1, xd_cond(im));
                          out_str(1, " "); xd_reg(rd); out_str(1, "\n"); return; }
    if (op == X_JMP)    { xd_head(m); out_str(1, "L"); out_num(1, ins_label(in));
                          out_str(1, "\n"); return; }
    if (op == X_JCC)    { out_str(1, "  j"); out_str(1, xd_cond(im)); out_str(1, " L");
                          out_num(1, ins_label(in)); out_str(1, "\n"); return; }
    if (op == X_CALL)   { xd_head(m); out_str(1, sym_name(sym_at(ins_sym(in))));
                          out_str(1, "\n"); return; }
    if (op == X_SPADD || op == X_SPSUB) { xd_head(m); out_str(1, "rsp, "); xd_num(im);
                                          out_str(1, "\n"); return; }
    if (op == X_EMIT)   { xd_word((u32) im); return; }
    die("x86 instruction with no dump");
}

// ---- registration ----
void x86_task(i64 task, uptr fn) { st64(m_x86_64 + task * 8, fn); }

void machine_x86_64_init() {
    x86_task(MTASK_PROLOGUE,     &x86_prologue);
    x86_task(MTASK_PARAM,        &x86_param);
    x86_task(MTASK_EPILOGUE,     &x86_epilogue);
    x86_task(MTASK_FRAME_FIX,    &x86_frame_fix);
    x86_task(MTASK_CONST,        &x86_const);
    x86_task(MTASK_BIN,          &x86_bin);
    x86_task(MTASK_CMP,          &x86_cmp);
    x86_task(MTASK_UN,           &x86_un);
    x86_task(MTASK_BOOL,         &x86_bool);
    x86_task(MTASK_CAST,         &x86_cast);
    x86_task(MTASK_LOAD,         &x86_load);
    x86_task(MTASK_STORE,        &x86_store);
    x86_task(MTASK_LOCAL_ADDR,   &x86_local_addr);
    x86_task(MTASK_LOCAL_LOAD,   &x86_local_load);
    x86_task(MTASK_LOCAL_STORE,  &x86_local_store);
    x86_task(MTASK_SYM_ADDR,     &x86_sym_addr);
    x86_task(MTASK_GLOBAL_LOAD,  &x86_global_load);
    x86_task(MTASK_GLOBAL_STORE, &x86_global_store);
    x86_task(MTASK_CALL,         &x86_call);
    x86_task(MTASK_CALLP,        &x86_callp);
    x86_task(MTASK_RET,          &x86_ret);
    x86_task(MTASK_JUMP,         &x86_jump);
    x86_task(MTASK_JZ,           &x86_jz);
    x86_task(MTASK_JNZ,          &x86_jnz);
    x86_task(MTASK_LABEL,        &x86_label);
    x86_task(MTASK_WORD,         &x86_word);
    x86_task(MTASK_INS_SIZE,     &x86_ins_size);
    x86_task(MTASK_ENCODE,       &x86_put);
    x86_task(MTASK_DUMP,         &x86_dump);
    x86_task(MTASK_RELOC_KIND,   &x86_reloc_kind);
    x86_task(MTASK_RELOC_OFF,    &x86_reloc_off);
    machine("x86_64", m_x86_64);

    // M20: the Win64 machine is the SAME machine with one slot replaced. Every
    // encoder, the size task, the dump and the two relocation tasks are pure
    // functions of the Ins record and are ABI-blind, so copying the table and
    // swapping the prologue is the whole of it.
    i64 t = 0;
    loop {
        if (t >= MTASK_COUNT) break;
        st64(m_x86_64_win + t * 8, ld64(m_x86_64 + t * 8));
        t = t + 1;
    }
    st64(m_x86_64_win + MTASK_PROLOGUE * 8, &x86_prologue_win);
    machine("x86_64-win", m_x86_64_win);
}
