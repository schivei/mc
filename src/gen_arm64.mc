// gen_arm64.mc — transliteration of stage0/gen_arm64.c: linear instruction
// buffer per function + AArch64 encoders. The AST becomes Ins[]; gen_encode
// resolves local labels, registers relocations and writes words to __text.
// --dump-asm prints the buffer before encoding. Locals, parameters,
// saves and spills live in the frame. Instructions come out with the fictitious
// base REG_FRAME and a negative offset from x29; after walking the whole
// function, fix_frame swaps the base for sp and the offset for
// (frame - off) — which is why the frame can be computed at the end.
// Same functions, same order, same I/O shape.
//
// No struct: each C record becomes a flat block with #define offsets +
// accessors. Layouts derived from stage0/mc.h (current C version):
//
//   C: typedef struct { int op, rd, rn, rm; i64 imm; int label, sym; } Ins;
//      INS_OP 0  INS_RD 8  INS_RN 16  INS_RM 24  INS_IMM 32
//      INS_LABEL 40  INS_SYM 48                          -> INS_SIZE 56
//   C: typedef struct { const char *name; int type, off, nelem; } Local;
//      LOC_NAME 0  LOC_TYPE 8  LOC_OFF 16  LOC_NELEM 24  -> LOC_SIZE 32
//   C: typedef struct { const char *name; int type, nelem, sym; } Global;
//      GLB_NAME 0  GLB_TYPE 8  GLB_NELEM 16  GLB_SYM 24  -> GLB_SIZE 32
//   C: typedef struct { const char *bytes; int len, sym; } StrEnt;
//      STR_BYTES 0  STR_LEN 8  STR_SYM 16                -> STR_SIZE 24
//   C: typedef struct { const char *name; int type, nparams, def, node; } FuncSig;
//      FS_NAME 0  FS_TYPE 8  FS_NPARAMS 16  FS_DEF 24  FS_NODE 32 -> FS_SIZE 40
//
// Three renames forced by the lack of static scope in .mc (C uses
// `static`, here every name is global and macho.mc comes first):
//   sec_text/sec_cstr/sec_data/sec_bss -> isec_text/isec_cstr/isec_data/isec_bss
//     (sec_data is already the accessor for Section's inline Buf in macho.mc)
//   rel_pcrel(type)/rel_len(type)      -> relt_pcrel/relt_len
//     (rel_pcrel/rel_len are already the Reloc accessors in macho.mc)
// C's forward declarations (gen_expr, gen_stmt, str_sym) are not
// needed: the top of the .mc registers every signature before the bodies.
//
// MAXPARAMS and MAXSECS come from parse.mc, as they came from mc.h.
// Depends on arena.mc (xalloc, cstrlen, str_eq, mem_eq, mem_copy, buf_*,
// out_*, die), on ast.mc (nodes, err_node, type_width), on parse.mc (opc_find,
// opc_expand, sec_pending, sec_make) and on macho.mc (sections, symbols,
// relocations).

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
#define MAXDEPTH  64
#define MAXLOCALS 256
#define MAXFUNCS  1024
#define MAXLOOPS  32
#define MAXGLOBALS 256
#define MAXSTRS    512
#define MAXPREL   512                 // reloc() relocations for the whole module

// ---- full plan enum; the encoder only implements what it uses ----
#define I_LABEL    0
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

// ---- intrinsics (name, not symbol); the memory ones and the raw-output ones ----
#define IN_NONE  0
#define IN_EMIT  1
#define IN_RELOC 2
#define IN_CALLP 3
#define IN_LD8   4
#define IN_LD16  5
#define IN_LD32  6
#define IN_LD64  7
#define IN_ST8   8
#define IN_ST16  9
#define IN_ST32 10
#define IN_ST64 11

// ---- Ins ----
#define INS_OP    0
#define INS_RD    8
#define INS_RN   16
#define INS_RM   24
#define INS_IMM  32
#define INS_LABEL 40
#define INS_SYM  48
#define INS_SIZE 56

// ---- Local: address = x29 - off; nelem > 0 marks an array ----
#define LOC_NAME  0
#define LOC_TYPE  8
#define LOC_OFF  16
#define LOC_NELEM 24
#define LOC_SIZE 32

// ---- Global: own symbol in __data or __bss; nelem > 0 marks an array ----
#define GLB_NAME  0
#define GLB_TYPE  8
#define GLB_NELEM 16
#define GLB_SYM  24
#define GLB_SIZE 32

// ---- StrEnt: literal already emitted in __cstring, to deduplicate by content ----
#define STR_BYTES 0
#define STR_LEN   8
#define STR_SYM  16
#define STR_SIZE 24

// ---- FuncSig: file signature (N_FUNC, N_EXTERN or N_PROTO). def = 0
// while there is only a prototype; node is the node that declared it (for the final error) ----
#define FS_NAME    0
#define FS_TYPE    8
#define FS_NPARAMS 16
#define FS_DEF    24
#define FS_NODE   32
#define FS_SIZE   40

uptr ibuf;
i64  nins = 0;
i64  inscap = 0;
i64  nlabels = 0;

// ---- current function state ----
u8  locals[MAXLOCALS * LOC_SIZE];
i64 nlocals = 0;
i64 dslot[MAXDEPTH];                  // slot for the depth: save (<=6) or spill (>=7)
i64 frame_off = 0;
i64 lbreak[MAXLOOPS];
i64 lcont[MAXLOOPS];
i64 nloops = 0;
// reloc(): the relocation stays pending until the next raw word (gen_word)
i64 prel_ins[MAXPREL];
i64 prel_sym[MAXPREL];
i64 prel_type[MAXPREL];
i64 nprel = 0;
i64 pend_type = -1;
i64 pend_sym = 0;
i64 pend_node = 0;

// ---- functions already lowered: ibuf is append-only and each function is a slice of it ----
i64 fn_start[MAXFUNCS];
i64 fn_count[MAXFUNCS];
i64 fn_labels[MAXFUNCS];
i64 fn_sec[MAXFUNCS];
i64 fn_sym[MAXFUNCS];
i64 fn_pstart[MAXFUNCS];
i64 fn_pcount[MAXFUNCS];
i64 nfn = 0;
i64 ins_base = 0;                     // start of the current function in ibuf
i64 prel_base = 0;                    // start of the current function in prel_*

// signatures for the whole file (N_FUNC and N_EXTERN), registered before the bodies
u8  funcs[MAXFUNCS * FS_SIZE];
i64 nfuncs = 0;

// ---- module state: globals, strings and the sections in fixed order ----
u8  globals[MAXGLOBALS * GLB_SIZE];
i64 nglobals = 0;
u8  strs[MAXSTRS * STR_SIZE];
i64 nstrs = 0;
i64 isec_text = 0;                    // -1 = section not created
i64 isec_cstr = 0;
i64 isec_data = 0;
i64 isec_bss  = 0;
i64 secmap[MAXSECS];                  // parser's #section i -> real section

// ---- Ins accessors ----
uptr ins_at(i64 i)     { return ibuf + i * INS_SIZE; }
i64  ins_op(uptr e)    { return ld64(e + INS_OP); }
i64  ins_rd(uptr e)    { return ld64(e + INS_RD); }
i64  ins_rn(uptr e)    { return ld64(e + INS_RN); }
i64  ins_rm(uptr e)    { return ld64(e + INS_RM); }
i64  ins_imm(uptr e)   { return ld64(e + INS_IMM); }
i64  ins_label(uptr e) { return ld64(e + INS_LABEL); }
i64  ins_sym(uptr e)   { return ld64(e + INS_SYM); }
void set_ins_op(uptr e, i64 v)    { st64(e + INS_OP, v); }
void set_ins_rd(uptr e, i64 v)    { st64(e + INS_RD, v); }
void set_ins_rn(uptr e, i64 v)    { st64(e + INS_RN, v); }
void set_ins_rm(uptr e, i64 v)    { st64(e + INS_RM, v); }
void set_ins_imm(uptr e, i64 v)   { st64(e + INS_IMM, v); }
void set_ins_label(uptr e, i64 v) { st64(e + INS_LABEL, v); }
void set_ins_sym(uptr e, i64 v)   { st64(e + INS_SYM, v); }

// ---- Local accessors ----
uptr loc_at(i64 i)     { return locals + i * LOC_SIZE; }
uptr loc_name(uptr e)  { return ld64(e + LOC_NAME); }
i64  loc_type(uptr e)  { return ld64(e + LOC_TYPE); }
i64  loc_off(uptr e)   { return ld64(e + LOC_OFF); }
i64  loc_nelem(uptr e) { return ld64(e + LOC_NELEM); }
void set_loc_name(uptr e, uptr v)  { st64(e + LOC_NAME, v); }
void set_loc_type(uptr e, i64 v)   { st64(e + LOC_TYPE, v); }
void set_loc_off(uptr e, i64 v)    { st64(e + LOC_OFF, v); }
void set_loc_nelem(uptr e, i64 v)  { st64(e + LOC_NELEM, v); }

// ---- Global accessors ----
uptr glb_at(i64 i)     { return globals + i * GLB_SIZE; }
uptr glb_name(uptr e)  { return ld64(e + GLB_NAME); }
i64  glb_type(uptr e)  { return ld64(e + GLB_TYPE); }
i64  glb_nelem(uptr e) { return ld64(e + GLB_NELEM); }
i64  glb_sym(uptr e)   { return ld64(e + GLB_SYM); }
void set_glb_name(uptr e, uptr v)  { st64(e + GLB_NAME, v); }
void set_glb_type(uptr e, i64 v)   { st64(e + GLB_TYPE, v); }
void set_glb_nelem(uptr e, i64 v)  { st64(e + GLB_NELEM, v); }
void set_glb_sym(uptr e, i64 v)    { st64(e + GLB_SYM, v); }

// ---- StrEnt accessors ----
uptr ste_at(i64 i)     { return strs + i * STR_SIZE; }
uptr ste_bytes(uptr e) { return ld64(e + STR_BYTES); }
i64  ste_len(uptr e)   { return ld64(e + STR_LEN); }
i64  ste_sym(uptr e)   { return ld64(e + STR_SYM); }
void set_ste_bytes(uptr e, uptr v) { st64(e + STR_BYTES, v); }
void set_ste_len(uptr e, i64 v)    { st64(e + STR_LEN, v); }
void set_ste_sym(uptr e, i64 v)    { st64(e + STR_SYM, v); }

// ---- FuncSig accessors ----
uptr fs_at(i64 i)       { return funcs + i * FS_SIZE; }
uptr fs_name(uptr e)    { return ld64(e + FS_NAME); }
i64  fs_type(uptr e)    { return ld64(e + FS_TYPE); }
i64  fs_nparams(uptr e) { return ld64(e + FS_NPARAMS); }
i64  fs_def(uptr e)     { return ld64(e + FS_DEF); }
i64  fs_node(uptr e)    { return ld64(e + FS_NODE); }
void set_fs_name(uptr e, uptr v)    { st64(e + FS_NAME, v); }
void set_fs_type(uptr e, i64 v)     { st64(e + FS_TYPE, v); }
void set_fs_nparams(uptr e, i64 v)  { st64(e + FS_NPARAMS, v); }
void set_fs_def(uptr e, i64 v)      { st64(e + FS_DEF, v); }
void set_fs_node(uptr e, i64 v)     { st64(e + FS_NODE, v); }

// ---- accessors for the module's flat i64 vectors ----
i64  dslot_at(i64 i)      { return ld64(dslot + i * 8); }
void set_dslot_at(i64 i, i64 v) { st64(dslot + i * 8, v); }
i64  lbreak_at(i64 i)     { return ld64(lbreak + i * 8); }
void set_lbreak_at(i64 i, i64 v) { st64(lbreak + i * 8, v); }
i64  lcont_at(i64 i)      { return ld64(lcont + i * 8); }
void set_lcont_at(i64 i, i64 v) { st64(lcont + i * 8, v); }
i64  prel_ins_at(i64 i)   { return ld64(prel_ins + i * 8); }
void set_prel_ins_at(i64 i, i64 v) { st64(prel_ins + i * 8, v); }
i64  prel_sym_at(i64 i)   { return ld64(prel_sym + i * 8); }
void set_prel_sym_at(i64 i, i64 v) { st64(prel_sym + i * 8, v); }
i64  prel_type_at(i64 i)  { return ld64(prel_type + i * 8); }
void set_prel_type_at(i64 i, i64 v) { st64(prel_type + i * 8, v); }
i64  secmap_at(i64 i)     { return ld64(secmap + i * 8); }
void set_secmap_at(i64 i, i64 v) { st64(secmap + i * 8, v); }
i64  fn_start_at(i64 i)   { return ld64(fn_start + i * 8); }
void set_fn_start_at(i64 i, i64 v) { st64(fn_start + i * 8, v); }
i64  fn_count_at(i64 i)   { return ld64(fn_count + i * 8); }
void set_fn_count_at(i64 i, i64 v) { st64(fn_count + i * 8, v); }
i64  fn_labels_at(i64 i)  { return ld64(fn_labels + i * 8); }
void set_fn_labels_at(i64 i, i64 v) { st64(fn_labels + i * 8, v); }
i64  fn_sec_at(i64 i)     { return ld64(fn_sec + i * 8); }
void set_fn_sec_at(i64 i, i64 v) { st64(fn_sec + i * 8, v); }
i64  fn_sym_at(i64 i)     { return ld64(fn_sym + i * 8); }
void set_fn_sym_at(i64 i, i64 v) { st64(fn_sym + i * 8, v); }
i64  fn_pstart_at(i64 i)  { return ld64(fn_pstart + i * 8); }
void set_fn_pstart_at(i64 i, i64 v) { st64(fn_pstart + i * 8, v); }
i64  fn_pcount_at(i64 i)  { return ld64(fn_pcount + i * 8); }
void set_fn_pcount_at(i64 i, i64 v) { st64(fn_pcount + i * 8, v); }
// i64 vectors that gen_encode allocates in the arena (off and lab)
i64  ivec_at(uptr v, i64 i)          { return ld64(v + i * 8); }
void set_ivec_at(uptr v, i64 i, i64 x) { st64(v + i * 8, x); }

// ---- buffer ----
void ins_add(i64 op, i64 rd, i64 rn, i64 rm, i64 imm, i64 label, i64 sym) {
    // the pending relocation only sticks to the raw word that gen_word puts in the
    // buffer; a label does not become a word and is transparent, everything else is an error
    if (pend_type >= 0 && op != I_LABEL) err_node(pend_node, "reloc without an immediately following emit");
    if (nins == inscap) {
        i64 cap = 256;
        if (inscap) cap = inscap * 2;
        uptr np = xalloc(INS_SIZE * cap);
        mem_copy(np, ibuf, nins * INS_SIZE);
        ibuf = np;
        inscap = cap;
    }
    uptr e = ins_at(nins);
    set_ins_op(e, op);
    set_ins_rd(e, rd);
    set_ins_rn(e, rn);
    set_ins_rm(e, rm);
    set_ins_imm(e, imm);
    set_ins_label(e, label);
    set_ins_sym(e, sym);
    nins = nins + 1;
}

void e0(i64 op)                          { ins_add(op, 0, 0, 0, 0, 0, 0); }
void e2(i64 op, i64 rd, i64 rn)          { ins_add(op, rd, rn, 0, 0, 0, 0); }
void e3(i64 op, i64 rd, i64 rn, i64 rm)  { ins_add(op, rd, rn, rm, 0, 0, 0); }
void ei(i64 op, i64 rd, i64 rn, i64 imm) { ins_add(op, rd, rn, 0, imm, 0, 0); }
void el(i64 op, i64 label)               { ins_add(op, 0, 0, 0, 0, label, 0); }
void elr(i64 op, i64 rd, i64 label)      { ins_add(op, rd, 0, 0, 0, label, 0); }
void em(i64 op, i64 rt, i64 rn, i64 off) { ins_add(op, rt, rn, 0, off, 0, 0); }

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

// ---- frame, depth and spill ----
i64 slot_new(i64 size) {              // returns the positive offset from x29
    frame_off = frame_off + ((size + 7) & ~7);
    return frame_off;
}

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

i64  rrr_ins_at(i64 i)   { return ld64(rrr_ins + i * 8); }
i64  rrr_base_at(i64 i)  { return ld32(rrr_base + i * 4); }
uptr rrr_name_at(i64 i)  { return ld64(rrr_name + i * 8); }
i64  mem_ins_at(i64 i)   { return ld64(mem_ins + i * 8); }
i64  mem_base_at(i64 i)  { return ld32(mem_base + i * 4); }
i64  mem_scale_at(i64 i) { return ld64(mem_scale + i * 8); }
uptr mem_name_at(i64 i)  { return ld64(mem_name + i * 8); }

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

// ---- locals (flat stack, size mark per block) ----
i64 local_find(uptr name) {
    i64 i = nlocals - 1;
    loop {
        if (i < 0) break;
        if (str_eq(loc_name(loc_at(i)), name)) return i;
        i = i - 1;
    }
    return -1;
}

void local_add(uptr name, i64 type, i64 off, i64 nelem) {
    if (nlocals == MAXLOCALS) die("too many locals");
    uptr e = loc_at(nlocals);
    set_loc_name(e, name);
    set_loc_type(e, type);
    set_loc_off(e, off);
    set_loc_nelem(e, nelem);
    nlocals = nlocals + 1;
}

// ---- signatures ----
i64 func_find(uptr name) {
    i64 i = 0;
    loop {
        if (i >= nfuncs) break;
        if (str_eq(fs_name(fs_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

// def = 1 for N_FUNC/N_EXTERN, 0 for a prototype; the prototype only reserves the
// signature and the later definition must match it
void func_add(uptr name, i64 type, i64 nparams, i64 def, i64 n) {
    i64 i = func_find(name);
    if (i >= 0) {
        uptr e = fs_at(i);
        if (fs_def(e) && def) err_node(n, "function declared twice");
        if (fs_type(e) != type || fs_nparams(e) != nparams)
            err_node(n, "declaration does not match prototype");
        if (def) { set_fs_def(e, 1); set_fs_node(e, n); }
        return;
    }
    if (nfuncs == MAXFUNCS) die("too many functions");
    uptr ne = fs_at(nfuncs);
    set_fs_name(ne, name);
    set_fs_type(ne, type);
    set_fs_nparams(ne, nparams);
    set_fs_def(ne, def);
    set_fs_node(ne, n);
    nfuncs = nfuncs + 1;
}

uptr usym(uptr name) {                // the compiler prefixes _
    i64 n = cstrlen(name);
    uptr s = xalloc(n + 2);
    st8(s, '_');
    i64 i = 0;
    loop {
        if (i >= n) break;
        st8(s + i + 1, ld8(name + i));
        i = i + 1;
    }
    st8(s + n + 1, 0);
    return s;
}

// ---- globals: own local symbol in __data (with a value) or __bss (zeroed) ----
i64 global_find(uptr name) {
    i64 i = 0;
    loop {
        if (i >= nglobals) break;
        if (str_eq(glb_name(glb_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

// Places global g (size bytes) in section sec and returns the offset.
// Zerofill just counts bytes (everything starts and occupies a multiple of 16); in the
// others each initializer element comes out at the type's width and the rest is
// zeroed — which is why an array in a non-zerofill custom section takes up space in the file.
i64 glob_place(i64 g, i64 sec, i64 size, i64 width) {
    uptr sp = sec_at(sec);
    if ((sec_flags(sp) & 0xff) == S_ZEROFILL) {
        i64 zoff = (sec_zsize(sp) + 15) & ~15;
        set_sec_zsize(sp, zoff + ((size + 15) & ~15));
        return zoff;
    }
    uptr b = sec_data(sp);
    i64 al = width;                              // array at 16, scalar at the width
    if (nd_val(g)) al = 16;
    buf_pad(b, al);
    i64 off = buf_len(b);
    i64 e = nd_a(g);
    loop {
        if (e == 0) break;
        if (nd_kind(e) == N_STR) {               // pointer to l_strN: 8 zeros + R_UNSIGNED
            reloc_add(sec, buf_len(b), str_sym(nd_name(e), nd_val(e)), R_UNSIGNED, 0, 3);
            buf_u64(b, 0);
        } else {
            i64 v = nd_val(e);
            if (width == 1)      buf_u8(b, v);
            else if (width == 2) buf_u16(b, v);
            else if (width == 4) buf_u32(b, v);
            else                 buf_u64(b, v);
        }
        e = nd_next(e);
    }
    loop {
        if (buf_len(b) - off >= size) break;
        buf_u8(b, 0);
    }
    return off;
}

// ---- strings: bytes + NUL in __cstring, local symbol l_str<N> ----
uptr str_name(i64 n) {
    u8 tmp[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + n % 10);
        n = n / 10;
        if (n == 0) break;
    }
    uptr s = xalloc(32);
    st8(s, 'l');
    st8(s + 1, '_');
    st8(s + 2, 's');
    st8(s + 3, 't');
    st8(s + 4, 'r');
    i64 k = 5;
    loop {
        if (i >= 24) break;
        st8(s + k, ld8(tmp + i));
        k = k + 1;
        i = i + 1;
    }
    st8(s + k, 0);
    return s;
}

// deduplicates by content (linear search); N follows the order of first occurrence
i64 str_sym(uptr bytes, i64 len) {
    i64 i = 0;
    loop {
        if (i >= nstrs) break;
        uptr old = ste_at(i);
        if (ste_len(old) == len && mem_eq(ste_bytes(old), bytes, len)) return ste_sym(old);
        i = i + 1;
    }
    if (nstrs == MAXSTRS) die("too many strings");
    uptr b = sec_data(sec_at(isec_cstr));
    i64 off = buf_len(b);
    buf_put(b, bytes, len);
    buf_u8(b, 0);                                // __cstring keeps each literal NUL-terminated
    i64 sym = sym_new(str_name(nstrs), isec_cstr + 1, off, 0);
    uptr e = ste_at(nstrs);
    set_ste_bytes(e, bytes);
    set_ste_len(e, len);
    set_ste_sym(e, sym);
    nstrs = nstrs + 1;
    return sym;
}

// address of a local symbol: adrp of the page + add of the offset
void gen_gaddr(i64 rd, i64 sym) {
    ins_add(I_ADRP,  rd, 0,  0, 0, 0, sym);
    ins_add(I_ADDLO, rd, rd, 0, 0, 0, sym);
}

i64 intrin_id(uptr name) {
    if (str_eq(name, "emit"))  return IN_EMIT;
    if (str_eq(name, "reloc")) return IN_RELOC;
    if (str_eq(name, "callp")) return IN_CALLP;
    if (str_eq(name, "ld8"))  return IN_LD8;
    if (str_eq(name, "ld16")) return IN_LD16;
    if (str_eq(name, "ld32")) return IN_LD32;
    if (str_eq(name, "ld64")) return IN_LD64;
    if (str_eq(name, "st8"))  return IN_ST8;
    if (str_eq(name, "st16")) return IN_ST16;
    if (str_eq(name, "st32")) return IN_ST32;
    if (str_eq(name, "st64")) return IN_ST64;
    return IN_NONE;
}

// type of the accessed width; also the type of the ld* result
i64 intrin_type(i64 in) {
    if (in == IN_LD8  || in == IN_ST8)  return TY_U8;
    if (in == IN_LD16 || in == IN_ST16) return TY_U16;
    if (in == IN_LD32 || in == IN_ST32) return TY_U32;
    return TY_U64;
}

// ---- expressions ----
void gen_value(i64 n, i64 depth) {    // where a value is mandatory
    gen_expr(n, depth);
    if (nd_type(n) == TY_VOID) err_node(n, "value of type void");
}

i64 cmp_toks[]  = { K_EQ, K_NE, K_LT, K_LE, K_GT, K_GE };
i64 cmp_conds[] = { C_EQ, C_NE, C_LT, C_LE, C_GT, C_GE };

i64 cmp_toks_at(i64 i)  { return ld64(cmp_toks + i * 8); }
i64 cmp_conds_at(i64 i) { return ld64(cmp_conds + i * 8); }

i64 cmp_cond(i64 op) {
    i64 i = 0;
    loop {
        if (i >= 6) break;
        if (cmp_toks_at(i) == op) return cmp_conds_at(i);
        i = i + 1;
    }
    return -1;
}

void gen_cast(i64 rd, i64 ty) {
    if (ty == TY_U8)       ei(I_ANDI, rd, rd, 0xff);
    else if (ty == TY_U16) ei(I_ANDI, rd, rd, 0xffff);
    else if (ty == TY_U32) e2(I_MOVW, rd, rd);        // mov wd, wn zeroes the top half
}

void gen_unary(i64 n, i64 depth) {
    i64 op = nd_op(n);
    gen_value(nd_a(n), depth);
    if (op == K_BANG) set_nd_type(n, TY_I64);
    else              set_nd_type(n, nd_type(nd_a(n)));
    i64 rd = val_reg(depth, REG_S1);             // operates in place
    if (op == K_SUB)        e2(I_NEG, rd, rd);
    else if (op == K_TILDE) e2(I_MVN, rd, rd);
    else if (op == K_BANG)  { ei(I_CMPI, 0, rd, 0); ins_add(I_CSET, rd, 0, 0, C_EQ, 0, 0); }
    else err_node(n, "unary operator with no codegen");
    dst_done(depth, rd);
}

// && and || with short-circuiting, via local labels
void gen_logic(i64 n, i64 depth) {
    nlabels = nlabels + 1;
    i64 lalt = nlabels;
    nlabels = nlabels + 1;
    i64 lend = nlabels;
    i64 andand = nd_op(n) == K_ANDAND;
    i64 rd = dst_reg(depth);
    gen_value(nd_a(n), depth);
    // shortcut: && branches away when a is false, || when a is true
    i64 br = I_CBNZ;
    if (andand) br = I_CBZ;
    elr(br, val_reg(depth, REG_S1), lalt);
    gen_value(nd_b(n), depth);                   // no shortcut: the result is (b != 0)
    ei(I_CMPI, 0, val_reg(depth, REG_S1), 0);
    ins_add(I_CSET, rd, 0, 0, C_NE, 0, 0);
    dst_done(depth, rd);
    el(I_B, lend);
    el(I_LABEL, lalt);
    i64 shortcut = 1;
    if (andand) shortcut = 0;
    gen_imm(rd, shortcut);                       // shortcut value
    dst_done(depth, rd);
    el(I_LABEL, lend);
    set_nd_type(n, TY_I64);
}

void gen_binary(i64 n, i64 depth) {
    i64 op = nd_op(n);
    if (op == K_ANDAND || op == K_OROR) { gen_logic(n, depth); return; }
    gen_value(nd_a(n), depth);
    gen_value(nd_b(n), depth + 1);
    i64 cond = cmp_cond(op);
    if (cond >= 0) set_nd_type(n, TY_I64);
    else           set_nd_type(n, nd_type(nd_a(n)));
    i64 rl = val_reg(depth, REG_S1);
    i64 rr = val_reg(depth + 1, REG_S2);
    i64 rd = dst_reg(depth);
    // only i64 divides with sign; everything else (u8..u64, uptr) uses udiv
    i64 div = I_UDIV;
    if (nd_type(nd_a(n)) == TY_I64) div = I_SDIV;
    i64 shr = I_LSRV;
    if (nd_type(nd_a(n)) == TY_I64) shr = I_ASRV;
    if (cond >= 0) { e3(I_CMP, 0, rl, rr); ins_add(I_CSET, rd, 0, 0, cond, 0, 0); }
    else if (op == K_ADD) e3(I_ADD, rd, rl, rr);
    else if (op == K_SUB) e3(I_SUB, rd, rl, rr);
    else if (op == K_MUL) e3(I_MUL, rd, rl, rr);
    else if (op == K_DIV) e3(div,   rd, rl, rr);
    else if (op == K_MOD) { e3(div, REG_TMP, rl, rr);
                            ins_add(I_MSUB, rd, REG_TMP, rr, rl, 0, 0); }   // rd = rl - q*rr
    else if (op == K_AND) e3(I_AND,  rd, rl, rr);
    else if (op == K_OR)  e3(I_ORR,  rd, rl, rr);
    else if (op == K_XOR) e3(I_EOR,  rd, rl, rr);
    else if (op == K_SHL) e3(I_LSLV, rd, rl, rr);
    else if (op == K_SHR) e3(shr,    rd, rl, rr);
    else err_node(n, "binary operator with no codegen");
    dst_done(depth, rd);
}

// resolves the name of a node: >= 0 is a local index, < 0 is the global -(g + 1)
i64 name_find(i64 n) {
    i64 i = local_find(nd_name(n));
    if (i >= 0) return i;
    i64 g = global_find(nd_name(n));
    if (g < 0) err_node(n, "unknown name");
    return 0 - (g + 1);
}

// name: local first, then global. An array decays to the address (uptr);
// a scalar is read at the type's width.
void gen_ident(i64 n, i64 depth) {
    i64 rd = dst_reg(depth);
    i64 i = name_find(n);
    if (i >= 0) {
        uptr e = loc_at(i);
        if (loc_nelem(e)) {
            ei(I_ADDI, rd, REG_FRAME, 0 - loc_off(e));
            set_nd_type(n, TY_UPTR);
        } else {
            em(mem_op(loc_type(e), 0), rd, REG_FRAME, 0 - loc_off(e));
            set_nd_type(n, loc_type(e));
        }
        dst_done(depth, rd);
        return;
    }
    uptr g = glb_at(0 - i - 1);
    gen_gaddr(rd, glb_sym(g));
    if (glb_nelem(g)) set_nd_type(n, TY_UPTR);
    else { em(mem_op(glb_type(g), 0), rd, rd, 0); set_nd_type(n, glb_type(g)); }
    dst_done(depth, rd);
}

// &name: local, global or — new in M10 — function/extern, which becomes the
// address of the `_name` symbol (adrp/add, with PAGE21+PAGEOFF12; undefined when extern)
void gen_addr(i64 n, i64 depth) {
    i64 rd = dst_reg(depth);
    i64 i = local_find(nd_name(n));
    if (i >= 0) ei(I_ADDI, rd, REG_FRAME, 0 - loc_off(loc_at(i)));
    else {
        i64 g = global_find(nd_name(n));
        if (g >= 0) gen_gaddr(rd, glb_sym(glb_at(g)));
        else {
            i64 fi = func_find(nd_name(n));
            if (fi < 0) err_node(n, "unknown name");
            gen_gaddr(rd, sym_ref(usym(fs_name(fs_at(fi)))));
        }
    }
    set_nd_type(n, TY_UPTR);
    dst_done(depth, rd);
}

void gen_str(i64 n, i64 depth) {
    i64 rd = dst_reg(depth);
    gen_gaddr(rd, str_sym(nd_name(n), nd_val(n)));
    set_nd_type(n, TY_UPTR);
    dst_done(depth, rd);
}

i64 arg_count(i64 n) {
    i64 k = 0;
    i64 a = nd_a(n);
    loop {
        if (a == 0) break;
        k = k + 1;
        a = nd_next(a);
    }
    return k;
}

void gen_intrin(i64 n, i64 depth, i64 in) {
    i64 store = in >= IN_ST8;
    i64 want = 1;
    if (store) want = 2;
    if (arg_count(n) != want) err_node(n, "wrong arity in intrinsic");
    i64 t = intrin_type(in);
    i64 p = nd_a(n);
    gen_value(p, depth);
    if (!store) {
        i64 rp = val_reg(depth, REG_S1);
        i64 rd = dst_reg(depth);
        em(mem_op(t, 0), rd, rp, 0);             // zero-extend por construcao
        dst_done(depth, rd);
        set_nd_type(n, t);
        return;
    }
    gen_value(nd_next(p), depth + 1);
    i64 rp2 = val_reg(depth, REG_S1);
    i64 rv = val_reg(depth + 1, REG_S2);
    em(mem_op(t, 1), rv, rp2, 0);
    set_nd_type(n, TY_VOID);
}

// ---- raw output: emit(), reloc() and #opcode calls ----
// a 32-bit word in the instruction stream; the pending relocation sticks to it.
// The C compares `(u64)w > 0xffffffffu`; comparison in .mc is always signed,
// so a negative value is caught by the first half of the test.
void gen_word(i64 n, i64 w) {
    if (w < 0 || w > 0xffffffff) err_node(n, "emitted word does not fit in 32 bits");
    if (pend_type >= 0) {                        // the pending relocation sticks to this word
        // UNSIGNED is 8 bytes (length 3) and would run over the next word
        if (pend_type == R_UNSIGNED)
            err_node(pend_node, "reloc UNSIGNED requires 8 bytes: use a global array initializer");
        if (nprel == MAXPREL) die("too many raw relocations");
        set_prel_ins_at(nprel, nins - ins_base);  // index relative to the function
        set_prel_sym_at(nprel, pend_sym);
        set_prel_type_at(nprel, pend_type);
        nprel = nprel + 1;
        pend_type = -1;
    }
    ins_add(I_EMIT, 0, 0, 0, w, 0, 0);
    set_nd_type(n, TY_VOID);
}

void gen_emit(i64 n) {
    if (arg_count(n) != 1) err_node(n, "emit expects an argument");
    if (nd_kind(nd_a(n)) != N_INT) err_node(n, "emit expects a constant");
    gen_word(n, nd_val(nd_a(n)));
}

void gen_opcode(i64 n, i64 oi) {
    i64 e = opc_expand(oi, n);
    if (nd_kind(e) != N_INT) err_node(n, "#opcode argument not constant");
    gen_word(n, nd_val(e));
}

// reloc(TYPE, "symbol"): the next instruction generated must be the raw word
void gen_reloc(i64 n) {
    if (arg_count(n) != 2) err_node(n, "reloc expects two arguments");
    i64 a = nd_a(n);
    i64 b = nd_next(a);
    if (nd_kind(a) != N_INT) err_node(n, "relocation type must be constant");
    if (nd_kind(b) != N_STR) err_node(n, "reloc expects the symbol in quotes");
    i64 t = nd_val(a);
    if (t != R_UNSIGNED && t != R_BRANCH26 && t != R_PAGE21 && t != R_PAGEOFF12)
        err_node(n, "unknown relocation type");
    if (pend_type >= 0) err_node(n, "two relocations for the same word");
    pend_type = t;
    pend_sym  = sym_ref(nd_name(b));
    pend_node = n;
    set_nd_type(n, TY_VOID);
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

// callp(p, a1..a7): args in x0..x6, pointer in x16 (outside the ABI), blr x16.
// Same saving of the live depths as bl; i64 result in x0.
void gen_callp(i64 n, i64 depth) {
    i64 na = arg_count(n);
    if (na < 1 || na > MAXPARAMS) err_node(n, "callp expects 1 to 8 arguments");
    i64 i = 0;
    i64 a = nd_a(n);
    loop {
        if (a == 0) break;
        gen_value(a, depth + i);
        i = i + 1;
        a = nd_next(a);
    }
    save_live(depth);
    i = 0;                                       // the pointer (arg 0) goes to x16
    a = nd_a(n);
    loop {
        if (a == 0) break;
        i64 r = REG_S1;
        if (i) r = i - 1;
        arg_to_reg(r, depth + i);
        i = i + 1;
        a = nd_next(a);
    }
    ins_add(I_BLR, REG_S1, 0, 0, 0, 0, 0);
    restore_live(depth);
    i64 rd = dst_reg(depth);
    e2(I_MOV, rd, 0);
    dst_done(depth, rd);
    set_nd_type(n, TY_I64);
}

// call: args at depths cur..cur+n-1, saving the live ones, bl, result
void gen_call(i64 n, i64 depth) {
    i64 in = intrin_id(nd_name(n));
    if (in == IN_EMIT)  { gen_emit(n);  return; }
    if (in == IN_RELOC) { gen_reloc(n); return; }
    if (in == IN_CALLP) { gen_callp(n, depth); return; }
    if (in) { gen_intrin(n, depth, in); return; }
    i64 oi = opc_find(nd_name(n));
    if (oi >= 0) { gen_opcode(n, oi); return; }
    i64 fi = func_find(nd_name(n));
    if (fi < 0) err_node(n, "call to unknown function");
    if (arg_count(n) != fs_nparams(fs_at(fi))) err_node(n, "wrong number of arguments");
    i64 i = 0;
    i64 a = nd_a(n);
    loop {
        if (a == 0) break;
        gen_value(a, depth + i);
        i = i + 1;
        a = nd_next(a);
    }
    save_live(depth);                            // live: depths below
    i = 0;
    a = nd_a(n);
    loop {
        if (a == 0) break;
        arg_to_reg(i, depth + i);
        i = i + 1;
        a = nd_next(a);
    }
    ins_add(I_BL, 0, 0, 0, 0, 0, sym_ref(usym(fs_name(fs_at(fi)))));
    restore_live(depth);
    i64 rd = dst_reg(depth);
    e2(I_MOV, rd, 0);
    dst_done(depth, rd);
    set_nd_type(n, fs_type(fs_at(fi)));
}

void gen_expr(i64 n, i64 depth) {
    if (depth >= MAXDEPTH) err_node(n, "expression too deep");
    i64 k = nd_kind(n);
    if (k == N_INT) {
        i64 rd = dst_reg(depth);
        gen_imm(rd, nd_val(n));
        dst_done(depth, rd);
        set_nd_type(n, TY_I64);
        return;
    }
    if (k == N_UNARY)  { gen_unary(n, depth);  return; }
    if (k == N_BINARY) { gen_binary(n, depth); return; }
    if (k == N_CAST) {
        gen_value(nd_a(n), depth);
        i64 rd = val_reg(depth, REG_S1);
        gen_cast(rd, nd_type(n));
        dst_done(depth, rd);
        return;
    }
    if (k == N_STR)   { gen_str(n, depth);   return; }
    if (k == N_IDENT) { gen_ident(n, depth); return; }
    if (k == N_ADDR)  { gen_addr(n, depth);  return; }
    if (k == N_CALL)  { gen_call(n, depth);  return; }
    err_node(n, "expression with no codegen");
}

// ---- statements ----
void gen_var(i64 n) {
    i64 ty = nd_type(n);
    if (nd_val(n)) {                             // local array: nelem * width, at 16
        i64 nel = nd_val(n);                     // count in i64: (int) would truncate/overflow
        if (nel < 1 || nel > 4095 || nel * type_width(ty) > 4095)
            err_node(n, "local array too large");
        i64 size = nel * type_width(ty);
        local_add(nd_name(n), ty, slot_new((size + 15) & ~15), nel);
        return;
    }
    if (nd_a(n)) gen_value(nd_a(n), 0);          // initializer before the name exists
    i64 off = slot_new(8);
    local_add(nd_name(n), ty, off, 0);
    if (nd_a(n)) em(mem_op(ty, 1), REG_BASE, REG_FRAME, 0 - off);
}

void gen_assign(i64 n) {
    i64 i = name_find(n);
    i64 arr = 0;
    if (i >= 0) arr = loc_nelem(loc_at(i)) != 0;
    else        arr = glb_nelem(glb_at(0 - i - 1)) != 0;
    if (arr) err_node(n, "assignment to array");
    gen_value(nd_a(n), 0);
    if (i >= 0) {
        uptr e = loc_at(i);
        em(mem_op(loc_type(e), 1), REG_BASE, REG_FRAME, 0 - loc_off(e));
        return;
    }
    uptr g = glb_at(0 - i - 1);
    gen_gaddr(REG_S1, glb_sym(g));               // x16 is free: the expression is already done
    em(mem_op(glb_type(g), 1), REG_BASE, REG_S1, 0);
}

void gen_if(i64 n, i64 lepi) {
    nlabels = nlabels + 1;
    i64 lelse = nlabels;
    gen_value(nd_a(n), 0);
    elr(I_CBZ, REG_BASE, lelse);
    gen_stmt(nd_b(n), lepi);
    if (nd_c(n)) {
        nlabels = nlabels + 1;
        i64 lend = nlabels;
        el(I_B, lend);
        el(I_LABEL, lelse);
        gen_stmt(nd_c(n), lepi);
        el(I_LABEL, lend);
        return;
    }
    el(I_LABEL, lelse);
}

void gen_loop(i64 n, i64 lepi) {
    if (nloops == MAXLOOPS) die("too many nested loops");
    nlabels = nlabels + 1;
    i64 lbeg = nlabels;
    nlabels = nlabels + 1;
    i64 lend = nlabels;
    set_lcont_at(nloops, lbeg);
    set_lbreak_at(nloops, lend);
    nloops = nloops + 1;
    el(I_LABEL, lbeg);
    gen_stmt(nd_a(n), lepi);
    el(I_B, lbeg);
    el(I_LABEL, lend);
    nloops = nloops - 1;
}

void gen_stmt(i64 n, i64 lepi) {
    i64 k = nd_kind(n);
    if (k == N_BLOCK) {
        i64 mark = nlocals;                      // scope: names disappear, slots do not
        i64 s = nd_a(n);
        loop {
            if (s == 0) break;
            gen_stmt(s, lepi);
            s = nd_next(s);
        }
        nlocals = mark;
        return;
    }
    if (k == N_VAR)      { gen_var(n);         return; }
    if (k == N_ASSIGN)   { gen_assign(n);      return; }
    if (k == N_IF)       { gen_if(n, lepi);    return; }
    if (k == N_LOOP)     { gen_loop(n, lepi);  return; }
    if (k == N_BREAK) {
        i64 lv = nd_val(n);                      // validate in i64: (int) would truncate
        if (lv < 1 || lv > nloops) err_node(n, "break out of range");
        el(I_B, lbreak_at(nloops - lv));
        return;
    }
    if (k == N_CONTINUE) {
        if (nloops == 0) err_node(n, "continue outside loop");
        el(I_B, lcont_at(nloops - 1));
        return;
    }
    if (k == N_RETURN) {
        if (nd_a(n)) { gen_value(nd_a(n), 0); e2(I_MOV, 0, REG_BASE); }
        el(I_B, lepi);
        return;
    }
    if (k == N_EXPRSTMT) { gen_expr(nd_a(n), 0); return; }
    err_node(n, "statement with no codegen");
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

uptr rel_name(i64 t) {
    if (t == R_BRANCH26)  return "BRANCH26";
    if (t == R_PAGE21)    return "PAGE21";
    if (t == R_PAGEOFF12) return "PAGEOFF12";
    return "UNSIGNED";
}

i64 relt_pcrel(i64 t) { return t == R_BRANCH26 || t == R_PAGE21; }

i64 relt_len(i64 t) {
    if (t == R_UNSIGNED) return 3;
    return 2;
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
                        out_str(1, sym_name(sym_at(ins_sym(in)))); out_str(1, "@PAGE\n"); return; }
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

// the buffer with reloc()'s relocations before the word each one sticks to
void dump_buf(i64 f) {
    i64 p0 = fn_pstart_at(f);
    i64 k = 0;
    loop {
        if (k >= fn_count_at(f)) break;
        i64 j = 0;
        loop {
            if (j >= fn_pcount_at(f)) break;
            if (prel_ins_at(p0 + j) == k) {
                out_str(1, "  .reloc "); out_str(1, rel_name(prel_type_at(p0 + j)));
                out_str(1, " "); out_str(1, sym_name(sym_at(prel_sym_at(p0 + j))));
                out_str(1, "\n");
            }
            j = j + 1;
        }
        dump_ins(ins_at(fn_start_at(f) + k));
        k = k + 1;
    }
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

// encodes function f: reserves its place in __text, fixes the symbol's value and
// writes the words. This is the second half of gen — the one a backend replaces.
void gen_encode_one(i64 f) {
    i64 b = fn_start_at(f);
    i64 n = fn_count_at(f);
    i64 text = fn_sec_at(f);
    i64 p0 = fn_pstart_at(f);
    uptr off = xalloc(8 * (n + 1));
    uptr lab = xalloc(8 * (fn_labels_at(f) + 2));
    buf_pad(sec_data(sec_at(text)), 4);              // every function aligned to 4
    i64 base = buf_len(sec_data(sec_at(text)));
    sym_set_value(fn_sym_at(f), base);
    i64 pc = 0;
    i64 i = 0;
    loop {                                           // pass 1: offsets and labels
        if (i >= n) break;
        uptr e = ins_at(b + i);
        set_ivec_at(off, i, pc);
        if (ins_op(e) == I_LABEL) set_ivec_at(lab, ins_label(e), pc);
        else if (ins_op(e) != I_NOP) pc = pc + 4;
        i = i + 1;
    }
    i = 0;
    loop {                                           // pass 2: words and relocations
        if (i >= n) break;
        uptr e = ins_at(b + i);
        if (ins_op(e) != I_LABEL && ins_op(e) != I_NOP) {
            i64 at = (u32) (base + ivec_at(off, i));
            // these three always carry a symbol; 0 is a valid index, so what
            // decides whether there is a relocation is the opcode, never the value of sym
            if (ins_op(e) == I_BL)         reloc_add(text, at, ins_sym(e), R_BRANCH26, 1, 2);
            else if (ins_op(e) == I_ADRP)  reloc_add(text, at, ins_sym(e), R_PAGE21, 1, 2);
            else if (ins_op(e) == I_ADDLO) reloc_add(text, at, ins_sym(e), R_PAGEOFF12, 0, 2);
            i64 k = 0;
            loop {                                   // the ones reloc() hung here
                if (k >= fn_pcount_at(f)) break;
                if (prel_ins_at(p0 + k) == i)
                    reloc_add(text, at, prel_sym_at(p0 + k), prel_type_at(p0 + k),
                              relt_pcrel(prel_type_at(p0 + k)), relt_len(prel_type_at(p0 + k)));
                k = k + 1;
            }
            buf_u32(sec_data(sec_at(text)), encode(e, ivec_at(off, i), lab));
        }
        i = i + 1;
    }
}

// ---- functions ----
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

void gen_func(i64 f, i64 text) {
    ins_base = nins; nlabels = 0; nlocals = 0; nloops = 0; frame_off = 0;
    prel_base = nprel; pend_type = -1;
    i64 d = 0;
    loop {
        if (d >= MAXDEPTH) break;
        set_dslot_at(d, 0);
        d = d + 1;
    }
    if ((sec_flags(sec_at(text)) & 0xff) == S_ZEROFILL) err_node(f, "function in a zerofill section");
    nlabels = nlabels + 1;
    i64 lepi = nlabels;

    ins_add(I_STP_PRE, REG_FP, REG_SP, REG_LR, 0 - 16, 0, 0);
    ei(I_ADDI, REG_FP, REG_SP, 0);               // mov x29, sp
    i64 isub = nins;
    ei(I_SUBI, REG_SP, REG_SP, 0);               // frame only at the end
    i64 i = 0;
    i64 p = nd_a(f);
    loop {                                       // params: x0..x7 go to the frame
        if (p == 0) break;
        i64 off = slot_new(8);
        local_add(nd_name(p), nd_type(p), off, 0);
        em(mem_op(nd_type(p), 1), i, REG_FRAME, 0 - off);
        i = i + 1;
        p = nd_next(p);
    }
    gen_stmt(nd_b(f), lepi);
    if (pend_type >= 0) err_node(pend_node, "reloc without an immediately following emit");
    el(I_LABEL, lepi);
    i64 iadd = nins;
    ei(I_ADDI, REG_SP, REG_SP, 0);
    ins_add(I_LDP_POST, REG_FP, REG_SP, REG_LR, 16, 0, 0);
    e0(I_RET);

    i64 frame = (frame_off + 15) & ~15;          // sp always aligned to 16
    if (frame > 4095) err_node(f, "frame too large");
    set_ins_imm(ins_at(isub), frame);
    set_ins_imm(ins_at(iadd), frame);
    if (frame == 0) { set_ins_op(ins_at(isub), I_NOP); set_ins_op(ins_at(iadd), I_NOP); }
    fix_frame(frame);

    if (nfn == MAXFUNCS) die("too many functions");  // the function becomes a slice of ibuf
    set_fn_start_at(nfn, ins_base);
    set_fn_count_at(nfn, nins - ins_base);
    set_fn_pstart_at(nfn, prel_base);
    set_fn_pcount_at(nfn, nprel - prel_base);
    set_fn_labels_at(nfn, nlabels);
    set_fn_sec_at(nfn, text);
    // the symbol is born here (the symtab order is the lowering order); the value only in gen_encode_one
    set_fn_sym_at(nfn, sym_new(usym(nd_name(f)), text + 1, 0, 1));
    nfn = nfn + 1;
}

// section of a function or global: the #section in effect, otherwise the default
i64 node_sec(i64 n, i64 def) {
    if (nd_sect(n)) return secmap_at(nd_sect(n) - 1);
    return def;
}

// allocates each global and creates its symbol; runs before any function body
void gen_globals(i64 unit) {
    i64 g = unit;
    loop {
        if (g == 0) break;
        if (nd_kind(g) == N_GLOBAL) {
            if (nglobals == MAXGLOBALS) die("too many globals");
            if (global_find(nd_name(g)) >= 0 || func_find(nd_name(g)) >= 0)
                err_node(g, "global name declared twice");
            i64 ty = nd_type(g);
            i64 w = type_width(ty);
            i64 nel = nd_val(g);
            i64 def = isec_data;
            if (nd_a(g) == 0) def = isec_bss;
            i64 sec = node_sec(g, def);
            if (nd_a(g) && (sec_flags(sec_at(sec)) & 0xff) == S_ZEROFILL)
                err_node(g, "global with initializer in a zerofill section");
            i64 size = w;
            if (nel) size = nel * w;
            i64 off = glob_place(g, sec, size, w);
            uptr e = glb_at(nglobals);
            set_glb_name(e, nd_name(g));
            set_glb_type(e, ty);
            set_glb_nelem(e, nel);
            set_glb_sym(e, sym_new(usym(nd_name(g)), sec + 1, off, 0));
            nglobals = nglobals + 1;
        }
        g = nd_next(g);
    }
}

// __text, __cstring, __data and __bss (the ones the module uses) and only after
// that the #section ones, in order of first appearance in the source
void gen_sections(i64 unit) {
    i64 want_str = 0;
    i64 want_data = 0;
    i64 want_bss = 0;
    // reloc()'s string names a symbol and is not a literal: marking it via op removes
    // it from the __cstring count (codegen also never passes it through str_sym)
    i64 i = 1;
    loop {
        if (i >= nnodes) break;
        if (nd_kind(i) == N_CALL && intrin_id(nd_name(i)) == IN_RELOC) {
            i64 a = nd_a(i);
            if (a && nd_next(a)) set_nd_op(nd_next(a), 1);
        }
        i = i + 1;
    }
    i = 1;
    loop {
        if (i >= nnodes) break;
        if (nd_kind(i) == N_STR && nd_op(i) == 0) want_str = 1;
        i = i + 1;
    }
    i64 g = unit;
    loop {
        if (g == 0) break;
        if (nd_kind(g) == N_GLOBAL && nd_sect(g) == 0) {   // a custom one already has a section
            if (nd_a(g) == 0) want_bss = 1;
            else              want_data = 1;
        }
        g = nd_next(g);
    }
    isec_text = sec_new("__TEXT", "__text", TEXT_FLAGS, 2);
    isec_cstr = -1;
    isec_data = -1;
    isec_bss  = -1;
    if (want_str)  isec_cstr = sec_new("__TEXT", "__cstring", S_CSTRING_LITERALS, 0);
    if (want_data) isec_data = sec_new("__DATA", "__data", S_REGULAR, 4);
    if (want_bss)  isec_bss  = sec_new("__DATA", "__bss", S_ZEROFILL, 4);
    if (sec_pending() > MAXSECS) die("too many sections");
    i = 0;
    loop {
        if (i >= sec_pending()) break;
        set_secmap_at(i, sec_make(i));
        i = i + 1;
    }
}

void gen_lower(i64 unit) {
    gen_sections(unit);
    i64 f = unit;
    loop {                                        // signatures before the bodies
        if (f == 0) break;
        i64 k = nd_kind(f);
        if (k == N_FUNC || k == N_EXTERN || k == N_PROTO) {
            i64 np = 0;
            i64 p = nd_a(f);
            loop {
                if (p == 0) break;
                np = np + 1;
                p = nd_next(p);
            }
            if (np > MAXPARAMS) err_node(f, "at most 8 parameters");
            i64 def = 1;
            if (k == N_PROTO) def = 0;
            func_add(nd_name(f), nd_type(f), np, def, f);
        }
        f = nd_next(f);
    }
    i64 i = 0;
    loop {                                        // prototype with no definition or extern
        if (i >= nfuncs) break;
        if (!fs_def(fs_at(i))) err_node(fs_node(fs_at(i)), "prototype with no definition");
        i = i + 1;
    }
    gen_globals(unit);
    f = unit;
    loop {
        if (f == 0) break;
        if (nd_kind(f) == N_FUNC) gen_func(f, node_sec(f, isec_text));
        f = nd_next(f);
    }
}

void gen_encode_all() {
    i64 f = 0;
    loop {
        if (f >= nfn) break;
        gen_encode_one(f);
        f = f + 1;
    }
}

void gen_dump_asm() {
    i64 f = 0;
    loop {
        if (f >= nfn) break;
        out_str(1, gen_func_name(f)); out_str(1, ":\n");
        dump_buf(f);
        f = f + 1;
    }
}

// ---- public accessors: everything a surface backend needs to read ----
i64  gen_func_count()            { return nfn; }
uptr gen_func_name(i64 f)        { return sym_name(sym_at(fn_sym_at(f))); }
i64  gen_func_sec(i64 f)         { return fn_sec_at(f); }
i64  gen_func_sym(i64 f)         { return fn_sym_at(f); }
i64  gen_func_labels(i64 f)      { return fn_labels_at(f); }
i64  gen_ins_count(i64 f)        { return fn_count_at(f); }
uptr gen_ins_at(i64 f, i64 i)    { return ins_at(fn_start_at(f) + i); }
i64  gen_prel_count(i64 f)       { return fn_pcount_at(f); }
i64  gen_prel_ins(i64 f, i64 k)  { return prel_ins_at(fn_pstart_at(f) + k); }
i64  gen_prel_sym(i64 f, i64 k)  { return prel_sym_at(fn_pstart_at(f) + k); }
i64  gen_prel_type(i64 f, i64 k) { return prel_type_at(fn_pstart_at(f) + k); }
i64  gen_global_count()          { return nglobals; }
i64  gen_global_sym(i64 g)       { return glb_sym(glb_at(g)); }
i64  gen_str_count()             { return nstrs; }
i64  gen_str_sym(i64 s)          { return ste_sym(ste_at(s)); }
