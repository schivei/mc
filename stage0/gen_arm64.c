/* gen_arm64.c — linear per-function instruction buffer + AArch64 encoders.
 * The AST becomes Ins[]; gen_encode resolves local labels, registers relocations and
 * writes words into __text. --dump-asm prints the buffer before encoding.
 * Locals, parameters, saves and spills live in the frame. Instructions come out
 * with the fictitious base REG_FRAME and a negative offset from x29; after
 * walking through the whole function, fix_frame swaps the base for sp and the offset
 * for (frame - off) — that is why the frame can be computed at the end. */
#include "mc.h"

static Ins *ibuf; static int nins, inscap;
static int nlabels;

/* registers: depth 0..6 in x9..x15; above that the value lives in the frame */
#define REG_BASE   9
#define REG_MAX    6
#define REG_TMP    8              /* scratch for the remainder (%) */
#define REG_S1    16              /* spill scratch: left/destination */
#define REG_S2    17              /* spill scratch: right */
#define REG_FP    29
#define REG_LR    30
#define REG_SP    31
#define REG_FRAME 32              /* fictitious base swapped for sp in fix_frame */
#define MAXDEPTH  64
#define MAXLOCALS 256
#define MAXFUNCS 2048
#define MAXLOOPS  32
#define MAXGLOBALS 512
#define MAXSTRS    2048
#define MAXPREL   512             /* reloc() relocations for the whole module */

/* ---- current function state ---- */
static Local locals[MAXLOCALS]; static int nlocals;
static int dslot[MAXDEPTH];      /* slot for the depth: save (<=6) or spill (>=7) */
static int frame_off;            /* bytes already reserved in the frame */
static int lbreak[MAXLOOPS], lcont[MAXLOOPS]; static int nloops;
/* reloc(): the relocation stays pending until the next raw word (gen_word) */
static int prel_ins[MAXPREL], prel_sym[MAXPREL], prel_type[MAXPREL]; static int nprel;
static int pend_type = -1, pend_sym, pend_node;

/* ---- functions already lowered: ibuf is append-only and each function is a slice of it ---- */
static int fn_start[MAXFUNCS], fn_count[MAXFUNCS], fn_labels[MAXFUNCS];
static int fn_sec[MAXFUNCS], fn_sym[MAXFUNCS], fn_pstart[MAXFUNCS], fn_pcount[MAXFUNCS];
static int nfn, ins_base, prel_base;   /* ins_base/prel_base: start of the current function */

/* signatures of the whole file (N_FUNC and N_EXTERN), registered before the bodies */
static FuncSig funcs[MAXFUNCS]; static int nfuncs;

/* ---- module state: globals, strings and the sections in fixed order ---- */
static Global globals[MAXGLOBALS]; static int nglobals;
static StrEnt strs[MAXSTRS];       static int nstrs;
static int sec_text, sec_cstr, sec_data, sec_bss;   /* -1 = section not created */
static int secmap[MAXSECS];        /* parser's #section i -> real section */

/* ---- buffer ---- */
static void ins_add(int op, int rd, int rn, int rm, i64 imm, int label, int sym) {
    /* the pending relocation only sticks to the raw word that gen_word puts in the buffer;
     * a label does not become a word and is transparent, everything else is an error */
    if (pend_type >= 0 && op != I_LABEL) err_node(pend_node, "reloc without an immediately following emit");
    if (nins == inscap) {
        int cap = inscap ? inscap * 2 : 256;
        Ins *n = xalloc(sizeof(Ins) * (size_t)cap);
        for (int i = 0; i < nins; i++) n[i] = ibuf[i];
        ibuf = n; inscap = cap;
    }
    ibuf[nins].op = op; ibuf[nins].rd = rd; ibuf[nins].rn = rn; ibuf[nins].rm = rm;
    ibuf[nins].imm = imm; ibuf[nins].label = label; ibuf[nins].sym = sym;
    nins++;
}
static void e0(int op)                        { ins_add(op, 0, 0, 0, 0, 0, 0); }
static void e2(int op, int rd, int rn)        { ins_add(op, rd, rn, 0, 0, 0, 0); }
static void e3(int op, int rd, int rn, int rm){ ins_add(op, rd, rn, rm, 0, 0, 0); }
static void ei(int op, int rd, int rn, i64 imm) { ins_add(op, rd, rn, 0, imm, 0, 0); }
static void el(int op, int label)             { ins_add(op, 0, 0, 0, 0, label, 0); }
static void elr(int op, int rd, int label)    { ins_add(op, rd, 0, 0, 0, label, 0); }
static void em(int op, int rt, int rn, i64 off) { ins_add(op, rt, rn, 0, off, 0, 0); }

/* 64-bit immediate in up to 4 instructions: movz for the low byte + movk for the rest */
static void gen_imm(int rd, u64 v) {
    ins_add(I_MOVZ, rd, 0, 0, (i64)(v & 0xffff), 0, 0);
    for (int hw = 1; hw < 4; hw++) {
        u64 part = (v >> (16 * hw)) & 0xffff;
        if (part) ins_add(I_MOVK, rd, hw, 0, (i64)part, 0, 0);
    }
}

/* ---- frame, depth and spill ---- */
static int slot_new(int size) {                  /* returns the positive offset from x29 */
    frame_off += (size + 7) & ~7;
    return frame_off;
}
static int slot_depth(int d) {
    if (dslot[d] == 0) dslot[d] = slot_new(8);
    return dslot[d];
}
static bool in_reg(int depth) { return depth <= REG_MAX; }
/* register holding the depth's value; loads from the frame into scratch if spilled */
static int val_reg(int depth, int scratch) {
    if (in_reg(depth)) return REG_BASE + depth;
    em(I_LDR, scratch, REG_FRAME, -slot_depth(depth));
    return scratch;
}
static int dst_reg(int depth) { return in_reg(depth) ? REG_BASE + depth : REG_S1; }
static void dst_done(int depth, int rd) {
    if (!in_reg(depth)) em(I_STR, rd, REG_FRAME, -slot_depth(depth));
}

/* ---- instruction tables (dump and encoder read the same ones) ---- */
/* three register-register operands: same shape, only the base changes */
static const int rrr_ins[] = { I_ADD, I_SUB, I_MUL, I_SDIV, I_UDIV, I_AND, I_ORR, I_EOR,
                               I_LSLV, I_LSRV, I_ASRV, 0 };
static const u32 rrr_base[] = { 0x8B000000u, 0xCB000000u, 0x9B007C00u, 0x9AC00C00u, 0x9AC00800u,
                                0x8A000000u, 0xAA000000u, 0xCA000000u,
                                0x9AC02000u, 0x9AC02400u, 0x9AC02800u };
static const char *rrr_name[] = { "add", "sub", "mul", "sdiv", "udiv", "and", "orr", "eor",
                                  "lsl", "lsr", "asr" };
/* memory: load/store pairs by width, from widest to narrowest */
static const int mem_ins[] = { I_LDR, I_STR, I_LDRW, I_STRW, I_LDRH, I_STRH, I_LDRB, I_STRB, 0 };
static const u32 mem_base[] = { 0xF9400000u, 0xF9000000u, 0xB9400000u, 0xB9000000u,
                                0x79400000u, 0x79000000u, 0x39400000u, 0x39000000u };
static const int mem_scale[] = { 8, 8, 4, 4, 2, 2, 1, 1 };
static const char *mem_name[] = { "ldr", "str", "ldr", "str", "ldrh", "strh", "ldrb", "strb" };
static int mem_slot(int op) {                    /* -1 if it is not a memory access */
    for (int i = 0; mem_ins[i]; i++) if (op == mem_ins[i]) return i;
    return -1;
}
/* access of t's width; even positions are load, odd ones store */
static int mem_op(int t, bool store) {
    int i = 0;
    if (t == TY_U8)       i = 6;
    else if (t == TY_U16) i = 4;
    else if (t == TY_U32) i = 2;
    return mem_ins[i + (store ? 1 : 0)];
}

/* ---- locals (flat stack, size mark per block) ---- */
static int local_find(const char *name) {
    for (int i = nlocals - 1; i >= 0; i--) if (str_eq(locals[i].name, name)) return i;
    return -1;
}
static void local_add(const char *name, int type, int off, int nelem) {
    if (nlocals == MAXLOCALS) die("too many locals");
    locals[nlocals].name = name; locals[nlocals].type = type;
    locals[nlocals].off = off;   locals[nlocals].nelem = nelem;
    nlocals++;
}

/* ---- signatures ---- */
static int func_find(const char *name) {
    for (int i = 0; i < nfuncs; i++) if (str_eq(funcs[i].name, name)) return i;
    return -1;
}
/* def = 1 for N_FUNC/N_EXTERN, 0 for a prototype; the prototype only reserves the
 * signature and the later definition has to match it */
static void func_add(const char *name, int type, int nparams, int def, int n) {
    int i = func_find(name);
    if (i >= 0) {
        if (funcs[i].def && def) err_node(n, "function declared twice");
        if (funcs[i].type != type || funcs[i].nparams != nparams)
            err_node(n, "declaration does not match prototype");
        if (def) { funcs[i].def = 1; funcs[i].node = n; }
        return;
    }
    if (nfuncs == MAXFUNCS) die("too many functions");
    funcs[nfuncs].name = name; funcs[nfuncs].type = type; funcs[nfuncs].nparams = nparams;
    funcs[nfuncs].def = def;   funcs[nfuncs].node = n;
    nfuncs++;
}
static const char *usym(const char *name) {      /* the compiler prefixes _ */
    size_t n = cstrlen(name);
    char *s = xalloc(n + 2);
    s[0] = '_';
    for (size_t i = 0; i < n; i++) s[i + 1] = name[i];
    s[n + 1] = 0;
    return s;
}

/* ---- globals: own local symbol in __data (with a value) or __bss (zeroed) ---- */
static int global_find(const char *name) {
    for (int i = 0; i < nglobals; i++) if (str_eq(globals[i].name, name)) return i;
    return -1;
}
static int str_sym(const char *bytes, int len);

/* Places global g (size bytes) in section sec and returns the offset.
 * Zerofill only counts bytes (everything starts and occupies a multiple of 16); in the
 * others each initializer element comes out at the type's width and the rest is zeroed —
 * that is why an array in a non-zerofill custom section occupies space in the file. */
static u64 glob_place(int g, int sec, i64 size, int width) {
    if ((sections[sec].flags & 0xff) == S_ZEROFILL) {
        u64 off = (sections[sec].zsize + 15) & ~15ull;
        sections[sec].zsize = off + (((u64)size + 15) & ~15ull);
        return off;
    }
    Buf *b = &sections[sec].data;
    buf_pad(b, (size_t)(nodes[g].val ? 16 : width));   /* array to 16, scalar to its width */
    u64 off = b->len;
    for (int e = nodes[g].a; e; e = nodes[e].next) {
        if (nodes[e].kind == N_STR) {            /* pointer to l_strN: 8 zero bytes + R_UNSIGNED */
            reloc_add(sec, (u32)b->len, str_sym(nodes[e].name, (int)nodes[e].val),
                      R_UNSIGNED, 0, 3);
            buf_u64(b, 0);
            continue;
        }
        i64 v = nodes[e].val;
        if (width == 1)      buf_u8(b, (u8)v);
        else if (width == 2) buf_u16(b, (u16)v);
        else if (width == 4) buf_u32(b, (u32)v);
        else                 buf_u64(b, (u64)v);
    }
    while ((i64)(b->len - off) < size) buf_u8(b, 0);
    return off;
}

/* ---- strings: bytes + NUL in __cstring, local symbol l_str<N> ---- */
static const char *str_name(int n) {
    char tmp[24]; int i = 24;
    do { tmp[--i] = (char)('0' + n % 10); n /= 10; } while (n);
    char *s = xalloc(32);
    s[0] = 'l'; s[1] = '_'; s[2] = 's'; s[3] = 't'; s[4] = 'r';
    int k = 5;
    while (i < 24) s[k++] = tmp[i++];
    s[k] = 0;
    return s;
}
/* deduplicates by content (linear search); N follows first-occurrence order */
static int str_sym(const char *bytes, int len) {
    for (int i = 0; i < nstrs; i++)
        if (strs[i].len == len && mem_eq(strs[i].bytes, bytes, (size_t)len)) return strs[i].sym;
    if (nstrs == MAXSTRS) die("too many strings");
    Buf *b = &sections[sec_cstr].data;
    u64 off = b->len;
    buf_put(b, bytes, (size_t)len);
    buf_u8(b, 0);                                /* __cstring keeps each literal NUL-terminated */
    int sym = sym_new(str_name(nstrs), sec_cstr + 1, off, false);
    strs[nstrs].bytes = bytes; strs[nstrs].len = len; strs[nstrs].sym = sym;
    nstrs++;
    return sym;
}
/* address of a local symbol: adrp for the page + add for the offset */
static void gen_gaddr(int rd, int sym) {
    ins_add(I_ADRP,  rd, 0,  0, 0, 0, sym);
    ins_add(I_ADDLO, rd, rd, 0, 0, 0, sym);
}

/* ---- intrinsics (name, not symbol); the memory ones and the raw-output ones ---- */
enum { IN_NONE = 0, IN_EMIT, IN_RELOC, IN_CALLP,
       IN_LD8, IN_LD16, IN_LD32, IN_LD64, IN_ST8, IN_ST16, IN_ST32, IN_ST64 };
static int intrin_id(const char *name) {
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
/* type of the accessed width; also the result type of the ld* ones */
static int intrin_type(int in) {
    if (in == IN_LD8  || in == IN_ST8)  return TY_U8;
    if (in == IN_LD16 || in == IN_ST16) return TY_U16;
    if (in == IN_LD32 || in == IN_ST32) return TY_U32;
    return TY_U64;
}

/* ---- expressions ---- */
static void gen_expr(int n, int depth);

static void gen_value(int n, int depth) {        /* where a value is mandatory */
    gen_expr(n, depth);
    if (nodes[n].type == TY_VOID) err_node(n, "value of type void");
}

static const int cmp_toks[6]  = { K_EQ, K_NE, K_LT, K_LE, K_GT, K_GE };
static const int cmp_conds[6] = { C_EQ, C_NE, C_LT, C_LE, C_GT, C_GE };
static int cmp_cond(int op) {
    for (int i = 0; i < 6; i++) if (cmp_toks[i] == op) return cmp_conds[i];
    return -1;
}

static void gen_cast(int rd, int ty) {
    if (ty == TY_U8)       ei(I_ANDI, rd, rd, 0xff);
    else if (ty == TY_U16) ei(I_ANDI, rd, rd, 0xffff);
    else if (ty == TY_U32) e2(I_MOVW, rd, rd);        /* mov wd, wn zeroes the top */
}

static void gen_unary(int n, int depth) {
    int op = nodes[n].op;
    gen_value(nodes[n].a, depth);
    nodes[n].type = op == K_BANG ? TY_I64 : nodes[nodes[n].a].type;
    int rd = val_reg(depth, REG_S1);             /* operates in place */
    if (op == K_SUB)        e2(I_NEG, rd, rd);
    else if (op == K_TILDE) e2(I_MVN, rd, rd);
    else if (op == K_BANG)  { ei(I_CMPI, 0, rd, 0); ins_add(I_CSET, rd, 0, 0, C_EQ, 0, 0); }
    else err_node(n, "unary operator with no codegen");
    dst_done(depth, rd);
}

/* && and || with short-circuit, via local labels */
static void gen_logic(int n, int depth) {
    int lalt = ++nlabels, lend = ++nlabels;
    bool andand = nodes[n].op == K_ANDAND;
    int rd = dst_reg(depth);
    gen_value(nodes[n].a, depth);
    /* shortcut: && branches away when a is false, || when a is true */
    elr(andand ? I_CBZ : I_CBNZ, val_reg(depth, REG_S1), lalt);
    gen_value(nodes[n].b, depth);                /* no shortcut: result is (b != 0) */
    ei(I_CMPI, 0, val_reg(depth, REG_S1), 0);
    ins_add(I_CSET, rd, 0, 0, C_NE, 0, 0);
    dst_done(depth, rd);
    el(I_B, lend);
    el(I_LABEL, lalt);
    gen_imm(rd, andand ? 0 : 1);                 /* shortcut value */
    dst_done(depth, rd);
    el(I_LABEL, lend);
    nodes[n].type = TY_I64;
}

static void gen_binary(int n, int depth) {
    int op = nodes[n].op;
    if (op == K_ANDAND || op == K_OROR) { gen_logic(n, depth); return; }
    gen_value(nodes[n].a, depth);
    gen_value(nodes[n].b, depth + 1);
    int cond = cmp_cond(op);
    nodes[n].type = cond >= 0 ? TY_I64 : nodes[nodes[n].a].type;
    int rl = val_reg(depth, REG_S1);
    int rr = val_reg(depth + 1, REG_S2);
    int rd = dst_reg(depth);
    /* only i64 divides signed; everything else (u8..u64, uptr) uses udiv */
    int div = nodes[nodes[n].a].type == TY_I64 ? I_SDIV : I_UDIV;
    if (cond >= 0) { e3(I_CMP, 0, rl, rr); ins_add(I_CSET, rd, 0, 0, cond, 0, 0); }
    else if (op == K_ADD) e3(I_ADD, rd, rl, rr);
    else if (op == K_SUB) e3(I_SUB, rd, rl, rr);
    else if (op == K_MUL) e3(I_MUL, rd, rl, rr);
    else if (op == K_DIV) e3(div,   rd, rl, rr);
    else if (op == K_MOD) { e3(div, REG_TMP, rl, rr);
                            ins_add(I_MSUB, rd, REG_TMP, rr, rl, 0, 0); }  /* rd = rl - q*rr */
    else if (op == K_AND) e3(I_AND,  rd, rl, rr);
    else if (op == K_OR)  e3(I_ORR,  rd, rl, rr);
    else if (op == K_XOR) e3(I_EOR,  rd, rl, rr);
    else if (op == K_SHL) e3(I_LSLV, rd, rl, rr);
    else if (op == K_SHR) e3(nodes[nodes[n].a].type == TY_I64 ? I_ASRV : I_LSRV, rd, rl, rr);
    else err_node(n, "binary operator with no codegen");
    dst_done(depth, rd);
}

/* resolves a node's name: >= 0 is a local index, < 0 is the global -(g + 1) */
static int name_find(int n) {
    int i = local_find(nodes[n].name);
    if (i >= 0) return i;
    int g = global_find(nodes[n].name);
    if (g < 0) err_node(n, "unknown name");
    return -(g + 1);
}

/* name: local first, global next. An array decays to its address (uptr);
 * a scalar is read at the type's width. */
static void gen_ident(int n, int depth) {
    int rd = dst_reg(depth), i = name_find(n);
    if (i >= 0) {
        if (locals[i].nelem) { ei(I_ADDI, rd, REG_FRAME, -locals[i].off);
                               nodes[n].type = TY_UPTR; }
        else { em(mem_op(locals[i].type, false), rd, REG_FRAME, -locals[i].off);
               nodes[n].type = locals[i].type; }
        dst_done(depth, rd);
        return;
    }
    int g = -i - 1;
    gen_gaddr(rd, globals[g].sym);
    if (globals[g].nelem) nodes[n].type = TY_UPTR;
    else { em(mem_op(globals[g].type, false), rd, rd, 0); nodes[n].type = globals[g].type; }
    dst_done(depth, rd);
}

/* &name: local, global or — new in M10 — function/extern, which becomes the address of
 * the `_name` symbol (adrp/add, with PAGE21+PAGEOFF12; undefined when extern) */
static void gen_addr(int n, int depth) {
    int rd = dst_reg(depth), i = local_find(nodes[n].name);
    if (i >= 0) ei(I_ADDI, rd, REG_FRAME, -locals[i].off);
    else {
        int g = global_find(nodes[n].name);
        if (g >= 0) gen_gaddr(rd, globals[g].sym);
        else {
            int fi = func_find(nodes[n].name);
            if (fi < 0) err_node(n, "unknown name");
            gen_gaddr(rd, sym_ref(usym(funcs[fi].name)));
        }
    }
    nodes[n].type = TY_UPTR;
    dst_done(depth, rd);
}

static void gen_str(int n, int depth) {
    int rd = dst_reg(depth);
    gen_gaddr(rd, str_sym(nodes[n].name, (int)nodes[n].val));
    nodes[n].type = TY_UPTR;
    dst_done(depth, rd);
}

static int arg_count(int n) {
    int k = 0;
    for (int a = nodes[n].a; a; a = nodes[a].next) k++;
    return k;
}

static void gen_intrin(int n, int depth, int in) {
    bool store = in >= IN_ST8;
    if (arg_count(n) != (store ? 2 : 1)) err_node(n, "wrong arity in intrinsic");
    int t = intrin_type(in);
    int p = nodes[n].a;
    gen_value(p, depth);
    if (!store) {
        int rp = val_reg(depth, REG_S1);
        int rd = dst_reg(depth);
        em(mem_op(t, false), rd, rp, 0);                 /* zero-extend by construction */
        dst_done(depth, rd);
        nodes[n].type = t;
        return;
    }
    gen_value(nodes[p].next, depth + 1);
    int rp = val_reg(depth, REG_S1);
    int rv = val_reg(depth + 1, REG_S2);
    em(mem_op(t, true), rv, rp, 0);
    nodes[n].type = TY_VOID;
}

/* ---- raw output: emit(), reloc() and #opcode calls ---- */
/* a 32-bit word in the instruction stream; the pending relocation sticks to it */
static void gen_word(int n, i64 w) {
    if ((u64)w > 0xffffffffu) err_node(n, "emitted word does not fit in 32 bits");
    if (pend_type >= 0) {                        /* the pending relocation sticks to this word */
        /* UNSIGNED is 8 bytes (length 3) and would overrun into the following word */
        if (pend_type == R_UNSIGNED)
            err_node(pend_node, "reloc UNSIGNED requires 8 bytes: use a global array initializer");
        if (nprel == MAXPREL) die("too many raw relocations");
        prel_ins[nprel] = nins - ins_base;            /* index relative to the function */
        prel_sym[nprel] = pend_sym; prel_type[nprel] = pend_type;
        nprel++;
        pend_type = -1;
    }
    ins_add(I_EMIT, 0, 0, 0, w, 0, 0);
    nodes[n].type = TY_VOID;
}
static void gen_emit(int n) {
    if (arg_count(n) != 1) err_node(n, "emit expects an argument");
    if (nodes[nodes[n].a].kind != N_INT) err_node(n, "emit expects a constant");
    gen_word(n, nodes[nodes[n].a].val);
}
static void gen_opcode(int n, int oi) {
    int e = opc_expand(oi, n);
    if (nodes[e].kind != N_INT) err_node(n, "#opcode argument not constant");
    gen_word(n, nodes[e].val);
}
/* reloc(TYPE, "symbol"): the next instruction generated must be the raw word */
static void gen_reloc(int n) {
    if (arg_count(n) != 2) err_node(n, "reloc expects two arguments");
    int a = nodes[n].a, b = nodes[a].next;
    if (nodes[a].kind != N_INT) err_node(n, "relocation type must be constant");
    if (nodes[b].kind != N_STR) err_node(n, "reloc expects the symbol in quotes");
    i64 t = nodes[a].val;
    if (t != R_UNSIGNED && t != R_BRANCH26 && t != R_PAGE21 && t != R_PAGEOFF12)
        err_node(n, "unknown relocation type");
    if (pend_type >= 0) err_node(n, "two relocations for the same word");
    pend_type = (int)t;
    pend_sym  = sym_ref(nodes[b].name);
    pend_node = n;
    nodes[n].type = TY_VOID;
}

/* saves the live depths (the ones in a register) before a call */
static void save_live(int depth) {
    for (int d = 0; d < depth && in_reg(d); d++)
        em(I_STR, REG_BASE + d, REG_FRAME, -slot_depth(d));
}
static void restore_live(int depth) {
    for (int d = 0; d < depth && in_reg(d); d++)
        em(I_LDR, REG_BASE + d, REG_FRAME, -slot_depth(d));
}
/* moves depth depth+i into register r (the ABI one, or callp's x16) */
static void arg_to_reg(int r, int d) {
    if (in_reg(d)) e2(I_MOV, r, REG_BASE + d);
    else           em(I_LDR, r, REG_FRAME, -slot_depth(d));
}

/* callp(p, a1..a7): args in x0..x6, pointer in x16 (outside the ABI), blr x16.
 * Same live-depth saving as bl; i64 result in x0. */
static void gen_callp(int n, int depth) {
    int na = arg_count(n);
    if (na < 1 || na > MAXPARAMS) err_node(n, "callp expects 1 to 8 arguments");
    int i = 0;
    for (int a = nodes[n].a; a; a = nodes[a].next) { gen_value(a, depth + i); i++; }
    save_live(depth);
    i = 0;                                       /* the pointer (arg 0) goes to x16 */
    for (int a = nodes[n].a; a; a = nodes[a].next) { arg_to_reg(i ? i - 1 : REG_S1, depth + i); i++; }
    ins_add(I_BLR, REG_S1, 0, 0, 0, 0, 0);
    restore_live(depth);
    int rd = dst_reg(depth);
    e2(I_MOV, rd, 0);
    dst_done(depth, rd);
    nodes[n].type = TY_I64;
}

/* call: args at depths cur..cur+n-1, saving of the live ones, bl, result */
static void gen_call(int n, int depth) {
    int in = intrin_id(nodes[n].name);
    if (in == IN_EMIT)  { gen_emit(n);  return; }
    if (in == IN_RELOC) { gen_reloc(n); return; }
    if (in == IN_CALLP) { gen_callp(n, depth); return; }
    if (in) { gen_intrin(n, depth, in); return; }
    int oi = opc_find(nodes[n].name);
    if (oi >= 0) { gen_opcode(n, oi); return; }
    int fi = func_find(nodes[n].name);
    if (fi < 0) err_node(n, "call to unknown function");
    if (arg_count(n) != funcs[fi].nparams) err_node(n, "wrong number of arguments");
    int i = 0;
    for (int a = nodes[n].a; a; a = nodes[a].next) { gen_value(a, depth + i); i++; }
    save_live(depth);                                /* live ones: the depths below */
    i = 0;
    for (int a = nodes[n].a; a; a = nodes[a].next) { arg_to_reg(i, depth + i); i++; }
    ins_add(I_BL, 0, 0, 0, 0, 0, sym_ref(usym(funcs[fi].name)));
    restore_live(depth);
    int rd = dst_reg(depth);
    e2(I_MOV, rd, 0);
    dst_done(depth, rd);
    nodes[n].type = funcs[fi].type;
}

static void gen_expr(int n, int depth) {
    if (depth >= MAXDEPTH) err_node(n, "expression too deep");
    int k = nodes[n].kind;
    if (k == N_INT) {
        int rd = dst_reg(depth);
        gen_imm(rd, (u64)nodes[n].val);
        dst_done(depth, rd);
        nodes[n].type = TY_I64;
        return;
    }
    if (k == N_UNARY)  { gen_unary(n, depth);  return; }
    if (k == N_BINARY) { gen_binary(n, depth); return; }
    if (k == N_CAST) {
        gen_value(nodes[n].a, depth);
        int rd = val_reg(depth, REG_S1);
        gen_cast(rd, nodes[n].type);
        dst_done(depth, rd);
        return;
    }
    if (k == N_STR)   { gen_str(n, depth);   return; }
    if (k == N_IDENT) { gen_ident(n, depth); return; }
    if (k == N_ADDR)  { gen_addr(n, depth);  return; }
    if (k == N_CALL)  { gen_call(n, depth);  return; }
    err_node(n, "expression with no codegen");
}

/* ---- statements ---- */
static void gen_stmt(int n, int lepi);

static void gen_var(int n) {
    int ty = nodes[n].type;
    if (nodes[n].val) {                          /* local array: nelem * width, to 16 */
        i64 nel = nodes[n].val;                  /* count in i64: (int) would truncate/overflow */
        if (nel < 1 || nel > 4095 || nel * type_width(ty) > 4095)
            err_node(n, "local array too large");
        int size = (int)(nel * type_width(ty));
        local_add(nodes[n].name, ty, slot_new((size + 15) & ~15), (int)nel);
        return;
    }
    if (nodes[n].a) gen_value(nodes[n].a, 0);    /* initializer before the name exists */
    int off = slot_new(8);
    local_add(nodes[n].name, ty, off, 0);
    if (nodes[n].a) em(mem_op(ty, true), REG_BASE, REG_FRAME, -off);
}

static void gen_assign(int n) {
    int i = name_find(n);
    if (i >= 0 ? locals[i].nelem != 0 : globals[-i - 1].nelem != 0)
        err_node(n, "assignment to array");
    gen_value(nodes[n].a, 0);
    if (i >= 0) { em(mem_op(locals[i].type, true), REG_BASE, REG_FRAME, -locals[i].off); return; }
    int g = -i - 1;
    gen_gaddr(REG_S1, globals[g].sym);           /* x16 is free: the expression already finished */
    em(mem_op(globals[g].type, true), REG_BASE, REG_S1, 0);
}

static void gen_if(int n, int lepi) {
    int lelse = ++nlabels;
    gen_value(nodes[n].a, 0);
    elr(I_CBZ, REG_BASE, lelse);
    gen_stmt(nodes[n].b, lepi);
    if (nodes[n].c) {
        int lend = ++nlabels;
        el(I_B, lend);
        el(I_LABEL, lelse);
        gen_stmt(nodes[n].c, lepi);
        el(I_LABEL, lend);
        return;
    }
    el(I_LABEL, lelse);
}

static void gen_loop(int n, int lepi) {
    if (nloops == MAXLOOPS) die("too many nested loops");
    int lbeg = ++nlabels, lend = ++nlabels;
    lcont[nloops] = lbeg; lbreak[nloops] = lend; nloops++;
    el(I_LABEL, lbeg);
    gen_stmt(nodes[n].a, lepi);
    el(I_B, lbeg);
    el(I_LABEL, lend);
    nloops--;
}

static void gen_stmt(int n, int lepi) {
    int k = nodes[n].kind;
    if (k == N_BLOCK) {
        int mark = nlocals;                      /* scope: names disappear, slots do not */
        for (int s = nodes[n].a; s; s = nodes[s].next) gen_stmt(s, lepi);
        nlocals = mark;
        return;
    }
    if (k == N_VAR)      { gen_var(n);         return; }
    if (k == N_ASSIGN)   { gen_assign(n);      return; }
    if (k == N_IF)       { gen_if(n, lepi);    return; }
    if (k == N_LOOP)     { gen_loop(n, lepi);  return; }
    if (k == N_BREAK) {
        i64 lv = nodes[n].val;                   /* validate in i64: (int) would truncate */
        if (lv < 1 || lv > nloops) err_node(n, "break out of range");
        el(I_B, lbreak[nloops - (int)lv]);
        return;
    }
    if (k == N_CONTINUE) {
        if (nloops == 0) err_node(n, "continue outside loop");
        el(I_B, lcont[nloops - 1]);
        return;
    }
    if (k == N_RETURN) {
        if (nodes[n].a) { gen_value(nodes[n].a, 0); e2(I_MOV, 0, REG_BASE); }
        el(I_B, lepi);
        return;
    }
    if (k == N_EXPRSTMT) { gen_expr(nodes[n].a, 0); return; }
    err_node(n, "statement with no codegen");
}

/* ---- text dump ---- */
static void d_reg(int r) {
    if (r == REG_SP) { out_str(1, "sp"); return; }
    out_str(1, "x"); out_num(1, r);
}
static void d_head(const char *m) { out_str(1, "  "); out_str(1, m); out_str(1, " "); }
static void d_3(const char *m, int rd, int rn, int rm) {
    d_head(m); d_reg(rd); out_str(1, ", "); d_reg(rn); out_str(1, ", "); d_reg(rm); out_str(1, "\n");
}
static void d_2(const char *m, int rd, int rn) {
    d_head(m); d_reg(rd); out_str(1, ", "); d_reg(rn); out_str(1, "\n");
}
static void d_i(const char *m, int rd, int rn, i64 imm) {
    d_head(m); d_reg(rd); out_str(1, ", "); d_reg(rn); out_str(1, ", #"); out_num(1, imm); out_str(1, "\n");
}
static void d_lab(const char *m, int label) {
    d_head(m); out_str(1, "L"); out_num(1, label); out_str(1, "\n");
}
/* ldr/str: 32-bit register for the short widths, base and offset inside [] */
static void d_mem(const char *m, bool wreg, int rt, int rn, i64 off) {
    d_head(m);
    if (wreg) { out_str(1, "w"); out_num(1, rt); } else d_reg(rt);
    out_str(1, ", ["); d_reg(rn);
    if (off) { out_str(1, ", #"); out_num(1, off); }
    out_str(1, "]\n");
}
/* a raw word always with 8 hexadecimal digits, so the dump is stable */
static const char hexdig[] = "0123456789abcdef";
static void d_word(u32 w) {
    out_str(1, "  .word 0x");
    for (int i = 7; i >= 0; i--) { char c = hexdig[(w >> (4 * i)) & 15]; out_bytes(1, &c, 1); }
    out_str(1, "\n");
}
static const char *rel_name(int t) {
    if (t == R_BRANCH26)  return "BRANCH26";
    if (t == R_PAGE21)    return "PAGE21";
    if (t == R_PAGEOFF12) return "PAGEOFF12";
    return "UNSIGNED";
}
static int rel_pcrel(int t) { return t == R_BRANCH26 || t == R_PAGE21; }
static int rel_len(int t)   { return t == R_UNSIGNED ? 3 : 2; }

static const char *cond_name(int c) {
    if (c == C_EQ) return "eq";
    if (c == C_NE) return "ne";
    if (c == C_GE) return "ge";
    if (c == C_LT) return "lt";
    if (c == C_GT) return "gt";
    if (c == C_LE) return "le";
    return "??";
}

static void dump_ins(Ins *in) {
    int op = in->op;
    if (op == I_NOP) return;
    if (op == I_LABEL) { out_str(1, "L"); out_num(1, in->label); out_str(1, ":\n"); return; }
    if (op == I_MOVZ || op == I_MOVK) {
        d_head(op == I_MOVZ ? "movz" : "movk");
        d_reg(in->rd); out_str(1, ", #"); out_num(1, in->imm);
        if (in->rn) { out_str(1, ", lsl #"); out_num(1, 16 * in->rn); }
        out_str(1, "\n");
        return;
    }
    for (int i = 0; rrr_ins[i]; i++)                      /* the 11 with 3 operands */
        if (op == rrr_ins[i]) { d_3(rrr_name[i], in->rd, in->rn, in->rm); return; }
    int mi = mem_slot(op);
    if (mi >= 0) { d_mem(mem_name[mi], mi >= 2, in->rd, in->rn, in->imm); return; }
    if (op == I_MOV)  { d_2("mov", in->rd, in->rn); return; }
    if (op == I_MOVW) { d_head("mov"); out_str(1, "w"); out_num(1, in->rd);
                        out_str(1, ", w"); out_num(1, in->rn); out_str(1, "\n"); return; }
    if (op == I_MSUB) { d_head("msub"); d_reg(in->rd); out_str(1, ", "); d_reg(in->rn);
                        out_str(1, ", "); d_reg(in->rm); out_str(1, ", ");
                        d_reg((int)in->imm); out_str(1, "\n"); return; }
    if (op == I_MVN)  { d_2("mvn", in->rd, in->rn); return; }
    if (op == I_NEG)  { d_2("neg", in->rd, in->rn); return; }
    if (op == I_CMP)  { d_head("cmp"); d_reg(in->rn); out_str(1, ", "); d_reg(in->rm);
                        out_str(1, "\n"); return; }
    if (op == I_CMPI) { d_head("cmp"); d_reg(in->rn); out_str(1, ", #"); out_num(1, in->imm);
                        out_str(1, "\n"); return; }
    if (op == I_CSET) { d_head("cset"); d_reg(in->rd); out_str(1, ", ");
                        out_str(1, cond_name((int)in->imm)); out_str(1, "\n"); return; }
    if (op == I_ANDI) { d_i("and", in->rd, in->rn, in->imm); return; }
    if (op == I_ADDI) { if (in->imm == 0) d_2("mov", in->rd, in->rn);
                        else d_i("add", in->rd, in->rn, in->imm); return; }
    if (op == I_SUBI) { d_i("sub", in->rd, in->rn, in->imm); return; }
    if (op == I_BL)   { d_head("bl"); out_str(1, symbols[in->sym].name); out_str(1, "\n"); return; }
    if (op == I_ADRP) { d_head("adrp"); d_reg(in->rd); out_str(1, ", ");
                        out_str(1, symbols[in->sym].name); out_str(1, "@PAGE\n"); return; }
    if (op == I_ADDLO){ d_head("add"); d_reg(in->rd); out_str(1, ", "); d_reg(in->rn);
                        out_str(1, ", "); out_str(1, symbols[in->sym].name);
                        out_str(1, "@PAGEOFF\n"); return; }
    if (op == I_STP_PRE)  { out_str(1, "  stp x29, x30, [sp, #-16]!\n"); return; }
    if (op == I_LDP_POST) { out_str(1, "  ldp x29, x30, [sp], #16\n");  return; }
    if (op == I_RET)  { out_str(1, "  ret\n"); return; }
    if (op == I_B)    { d_lab("b", in->label); return; }
    if (op == I_BCOND){ d_head("b."); out_str(1, cond_name((int)in->imm)); out_str(1, " L");
                        out_num(1, in->label); out_str(1, "\n"); return; }
    if (op == I_CBZ || op == I_CBNZ) {
                        d_head(op == I_CBZ ? "cbz" : "cbnz"); d_reg(in->rd);
                        out_str(1, ", L"); out_num(1, in->label); out_str(1, "\n"); return; }
    if (op == I_EMIT) { d_word((u32)in->imm); return; }
    if (op == I_BLR)  { d_head("blr"); d_reg(in->rd); out_str(1, "\n"); return; }
    die("instruction with no dump");
}

/* the buffer with the reloc() relocations before the word each one sticks to */
static void dump_buf(int f) {
    for (int k = 0; k < fn_count[f]; k++) {
        for (int j = 0; j < fn_pcount[f]; j++)
            if (prel_ins[fn_pstart[f] + j] == k) {
                out_str(1, "  .reloc "); out_str(1, rel_name(prel_type[fn_pstart[f] + j]));
                out_str(1, " "); out_str(1, symbols[prel_sym[fn_pstart[f] + j]].name);
                out_str(1, "\n");
            }
        dump_ins(&ibuf[fn_start[f] + k]);
    }
}

/* ---- encoders ---- */
/* always checks against the 19-bit range (the smallest of the three): conservative and uniform */
static u32 br_off(int target, int pc, int line_ok) {
    int d = (target - pc) / 4;
    if (line_ok && (d > 0x1ffff || d < -0x20000)) die("branch too far");
    return (u32)d;
}

/* ldr/str with an unsigned scaled offset (0..4095 * width) */
static u32 enc_mem(Ins *in, int i) {
    int scale = mem_scale[i];
    if (in->imm < 0 || in->imm % scale != 0 || in->imm / scale > 4095)
        die("memory offset out of range");
    return mem_base[i] | ((u32)(in->imm / scale) << 10) | ((u32)in->rn << 5) | (u32)in->rd;
}

static u32 encode(Ins *in, int pc, const int *lab) {
    int op = in->op, rd = in->rd, rn = in->rn, rm = in->rm;
    u32 im = (u32)in->imm;
    for (int i = 0; rrr_ins[i]; i++)                      /* the 11 with 3 operands rd, rn, rm */
        if (op == rrr_ins[i]) return rrr_base[i] | ((u32)rm << 16) | ((u32)rn << 5) | (u32)rd;
    int mi = mem_slot(op);
    if (mi >= 0) return enc_mem(in, mi);
    if (op == I_MOVZ) return 0xD2800000u | ((u32)rn << 21) | ((im & 0xffff) << 5) | (u32)rd;
    if (op == I_MOVK) return 0xF2800000u | ((u32)rn << 21) | ((im & 0xffff) << 5) | (u32)rd;
    if (op == I_MOV)  return 0xAA0003E0u | ((u32)rn << 16) | (u32)rd;    /* orr rd, xzr, rn */
    if (op == I_MOVW) return 0x2A0003E0u | ((u32)rn << 16) | (u32)rd;    /* orr wd, wzr, wn */
    if (op == I_MSUB) return 0x9B008000u | ((u32)rm << 16) | ((im & 0x1f) << 10)
                             | ((u32)rn << 5) | (u32)rd;                /* ra = imm */
    if (op == I_MVN)  return 0xAA2003E0u | ((u32)rn << 16) | (u32)rd;
    if (op == I_NEG)  return 0xCB0003E0u | ((u32)rn << 16) | (u32)rd;
    if (op == I_CMP)  return 0xEB00001Fu | ((u32)rm << 16) | ((u32)rn << 5);
    if (op == I_CMPI) {
        if (in->imm < 0 || in->imm > 4095) die("cmp immediate out of 12 bits");
        return 0xF100001Fu | ((im & 0xfff) << 10) | ((u32)rn << 5);
    }
    if (op == I_CSET) return 0x9A9F07E0u | (((u32)(in->imm ^ 1) & 0xf) << 12) | (u32)rd;
    if (op == I_ANDI) {                        /* 2^k-1 mask: N=1, immr=0, imms=k-1 */
        u64 m = (u64)in->imm;
        int k = 0;
        while (k < 64 && ((m >> k) & 1)) k++;
        if (k == 0 || k == 64 || (m >> k) != 0) die("immediate and mask not supported");
        return 0x92400000u | ((u32)(k - 1) << 10) | ((u32)rn << 5) | (u32)rd;
    }
    if (op == I_ADDI || op == I_SUBI) {
        if (in->imm < 0 || in->imm > 4095) die("add/sub immediate out of 12 bits");
        u32 base = op == I_ADDI ? 0x91000000u : 0xD1000000u;
        return base | ((im & 0xfff) << 10) | ((u32)rn << 5) | (u32)rd;
    }
    if (op == I_STP_PRE)  return 0xA9800000u | ((u32)((in->imm / 8) & 0x7f) << 15)
                                 | ((u32)rm << 10) | ((u32)rn << 5) | (u32)rd;
    if (op == I_LDP_POST) return 0xA8C00000u | ((u32)((in->imm / 8) & 0x7f) << 15)
                                 | ((u32)rm << 10) | ((u32)rn << 5) | (u32)rd;
    if (op == I_RET)   return 0xD65F03C0u;
    if (op == I_B)     return 0x14000000u | (br_off(lab[in->label], pc, 1) & 0x3ffffffu);
    if (op == I_BCOND) return 0x54000000u | ((br_off(lab[in->label], pc, 1) & 0x7ffffu) << 5)
                              | (im & 0xf);
    if (op == I_CBZ || op == I_CBNZ)                      /* bit 24 distinguishes cbz from cbnz */
                       return (op == I_CBZ ? 0xB4000000u : 0xB5000000u)
                              | ((br_off(lab[in->label], pc, 1) & 0x7ffffu) << 5) | (u32)rd;
    /* the offset for these three comes from the relocation registered in gen_encode */
    if (op == I_BL)    return 0x94000000u;
    if (op == I_ADRP)  return 0x90000000u | (u32)rd;
    if (op == I_ADDLO) return 0x91000000u | ((u32)rn << 5) | (u32)rd;
    if (op == I_EMIT)  return im;
    if (op == I_BLR)   return 0xD63F0000u | ((u32)rd << 5);
    die("instruction with no encoder");
}

/* encodes function f: reserves its spot in __text, fixes the symbol's value and
 * writes the words. This is the second half of gen — the one a backend replaces. */
static void gen_encode_one(int f) {
    Ins *b = &ibuf[fn_start[f]];
    int n = fn_count[f], text = fn_sec[f], p0 = fn_pstart[f];
    int *off = xalloc(sizeof(int) * (size_t)(n + 1));
    int *lab = xalloc(sizeof(int) * (size_t)(fn_labels[f] + 2));
    buf_pad(&sections[text].data, 4);                /* each function aligned to 4 */
    u64 base = sections[text].data.len;
    sym_set_value(fn_sym[f], base);
    int pc = 0;
    for (int i = 0; i < n; i++) {                    /* pass 1: offsets and labels */
        off[i] = pc;
        if (b[i].op == I_LABEL) lab[b[i].label] = pc;
        else if (b[i].op != I_NOP) pc += 4;
    }
    for (int i = 0; i < n; i++) {                    /* pass 2: words and relocations */
        if (b[i].op == I_LABEL || b[i].op == I_NOP) continue;
        u32 at = (u32)base + (u32)off[i];
        /* these three always carry a symbol; 0 is a valid index, so what
         * decides whether there is a relocation is the opcode, never the value of sym */
        if (b[i].op == I_BL)         reloc_add(text, at, b[i].sym, R_BRANCH26, 1, 2);
        else if (b[i].op == I_ADRP)  reloc_add(text, at, b[i].sym, R_PAGE21, 1, 2);
        else if (b[i].op == I_ADDLO) reloc_add(text, at, b[i].sym, R_PAGEOFF12, 0, 2);
        for (int k = 0; k < fn_pcount[f]; k++)       /* the ones reloc() hung here */
            if (prel_ins[p0 + k] == i)
                reloc_add(text, at, prel_sym[p0 + k], prel_type[p0 + k],
                          rel_pcrel(prel_type[p0 + k]), rel_len(prel_type[p0 + k]));
        buf_u32(&sections[text].data, encode(&b[i], off[i], lab));
    }
}

/* ---- functions ---- */
/* swaps the frame's fictitious base for sp: address = x29 - off = sp + (frame - off) */
static void fix_frame(int frame) {
    for (int i = ins_base; i < nins; i++)
        if (ibuf[i].rn == REG_FRAME) { ibuf[i].rn = REG_SP; ibuf[i].imm += frame; }
}

static void gen_func(int f, int text) {
    ins_base = nins; nlabels = 0; nlocals = 0; nloops = 0; frame_off = 0;
    prel_base = nprel; pend_type = -1;
    for (int d = 0; d < MAXDEPTH; d++) dslot[d] = 0;
    if ((sections[text].flags & 0xff) == S_ZEROFILL) err_node(f, "function in a zerofill section");
    int lepi = ++nlabels;

    ins_add(I_STP_PRE, REG_FP, REG_SP, REG_LR, -16, 0, 0);
    ei(I_ADDI, REG_FP, REG_SP, 0);               /* mov x29, sp */
    int isub = nins; ei(I_SUBI, REG_SP, REG_SP, 0);   /* frame only at the end */
    int i = 0;
    for (int p = nodes[f].a; p; p = nodes[p].next) {  /* params: x0..x7 go to the frame */
        int off = slot_new(8);
        local_add(nodes[p].name, nodes[p].type, off, 0);
        em(mem_op(nodes[p].type, true), i, REG_FRAME, -off);
        i++;
    }
    gen_stmt(nodes[f].b, lepi);
    if (pend_type >= 0) err_node(pend_node, "reloc without an immediately following emit");
    el(I_LABEL, lepi);
    int iadd = nins; ei(I_ADDI, REG_SP, REG_SP, 0);
    ins_add(I_LDP_POST, REG_FP, REG_SP, REG_LR, 16, 0, 0);
    e0(I_RET);

    int frame = (frame_off + 15) & ~15;           /* sp always aligned to 16 */
    if (frame > 4095) err_node(f, "frame too large");
    ibuf[isub].imm = frame; ibuf[iadd].imm = frame;
    if (frame == 0) { ibuf[isub].op = I_NOP; ibuf[iadd].op = I_NOP; }
    fix_frame(frame);

    if (nfn == MAXFUNCS) die("too many functions");   /* the function becomes a slice of ibuf */
    fn_start[nfn] = ins_base;  fn_count[nfn]  = nins - ins_base;
    fn_pstart[nfn] = prel_base; fn_pcount[nfn] = nprel - prel_base;
    fn_labels[nfn] = nlabels;  fn_sec[nfn]    = text;
    /* the symbol is born here (the symtab order is the lowering order); the value only in gen_encode_one */
    fn_sym[nfn] = sym_new(usym(nodes[f].name), text + 1, 0, true);
    nfn++;
}

/* section for a function or global: the current #section one, otherwise the default */
static int node_sec(int n, int def) { return nodes[n].sect ? secmap[nodes[n].sect - 1] : def; }

/* allocates each global and creates its symbol; runs before any function body */
static void gen_globals(int unit) {
    for (int g = unit; g; g = nodes[g].next) {
        if (nodes[g].kind != N_GLOBAL) continue;
        if (nglobals == MAXGLOBALS) die("too many globals");
        if (global_find(nodes[g].name) >= 0 || func_find(nodes[g].name) >= 0)
            err_node(g, "global name declared twice");
        int ty = nodes[g].type, w = type_width(ty);
        i64 nel = nodes[g].val;
        int sec = node_sec(g, nodes[g].a == 0 ? sec_bss : sec_data);
        if (nodes[g].a && (sections[sec].flags & 0xff) == S_ZEROFILL)
            err_node(g, "global with initializer in a zerofill section");
        u64 off = glob_place(g, sec, nel ? nel * w : w, w);
        globals[nglobals].name = nodes[g].name; globals[nglobals].type = ty;
        globals[nglobals].nelem = (int)nel;
        globals[nglobals].sym = sym_new(usym(nodes[g].name), sec + 1, off, false);
        nglobals++;
    }
}

/* __text, __cstring, __data and __bss (the ones the module uses) and only then the
 * #section ones, in order of first appearance in the source */
static void gen_sections(int unit) {
    bool want_str = false, want_data = false, want_bss = false;
    /* the reloc() string names a symbol and is not a literal: marking it in op excludes it
     * from __cstring's count (codegen also never passes it through str_sym) */
    for (int i = 1; i < nnodes; i++) {
        if (nodes[i].kind != N_CALL || intrin_id(nodes[i].name) != IN_RELOC) continue;
        int a = nodes[i].a;
        if (a && nodes[a].next) nodes[nodes[a].next].op = 1;
    }
    for (int i = 1; i < nnodes; i++)
        if (nodes[i].kind == N_STR && nodes[i].op == 0) want_str = true;
    for (int g = unit; g; g = nodes[g].next) {
        if (nodes[g].kind != N_GLOBAL || nodes[g].sect) continue;    /* custom already has a section */
        if (nodes[g].a == 0) want_bss = true;
        else                 want_data = true;
    }
    sec_text = sec_new("__TEXT", "__text", TEXT_FLAGS, 2);
    sec_cstr = -1; sec_data = -1; sec_bss = -1;
    if (want_str)  sec_cstr = sec_new("__TEXT", "__cstring", S_CSTRING_LITERALS, 0);
    if (want_data) sec_data = sec_new("__DATA", "__data", S_REGULAR, 4);
    if (want_bss)  sec_bss  = sec_new("__DATA", "__bss", S_ZEROFILL, 4);
    if (sec_pending() > MAXSECS) die("too many sections");
    for (int i = 0; i < sec_pending(); i++) secmap[i] = sec_make(i);
}

void gen_lower(int unit) {
    gen_sections(unit);
    for (int f = unit; f; f = nodes[f].next) {    /* signatures before the bodies */
        int k = nodes[f].kind;
        if (k != N_FUNC && k != N_EXTERN && k != N_PROTO) continue;
        int np = 0;
        for (int p = nodes[f].a; p; p = nodes[p].next) np++;
        if (np > MAXPARAMS) err_node(f, "at most 8 parameters");
        func_add(nodes[f].name, nodes[f].type, np, k != N_PROTO, f);
    }
    for (int i = 0; i < nfuncs; i++)              /* prototype with no definition or extern */
        if (!funcs[i].def) err_node(funcs[i].node, "prototype with no definition");
    gen_globals(unit);
    for (int f = unit; f; f = nodes[f].next)
        if (nodes[f].kind == N_FUNC) gen_func(f, node_sec(f, sec_text));
}

void gen_encode_all(void) { for (int f = 0; f < nfn; f++) gen_encode_one(f); }
void gen_dump_asm(void) {
    for (int f = 0; f < nfn; f++) {
        out_str(1, gen_func_name(f)); out_str(1, ":\n");
        dump_buf(f);
    }
}

/* ---- public accessors: everything a surface backend needs to read ---- */
int  gen_func_count(void)         { return nfn; }
const char *gen_func_name(int f)  { return symbols[fn_sym[f]].name; }
int  gen_func_sec(int f)          { return fn_sec[f]; }
int  gen_func_sym(int f)          { return fn_sym[f]; }
int  gen_func_labels(int f)       { return fn_labels[f]; }
int  gen_ins_count(int f)         { return fn_count[f]; }
Ins *gen_ins_at(int f, int i)     { return &ibuf[fn_start[f] + i]; }
int  gen_prel_count(int f)        { return fn_pcount[f]; }
int  gen_prel_ins(int f, int k)   { return prel_ins[fn_pstart[f] + k]; }
int  gen_prel_sym(int f, int k)   { return prel_sym[fn_pstart[f] + k]; }
int  gen_prel_type(int f, int k)  { return prel_type[fn_pstart[f] + k]; }
int  gen_global_count(void)       { return nglobals; }
int  gen_global_sym(int g)        { return globals[g].sym; }
int  gen_str_count(void)          { return nstrs; }
int  gen_str_sym(int s)           { return strs[s].sym; }
