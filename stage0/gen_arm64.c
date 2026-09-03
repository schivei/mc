/* gen_arm64.c — buffer linear de instrucoes por funcao + encoders AArch64.
 * A AST vira Ins[]; gen_encode resolve labels locais, registra relocacoes e
 * escreve palavras no __text. --dump-asm imprime o buffer antes de encodar.
 * Locais, parametros, salvamentos e spills moram no frame. As instrucoes saem
 * com a base ficticia REG_FRAME e deslocamento negativo a partir de x29; depois
 * de percorrer a funcao inteira, fix_frame troca a base por sp e o deslocamento
 * por (frame - off) — e por isso que o frame pode ser calculado no fim. */
#include "mc.h"

static Ins *ibuf; static int nins, inscap;
static int nlabels;

/* registradores: profundidade 0..6 em x9..x15; acima disso o valor mora no frame */
#define REG_BASE   9
#define REG_MAX    6
#define REG_TMP    8              /* scratch do resto (%) */
#define REG_S1    16              /* scratch de spill: esquerda/destino */
#define REG_S2    17              /* scratch de spill: direita */
#define REG_FP    29
#define REG_LR    30
#define REG_SP    31
#define REG_FRAME 32              /* base ficticia trocada por sp em fix_frame */
#define MAXDEPTH  64
#define MAXLOCALS 256
#define MAXFUNCS  512
#define MAXLOOPS  32
#define MAXPARAMS 8
#define MAXGLOBALS 256
#define MAXSTRS    512

/* ---- estado da funcao atual ---- */
static Local locals[MAXLOCALS]; static int nlocals;
static int dslot[MAXDEPTH];      /* slot da profundidade: salvamento (<=6) ou spill (>=7) */
static int frame_off;            /* bytes ja reservados no frame */
static int lbreak[MAXLOOPS], lcont[MAXLOOPS]; static int nloops;

/* assinaturas de todo o arquivo (N_FUNC e N_EXTERN), registradas antes dos corpos */
static FuncSig funcs[MAXFUNCS]; static int nfuncs;

/* ---- estado do modulo: globais, strings e as secoes em ordem fixa ---- */
static Global globals[MAXGLOBALS]; static int nglobals;
static StrEnt strs[MAXSTRS];       static int nstrs;
static int sec_text, sec_cstr, sec_data, sec_bss;   /* -1 = secao nao criada */

/* ---- buffer ---- */
static void ins_add(int op, int rd, int rn, int rm, i64 imm, int label, int sym) {
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

/* imediato de 64 bits em ate 4 instrucoes: movz do byte baixo + movk do resto */
static void gen_imm(int rd, u64 v) {
    ins_add(I_MOVZ, rd, 0, 0, (i64)(v & 0xffff), 0, 0);
    for (int hw = 1; hw < 4; hw++) {
        u64 part = (v >> (16 * hw)) & 0xffff;
        if (part) ins_add(I_MOVK, rd, hw, 0, (i64)part, 0, 0);
    }
}

/* ---- frame, profundidade e spill ---- */
static int slot_new(int size) {                  /* devolve o offset positivo a partir de x29 */
    frame_off += (size + 7) & ~7;
    return frame_off;
}
static int slot_depth(int d) {
    if (dslot[d] == 0) dslot[d] = slot_new(8);
    return dslot[d];
}
static bool in_reg(int depth) { return depth <= REG_MAX; }
/* registrador com o valor da profundidade; carrega do frame no scratch se spillado */
static int val_reg(int depth, int scratch) {
    if (in_reg(depth)) return REG_BASE + depth;
    em(I_LDR, scratch, REG_FRAME, -slot_depth(depth));
    return scratch;
}
static int dst_reg(int depth) { return in_reg(depth) ? REG_BASE + depth : REG_S1; }
static void dst_done(int depth, int rd) {
    if (!in_reg(depth)) em(I_STR, rd, REG_FRAME, -slot_depth(depth));
}

/* ---- tipos (a largura mora em ast.c: o parser tambem precisa dela) ---- */
static int ld_op(int t) {
    if (t == TY_U8)  return I_LDRB;
    if (t == TY_U16) return I_LDRH;
    if (t == TY_U32) return I_LDRW;
    return I_LDR;
}
static int st_op(int t) {
    if (t == TY_U8)  return I_STRB;
    if (t == TY_U16) return I_STRH;
    if (t == TY_U32) return I_STRW;
    return I_STR;
}

/* ---- locais (pilha plana, marca de tamanho por bloco) ---- */
static int local_find(const char *name) {
    for (int i = nlocals - 1; i >= 0; i--) if (str_eq(locals[i].name, name)) return i;
    return -1;
}
static void local_add(const char *name, int type, int off, int nelem) {
    if (nlocals == MAXLOCALS) die("locais demais");
    locals[nlocals].name = name; locals[nlocals].type = type;
    locals[nlocals].off = off;   locals[nlocals].nelem = nelem;
    nlocals++;
}

/* ---- assinaturas ---- */
static int func_find(const char *name) {
    for (int i = 0; i < nfuncs; i++) if (str_eq(funcs[i].name, name)) return i;
    return -1;
}
static void func_add(const char *name, int type, int nparams, int n) {
    if (func_find(name) >= 0) err_node(n, "funcao declarada duas vezes");
    if (nfuncs == MAXFUNCS) die("funcoes demais");
    funcs[nfuncs].name = name; funcs[nfuncs].type = type; funcs[nfuncs].nparams = nparams;
    nfuncs++;
}
static const char *usym(const char *name) {      /* o compilador prefixa _ */
    size_t n = cstrlen(name);
    char *s = xalloc(n + 2);
    s[0] = '_';
    for (size_t i = 0; i < n; i++) s[i + 1] = name[i];
    s[n + 1] = 0;
    return s;
}

/* ---- globais: simbolo local proprio em __data (com valor) ou __bss (zerado) ---- */
static int global_find(const char *name) {
    for (int i = 0; i < nglobals; i++) if (str_eq(globals[i].name, name)) return i;
    return -1;
}
/* tudo no __bss comeca em multiplo de 16 e ocupa multiplo de 16 */
static u64 bss_alloc(i64 size) {
    u64 off = (sections[sec_bss].zsize + 15) & ~15ull;
    sections[sec_bss].zsize = off + (((u64)size + 15) & ~15ull);
    return off;
}
/* grava o inicializador com a largura do tipo, alinhado a ela */
static u64 data_put(i64 val, int width) {
    Buf *b = &sections[sec_data].data;
    buf_pad(b, (size_t)width);
    u64 off = b->len;
    if (width == 1)      buf_u8(b, (u8)val);
    else if (width == 2) buf_u16(b, (u16)val);
    else if (width == 4) buf_u32(b, (u32)val);
    else                 buf_u64(b, (u64)val);
    return off;
}

/* ---- strings: bytes + NUL em __cstring, simbolo local l_str<N> ---- */
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
/* deduplica por conteudo (busca linear); N segue a ordem da primeira ocorrencia */
static int str_sym(const char *bytes, int len) {
    for (int i = 0; i < nstrs; i++)
        if (strs[i].len == len && mem_eq(strs[i].bytes, bytes, (size_t)len)) return strs[i].sym;
    if (nstrs == MAXSTRS) die("strings demais");
    Buf *b = &sections[sec_cstr].data;
    u64 off = b->len;
    buf_put(b, bytes, (size_t)len);
    buf_u8(b, 0);                                /* __cstring guarda cada literal NUL-terminada */
    int sym = sym_new(str_name(nstrs), sec_cstr + 1, off, false);
    strs[nstrs].bytes = bytes; strs[nstrs].len = len; strs[nstrs].sym = sym;
    nstrs++;
    return sym;
}
/* endereco de um simbolo local: adrp da pagina + add do deslocamento */
static void gen_gaddr(int rd, int sym) {
    ins_add(I_ADRP,  rd, 0,  0, 0, 0, sym);
    ins_add(I_ADDLO, rd, rd, 0, 0, 0, sym);
}

/* ---- intrinsics de memoria (nome, nao simbolo) ---- */
enum { IN_NONE = 0, IN_LD8, IN_LD16, IN_LD32, IN_LD64, IN_ST8, IN_ST16, IN_ST32, IN_ST64 };
static int intrin_id(const char *name) {
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
/* tipo da largura acessada; tambem e o tipo do resultado das ld* */
static int intrin_type(int in) {
    if (in == IN_LD8  || in == IN_ST8)  return TY_U8;
    if (in == IN_LD16 || in == IN_ST16) return TY_U16;
    if (in == IN_LD32 || in == IN_ST32) return TY_U32;
    return TY_U64;
}

/* ---- expressoes ---- */
static void gen_expr(int n, int depth);

static void gen_value(int n, int depth) {        /* onde um valor e obrigatorio */
    gen_expr(n, depth);
    if (nodes[n].type == TY_VOID) err_node(n, "valor de tipo void");
}

static int cmp_cond(int op) {
    if (op == K_EQ) return C_EQ;
    if (op == K_NE) return C_NE;
    if (op == K_LT) return C_LT;
    if (op == K_LE) return C_LE;
    if (op == K_GT) return C_GT;
    if (op == K_GE) return C_GE;
    return -1;
}

static void gen_cast(int rd, int ty) {
    if (ty == TY_U8)       ei(I_ANDI, rd, rd, 0xff);
    else if (ty == TY_U16) ei(I_ANDI, rd, rd, 0xffff);
    else if (ty == TY_U32) e2(I_MOVW, rd, rd);        /* mov wd, wn zera o topo */
}

static void gen_unary(int n, int depth) {
    int op = nodes[n].op;
    gen_value(nodes[n].a, depth);
    nodes[n].type = op == K_BANG ? TY_I64 : nodes[nodes[n].a].type;
    int rd = val_reg(depth, REG_S1);             /* opera no lugar */
    if (op == K_SUB)        e2(I_NEG, rd, rd);
    else if (op == K_TILDE) e2(I_MVN, rd, rd);
    else if (op == K_BANG)  { ei(I_CMPI, 0, rd, 0); ins_add(I_CSET, rd, 0, 0, C_EQ, 0, 0); }
    else err_node(n, "operador unario sem codegen");
    dst_done(depth, rd);
}

/* && e || com curto-circuito, via labels locais */
static void gen_logic(int n, int depth) {
    int lalt = ++nlabels, lend = ++nlabels;
    bool andand = nodes[n].op == K_ANDAND;
    int rd = dst_reg(depth);
    gen_value(nodes[n].a, depth);
    /* atalho: && desvia quando a e falso, || quando a e verdadeiro */
    elr(andand ? I_CBZ : I_CBNZ, val_reg(depth, REG_S1), lalt);
    gen_value(nodes[n].b, depth);                /* sem atalho: resultado e (b != 0) */
    ei(I_CMPI, 0, val_reg(depth, REG_S1), 0);
    ins_add(I_CSET, rd, 0, 0, C_NE, 0, 0);
    dst_done(depth, rd);
    el(I_B, lend);
    el(I_LABEL, lalt);
    gen_imm(rd, andand ? 0 : 1);                 /* valor do atalho */
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
    if (cond >= 0) { e3(I_CMP, 0, rl, rr); ins_add(I_CSET, rd, 0, 0, cond, 0, 0); }
    else if (op == K_ADD) e3(I_ADD,  rd, rl, rr);
    else if (op == K_SUB) e3(I_SUB,  rd, rl, rr);
    else if (op == K_MUL) e3(I_MUL,  rd, rl, rr);
    else if (op == K_DIV) e3(I_SDIV, rd, rl, rr);
    else if (op == K_MOD) { e3(I_SDIV, REG_TMP, rl, rr);
                            ins_add(I_MSUB, rd, REG_TMP, rr, rl, 0, 0); }  /* rd = rl - q*rr */
    else if (op == K_AND) e3(I_AND,  rd, rl, rr);
    else if (op == K_OR)  e3(I_ORR,  rd, rl, rr);
    else if (op == K_XOR) e3(I_EOR,  rd, rl, rr);
    else if (op == K_SHL) e3(I_LSLV, rd, rl, rr);
    else if (op == K_SHR) e3(nodes[nodes[n].a].type == TY_I64 ? I_ASRV : I_LSRV, rd, rl, rr);
    else err_node(n, "operador binario sem codegen");
    dst_done(depth, rd);
}

/* nome: local primeiro, global depois. Array decai para o endereco (uptr);
 * escalar e lido pela largura do tipo. */
static void gen_ident(int n, int depth) {
    int rd = dst_reg(depth);
    int i = local_find(nodes[n].name);
    if (i >= 0) {
        if (locals[i].nelem) {
            ei(I_ADDI, rd, REG_FRAME, -locals[i].off);
            nodes[n].type = TY_UPTR;
        } else {
            em(ld_op(locals[i].type), rd, REG_FRAME, -locals[i].off);
            nodes[n].type = locals[i].type;
        }
        dst_done(depth, rd);
        return;
    }
    int g = global_find(nodes[n].name);
    if (g < 0) err_node(n, "nome desconhecido");
    gen_gaddr(rd, globals[g].sym);
    if (globals[g].nelem) nodes[n].type = TY_UPTR;
    else {
        em(ld_op(globals[g].type), rd, rd, 0);
        nodes[n].type = globals[g].type;
    }
    dst_done(depth, rd);
}

static void gen_addr(int n, int depth) {
    int rd = dst_reg(depth);
    int i = local_find(nodes[n].name);
    if (i >= 0) ei(I_ADDI, rd, REG_FRAME, -locals[i].off);
    else {
        int g = global_find(nodes[n].name);
        if (g < 0) err_node(n, "nome desconhecido em &");
        gen_gaddr(rd, globals[g].sym);
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
    if (arg_count(n) != (store ? 2 : 1)) err_node(n, "aridade errada na intrinsic");
    int t = intrin_type(in);
    int p = nodes[n].a;
    gen_value(p, depth);
    if (!store) {
        int rp = val_reg(depth, REG_S1);
        int rd = dst_reg(depth);
        em(ld_op(t), rd, rp, 0);                 /* zero-extend por construcao */
        dst_done(depth, rd);
        nodes[n].type = t;
        return;
    }
    gen_value(nodes[p].next, depth + 1);
    int rp = val_reg(depth, REG_S1);
    int rv = val_reg(depth + 1, REG_S2);
    em(st_op(t), rv, rp, 0);
    nodes[n].type = TY_VOID;
}

/* chamada: args nas profundidades cur..cur+n-1, salvamento dos vivos, bl, resultado */
static void gen_call(int n, int depth) {
    int in = intrin_id(nodes[n].name);
    if (in) { gen_intrin(n, depth, in); return; }
    int fi = func_find(nodes[n].name);
    if (fi < 0) err_node(n, "chamada a funcao desconhecida");
    if (arg_count(n) != funcs[fi].nparams) err_node(n, "numero de argumentos errado");
    int i = 0;
    for (int a = nodes[n].a; a; a = nodes[a].next) { gen_value(a, depth + i); i++; }
    for (int d = 0; d < depth && in_reg(d); d++)      /* vivos: profundidades abaixo */
        em(I_STR, REG_BASE + d, REG_FRAME, -slot_depth(d));
    i = 0;
    for (int a = nodes[n].a; a; a = nodes[a].next) {
        if (in_reg(depth + i)) e2(I_MOV, i, REG_BASE + depth + i);
        else                   em(I_LDR, i, REG_FRAME, -slot_depth(depth + i));
        i++;
    }
    ins_add(I_BL, 0, 0, 0, 0, 0, sym_ref(usym(funcs[fi].name)));
    for (int d = 0; d < depth && in_reg(d); d++)
        em(I_LDR, REG_BASE + d, REG_FRAME, -slot_depth(d));
    int rd = dst_reg(depth);
    e2(I_MOV, rd, 0);
    dst_done(depth, rd);
    nodes[n].type = funcs[fi].type;
}

static void gen_expr(int n, int depth) {
    if (depth >= MAXDEPTH) err_node(n, "expressao profunda demais");
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
    err_node(n, "expressao sem codegen");
}

/* ---- statements ---- */
static void gen_stmt(int n, int lepi);

static void gen_var(int n) {
    int ty = nodes[n].type;
    if (nodes[n].val) {                          /* array local: nelem * largura, a 16 */
        i64 nel = nodes[n].val;                  /* conta em i64: (int) truncaria/estouraria */
        if (nel < 1 || nel > 4095 || nel * type_width(ty) > 4095)
            err_node(n, "array local grande demais");
        int size = (int)(nel * type_width(ty));
        local_add(nodes[n].name, ty, slot_new((size + 15) & ~15), (int)nel);
        return;
    }
    if (nodes[n].a) gen_value(nodes[n].a, 0);    /* inicializador antes de o nome existir */
    int off = slot_new(8);
    local_add(nodes[n].name, ty, off, 0);
    if (nodes[n].a) em(st_op(ty), REG_BASE, REG_FRAME, -off);
}

static void gen_assign(int n) {
    int i = local_find(nodes[n].name);
    if (i >= 0) {
        if (locals[i].nelem) err_node(n, "atribuicao a array");
        gen_value(nodes[n].a, 0);
        em(st_op(locals[i].type), REG_BASE, REG_FRAME, -locals[i].off);
        return;
    }
    int g = global_find(nodes[n].name);
    if (g < 0)            err_node(n, "nome desconhecido na atribuicao");
    if (globals[g].nelem) err_node(n, "atribuicao a array");
    gen_value(nodes[n].a, 0);
    gen_gaddr(REG_S1, globals[g].sym);           /* x16 esta livre: a expressao ja terminou */
    em(st_op(globals[g].type), REG_BASE, REG_S1, 0);
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
    if (nloops == MAXLOOPS) die("loops aninhados demais");
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
        int mark = nlocals;                      /* escopo: nomes somem, slots nao */
        for (int s = nodes[n].a; s; s = nodes[s].next) gen_stmt(s, lepi);
        nlocals = mark;
        return;
    }
    if (k == N_VAR)      { gen_var(n);         return; }
    if (k == N_ASSIGN)   { gen_assign(n);      return; }
    if (k == N_IF)       { gen_if(n, lepi);    return; }
    if (k == N_LOOP)     { gen_loop(n, lepi);  return; }
    if (k == N_BREAK) {
        i64 lv = nodes[n].val;                   /* validar em i64: (int) truncaria */
        if (lv < 1 || lv > nloops) err_node(n, "break fora de alcance");
        el(I_B, lbreak[nloops - (int)lv]);
        return;
    }
    if (k == N_CONTINUE) {
        if (nloops == 0) err_node(n, "continue fora de loop");
        el(I_B, lcont[nloops - 1]);
        return;
    }
    if (k == N_RETURN) {
        if (nodes[n].a) { gen_value(nodes[n].a, 0); e2(I_MOV, 0, REG_BASE); }
        el(I_B, lepi);
        return;
    }
    if (k == N_EXPRSTMT) { gen_expr(nodes[n].a, 0); return; }
    err_node(n, "statement sem codegen");
}

/* ---- dump em texto ---- */
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
/* ldr/str: registrador de 32 bits nas larguras curtas, base e deslocamento entre [] */
static void d_mem(const char *m, bool wreg, int rt, int rn, i64 off) {
    d_head(m);
    if (wreg) { out_str(1, "w"); out_num(1, rt); } else d_reg(rt);
    out_str(1, ", ["); d_reg(rn);
    if (off) { out_str(1, ", #"); out_num(1, off); }
    out_str(1, "]\n");
}
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
    if (op == I_MOV)  { d_2("mov", in->rd, in->rn); return; }
    if (op == I_MOVW) { d_head("mov"); out_str(1, "w"); out_num(1, in->rd);
                        out_str(1, ", w"); out_num(1, in->rn); out_str(1, "\n"); return; }
    if (op == I_ADD)  { d_3("add",  in->rd, in->rn, in->rm); return; }
    if (op == I_SUB)  { d_3("sub",  in->rd, in->rn, in->rm); return; }
    if (op == I_MUL)  { d_3("mul",  in->rd, in->rn, in->rm); return; }
    if (op == I_SDIV) { d_3("sdiv", in->rd, in->rn, in->rm); return; }
    if (op == I_MSUB) { d_head("msub"); d_reg(in->rd); out_str(1, ", "); d_reg(in->rn);
                        out_str(1, ", "); d_reg(in->rm); out_str(1, ", ");
                        d_reg((int)in->imm); out_str(1, "\n"); return; }
    if (op == I_AND)  { d_3("and",  in->rd, in->rn, in->rm); return; }
    if (op == I_ORR)  { d_3("orr",  in->rd, in->rn, in->rm); return; }
    if (op == I_EOR)  { d_3("eor",  in->rd, in->rn, in->rm); return; }
    if (op == I_MVN)  { d_2("mvn", in->rd, in->rn); return; }
    if (op == I_NEG)  { d_2("neg", in->rd, in->rn); return; }
    if (op == I_LSLV) { d_3("lsl",  in->rd, in->rn, in->rm); return; }
    if (op == I_LSRV) { d_3("lsr",  in->rd, in->rn, in->rm); return; }
    if (op == I_ASRV) { d_3("asr",  in->rd, in->rn, in->rm); return; }
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
    if (op == I_LDR)  { d_mem("ldr",  false, in->rd, in->rn, in->imm); return; }
    if (op == I_STR)  { d_mem("str",  false, in->rd, in->rn, in->imm); return; }
    if (op == I_LDRW) { d_mem("ldr",  true,  in->rd, in->rn, in->imm); return; }
    if (op == I_STRW) { d_mem("str",  true,  in->rd, in->rn, in->imm); return; }
    if (op == I_LDRH) { d_mem("ldrh", true,  in->rd, in->rn, in->imm); return; }
    if (op == I_STRH) { d_mem("strh", true,  in->rd, in->rn, in->imm); return; }
    if (op == I_LDRB) { d_mem("ldrb", true,  in->rd, in->rn, in->imm); return; }
    if (op == I_STRB) { d_mem("strb", true,  in->rd, in->rn, in->imm); return; }
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
    die("instrucao sem dump");
}

/* ---- encoders ---- */
/* checa sempre no alcance de 19 bits (o menor dos tres): conservador e uniforme */
static u32 br_off(int target, int pc, int line_ok) {
    int d = (target - pc) / 4;
    if (line_ok && (d > 0x1ffff || d < -0x20000)) die("desvio longe demais");
    return (u32)d;
}

/* ldr/str com deslocamento escalado sem sinal (0..4095 * largura) */
static u32 enc_mem(Ins *in) {
    int op = in->op;
    u32 base = 0; int scale = 8;
    if (op == I_LDR)       { base = 0xF9400000u; scale = 8; }
    else if (op == I_STR)  { base = 0xF9000000u; scale = 8; }
    else if (op == I_LDRW) { base = 0xB9400000u; scale = 4; }
    else if (op == I_STRW) { base = 0xB9000000u; scale = 4; }
    else if (op == I_LDRH) { base = 0x79400000u; scale = 2; }
    else if (op == I_STRH) { base = 0x79000000u; scale = 2; }
    else if (op == I_LDRB) { base = 0x39400000u; scale = 1; }
    else                   { base = 0x39000000u; scale = 1; }
    if (in->imm < 0 || in->imm % scale != 0 || in->imm / scale > 4095)
        die("deslocamento de memoria fora de alcance");
    return base | ((u32)(in->imm / scale) << 10) | ((u32)in->rn << 5) | (u32)in->rd;
}

/* opcodes de 3 operandos registrador-registrador: mesma forma, so muda a base */
static const int rrr_ins[] = { I_ADD, I_SUB, I_MUL, I_SDIV, I_AND, I_ORR, I_EOR,
                               I_LSLV, I_LSRV, I_ASRV, 0 };
static const u32 rrr_base[] = { 0x8B000000u, 0xCB000000u, 0x9B007C00u, 0x9AC00C00u, 0x8A000000u,
                                0xAA000000u, 0xCA000000u, 0x9AC02000u, 0x9AC02400u, 0x9AC02800u };

static u32 encode(Ins *in, int pc, const int *lab) {
    int op = in->op, rd = in->rd, rn = in->rn, rm = in->rm;
    u32 im = (u32)in->imm;
    for (int i = 0; rrr_ins[i]; i++)                      /* os 10 de 3 operandos rd, rn, rm */
        if (op == rrr_ins[i]) return rrr_base[i] | ((u32)rm << 16) | ((u32)rn << 5) | (u32)rd;
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
        if (in->imm < 0 || in->imm > 4095) die("imediato de cmp fora de 12 bits");
        return 0xF100001Fu | ((im & 0xfff) << 10) | ((u32)rn << 5);
    }
    if (op == I_CSET) return 0x9A9F07E0u | (((u32)(in->imm ^ 1) & 0xf) << 12) | (u32)rd;
    if (op == I_ANDI) {                        /* mascara 2^k-1: N=1, immr=0, imms=k-1 */
        u64 m = (u64)in->imm;
        int k = 0;
        while (k < 64 && ((m >> k) & 1)) k++;
        if (k == 0 || k == 64 || (m >> k) != 0) die("mascara de and imediato nao suportada");
        return 0x92400000u | ((u32)(k - 1) << 10) | ((u32)rn << 5) | (u32)rd;
    }
    if (op == I_ADDI || op == I_SUBI) {
        if (in->imm < 0 || in->imm > 4095) die("imediato de add/sub fora de 12 bits");
        u32 base = op == I_ADDI ? 0x91000000u : 0xD1000000u;
        return base | ((im & 0xfff) << 10) | ((u32)rn << 5) | (u32)rd;
    }
    if (op == I_LDR || op == I_STR || op == I_LDRW || op == I_STRW ||
        op == I_LDRH || op == I_STRH || op == I_LDRB || op == I_STRB) return enc_mem(in);
    if (op == I_STP_PRE)  return 0xA9800000u | ((u32)((in->imm / 8) & 0x7f) << 15)
                                 | ((u32)rm << 10) | ((u32)rn << 5) | (u32)rd;
    if (op == I_LDP_POST) return 0xA8C00000u | ((u32)((in->imm / 8) & 0x7f) << 15)
                                 | ((u32)rm << 10) | ((u32)rn << 5) | (u32)rd;
    if (op == I_RET)   return 0xD65F03C0u;
    if (op == I_B)     return 0x14000000u | (br_off(lab[in->label], pc, 1) & 0x3ffffffu);
    if (op == I_BCOND) return 0x54000000u | ((br_off(lab[in->label], pc, 1) & 0x7ffffu) << 5)
                              | (im & 0xf);
    if (op == I_CBZ || op == I_CBNZ)                      /* bit 24 distingue cbz de cbnz */
                       return (op == I_CBZ ? 0xB4000000u : 0xB5000000u)
                              | ((br_off(lab[in->label], pc, 1) & 0x7ffffu) << 5) | (u32)rd;
    /* o deslocamento destes tres vem da relocacao registrada em gen_encode */
    if (op == I_BL)    return 0x94000000u;
    if (op == I_ADRP)  return 0x90000000u | (u32)rd;
    if (op == I_ADDLO) return 0x91000000u | ((u32)rn << 5) | (u32)rd;
    if (op == I_EMIT)  return im;
    die("instrucao sem encoder");
}

static void gen_encode(int text, u64 base) {
    int *off = xalloc(sizeof(int) * (size_t)(nins + 1));
    int *lab = xalloc(sizeof(int) * (size_t)(nlabels + 2));
    int pc = 0;
    for (int i = 0; i < nins; i++) {                 /* passada 1: offsets e labels */
        off[i] = pc;
        if (ibuf[i].op == I_LABEL) lab[ibuf[i].label] = pc;
        else if (ibuf[i].op != I_NOP) pc += 4;
    }
    for (int i = 0; i < nins; i++) {                 /* passada 2: palavras e relocacoes */
        if (ibuf[i].op == I_LABEL || ibuf[i].op == I_NOP) continue;
        u32 at = (u32)base + (u32)off[i];
        /* estas tres sempre carregam simbolo; 0 e um indice valido, entao quem
         * decide se ha relocacao e o opcode, nunca o valor de sym */
        if (ibuf[i].op == I_BL)         reloc_add(text, at, ibuf[i].sym, R_BRANCH26, 1, 2);
        else if (ibuf[i].op == I_ADRP)  reloc_add(text, at, ibuf[i].sym, R_PAGE21, 1, 2);
        else if (ibuf[i].op == I_ADDLO) reloc_add(text, at, ibuf[i].sym, R_PAGEOFF12, 0, 2);
        buf_u32(&sections[text].data, encode(&ibuf[i], off[i], lab));
    }
}

/* ---- funcoes ---- */
/* troca a base ficticia do frame por sp: endereco = x29 - off = sp + (frame - off) */
static void fix_frame(int frame) {
    for (int i = 0; i < nins; i++)
        if (ibuf[i].rn == REG_FRAME) { ibuf[i].rn = REG_SP; ibuf[i].imm += frame; }
}

static void gen_func(int f, int text, bool dump) {
    nins = 0; nlabels = 0; nlocals = 0; nloops = 0; frame_off = 0;
    for (int d = 0; d < MAXDEPTH; d++) dslot[d] = 0;
    int lepi = ++nlabels;

    ins_add(I_STP_PRE, REG_FP, REG_SP, REG_LR, -16, 0, 0);
    ei(I_ADDI, REG_FP, REG_SP, 0);               /* mov x29, sp */
    int isub = nins; ei(I_SUBI, REG_SP, REG_SP, 0);   /* frame so no fim */
    int i = 0;
    for (int p = nodes[f].a; p; p = nodes[p].next) {  /* params: x0..x7 vao para o frame */
        int off = slot_new(8);
        local_add(nodes[p].name, nodes[p].type, off, 0);
        em(st_op(nodes[p].type), i, REG_FRAME, -off);
        i++;
    }
    gen_stmt(nodes[f].b, lepi);
    el(I_LABEL, lepi);
    int iadd = nins; ei(I_ADDI, REG_SP, REG_SP, 0);
    ins_add(I_LDP_POST, REG_FP, REG_SP, REG_LR, 16, 0, 0);
    e0(I_RET);

    int frame = (frame_off + 15) & ~15;           /* sp sempre alinhado a 16 */
    if (frame > 4095) err_node(f, "frame grande demais");
    ibuf[isub].imm = frame; ibuf[iadd].imm = frame;
    if (frame == 0) { ibuf[isub].op = I_NOP; ibuf[iadd].op = I_NOP; }
    fix_frame(frame);

    const char *sym = usym(nodes[f].name);
    if (dump) {
        out_str(1, sym); out_str(1, ":\n");
        for (int k = 0; k < nins; k++) dump_ins(&ibuf[k]);
    }
    buf_pad(&sections[text].data, 4);             /* cada funcao alinhada a 4 */
    u64 base = sections[text].data.len;
    sym_new(sym, text + 1, base, true);
    gen_encode(text, base);
}

/* aloca cada global e cria seu simbolo; roda antes de qualquer corpo de funcao */
static void gen_globals(int unit) {
    for (int g = unit; g; g = nodes[g].next) {
        if (nodes[g].kind != N_GLOBAL) continue;
        if (nglobals == MAXGLOBALS) die("globais demais");
        if (global_find(nodes[g].name) >= 0 || func_find(nodes[g].name) >= 0)
            err_node(g, "nome global declarado duas vezes");
        int ty = nodes[g].type, w = type_width(ty);
        i64 nel = nodes[g].val;
        int sec; u64 off;
        if (nel)                 { sec = sec_bss;  off = bss_alloc(nel * w); }
        else if (nodes[g].a)     { sec = sec_data; off = data_put(nodes[nodes[g].a].val, w); }
        else                     { sec = sec_bss;  off = bss_alloc(w); }
        globals[nglobals].name = nodes[g].name; globals[nglobals].type = ty;
        globals[nglobals].nelem = (int)nel;
        globals[nglobals].sym = sym_new(usym(nodes[g].name), sec + 1, off, false);
        nglobals++;
    }
}

/* secoes sempre nesta ordem, e so as que o modulo usa */
static void gen_sections(int unit) {
    sec_text = sec_new("__TEXT", "__text", TEXT_FLAGS, 2);
    sec_cstr = -1; sec_data = -1; sec_bss = -1;
    bool want_str = false, want_data = false, want_bss = false;
    for (int i = 1; i < nnodes; i++) if (nodes[i].kind == N_STR) want_str = true;
    for (int g = unit; g; g = nodes[g].next) {
        if (nodes[g].kind != N_GLOBAL) continue;
        if (nodes[g].val || nodes[g].a == 0) want_bss = true;
        else                                 want_data = true;
    }
    if (want_str)  sec_cstr = sec_new("__TEXT", "__cstring", S_CSTRING_LITERALS, 0);
    if (want_data) sec_data = sec_new("__DATA", "__data", S_REGULAR, 3);
    if (want_bss)  sec_bss  = sec_new("__DATA", "__bss", S_ZEROFILL, 4);
}

void gen_unit(int unit, bool dump) {
    gen_sections(unit);
    for (int f = unit; f; f = nodes[f].next) {    /* assinaturas antes dos corpos */
        int k = nodes[f].kind;
        if (k != N_FUNC && k != N_EXTERN) continue;
        int np = 0;
        for (int p = nodes[f].a; p; p = nodes[p].next) np++;
        if (np > MAXPARAMS) err_node(f, "no maximo 8 parametros");
        func_add(nodes[f].name, nodes[f].type, np, f);
    }
    gen_globals(unit);
    for (int f = unit; f; f = nodes[f].next)
        if (nodes[f].kind == N_FUNC) gen_func(f, sec_text, dump);
}
