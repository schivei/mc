// machine_avr.mc — the ATmega328P machine (AVR5), written entirely OUTSIDE the
// compiler (M40, docs/specs/M40.md; the contract is docs/reference/machine.md).
//
// It fills the same thirty-one slots src/machine_arm64.mc, src/machine_x86_64.mc
// and examples/kernel/machine_riscv64.mc fill, so src/gen_walk.mc never learns a
// fourth instruction set. What is new here is not the seam -- M39 proved that --
// it is the WORD: this is the first machine whose target has an 8-bit register
// and a 16-bit pointer, and the compiler that carries it declares
// `type_set_width(TY_UPTR, 2)` from user_init (M41 § 4a, M40 § Amendment).
//
// The three decisions that shape everything below:
//
//   1. A DEPTH IS A FRAME SLOT, never a register. An AVR has 32 eight-bit
//      registers; one 64-bit value already costs eight of them, and Y (the frame
//      pointer), Z (the address register), X (the address scratch) and r0/r1 are
//      spoken for. Four depths in registers is not reachable, so this machine
//      does not try: every depth d lives in an 8-byte slot (avr_dslot), and the
//      register file r16..r23 is the accumulator every task loads into and
//      stores back from. That makes MTASK_CALL trivially safe (a callee cannot
//      clobber a frame slot), so save_live/restore_live do not exist.
//
//   2. EVERY SLOT HOLDS EIGHT VALID BYTES. A value of a type of width w < 8 has
//      its bytes above w set to zero -- every core type but i64 is unsigned, so
//      "extend" always means "zero". That is what lets a consumer read a depth
//      at a width the producer did not use: `i64 x = u8v;` stores one byte and
//      reads eight, and both are right.
//
//   3. ARITHMETIC IS DONE AT THE DEPTH'S DECLARED WIDTH (M24's walk_depth_type,
//      adopted by docs/specs/M40.md D4). `u16 + u16` is two `add`s and not
//      eight, which is the whole reason narrow types exist on this part. The
//      divergence it buys is real, declared, and tested:
//
//          u16 a = 0xFFFF;  i64 x = a * a;
//
//      is 0x0001 here and 0xFFFE0001 on arm64, because res_binary types the
//      product from its left operand and nothing re-widens it. It is stated in
//      docs/reference/machine.md § the avr column and asserted by
//      examples/avr/test.sh.
//
// The ABI this machine states (examples/avr/README.md § The ABI, and the AVR
// half of docs/reference/objects.md § 4):
//
//   r0, r1     scratch bytes; r0 also carries SREG across the SP writes
//   r8..r15    TMP: the right-hand operand of a binary chain
//   r16..r23   ACC: the accumulator -- left operand, result, RETURN VALUE
//   r24, r25   byte scratch: shift counters, the 0/1 of a comparison
//   r26:r27    X: the address scratch a far frame access borrows
//   r28:r29    Y: the frame pointer, and the stack pointer's value
//   r30:r31    Z: the address register of every load and store
//   r2..r7     NEVER WRITTEN by generated code (test.sh asserts zero mentions)
//
//   arguments  all of them in the CALLER's frame, 8 bytes each, zero-extended,
//              at [Y+1+8i]; the callee reads argument i at base + 4 + 8i, where
//              the 4 is the return address (2) plus the pushed Y (2). No
//              argument is ever in a register, so MAXPARAMS 12 costs nothing.
//   result     r16..r23, zero-extended to 8 bytes by the callee
//   clobbered  r0, r1, r8..r27, r30, r31 and SREG
//   preserved  r2..r7, Y (r28:r29) and SP
//
// The frame, and why the offsets are patched last:
//
//     Y+total  ... Y+1     the frame, [Y+1, Y+total]; SP == Y throughout
//     base = Y + total + 1 is the fictitious top a slot hangs off: a slot at
//     `off` is at base - off, exactly as src/machine_arm64.mc's REG_FRAME.
//     `total` is frame + the outgoing argument area, and neither is known until
//     MTASK_FRAME_FIX, so every frame-touching Ins carries `off` in rn and
//     avr_frame_fix rewrites it into a Y displacement in one pass.
//
// The two things that make MTASK_INS_SIZE run the REAL encoder (M39 risk 3, one
// architecture over): `ldd`/`std` have a 6-bit displacement (q = 0..63) and a
// frame past that costs three extra instructions, and AVR mixes 2- and 4-byte
// instructions. A switch that guessed a length would be a plausible image that
// lands in the middle of an instruction.
//
// Depends on gen_walk.mc (the Ins buffer, ins_add/e0/e2/e3/ei/el/elr/em,
// slot_new, the MTASK_/MOP_/MUN_/MCOND_ vocabulary, walk_depth_type and
// MAXDEPTH), on arena.mc (buf_*, out_str, out_num, die) and on objmodel.mc
// (sym_ref, sym_name, sym_at).

#include "../../lib/prelude.mc"

// ---- registers, by their AVR encoding number ----
#define AR_R0    0                    // scratch byte; carries SREG in the SP write
#define AR_TMP   8                    // r8..r15  the right-hand operand
#define AR_ACC  16                    // r16..r23 the accumulator
#define AR_CNT  24                    // r24 shift count / the 0/1 of a compare
#define AR_X    26                    // the address scratch of a far frame access
#define AR_Y    28                    // the frame pointer
#define AR_Z    30                    // the address register

// I/O addresses (in/out space, not data space)
#define IO_SPL  0x3d
#define IO_SPH  0x3e
#define IO_SREG 0x3f

// The two relocation kinds this module produces. They travel in the same Reloc
// record as the Mach-O ones, so their numbers only have to avoid
// R_UNSIGNED..R_ADDEND (0..4 and 10), machine_x86_64.mc's 16/17 and
// machine_riscv64.mc's 32/33.
#define AVRK_ADDR16 34                // two `ldi` halves: lo8(sym), hi8(sym)
#define AVRK_CALL22 35                // the 22-bit word address of a jmp/call

// A frame bigger than this is refused. The walker's own cap is 4095
// (src/gen_walk.mc), which is twice the SRAM of an ATmega328P: a machine with a
// smaller reach diagnoses it itself, which is what docs/reference/machine.md
// § 6 requires and what M39's rv_jal_off did for a jump.
#define AVR_FRAME_MAX 1024

// ---- the opcodes. 0 is I_LABEL and belongs to the walker. ----
// Each one is a MACRO: a byte-chain over w bytes, or a fixed sequence. The
// numbers overlap the other machines' on purpose -- only one machine ever
// encodes an Ins buffer.
#define A_PRO    1                    // push YH, push YL, Y = SP
#define A_FRAME  2                    // rn = total: reserve and write SP
#define A_EPI    3                    // rn = total: release, pop YL/YH, ret
#define A_FLD    4                    // rd, rn = off, rm = w : regs <- slot
#define A_FST    5                    // rd, rn = off, rm = w : slot <- regs
#define A_FZ     6                    // rn = off, imm = from, rm = to : zero
#define A_KST    7                    // rn = off, imm = value, rm = w : constant
#define A_FADDR  8                    // rd = pair, rn = off : pair = base - off
#define A_OST    9                    // rd, rn = Y displacement, rm = w (outgoing)
#define A_LDSYM 10                    // rd = pair, sym : two ldi + AVRK_ADDR16
#define A_ZLD   11                    // rd, rm = w : regs <- [Z]
#define A_ZST   12                    // rd, rm = w : [Z] <- regs
#define A_ALU   13                    // rd, rn, rm = w, imm = ALU_*
#define A_COM   14                    // rd, rm = w
#define A_NEG   15                    // rd, rm = w
#define A_SHIFT 16                    // rd, rm = w, imm = SH_* : count in r24
#define A_SETCC 17                    // imm = MCOND_* : r24 = 0/1 from the flags
#define A_TSTZ  18                    // rd, rm = w : or-chain, sets Z
#define A_JZ    19                    // label : brne .+2 ; rjmp L
#define A_JNZ   20                    // label : breq .+2 ; rjmp L
#define A_RJMP  21                    // label
#define A_CALL  22                    // sym : call, 4 bytes, AVRK_CALL22
#define A_ICALL 23                    // icall (Z is a WORD address by then)
#define A_ZHALF 24                    // lsr ZH ; ror ZL : byte address -> word
#define A_EMIT  25                    // imm : one or two raw words
#define A_LPM   26                    // rd : lpm rd, Z
#define A_NOP   27                    // erased: no bytes at all

// the ALU chains A_ALU spells, in the order avr_alu_base reads
#define ALU_ADD 0
#define ALU_SUB 1
#define ALU_AND 2
#define ALU_OR  3
#define ALU_EOR 4
#define ALU_CP  5

#define SH_LEFT 0
#define SH_LSR  1
#define SH_ASR  2

uptr m_avr[MTASK_COUNT];              // the task table the walker drives
u8   avr_tmpbuf[BUF_SIZE];            // the scratch MTASK_INS_SIZE encodes into
i64  avr_dslots[MAXDEPTH];            // frame slot of a depth: 0 = not asked yet
i64  avr_ires = 0;                    // index of the A_FRAME to patch
i64  avr_epi  = 0;                    // index of the A_EPI to patch
i64  avr_out  = 0;                    // bytes of OUTGOING argument area
i64  avr_first = 0;                   // first Ins of the function being lowered

// the ALU base words, in ALU_* order: add/sub/and/or/eor/cp, then the
// carry-propagating second byte of each: adc/sbc/and/or/eor/cpc
i64 avr_alu1[] = { 0x0c00, 0x1800, 0x2000, 0x2800, 0x2400, 0x1400 };
i64 avr_alu2[] = { 0x1c00, 0x0800, 0x2000, 0x2800, 0x2400, 0x0400 };
uptr avr_aluname[] = { "add", "sub", "and", "or", "eor", "cp" };

// MOP_* -> ALU_*, with -1 where the operation is a call or a shift
i64 avr_binalu[] = { ALU_ADD, ALU_SUB, 0 - 1, 0 - 1, 0 - 1, 0 - 1, 0 - 1,
                     ALU_AND, ALU_OR, ALU_EOR, 0 - 1, 0 - 1, 0 - 1 };
// the runtime helper each of the five non-inline MOP_* calls
uptr avr_binfn[] = { 0, 0, "_avr_mul", "_avr_sdiv", "_avr_udiv", "_avr_smod",
                     "_avr_umod", 0, 0, 0, 0, 0, 0 };

i64  avr_alu1_at(i64 i)   { return ld64(avr_alu1 + i * 8); }
i64  avr_alu2_at(i64 i)   { return ld64(avr_alu2 + i * 8); }
uptr avr_aluname_at(i64 i) { return ld64(avr_aluname + i * 8); }
i64  avr_binalu_at(i64 i) { return ld64(avr_binalu + i * 8); }
uptr avr_binfn_at(i64 i)  { return ld64(avr_binfn + i * 8); }
i64  avr_dslot_at(i64 i)  { return ld64(avr_dslots + i * 8); }
void set_avr_dslot_at(i64 i, i64 v) { st64(avr_dslots + i * 8, v); }

// ---- depths ----
// One 8-byte slot per depth, allocated the first time the depth is written or
// read. A function that never nests three deep never pays for the third slot.
i64 avr_dslot(i64 d) {
    if (d < 0 || d >= MAXDEPTH) die("avr: depth outside the table");
    if (avr_dslot_at(d) == 0) set_avr_dslot_at(d, slot_new(8));
    return avr_dslot_at(d);
}

// the width a depth's DECLARED type is computed at, clamped to 1..8
i64 avr_tw(i64 ty) {
    i64 w = type_width(ty);
    if (w < 1) return 1;
    if (w > 8) return 8;
    return w;
}

i64 avr_dw(i64 d) { return avr_tw(walk_depth_type(d)); }

// ---- the little emitters every task is written in ----
void avr_fld(i64 rd, i64 d, i64 w)  { ins_add(A_FLD, rd, avr_dslot(d), w, 0, 0, 0); }
void avr_fst(i64 rd, i64 d, i64 w)  { ins_add(A_FST, rd, avr_dslot(d), w, 0, 0, 0); }

// the zero-extension half of decision 2: everything above w in the slot
void avr_fz(i64 d, i64 from) {
    if (from >= 8) return;
    ins_add(A_FZ, 0, avr_dslot(d), 8, from, 0, 0);
}

// a value of width w has just landed in ACC: put it away and zero the rest
void avr_put(i64 d, i64 w) {
    avr_fst(AR_ACC, d, w);
    avr_fz(d, w);
}

// ---- the tasks ----
// The prologue is unconditional, exactly as on the other three machines: an
// interrupt handler and a stack walk both depend on Y being saved. It is also
// the reason an ISR can be an ordinary function whose frame is empty -- with
// `total` 0 the A_FRAME below emits NOTHING, so the four instructions here
// clobber Y (which they just saved) and no flag at all
// (examples/avr/lib/isr.mc).
void avr_prologue() {
    i64 d = 0;
    while (d < MAXDEPTH) {
        set_avr_dslot_at(d, 0);
        d = d + 1;
    }
    avr_out = 0;
    avr_first = nins;
    e0(A_PRO);
    avr_ires = nins;
    e0(A_FRAME);
}

// Argument i is in the CALLER's frame at [caller_Y + 1 + 8i], which is
// base + 4 + 8i here: the `call` pushed two bytes of return address and A_PRO
// pushed two of Y. A negative `off` is how that is said in the base-minus-off
// coordinates every other frame reference uses, and avr_frame_fix turns it into
// a Y displacement like any other.
void avr_param(i64 ty, i64 i, i64 off) {
    i64 w = avr_tw(ty);
    ins_add(A_FLD, AR_ACC, 0 - (4 + i * 8), 8, 0, 0, 0);
    ins_add(A_FST, AR_ACC, off, w, 0, 0, 0);
}

void avr_epilogue() {
    avr_epi = nins;
    e0(A_EPI);
}

// The outgoing argument area lives at the BOTTOM of the frame, immediately
// above SP -- which is where the callee looks, because SP is what `call`
// pushes the return address below. That is also why sp never moves inside a
// body: [Y + 1 + 8i] is only a fixed address if Y and SP agree.
void avr_frame_fix(i64 frame) {
    i64 total = frame + avr_out;
    if (total > AVR_FRAME_MAX) die("avr frame too large for 2 KiB of SRAM");
    set_ins_rn(ins_at(avr_ires), total);
    set_ins_rn(ins_at(avr_epi), total);
    // one pass over the function: every frame-relative `off` becomes the Y
    // displacement `total + 1 - off`, which is what the encoder needs and what
    // decides whether the access fits ldd's six bits
    i64 i = avr_first;
    while (i < nins) {
        uptr e = ins_at(i);
        i64 op = ins_op(e);
        if (op == A_FLD || op == A_FST || op == A_FZ || op == A_KST || op == A_FADDR)
            set_ins_rn(e, total + 1 - ins_rn(e));
        i = i + 1;
    }
}

// A literal is always TY_I64, so all eight bytes are written: a negative
// constant has 0xFF above its magnitude and zeroing those would change it.
void avr_const(i64 d, i64 imm) {
    ins_add(A_KST, 0, avr_dslot(d), 8, imm, 0, 0);
}

// The five MOP_* with no AVR instruction go to a helper in
// examples/avr/lib/rt_avr.mc, called with the ordinary ABI: both operands are
// full 8-byte values (the slots are zero-extended, so an unsigned operation on
// a narrow type is the same call), and the result is truncated to the depth's
// declared width on the way back.
void avr_bin_call(i64 op, i64 d, i64 d2, i64 w) {
    if (avr_out < 16) avr_out = 16;
    avr_fld(AR_ACC, d, 8);
    ins_add(A_OST, AR_ACC, 1, 8, 0, 0, 0);
    avr_fld(AR_ACC, d2, 8);
    ins_add(A_OST, AR_ACC, 9, 8, 0, 0, 0);
    ins_add(A_CALL, 0, 0, 0, 0, 0, sym_ref(avr_binfn_at(op)));
    avr_put(d, w);
}

void avr_bin(i64 op, i64 d, i64 d2) {
    i64 w = avr_dw(d);
    i64 alu = avr_binalu_at(op);
    if (alu >= 0) {
        avr_fld(AR_ACC, d, w);
        avr_fld(AR_TMP, d2, w);
        ins_add(A_ALU, AR_ACC, AR_TMP, w, alu, 0, 0);
        avr_put(d, w);
        return;
    }
    if (op == MOP_SHL || op == MOP_SHR || op == MOP_SAR) {
        i64 dir = SH_LEFT;
        if (op == MOP_SHR) dir = SH_LSR;
        if (op == MOP_SAR) dir = SH_ASR;
        avr_fld(AR_ACC, d, w);
        avr_fld(AR_CNT, d2, 1);                  // the count is one byte, masked
        ins_add(A_SHIFT, AR_ACC, 0, w, dir, 0, 0);
        avr_put(d, w);
        return;
    }
    avr_bin_call(op, d, d2, w);
}

// Comparison in this language is SIGNED (src/gen_walk.mc has no unsigned
// condition), and every value in a slot is zero-extended -- so comparing at the
// declared width would answer -1 < 1 for a u16 of 0xFFFF. The rule: i64 on
// either side takes all eight bytes; otherwise one byte more than the widest
// operand, which is zero and makes the signed comparison the unsigned one.
i64 avr_cmp_width(i64 d, i64 d2) {
    i64 t1 = walk_depth_type(d);
    i64 t2 = walk_depth_type(d2);
    if (t1 == TY_I64 || t2 == TY_I64) return 8;
    i64 w = avr_tw(t1);
    if (avr_tw(t2) > w) w = avr_tw(t2);
    if (w >= 8) return 8;
    return w + 1;
}

// AVR has brlt/brge (the S flag) and breq/brne, and nothing for `>` -- so `>`
// and `<=` are `<` and `>=` with the operands the other way round, which costs
// nothing because this machine chooses which file each side lands in.
void avr_cmp(i64 cond, i64 d, i64 d2) {
    i64 w = avr_cmp_width(d, d2);
    i64 c = cond;
    if (cond == MCOND_GT) { c = MCOND_LT; }
    if (cond == MCOND_LE) { c = MCOND_GE; }
    if (cond == MCOND_GT || cond == MCOND_LE) {
        avr_fld(AR_ACC, d2, w);
        avr_fld(AR_TMP, d, w);
    } else {
        avr_fld(AR_ACC, d, w);
        avr_fld(AR_TMP, d2, w);
    }
    ins_add(A_ALU, AR_ACC, AR_TMP, w, ALU_CP, 0, 0);
    ins_add(A_SETCC, 0, 0, 0, c, 0, 0);
    avr_fst(AR_CNT, d, 1);
    avr_fz(d, 1);
}

void avr_un(i64 op, i64 d) {
    i64 w = avr_dw(d);
    if (op == MUN_LNOT) {
        avr_fld(AR_ACC, d, w);
        ins_add(A_TSTZ, AR_ACC, 0, w, 0, 0, 0);
        ins_add(A_SETCC, 0, 0, 0, MCOND_EQ, 0, 0);
        avr_fst(AR_CNT, d, 1);
        avr_fz(d, 1);
        return;
    }
    avr_fld(AR_ACC, d, w);
    if (op == MUN_NEG) ins_add(A_NEG, AR_ACC, 0, w, 0, 0, 0);
    else               ins_add(A_COM, AR_ACC, 0, w, 0, 0, 0);
    avr_put(d, w);
}

void avr_bool(i64 d) {
    i64 w = avr_dw(d);
    avr_fld(AR_ACC, d, w);
    ins_add(A_TSTZ, AR_ACC, 0, w, 0, 0, 0);
    ins_add(A_SETCC, 0, 0, 0, MCOND_NE, 0, 0);
    avr_fst(AR_CNT, d, 1);
    avr_fz(d, 1);
}

// narrowing is zeroing: every core type but i64 is unsigned, and a cast to a
// WIDER type is nothing at all, because the slot was already zero-extended
void avr_cast(i64 ty, i64 d) { avr_fz(d, avr_tw(ty)); }

// The pointer is the low two bytes of the depth -- uptr is two bytes on this
// target, declared by type_set_width in examples/avr/mc-avr.mc. Loading Z from
// a FAR frame slot borrows X and not Z, which is the whole reason X exists.
void avr_load(i64 ty, i64 d) {
    i64 w = avr_tw(ty);
    avr_fld(AR_Z, d, 2);
    ins_add(A_ZLD, AR_ACC, 0, w, 0, 0, 0);
    avr_put(d, w);
}

// the value FIRST (its own frame access may borrow X), then the pointer into Z
void avr_store(i64 ty, i64 d) {
    i64 w = avr_tw(ty);
    avr_fld(AR_ACC, d + 1, w);
    avr_fld(AR_Z, d, 2);
    ins_add(A_ZST, AR_ACC, 0, w, 0, 0, 0);
}

void avr_local_addr(i64 d, i64 off) {
    ins_add(A_FADDR, AR_X, off, 0, 0, 0, 0);
    avr_fst(AR_X, d, 2);
    avr_fz(d, 2);
}

void avr_local_load(i64 ty, i64 d, i64 off) {
    i64 w = avr_tw(ty);
    ins_add(A_FLD, AR_ACC, off, w, 0, 0, 0);
    avr_put(d, w);
}

void avr_local_store(i64 ty, i64 d, i64 off) {
    i64 w = avr_tw(ty);
    avr_fld(AR_ACC, d, w);
    ins_add(A_FST, AR_ACC, off, w, 0, 0, 0);
}

void avr_sym_addr(i64 d, i64 sym) {
    ins_add(A_LDSYM, AR_Z, 0, 0, 0, 0, sym);
    avr_fst(AR_Z, d, 2);
    avr_fz(d, 2);
}

void avr_global_load(i64 ty, i64 d, i64 sym) {
    i64 w = avr_tw(ty);
    ins_add(A_LDSYM, AR_Z, 0, 0, 0, 0, sym);
    ins_add(A_ZLD, AR_ACC, 0, w, 0, 0, 0);
    avr_put(d, w);
}

void avr_global_store(i64 ty, i64 d, i64 sym) {
    i64 w = avr_tw(ty);
    avr_fld(AR_ACC, d, w);
    ins_add(A_LDSYM, AR_Z, 0, 0, 0, 0, sym);
    ins_add(A_ZST, AR_ACC, 0, w, 0, 0, 0);
}

// Every argument is eight bytes in the caller's own frame, so there is no
// register half of the ABI to get wrong and no 9th-argument special case: the
// area simply grows. `dbase + i` is where the walker left argument i.
void avr_args(i64 dbase, i64 na) {
    i64 need = na * 8;
    if (need > avr_out) avr_out = need;
    i64 i = 0;
    while (i < na) {
        avr_fld(AR_ACC, dbase + i, 8);
        ins_add(A_OST, AR_ACC, 1 + i * 8, 8, 0, 0, 0);
        i = i + 1;
    }
}

void avr_call(i64 d, i64 na, i64 sym) {
    avr_args(d, na);
    ins_add(A_CALL, 0, 0, 0, 0, 0, sym);
    avr_fst(AR_ACC, d, 8);                       // the result, all eight bytes
}

// callp(p, a1..a11): the pointer is argument 0 and it moves LAST, after the
// arguments are in place. `icall` jumps to the WORD address in Z and `&f` is a
// byte address like every other pointer in the language, so the halving is
// here and not in the image writer -- examples/avr/README.md § Function
// pointers.
void avr_callp(i64 d, i64 na) {
    avr_args(d + 1, na - 1);
    avr_fld(AR_Z, d, 2);
    e0(A_ZHALF);
    e0(A_ICALL);
    avr_fst(AR_ACC, d, 8);
}

void avr_ret(i64 d)        { avr_fld(AR_ACC, d, 8); }
void avr_jump(i64 l)       { el(A_RJMP, l); }

void avr_jz(i64 d, i64 l) {
    i64 w = avr_dw(d);
    avr_fld(AR_ACC, d, w);
    ins_add(A_TSTZ, AR_ACC, 0, w, 0, 0, 0);
    el(A_JZ, l);
}

void avr_jnz(i64 d, i64 l) {
    i64 w = avr_dw(d);
    avr_fld(AR_ACC, d, w);
    ins_add(A_TSTZ, AR_ACC, 0, w, 0, 0, 0);
    el(A_JNZ, l);
}

void avr_label(i64 l) { el(I_LABEL, l); }

// M40 D8: emit() carries one 16-bit AVR instruction word below 0x10000, and a
// 32-bit one above it, high half first -- which is how a `jmp` or a `call`
// reads in a listing (`0x940c0034`). Nothing in the language can spell a
// four-byte instruction otherwise, and M24's deferred emitb(v, n) stays
// deferred.
void avr_word(i64 w) { ins_add(A_EMIT, 0, 0, 0, w, 0, 0); }

// The two instructions that always carry a relocation of their own. reloc()'s
// R_BRANCH26 (the only kind the surface has for "a symbol in an instruction",
// M39 § G2) is accepted by the image writer as AVRK_CALL22, which is what lets
// examples/avr/lib/isr.mc write a `call` by hand.
i64 avr_reloc_kind(uptr e) {
    i64 op = ins_op(e);
    if (op == A_LDSYM) return AVRK_ADDR16;
    if (op == A_CALL)  return AVRK_CALL22;
    return 0 - 1;
}

i64 avr_reloc_off(uptr e) { return 0; }

// ---- the encoder ----
// One function, and MTASK_INS_SIZE runs it over a scratch buffer: on a machine
// that mixes 2- and 4-byte instructions and whose frame accesses grow by three
// instructions past a 6-bit displacement, a size that disagreed with the
// encoding by two bytes would be an image that boots and then lands mid-word.
i64 avr_reg2(i64 base, i64 rd, i64 rr) {
    return base | ((rr & 0x10) << 5) | ((rd & 0x1f) << 4) | (rr & 0x0f);
}

i64 avr_ldi_w(i64 rd, i64 k)  { return 0xe000 | ((k & 0xf0) << 4) | ((rd - 16) << 4) | (k & 0x0f); }
i64 avr_subi_w(i64 rd, i64 k) { return 0x5000 | ((k & 0xf0) << 4) | ((rd - 16) << 4) | (k & 0x0f); }
i64 avr_sbci_w(i64 rd, i64 k) { return 0x4000 | ((k & 0xf0) << 4) | ((rd - 16) << 4) | (k & 0x0f); }
i64 avr_andi_w(i64 rd, i64 k) { return 0x7000 | ((k & 0xf0) << 4) | ((rd - 16) << 4) | (k & 0x0f); }
i64 avr_one_w(i64 rd, i64 fn) { return 0x9400 | (rd << 4) | fn; }
i64 avr_adiw_w(i64 rd, i64 k) { return 0x9600 | ((k & 0x30) << 2) | (((rd - 24) / 2) << 4) | (k & 0x0f); }
i64 avr_movw_w(i64 rd, i64 rr) { return 0x0100 | ((rd / 2) << 4) | (rr / 2); }
i64 avr_in_w(i64 rd, i64 a)   { return 0xb000 | ((a & 0x30) << 5) | (rd << 4) | (a & 0x0f); }
i64 avr_out_w(i64 a, i64 rr)  { return 0xb800 | ((a & 0x30) << 5) | (rr << 4) | (a & 0x0f); }

// ldd/std: q is six bits, split across bits 13, 11:10 and 2:0; the base is Y
// (bit 3) or Z (bit 3 clear), and there is no X form at all -- which is why a
// far access below goes through post-increment.
i64 avr_ldd_w(i64 rd, i64 y, i64 q, i64 store) {
    return 0x8000 | (store << 9) | (y << 3) | (rd << 4)
           | ((q & 0x20) << 8) | ((q & 0x18) << 7) | (q & 0x07);
}

void avr_e(uptr o, i64 word) { buf_u16(o, word); }

// pair (X or Z) <- Y + q, the address of a frame byte
void avr_put_base(uptr o, i64 pair, i64 q) {
    avr_e(o, avr_movw_w(pair, AR_Y));
    if (q == 0) return;
    if (q <= 63) { avr_e(o, avr_adiw_w(pair, q)); return; }
    i64 neg = (0 - q) & 0xffff;                  // adding q is subtracting -q
    avr_e(o, avr_subi_w(pair, neg & 0xff));
    avr_e(o, avr_sbci_w(pair + 1, (neg >> 8) & 0xff));
}

// A frame access of w bytes at Y displacement q. Inside ldd's six bits it is w
// instructions; past them it is a base in X (or in Z when the value itself is
// X) plus w post-increment accesses.
void avr_put_frame(uptr o, i64 rd, i64 q, i64 w, i64 store) {
    if (q >= 0 && q + w - 1 <= 63) {
        i64 i = 0;
        while (i < w) {
            avr_e(o, avr_ldd_w(rd + i, 1, q + i, store));
            i = i + 1;
        }
        return;
    }
    i64 pair = AR_X;
    if (rd == AR_X) pair = AR_Z;
    avr_put_base(o, pair, q);
    i64 post = 0x900d;                           // ld rd, X+
    if (store) post = 0x920d;                    // st X+, rr
    if (pair == AR_Z) post = post - 0x000c;      // ...Z+ is 0x9001 / 0x9201
    i64 i = 0;
    while (i < w) {
        avr_e(o, post | ((rd + i) << 4));
        i = i + 1;
    }
}

// The same register into n consecutive frame bytes -- the zero-fill of
// decision 2, which would otherwise pay a base setup per byte when the frame
// is past ldd's six bits.
void avr_put_fill(uptr o, i64 rd, i64 q, i64 n) {
    if (n <= 0) return;
    if (q >= 0 && q + n - 1 <= 63) {
        i64 i = 0;
        while (i < n) {
            avr_e(o, avr_ldd_w(rd, 1, q + i, 1));
            i = i + 1;
        }
        return;
    }
    i64 pair = AR_X;
    if (rd == AR_X) pair = AR_Z;
    avr_put_base(o, pair, q);
    i64 post = 0x920d;                           // st X+, rr
    if (pair == AR_Z) post = 0x9201;             // st Z+, rr
    i64 i = 0;
    while (i < n) {
        avr_e(o, post | (rd << 4));
        i = i + 1;
    }
}

// r0 carries SREG across the two `out`s: SPH must be written with interrupts
// off and SPL after SREG is back, which is the sequence avr-gcc emits and the
// only atomic way to move a 16-bit stack pointer.
void avr_put_sp(uptr o) {
    avr_e(o, avr_in_w(AR_R0, IO_SREG));
    avr_e(o, 0x94f8);                            // cli
    avr_e(o, avr_out_w(IO_SPH, AR_Y + 1));
    avr_e(o, avr_out_w(IO_SREG, AR_R0));
    avr_e(o, avr_out_w(IO_SPL, AR_Y));
}

// rjmp's displacement is a SIGNED 12-bit word offset: it reaches 4 KiB either
// way and the field would silently wrap anything further. Only the ENCODE pass
// can check it -- MTASK_INS_SIZE runs with no label vector, and both jump forms
// are fixed width, so the size does not depend on the answer.
//
// There is no `jmp` fallback and there cannot be one here: `jmp` takes an
// ABSOLUTE word address, and at encode time a label is a byte offset inside the
// function -- where the section will sit in flash is examples/avr/image_avr.mc's
// decision, and a relocation names a symbol, not a local label. So +/-4 KiB of
// code per function is this machine's stated reach, and a function past it is a
// diagnostic rather than a wrapped displacement that boots and lands mid-word
// (docs/reference/machine.md § 6, and the M39 review that put the rule there).
i64 avr_rjmp_off(i64 target, i64 here, i64 real) {
    i64 d = (target - (here + 2)) / 2;
    if (real && (d > 2047 || d < 0 - 2048))
        die("avr rjmp out of range: one function's jumps reach +/-4 KiB of code");
    return d;
}

i64 avr_target(uptr lab, i64 l) {
    if (lab == 0) return 0;
    return ivec_at(lab, l);
}

// A shift by a variable count, inline: the count is in r24, masked to 0..63 the
// way every other machine in this repository masks it, and the body is one
// byte-chain per iteration. A count of zero skips the loop.
void avr_put_shift(uptr o, i64 rd, i64 w, i64 dir) {
    avr_e(o, avr_andi_w(AR_CNT, 0x3f));
    avr_e(o, 0xf001 | (((w + 2) & 0x7f) << 3));  // breq past the body when count == 0
    i64 i = 0;
    while (i < w) {
        i64 r = rd + i;                          // left: from the low byte up
        i64 fn = 0;
        if (dir == SH_LEFT) {
            if (i == 0) avr_e(o, avr_reg2(0x0c00, r, r));       // lsl = add r,r
            else        avr_e(o, avr_reg2(0x1c00, r, r));       // rol = adc r,r
        } else {
            r = rd + w - 1 - i;                  // right: from the high byte down
            if (i == 0) {
                if (dir == SH_ASR) fn = 5;       // asr
                else               fn = 6;       // lsr
            } else {
                fn = 7;                          // ror
            }
            avr_e(o, avr_one_w(r, fn));
        }
        i = i + 1;
    }
    avr_e(o, avr_one_w(AR_CNT, 0x0a));           // dec r24
    avr_e(o, 0xf401 | (((0 - (w + 2)) & 0x7f) << 3));   // brne back to the body
}

// r24 = 0 or 1 from the flags a `cp` chain left. `ldi` touches no flag, so the
// value is loaded first and the branch decides whether to clear it.
i64 avr_cc_word(i64 cond) {
    if (cond == MCOND_EQ) return 0xf001;         // breq
    if (cond == MCOND_NE) return 0xf401;         // brne
    if (cond == MCOND_LT) return 0xf00c;         // brlt
    return 0xf40c;                               // brge
}

void avr_put_setcc(uptr o, i64 cond) {
    avr_e(o, avr_ldi_w(AR_CNT, 1));
    avr_e(o, avr_cc_word(cond) | (1 << 3));      // skip the clr when it holds
    avr_e(o, avr_reg2(0x2400, AR_CNT, AR_CNT));  // clr r24 = eor r24, r24
}

// THE encoder. MTASK_ENCODE calls it with the section buffer, MTASK_INS_SIZE
// with a scratch one whose length was reset -- so the bytes the label pass
// reserves are by construction the bytes that get written.
void avr_put_ins(uptr e, i64 pc, uptr lab, uptr o) {
    i64 op = ins_op(e);
    i64 rd = ins_rd(e);
    i64 rn = ins_rn(e);
    i64 w  = ins_rm(e);
    i64 im = ins_imm(e);
    i64 start = buf_len(o);
    if (op == I_LABEL || op == A_NOP) return;
    if (op == A_PRO) {
        avr_e(o, 0x920f | ((AR_Y + 1) << 4));    // push YH
        avr_e(o, 0x920f | (AR_Y << 4));          // push YL
        avr_e(o, avr_in_w(AR_Y, IO_SPL));
        avr_e(o, avr_in_w(AR_Y + 1, IO_SPH));
        return;
    }
    if (op == A_FRAME) {
        if (rn == 0) return;
        if (rn <= 63) {
            avr_e(o, 0x9700 | ((rn & 0x30) << 2) | (((AR_Y - 24) / 2) << 4) | (rn & 0x0f));
        } else {
            avr_e(o, avr_subi_w(AR_Y, rn & 0xff));
            avr_e(o, avr_sbci_w(AR_Y + 1, (rn >> 8) & 0xff));
        }
        avr_put_sp(o);
        return;
    }
    if (op == A_EPI) {
        if (rn != 0) {
            if (rn <= 63) {
                avr_e(o, avr_adiw_w(AR_Y, rn));
            } else {
                i64 neg = (0 - rn) & 0xffff;
                avr_e(o, avr_subi_w(AR_Y, neg & 0xff));
                avr_e(o, avr_sbci_w(AR_Y + 1, (neg >> 8) & 0xff));
            }
            avr_put_sp(o);
        }
        avr_e(o, 0x900f | (AR_Y << 4));          // pop YL
        avr_e(o, 0x900f | ((AR_Y + 1) << 4));    // pop YH
        avr_e(o, 0x9508);                        // ret
        return;
    }
    if (op == A_FLD)   { avr_put_frame(o, rd, rn, w, 0); return; }
    if (op == A_FST)   { avr_put_frame(o, rd, rn, w, 1); return; }
    if (op == A_OST)   { avr_put_frame(o, rd, rn, w, 1); return; }
    if (op == A_FZ) {
        avr_e(o, avr_reg2(0x2400, AR_CNT, AR_CNT));          // clr r24
        avr_put_fill(o, AR_CNT, rn + im, w - im);
        return;
    }
    if (op == A_KST) {
        i64 i = 0;
        i64 last = 0 - 1;
        while (i < w) {
            i64 b = (im >> (i * 8)) & 0xff;
            if (b != last) { avr_e(o, avr_ldi_w(AR_CNT, b)); last = b; }
            avr_put_frame(o, AR_CNT, rn + i, 1, 1);
            i = i + 1;
        }
        return;
    }
    if (op == A_FADDR) { avr_put_base(o, rd, rn); return; }
    if (op == A_LDSYM) {                         // patched by the image writer
        avr_e(o, avr_ldi_w(rd, 0));
        avr_e(o, avr_ldi_w(rd + 1, 0));
        return;
    }
    if (op == A_ZLD || op == A_ZST) {
        i64 store = 0;
        if (op == A_ZST) store = 1;
        i64 i = 0;
        while (i < w) {
            avr_e(o, avr_ldd_w(rd + i, 0, i, store));
            i = i + 1;
        }
        return;
    }
    if (op == A_ALU) {
        i64 i = 0;
        while (i < w) {
            i64 base = avr_alu2_at(im);
            if (i == 0) base = avr_alu1_at(im);
            avr_e(o, avr_reg2(base, rd + i, rn + i));
            i = i + 1;
        }
        return;
    }
    if (op == A_COM) {
        i64 i = 0;
        while (i < w) {
            avr_e(o, avr_one_w(rd + i, 0));
            i = i + 1;
        }
        return;
    }
    if (op == A_NEG) {
        // neg on the low byte, com above it, then sbci -1 to carry the +1 up:
        // the classic AVR multi-byte negate
        avr_e(o, avr_one_w(rd, 1));
        i64 i = 1;
        while (i < w) {
            avr_e(o, avr_one_w(rd + i, 0));
            i = i + 1;
        }
        i = 1;
        while (i < w) {
            avr_e(o, avr_sbci_w(rd + i, 0xff));
            i = i + 1;
        }
        return;
    }
    if (op == A_SHIFT) { avr_put_shift(o, rd, w, im); return; }
    if (op == A_SETCC) { avr_put_setcc(o, im); return; }
    if (op == A_TSTZ) {
        // `mov` sets NO flag on an AVR, and `or` sets Z -- so a one-byte test
        // needs a `tst` (= and r0, r0) after the move, and a wider one gets Z
        // from its last `or` for free. Getting this wrong is a loop that never
        // ends and an image that boots: it cost this milestone an afternoon.
        avr_e(o, avr_reg2(0x2c00, AR_R0, rd));   // mov r0, rd
        i64 i = 1;
        while (i < w) {
            avr_e(o, avr_reg2(0x2800, AR_R0, rd + i));   // or r0, rd+i
            i = i + 1;
        }
        if (w == 1) avr_e(o, avr_reg2(0x2000, AR_R0, AR_R0));   // tst r0
        return;
    }
    if (op == A_JZ || op == A_JNZ) {
        i64 br = 0xf401;                         // brne: skip the rjmp
        if (op == A_JNZ) br = 0xf001;            // breq
        avr_e(o, br | (1 << 3));
        i64 here = pc + (buf_len(o) - start);
        avr_e(o, 0xc000 | (avr_rjmp_off(avr_target(lab, ins_label(e)), here, lab != 0) & 0x0fff));
        return;
    }
    if (op == A_RJMP) {
        avr_e(o, 0xc000 | (avr_rjmp_off(avr_target(lab, ins_label(e)), pc, lab != 0) & 0x0fff));
        return;
    }
    if (op == A_CALL)  { avr_e(o, 0x940e); avr_e(o, 0); return; }
    if (op == A_ICALL) { avr_e(o, 0x9509); return; }
    if (op == A_ZHALF) {
        avr_e(o, avr_one_w(AR_Z + 1, 6));        // lsr ZH
        avr_e(o, avr_one_w(AR_Z, 7));            // ror ZL
        return;
    }
    if (op == A_LPM)   { avr_e(o, 0x9004 | (rd << 4)); return; }
    if (op == A_EMIT) {
        if (im < 0x10000) { avr_e(o, im); return; }
        avr_e(o, (im >> 16) & 0xffff);
        avr_e(o, im & 0xffff);
        return;
    }
    die("avr instruction with no encoder");
}

i64 avr_ins_size(uptr e) {
    set_buf_len(avr_tmpbuf, 0);
    avr_put_ins(e, 0, 0, avr_tmpbuf);
    return buf_len(avr_tmpbuf);
}

// ---- text dump ----
// One line per Ins, which is one line per MACRO -- `fld acc, 12(fp), 8` is
// eight `ldd`s. The byte-level oracle is examples/avr/test.sh's llvm-mc sweep
// over the image, not this text; what the dump is for is the ABI assertions and
// reading what the machine decided.
void avrd_num(i64 v) {
    if (v < 0) { out_str(1, "-"); out_num(1, 0 - v); return; }
    out_num(1, v);
}

void avrd_reg(i64 r) {
    if (r == AR_ACC) { out_str(1, "acc"); return; }
    if (r == AR_TMP) { out_str(1, "tmp"); return; }
    if (r == AR_X)   { out_str(1, "X");   return; }
    if (r == AR_Y)   { out_str(1, "Y");   return; }
    if (r == AR_Z)   { out_str(1, "Z");   return; }
    out_str(1, "r");
    out_num(1, r);
}

void avrd_head(uptr m) { out_str(1, "  "); out_str(1, m); out_str(1, " "); }

// After MTASK_FRAME_FIX every frame reference is a Y displacement and nothing
// else, so that is what the dump prints -- the same number the `ldd`/`std` will
// carry, and the number examples/avr/test.sh asserts the 63-byte edge against.
void avrd_slot(i64 rn) {
    out_str(1, "[Y+");
    avrd_num(rn);
    out_str(1, "]");
}

void avrd_w(i64 w) { out_str(1, ".u"); out_num(1, w * 8); }

void avr_dump(uptr in) {
    i64 op = ins_op(in);
    i64 rd = ins_rd(in);
    i64 rn = ins_rn(in);
    i64 w  = ins_rm(in);
    i64 im = ins_imm(in);
    if (op == A_NOP) return;
    if (op == I_LABEL) { out_str(1, "L"); out_num(1, ins_label(in)); out_str(1, ":\n"); return; }
    if (op == A_PRO)   { out_str(1, "  prologue\n"); return; }
    if (op == A_FRAME) { avrd_head("frame"); avrd_num(rn); out_str(1, "\n"); return; }
    if (op == A_EPI)   { avrd_head("epilogue"); avrd_num(rn); out_str(1, "\n"); return; }
    if (op == A_FLD)   { avrd_head("fld"); avrd_reg(rd); avrd_w(w); out_str(1, ", ");
                         avrd_slot(rn); out_str(1, "\n"); return; }
    if (op == A_FST)   { avrd_head("fst"); avrd_slot(rn); out_str(1, ", ");
                         avrd_reg(rd); avrd_w(w); out_str(1, "\n"); return; }
    if (op == A_OST)   { avrd_head("arg"); out_str(1, "[Y+"); avrd_num(rn);
                         out_str(1, "], "); avrd_reg(rd); avrd_w(w); out_str(1, "\n"); return; }
    if (op == A_FZ)    { avrd_head("fzero"); avrd_slot(rn); out_str(1, ", ");
                         avrd_num(im); out_str(1, "..8\n"); return; }
    if (op == A_KST)   { avrd_head("kst"); avrd_slot(rn); out_str(1, ", ");
                         avrd_num(im); out_str(1, "\n"); return; }
    if (op == A_FADDR) { avrd_head("addr"); avrd_reg(rd); out_str(1, ", ");
                         avrd_slot(rn); out_str(1, "\n"); return; }
    if (op == A_LDSYM) { avrd_head("ldsym"); avrd_reg(rd); out_str(1, ", ");
                         out_str(1, sym_name(sym_at(ins_sym(in)))); out_str(1, "\n"); return; }
    if (op == A_ZLD)   { avrd_head("ld"); avrd_reg(rd); avrd_w(w); out_str(1, ", [Z]\n"); return; }
    if (op == A_ZST)   { avrd_head("st"); out_str(1, "[Z], "); avrd_reg(rd);
                         avrd_w(w); out_str(1, "\n"); return; }
    if (op == A_ALU)   { avrd_head(avr_aluname_at(im)); avrd_reg(rd); avrd_w(w);
                         out_str(1, ", "); avrd_reg(rn); out_str(1, "\n"); return; }
    if (op == A_COM)   { avrd_head("com"); avrd_reg(rd); avrd_w(w); out_str(1, "\n"); return; }
    if (op == A_NEG)   { avrd_head("neg"); avrd_reg(rd); avrd_w(w); out_str(1, "\n"); return; }
    if (op == A_SHIFT) {
        uptr m = "shl";
        if (im == SH_LSR) m = "shr";
        if (im == SH_ASR) m = "sar";
        avrd_head(m); avrd_reg(rd); avrd_w(w); out_str(1, ", r24\n");
        return;
    }
    if (op == A_SETCC) { avrd_head("setcc"); avrd_num(im); out_str(1, "\n"); return; }
    if (op == A_TSTZ)  { avrd_head("tst"); avrd_reg(rd); avrd_w(w); out_str(1, "\n"); return; }
    if (op == A_JZ)    { avrd_head("jz"); out_str(1, "L"); out_num(1, ins_label(in));
                         out_str(1, "\n"); return; }
    if (op == A_JNZ)   { avrd_head("jnz"); out_str(1, "L"); out_num(1, ins_label(in));
                         out_str(1, "\n"); return; }
    if (op == A_RJMP)  { avrd_head("rjmp"); out_str(1, "L"); out_num(1, ins_label(in));
                         out_str(1, "\n"); return; }
    if (op == A_CALL)  { avrd_head("call"); out_str(1, sym_name(sym_at(ins_sym(in))));
                         out_str(1, "\n"); return; }
    if (op == A_ICALL) { out_str(1, "  icall\n"); return; }
    if (op == A_ZHALF) { out_str(1, "  zhalf\n"); return; }
    if (op == A_LPM)   { avrd_head("lpm"); avrd_reg(rd); out_str(1, ", [Z]\n"); return; }
    if (op == A_EMIT) {
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
    die("avr instruction with no dump");
}

// ---- lpm: the one intrinsic this target cannot do without ----
// Flash is not SRAM (Harvard), and the startup copy in examples/avr/lib/
// sys_avr.mc has to read the initialized data out of flash. `lpm8(p)` is that
// read, registered with M24's intrinsic(): its argument arrives at depth d
// already lowered, and the handler is the machine's own three instructions.
void avr_lpm8(i64 d, i64 nargs) {
    avr_fld(AR_Z, d, 2);
    ins_add(A_LPM, AR_ACC, 0, 1, 0, 0, 0);
    avr_put(d, 1);
}

// ---- registration ----
// Its own two-line setter, for the reason docs/reference/hooks.md records:
// machine_task (src/machine_arm64.mc) writes m_arm64 BY NAME.
void avr_task(i64 task, uptr fn) { st64(m_avr + task * 8, fn); }

void machine_avr_init() {
    avr_task(MTASK_PROLOGUE,     &avr_prologue);
    avr_task(MTASK_PARAM,        &avr_param);
    avr_task(MTASK_EPILOGUE,     &avr_epilogue);
    avr_task(MTASK_FRAME_FIX,    &avr_frame_fix);
    avr_task(MTASK_CONST,        &avr_const);
    avr_task(MTASK_BIN,          &avr_bin);
    avr_task(MTASK_CMP,          &avr_cmp);
    avr_task(MTASK_UN,           &avr_un);
    avr_task(MTASK_BOOL,         &avr_bool);
    avr_task(MTASK_CAST,         &avr_cast);
    avr_task(MTASK_LOAD,         &avr_load);
    avr_task(MTASK_STORE,        &avr_store);
    avr_task(MTASK_LOCAL_ADDR,   &avr_local_addr);
    avr_task(MTASK_LOCAL_LOAD,   &avr_local_load);
    avr_task(MTASK_LOCAL_STORE,  &avr_local_store);
    avr_task(MTASK_SYM_ADDR,     &avr_sym_addr);
    avr_task(MTASK_GLOBAL_LOAD,  &avr_global_load);
    avr_task(MTASK_GLOBAL_STORE, &avr_global_store);
    avr_task(MTASK_CALL,         &avr_call);
    avr_task(MTASK_CALLP,        &avr_callp);
    avr_task(MTASK_RET,          &avr_ret);
    avr_task(MTASK_JUMP,         &avr_jump);
    avr_task(MTASK_JZ,           &avr_jz);
    avr_task(MTASK_JNZ,          &avr_jnz);
    avr_task(MTASK_LABEL,        &avr_label);
    avr_task(MTASK_WORD,         &avr_word);
    avr_task(MTASK_INS_SIZE,     &avr_ins_size);
    avr_task(MTASK_ENCODE,       &avr_put_ins);
    avr_task(MTASK_DUMP,         &avr_dump);
    avr_task(MTASK_RELOC_KIND,   &avr_reloc_kind);
    avr_task(MTASK_RELOC_OFF,    &avr_reloc_off);
    machine("avr", m_avr);
    intrinsic("lpm8", 1, TY_U8, &avr_lpm8);
}
