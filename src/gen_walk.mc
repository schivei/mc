// gen_walk.mc — the target-independent half of the code generator (M17 step A,
// docs/specs/M17.md; the contract is docs/reference/machine.md).
//
// Until M17 this file and src/machine_arm64.mc were one file, src/gen_arm64.mc,
// which mixed the AST walk (frames, the depth stack, labels, calls, name
// resolution) with AArch64 instruction selection (I_* opcodes, x9..x15 as depth
// registers, x16/x17 as scratch). A second instruction set cannot be added
// without separating them, and separating them must not change a single byte of
// what the first one emits -- which is why the acceptance criterion of the split
// is that the frozen C seed's objects and `--dump-asm` stay identical.
//
// What is left here knows nothing about registers:
//
//   * the buffer of `Ins` records -- one slice per function, append-only -- and
//     the pending `reloc()` list that hangs off it;
//   * the frame in BYTES: slot_new() hands out offsets, the machine decides
//     which depths get a register and which get a slot;
//   * the label counter, the loop stack and the block scoping of locals;
//   * sections, globals, string literals and every symbol -- the object model,
//     which is format work, not machine work;
//   * the walk itself, which turns each node into MACHINE TASKS: one `&fn` per
//     task in a table registered with `machine(name, tab)` (src/hooks.mc) and
//     called through `callp`. The walker never names an arm64 function.
//
// The tasks take DEPTH INDICES, never registers: the walker says "the value is
// at depth 2" and whether depth 2 lives in a register or in a frame slot is the
// machine's business. docs/reference/machine.md is the task list, with the
// signature of each one.
//
// The record layouts came from stage0/mc.h and have not moved:
//
//   C: typedef struct { int op, rd, rn, rm; i64 imm; int label, sym; } Ins;
//      INS_OP 0  INS_RD 8  INS_RN 16  INS_RM 24  INS_IMM 32
//      INS_LABEL 40  INS_SYM 48                          -> INS_SIZE 56
//   C: typedef struct { const char *name; int type, off, nelem; } Local;
//      LOC_NAME 0  LOC_TYPE 8  LOC_OFF 16  LOC_NELEM 24  -> LOC_SIZE 32
//   C: typedef struct { const char *bytes; int len, sym; } StrEnt;
//      STR_BYTES 0  STR_LEN 8  STR_SYM 16                -> STR_SIZE 24
//
// Two renames forced by the lack of static scope in .mc (C uses `static`, here
// every name is global and macho.mc comes first):
//   sec_text/sec_cstr/sec_data/sec_bss -> isec_text/isec_cstr/isec_data/isec_bss
//     (sec_data is already the accessor for Section's inline Buf in macho.mc)
//   rel_pcrel(type)/rel_len(type)      -> relt_pcrel/relt_len
//     (rel_pcrel/rel_len are already the Reloc accessors in macho.mc)
//
// Depends on arena.mc (xalloc, cstrlen, str_eq, mem_eq, buf_*, out_*, die),
// on ast.mc (nodes, err_node, type_width), on parse.mc (opc_find, opc_expand,
// sec_pending, sec_make), on macho.mc (sections, symbols, relocations),
// on gen_resolve.mc (res_*, the signatures and the globals) and on hooks.mc
// (mach_tab, the machine in effect).

// expression depth: an ERROR, not a table. The machine decides how many of
// those depths live in registers.
#define MAXDEPTH  64

// Opcode 0 of the Ins buffer is reserved: it marks a label position, generates
// no word, and is the one instruction the walker itself has to recognise (the
// pending-reloc guard and the label pass both key off it). Every other I_* is
// the machine's own vocabulary -- src/machine_arm64.mc.
#define I_LABEL 0

// ---- the machine table: one task per slot, `&fn` each, called with callp ----
#define MTASK_PROLOGUE      0            // ()                    frame record, frame reserve
#define MTASK_PARAM         1            // (ty, i, off)          argument i into its slot
#define MTASK_EPILOGUE      2            // ()                    frame release, return
#define MTASK_FRAME_FIX     3            // (frame)               the frame size, known last
#define MTASK_CONST         4            // (d, imm)
#define MTASK_BIN           5            // (op, d, d2)           MOP_*
#define MTASK_CMP           6            // (cond, d, d2)         MCOND_*, 0/1
#define MTASK_UN            7            // (op, d)               MUN_*
#define MTASK_BOOL          8            // (d)                   d = (d != 0)
#define MTASK_CAST          9            // (ty, d)               narrow to the type's width
#define MTASK_LOAD         10            // (ty, d)               d = [d]
#define MTASK_STORE        11            // (ty, d)               [d] = d + 1
#define MTASK_LOCAL_ADDR   12            // (d, off)
#define MTASK_LOCAL_LOAD   13            // (ty, d, off)
#define MTASK_LOCAL_STORE  14            // (ty, d, off)
#define MTASK_SYM_ADDR     15            // (d, sym)              a global's or a literal's address
#define MTASK_GLOBAL_LOAD  16            // (ty, d, sym)
#define MTASK_GLOBAL_STORE 17            // (ty, d, sym)
#define MTASK_CALL         18            // (d, nargs, sym)       args at d .. d+nargs-1
#define MTASK_CALLP        19            // (d, nargs)            the pointer is arg 0
#define MTASK_RET          20            // (d)                   d into the return position
#define MTASK_JUMP         21            // (l)
#define MTASK_JZ           22            // (d, l)
#define MTASK_JNZ          23            // (d, l)
#define MTASK_LABEL        24            // (l)
#define MTASK_WORD         25            // (w)                   one raw word
#define MTASK_INS_SIZE     26            // (e) -> bytes          0 for what emits nothing
#define MTASK_ENCODE       27            // (e, pc, lab, buf)     write the instruction
#define MTASK_DUMP         28            // (e)                   --dump-asm, one line
#define MTASK_RELOC_KIND   29            // (e) -> R_* or -1      the implicit relocation
#define MTASK_RELOC_OFF    30            // (e) -> bytes          where inside it the field sits
#define MTASK_COUNT        31

// M24 (M9): the task names --dump-machine prints, in MTASK_* order. They live
// here because the vocabulary is the walker's; the dump itself is in main.mc,
// which is the one file that has both this list and the machine registry.
uptr mtask_names[] = {
    "prologue", "param", "epilogue", "frame_fix", "const", "bin", "cmp", "un",
    "bool", "cast", "load", "store", "local_addr", "local_load", "local_store",
    "sym_addr", "global_load", "global_store", "call", "callp", "ret", "jump",
    "jz", "jnz", "label", "word", "ins_size", "encode", "dump", "reloc_kind",
    "reloc_off" };

uptr mtask_name(i64 t) {
    if (t >= 0 && t < MTASK_COUNT) return ld64(mtask_names + t * 8);
    return "?";
}

// ---- the operator vocabulary the tasks speak ----
#define MOP_ADD   0
#define MOP_SUB   1
#define MOP_MUL   2
#define MOP_SDIV  3
#define MOP_UDIV  4
#define MOP_SMOD  5
#define MOP_UMOD  6
#define MOP_AND   7
#define MOP_OR    8
#define MOP_XOR   9
#define MOP_SHL  10
#define MOP_SHR  11
#define MOP_SAR  12

#define MUN_NEG   0
#define MUN_NOT   1
#define MUN_LNOT  2

#define MCOND_EQ 0
#define MCOND_NE 1
#define MCOND_LT 2
#define MCOND_LE 3
#define MCOND_GT 4
#define MCOND_GE 5

// ---- Ins ----
#define INS_OP    0
#define INS_RD    8
#define INS_RN   16
#define INS_RM   24
#define INS_IMM  32
#define INS_LABEL 40
#define INS_SYM  48
#define INS_SIZE 56

// ---- Local: the frame slot of a name; nelem > 0 marks an array.
// Nothing here searches by name any more -- gen_resolve.mc already turned every
// use into an index -- but the name is still recorded, because the frame layout
// plus the name is exactly what a debug-info writer needs. ----
#define LOC_NAME  0
#define LOC_TYPE  8
#define LOC_OFF  16
#define LOC_NELEM 24
#define LOC_SIZE 32

// ---- StrEnt: literal already emitted in __cstring, to deduplicate by content ----
#define STR_BYTES 0
#define STR_LEN   8
#define STR_SYM  16
#define STR_SIZE 24

uptr ibuf;
i64  nins = 0;
i64  inscap = 0;
i64  nlabels = 0;

// ---- current function state ----
uptr locals;
i64 localcap = 0;
i64 nlocals = 0;
i64 frame_off = 0;
uptr lbreak;
uptr lcont;
i64 loopcap = 0;
i64 nloops = 0;
// reloc(): the relocation stays pending until the next raw word (gen_word)
uptr prel_ins;
uptr prel_sym;
uptr prel_type;
i64 prelcap = 0;
i64 nprel = 0;
i64 pend_type = -1;
i64 pend_sym = 0;
i64 pend_node = 0;

// ---- functions already lowered: ibuf is append-only and each function is a slice of it ----
uptr fn_start;
uptr fn_count;
uptr fn_labels;
uptr fn_sec;
uptr fn_sym;
uptr fn_pstart;
uptr fn_pcount;
i64 fncap = 0;
i64 nfn = 0;
i64 ins_base = 0;                     // start of the current function in ibuf
i64 prel_base = 0;                    // start of the current function in prel_*

// ---- module state: strings and the sections in fixed order ----
uptr strs;
i64 strcap = 0;
i64 nstrs = 0;
i64 isec_text = 0;                    // -1 = section not created
i64 isec_cstr = 0;
i64 isec_data = 0;
i64 isec_bss  = 0;
uptr secmap;                          // parser's #section i -> real section

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

// ---- StrEnt accessors ----
uptr ste_at(i64 i)     { return strs + i * STR_SIZE; }
uptr ste_bytes(uptr e) { return ld64(e + STR_BYTES); }
i64  ste_len(uptr e)   { return ld64(e + STR_LEN); }
i64  ste_sym(uptr e)   { return ld64(e + STR_SYM); }
void set_ste_bytes(uptr e, uptr v) { st64(e + STR_BYTES, v); }
void set_ste_len(uptr e, i64 v)    { st64(e + STR_LEN, v); }
void set_ste_sym(uptr e, i64 v)    { st64(e + STR_SYM, v); }

// ---- accessors for the module's flat i64 vectors ----
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
// M23: the seven fn_* arrays share `nfn`, so one grow() accounts for them and
// grow_to() re-sizes the rest to the same capacity. Same for the three prel_*.
void fn_grow() {
    i64 oc = fncap;
    fn_start = grow(T_LOWERED, fn_start, nfn, &fncap, 8);
    if (fncap == oc) return;
    fn_count  = grow_to(fn_count,  nfn, fncap, 8);
    fn_labels = grow_to(fn_labels, nfn, fncap, 8);
    fn_sec    = grow_to(fn_sec,    nfn, fncap, 8);
    fn_sym    = grow_to(fn_sym,    nfn, fncap, 8);
    fn_pstart = grow_to(fn_pstart, nfn, fncap, 8);
    fn_pcount = grow_to(fn_pcount, nfn, fncap, 8);
}

void prel_grow() {
    i64 oc = prelcap;
    prel_ins = grow(T_PREL, prel_ins, nprel, &prelcap, 8);
    if (prelcap == oc) return;
    prel_sym  = grow_to(prel_sym,  nprel, prelcap, 8);
    prel_type = grow_to(prel_type, nprel, prelcap, 8);
}

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

// ---- the machine in effect ----
// `mach(MTASK_X)` is the address of task X. One indirection, always through the
// table hooks.mc holds, so a module that registers its own machine replaces the
// whole set at once and never half of it.
uptr mach(i64 task) {
    if (mach_tab == 0) die("no machine registered");
    return ld64(mach_tab + task * 8);
}

// M24 (M8): the write side, for a module DERIVING a machine. It is here and not
// in src/hooks.mc because the bound it checks is the MTASK_* list above -- the
// walker's own vocabulary. Its companion, machine_tab(name), is in the registry
// with machine()/machine_find()/machine_use().
//
// The recipe, and the one trap in it: copy machine_tab("arm64") into TWO blocks
// of MTASK_COUNT entries, patch the slots you are replacing in one of them,
// register that one, and delegate through the OTHER -- reading the patched
// table from inside a wrapper makes every wrapper call itself
// (lib/machine_probe.mc is the worked example).
void machine_slot(uptr tab, i64 task, uptr fn) {
    if (task < 0 || task >= MTASK_COUNT) die("machine_slot outside the task table");
    st64(tab + task * 8, fn);
}

// ---- buffer ----
void ins_add(i64 op, i64 rd, i64 rn, i64 rm, i64 imm, i64 label, i64 sym) {
    // the pending relocation only sticks to the raw word that gen_word puts in the
    // buffer; a label does not become a word and is transparent, everything else is an error
    if (pend_type >= 0 && op != I_LABEL) err_node(pend_node, "reloc without an immediately following emit");
    ibuf = grow(T_INS, ibuf, nins, &inscap, INS_SIZE);
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

// ---- the frame, in bytes ----
i64 slot_new(i64 size) {              // returns the positive offset from the frame base
    frame_off = frame_off + ((size + 7) & ~7);
    return frame_off;
}

// ---- M24: the type of each depth ----
// The walker says "the value is at depth 2"; a machine that has more than one
// register file has to know WHAT is at depth 2 to pick the file, the
// instruction and the ABI register. MTASK_PARAM has carried `ty` since M17, so
// the callee side of a float ABI was already reachable; MTASK_BIN/CMP/UN/BOOL/
// CALL/RET carry no type at all, and that asymmetry is exactly this array.
//
// NOT a task slot: no signature moves, the contract stays additive, and a
// machine that never reads it emits byte for byte what it emitted before.
//
// dtype[d] is written by gen_expr around every node it lowers -- res_type(n)
// before the children run, and again after, because the value that ACTUALLY
// lands at d is the node's own type and not the last child's. That post-write
// is what covers, in one place, the five sites the type changes under the
// walker's feet: a comparison (i64 out of two floats), gen_logic's shortcut
// constant, MUN_LNOT, an intrinsic load and a call -- where depth d is
// overwritten by argument 0 before the result comes back.
//
// walk_ret_type() is that same node's type while its own task runs, which is
// what a MTASK_CALL handler needs: by then dtype[d] holds ARGUMENT 0's type.
i64 dtype[MAXDEPTH];
i64 walk_ret = TY_I64;

i64  walk_depth_type(i64 d) {
    if (d < 0 || d >= MAXDEPTH) return TY_I64;
    return ld64(dtype + d * 8);
}
void set_walk_depth_type(i64 d, i64 t) {
    if (d >= 0 && d < MAXDEPTH) st64(dtype + d * 8, t);
}
i64  walk_ret_type() { return walk_ret; }

// every depth back to TY_I64: a function starts with nothing announced
void depth_types_reset() {
    i64 i = 0;
    loop {
        if (i >= MAXDEPTH) break;
        st64(dtype + i * 8, TY_I64);
        i = i + 1;
    }
    walk_ret = TY_I64;
}

// ---- locals (flat stack, size mark per block) ----
// The names live in gen_resolve.mc's own stack, built in this same order, so
// what a name resolved to is an INDEX into this table and nothing here searches.
void local_add(uptr name, i64 type, i64 off, i64 nelem) {
    locals = grow(T_LOCALS, locals, nlocals, &localcap, LOC_SIZE);
    uptr e = loc_at(nlocals);
    set_loc_name(e, name);
    set_loc_type(e, type);
    set_loc_off(e, off);
    set_loc_nelem(e, nelem);
    nlocals = nlocals + 1;
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
        if (nd_kind(e) == N_BLOB) {              // M21.5: #embed's payload, copied whole
            buf_put(b, nd_name(e), nd_val(e));
        } else if (nd_kind(e) == N_STR) {        // pointer to l_strN: 8 zeros + R_UNSIGNED
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
    strs = grow(T_STRINGS, strs, nstrs, &strcap, STR_SIZE);
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

// ---- the operator token tables ----
// The walker's job here is to say WHICH abstract operation the token names; how
// it is spelled in instructions is the machine's.
i64 cmp_toks[]  = { K_EQ, K_NE, K_LT, K_LE, K_GT, K_GE };
i64 cmp_conds[] = { MCOND_EQ, MCOND_NE, MCOND_LT, MCOND_LE, MCOND_GT, MCOND_GE };
i64 bin_toks[]  = { K_ADD, K_SUB, K_MUL, K_DIV, K_MOD,
                    K_AND, K_OR, K_XOR, K_SHL, K_SHR, 0 };
i64 bin_uops[]  = { MOP_ADD, MOP_SUB, MOP_MUL, MOP_UDIV, MOP_UMOD,
                    MOP_AND, MOP_OR, MOP_XOR, MOP_SHL, MOP_SHR };
i64 bin_sops[]  = { MOP_ADD, MOP_SUB, MOP_MUL, MOP_SDIV, MOP_SMOD,
                    MOP_AND, MOP_OR, MOP_XOR, MOP_SHL, MOP_SAR };

i64 cmp_toks_at(i64 i)  { return ld64(cmp_toks + i * 8); }
i64 cmp_conds_at(i64 i) { return ld64(cmp_conds + i * 8); }
i64 bin_toks_at(i64 i)  { return ld64(bin_toks + i * 8); }
i64 bin_uops_at(i64 i)  { return ld64(bin_uops + i * 8); }
i64 bin_sops_at(i64 i)  { return ld64(bin_sops + i * 8); }

i64 cmp_cond(i64 op) {
    i64 i = 0;
    loop {
        if (i >= 6) break;
        if (cmp_toks_at(i) == op) return cmp_conds_at(i);
        i = i + 1;
    }
    return -1;
}

// only i64 divides and shifts with sign; everything else (u8..u64, uptr) is unsigned
i64 bin_op(i64 op, i64 sgn) {
    i64 i = 0;
    loop {
        if (bin_toks_at(i) == 0) break;
        if (bin_toks_at(i) == op) {
            if (sgn) return bin_sops_at(i);
            return bin_uops_at(i);
        }
        i = i + 1;
    }
    return -1;
}

// ---- expressions ----
void gen_value(i64 n, i64 depth) {    // where a value is mandatory
    gen_expr(n, depth);
    if (res_type(n) == TY_VOID) err_node(n, "value of type void");
}

void gen_unary(i64 n, i64 depth) {
    i64 op = nd_op(n);
    gen_value(nd_a(n), depth);
    if (op == K_SUB)        callp(mach(MTASK_UN), MUN_NEG, depth);
    else if (op == K_TILDE) callp(mach(MTASK_UN), MUN_NOT, depth);
    else if (op == K_BANG)  callp(mach(MTASK_UN), MUN_LNOT, depth);
    else err_node(n, "unary operator with no codegen");
}

// && and || with short-circuiting, via local labels
void gen_logic(i64 n, i64 depth) {
    nlabels = nlabels + 1;
    i64 lalt = nlabels;
    nlabels = nlabels + 1;
    i64 lend = nlabels;
    i64 andand = nd_op(n) == K_ANDAND;
    gen_value(nd_a(n), depth);
    // shortcut: && branches away when a is false, || when a is true
    if (andand) callp(mach(MTASK_JZ), depth, lalt);
    else        callp(mach(MTASK_JNZ), depth, lalt);
    gen_value(nd_b(n), depth);                   // no shortcut: the result is (b != 0)
    callp(mach(MTASK_BOOL), depth);
    callp(mach(MTASK_JUMP), lend);
    callp(mach(MTASK_LABEL), lalt);
    i64 shortcut = 1;
    if (andand) shortcut = 0;
    callp(mach(MTASK_CONST), depth, shortcut);   // shortcut value
    callp(mach(MTASK_LABEL), lend);
}

void gen_binary(i64 n, i64 depth) {
    i64 op = nd_op(n);
    if (op == K_ANDAND || op == K_OROR) { gen_logic(n, depth); return; }
    gen_value(nd_a(n), depth);
    gen_value(nd_b(n), depth + 1);
    i64 cond = cmp_cond(op);
    if (cond >= 0) { callp(mach(MTASK_CMP), cond, depth, depth + 1); return; }
    i64 mop = bin_op(op, res_type(nd_a(n)) == TY_I64);
    if (mop < 0) err_node(n, "binary operator with no codegen");
    callp(mach(MTASK_BIN), mop, depth, depth + 1);
}

// name: local first, then global (gen_resolve.mc already decided which).
// An array decays to the address (uptr); a scalar is read at the type's width.
void gen_ident(i64 n, i64 depth) {
    if (res_kind(n) == RK_LOCAL) {
        uptr e = loc_at(res_decl(n));
        if (loc_nelem(e)) callp(mach(MTASK_LOCAL_ADDR), depth, loc_off(e));
        else              callp(mach(MTASK_LOCAL_LOAD), loc_type(e), depth, loc_off(e));
        return;
    }
    uptr g = glb_at(res_decl(n));
    if (glb_nelem(g)) callp(mach(MTASK_SYM_ADDR), depth, glb_sym(g));
    else              callp(mach(MTASK_GLOBAL_LOAD), glb_type(g), depth, glb_sym(g));
}

// &name: local, global or — new in M10 — function/extern, which becomes the
// address of the `_name` symbol (undefined when extern)
void gen_addr(i64 n, i64 depth) {
    i64 k = res_kind(n);
    if (k == RK_LOCAL) {
        callp(mach(MTASK_LOCAL_ADDR), depth, loc_off(loc_at(res_decl(n))));
        return;
    }
    if (k == RK_GLOBAL) {
        callp(mach(MTASK_SYM_ADDR), depth, glb_sym(glb_at(res_decl(n))));
        return;
    }
    callp(mach(MTASK_SYM_ADDR), depth, sym_ref(usym(fs_name(fs_at(res_decl(n))))));
}

void gen_str(i64 n, i64 depth) {
    callp(mach(MTASK_SYM_ADDR), depth, str_sym(nd_name(n), nd_val(n)));
}

void gen_intrin(i64 n, i64 depth, i64 in) {
    i64 t = intrin_type(in);
    i64 p = nd_a(n);
    gen_value(p, depth);
    if (in < IN_ST8) { callp(mach(MTASK_LOAD), t, depth); return; }
    gen_value(nd_next(p), depth + 1);
    callp(mach(MTASK_STORE), t, depth);
}

// ---- raw output: emit(), reloc() and #opcode calls ----
// a raw word in the instruction stream; the pending relocation sticks to it.
// The C compares `(u64)w > 0xffffffffu`; comparison in .mc is always signed,
// so a negative value is caught by the first half of the test.
void gen_word(i64 n, i64 w) {
    if (w < 0 || w > 0xffffffff) err_node(n, "emitted word does not fit in 32 bits");
    if (pend_type >= 0) {                        // the pending relocation sticks to this word
        // UNSIGNED is 8 bytes (length 3) and would run over the next word
        if (pend_type == R_UNSIGNED)
            err_node(pend_node, "reloc UNSIGNED requires 8 bytes: use a global array initializer");
        prel_grow();
        set_prel_ins_at(nprel, nins - ins_base);  // index relative to the function
        set_prel_sym_at(nprel, pend_sym);
        set_prel_type_at(nprel, pend_type);
        nprel = nprel + 1;
        pend_type = -1;
    }
    callp(mach(MTASK_WORD), w);
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
}

// M24: the arguments of a taught intrinsic, then its handler. The handler is
// the module's; what it may rely on is contract version 3 -- walk_depth_type on
// every one of those depths, and val_reg/dst_reg/dst_done from the machine in
// effect (docs/reference/machine.md § 3).
void lower_uintrin(i64 n, i64 depth, i64 ui) {
    i64 i = 0;
    i64 a = nd_a(n);
    loop {
        if (a == 0) break;
        gen_value(a, depth + i);
        i = i + 1;
        a = nd_next(a);
    }
    callp(intrinsic_fn_at(ui), depth, i);
}

// callp(p, a1..a11): the pointer is argument 0; the machine says where each one
// goes and saves whatever it has live, exactly as it does for a direct call.
void gen_callp(i64 n, i64 depth) {
    i64 i = 0;
    i64 a = nd_a(n);
    loop {
        if (a == 0) break;
        gen_value(a, depth + i);
        i = i + 1;
        a = nd_next(a);
    }
    callp(mach(MTASK_CALLP), depth, i);
}

// call: args at depths cur..cur+n-1, then the machine's call sequence
void gen_call(i64 n, i64 depth) {
    if (res_kind(n) == RK_INTRIN) {
        i64 in = res_decl(n);
        if (in == IN_EMIT)  { gen_emit(n);  return; }
        if (in == IN_RELOC) { gen_reloc(n); return; }
        if (in == IN_CALLP) { gen_callp(n, depth); return; }
        gen_intrin(n, depth, in);
        return;
    }
    if (res_kind(n) == RK_OPCODE) { gen_opcode(n, res_decl(n)); return; }
    // M24 (M7): a taught intrinsic. Its arguments are lowered exactly like a
    // call's -- depths d .. d+nargs-1, with walk_depth_type filled in -- and
    // then the module's handler runs INSTEAD of the call sequence.
    if (res_kind(n) == RK_UINTRIN) { lower_uintrin(n, depth, res_decl(n)); return; }
    i64 fi = res_decl(n);
    i64 i = 0;
    i64 a = nd_a(n);
    loop {
        if (a == 0) break;
        gen_value(a, depth + i);
        i = i + 1;
        a = nd_next(a);
    }
    callp(mach(MTASK_CALL), depth, i, sym_ref(usym(fs_name(fs_at(fi)))));
}

// M24: the announcement wrapper around the dispatch. `walk_ret` is saved and
// restored so a child's type does not leak into the parent's task, and dtype[d]
// is written twice -- before, so a task the dispatch issues over its OWN depth
// sees the right thing, and after, so the value that landed is described by the
// node that produced it.
void gen_expr(i64 n, i64 depth) {
    if (depth >= MAXDEPTH) err_node(n, "expression too deep");
    i64 save = walk_ret;
    walk_ret = res_type(n);
    set_walk_depth_type(depth, walk_ret);
    lower_expr(n, depth);
    set_walk_depth_type(depth, res_type(n));
    walk_ret = save;
}

void lower_expr(i64 n, i64 depth) {
    i64 k = nd_kind(n);
    if (k == N_INT) {
        callp(mach(MTASK_CONST), depth, nd_val(n));
        return;
    }
    if (k == N_UNARY)  { gen_unary(n, depth);  return; }
    if (k == N_BINARY) { gen_binary(n, depth); return; }
    if (k == N_CAST) {
        gen_value(nd_a(n), depth);
        callp(mach(MTASK_CAST), res_type(n), depth);
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
    // M24: the slot is the TYPE's width, not 8. Provably byte-identical for all
    // seven core types -- slot_new rounds (size + 7) & ~7, so 1..8 give the same
    // offset -- and a 16-byte taught type gets 16.
    i64 off = slot_new(type_width(ty));
    local_add(nd_name(n), ty, off, 0);
    if (nd_a(n)) callp(mach(MTASK_LOCAL_STORE), ty, 0, off);
}

void gen_assign(i64 n) {
    gen_value(nd_a(n), 0);
    if (res_kind(n) == RK_LOCAL) {
        uptr e = loc_at(res_decl(n));
        callp(mach(MTASK_LOCAL_STORE), loc_type(e), 0, loc_off(e));
        return;
    }
    uptr g = glb_at(res_decl(n));
    callp(mach(MTASK_GLOBAL_STORE), glb_type(g), 0, glb_sym(g));
}

void gen_if(i64 n, i64 lepi) {
    nlabels = nlabels + 1;
    i64 lelse = nlabels;
    gen_value(nd_a(n), 0);
    callp(mach(MTASK_JZ), 0, lelse);
    gen_stmt(nd_b(n), lepi);
    if (nd_c(n)) {
        nlabels = nlabels + 1;
        i64 lend = nlabels;
        callp(mach(MTASK_JUMP), lend);
        callp(mach(MTASK_LABEL), lelse);
        gen_stmt(nd_c(n), lepi);
        callp(mach(MTASK_LABEL), lend);
        return;
    }
    callp(mach(MTASK_LABEL), lelse);
}

void gen_loop(i64 n, i64 lepi) {
    i64 loc = loopcap;
    lbreak = grow(T_LOOPS, lbreak, nloops, &loopcap, 8);
    if (loopcap != loc) lcont = grow_to(lcont, nloops, loopcap, 8);
    nlabels = nlabels + 1;
    i64 lbeg = nlabels;
    nlabels = nlabels + 1;
    i64 lend = nlabels;
    set_lcont_at(nloops, lbeg);
    set_lbreak_at(nloops, lend);
    nloops = nloops + 1;
    callp(mach(MTASK_LABEL), lbeg);
    gen_stmt(nd_a(n), lepi);
    callp(mach(MTASK_JUMP), lbeg);
    callp(mach(MTASK_LABEL), lend);
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
        callp(mach(MTASK_JUMP), lbreak_at(nloops - lv));
        return;
    }
    if (k == N_CONTINUE) {
        if (nloops == 0) err_node(n, "continue outside loop");
        callp(mach(MTASK_JUMP), lcont_at(nloops - 1));
        return;
    }
    if (k == N_RETURN) {
        if (nd_a(n)) { gen_value(nd_a(n), 0); callp(mach(MTASK_RET), 0); }
        callp(mach(MTASK_JUMP), lepi);
        return;
    }
    if (k == N_EXPRSTMT) { gen_expr(nd_a(n), 0); return; }
    err_node(n, "statement with no codegen");
}

// ---- text dump ----
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
        callp(mach(MTASK_DUMP), ins_at(fn_start_at(f) + k));
        k = k + 1;
    }
}

// ---- encoding ----
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
        else pc = pc + callp(mach(MTASK_INS_SIZE), e);
        i = i + 1;
    }
    i = 0;
    loop {                                           // pass 2: words and relocations
        if (i >= n) break;
        uptr e = ins_at(b + i);
        if (ins_op(e) != I_LABEL && callp(mach(MTASK_INS_SIZE), e) != 0) {
            i64 at = (u32) (base + ivec_at(off, i));
            // the machine says which instructions carry a relocation of their own;
            // 0 is a valid symbol index, so the opcode decides, never the value of sym
            i64 rt = callp(mach(MTASK_RELOC_KIND), e);
            // ...and where inside the instruction the field to patch begins: 0 on a
            // fixed-width machine, 1 for an x86 `call rel32`, 3 for a `lea [rip+d32]`
            if (rt >= 0) reloc_add(text, at + callp(mach(MTASK_RELOC_OFF), e),
                                   ins_sym(e), rt, relt_pcrel(rt), relt_len(rt));
            i64 k = 0;
            loop {                                   // the ones reloc() hung here
                if (k >= fn_pcount_at(f)) break;
                if (prel_ins_at(p0 + k) == i)
                    reloc_add(text, at, prel_sym_at(p0 + k), prel_type_at(p0 + k),
                              relt_pcrel(prel_type_at(p0 + k)), relt_len(prel_type_at(p0 + k)));
                k = k + 1;
            }
            callp(mach(MTASK_ENCODE), e, ivec_at(off, i), lab, sec_data(sec_at(text)));
        }
        i = i + 1;
    }
}

// ---- functions ----
void gen_func(i64 f, i64 text) {
    ins_base = nins; nlabels = 0; nlocals = 0; nloops = 0; frame_off = 0;
    prel_base = nprel; pend_type = -1;
    depth_types_reset();                          // M24: nothing announced yet
    if ((sec_flags(sec_at(text)) & 0xff) == S_ZEROFILL) err_node(f, "function in a zerofill section");
    nlabels = nlabels + 1;
    i64 lepi = nlabels;

    callp(mach(MTASK_PROLOGUE));
    i64 i = 0;
    i64 p = nd_a(f);
    loop {                                       // params: the ABI registers go to the frame
        if (p == 0) break;
        i64 off = slot_new(type_width(nd_type(p)));   // M24, as in gen_var

        local_add(nd_name(p), nd_type(p), off, 0);
        callp(mach(MTASK_PARAM), nd_type(p), i, off);
        i = i + 1;
        p = nd_next(p);
    }
    gen_stmt(nd_b(f), lepi);
    if (pend_type >= 0) err_node(pend_node, "reloc without an immediately following emit");
    callp(mach(MTASK_LABEL), lepi);
    callp(mach(MTASK_EPILOGUE));

    i64 frame = (frame_off + 15) & ~15;          // the stack always aligned to 16
    if (frame > 4095) err_node(f, "frame too large");
    callp(mach(MTASK_FRAME_FIX), frame);

    fn_grow();                                   // the function becomes a slice of ibuf
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

// places every global and creates its symbol; runs before any function body.
// gen_resolve.mc already declared them, in this same order, so this fills in
// the one field it left empty.
void gen_globals(i64 unit) {
    i64 gi = 0;
    i64 g = unit;
    loop {
        if (g == 0) break;
        if (nd_kind(g) == N_GLOBAL) {
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
            set_glb_sym(glb_at(gi), sym_new(usym(nd_name(g)), sec + 1, off, 0));
            gi = gi + 1;
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
    secmap = xalloc(8 * (sec_pending() + 1));  // one slot per #section, exactly
    i = 0;
    loop {
        if (i >= sec_pending()) break;
        set_secmap_at(i, sec_make(i));
        i = i + 1;
    }
}

// The AST becomes Ins buffers, sections, globals, strings and symbols; nothing
// is encoded yet. gen_resolve runs first and is idempotent, so a backend that
// only knows the old two halves needs no change at all.
void gen_lower(i64 unit) {
    gen_resolve(unit);
    gen_sections(unit);
    gen_globals(unit);
    i64 f = unit;
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
