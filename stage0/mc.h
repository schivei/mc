/* mc.h — shared declarations for stage0 (C23).
 * Everything here has the shape it will have in .mc: flat data, indices instead of
 * pointers to nodes, no clever macro. */
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t  i64;

/* ---- arena / buffers / io (arena.c) ---- */
void *xalloc(size_t n);                    /* zeroed, aligned to 16 */
char *xstrdup(const char *s, size_t n);

typedef struct { u8 *p; size_t len, cap; } Buf;
void buf_put(Buf *b, const void *src, size_t n);
void buf_u8(Buf *b, u8 v);
void buf_u16(Buf *b, u16 v);
void buf_u32(Buf *b, u32 v);
void buf_u64(Buf *b, u64 v);
void buf_pad(Buf *b, size_t align);        /* fills with zeros up to a multiple of align */
void buf_patch32(Buf *b, size_t off, u32 v);
u32  buf_get32(Buf *b, size_t off);

void out_str(int fd, const char *s);
void out_bytes(int fd, const void *p, size_t n);
void out_num(int fd, i64 v);
void out_hex(int fd, u64 v);
[[noreturn]] void die(const char *msg);
[[noreturn]] void die2(const char *msg, const char *detail);
/* file:line: msg — the file always comes from the token/node that gave the line */
[[noreturn]] void err_at(const char *file, int line, const char *msg);
[[noreturn]] void err_at2(const char *file, int line, const char *msg, const char *detail);
u8  *read_file(const char *path, size_t *len);   /* NUL-terminated; dies on failure */
void write_file(const char *path, Buf *b);
size_t cstrlen(const char *s);
bool str_eq(const char *a, const char *b);
bool mem_eq(const void *a, const void *b, size_t n);

/* ---- tokens (lex.c) ---- */
enum { T_EOF = 0, T_IDENT = 1, T_INT = 2, T_CHAR = 3, T_STR = 4, T_DIR = 5, T_HOLE = 6 };

/* file: the file the token came from; the lexer may already be back in another one */
typedef struct { int id; const u8 *start; int len; i64 val; int line; const char *file; } Token;
typedef struct { const char *text; int len; bool word; int id; } TokEnt;

/* core ids: 256 onward, in the fixed insertion order made by tok_init */
enum {
    K_U8 = 256, K_U16, K_U32, K_U64, K_I64, K_UPTR, K_VOID,
    K_IF, K_ELSE, K_LOOP, K_BREAK, K_CONTINUE, K_RETURN, K_EXTERN,
    K_LPAR, K_RPAR, K_LBRACE, K_RBRACE, K_LBRACK, K_RBRACK, K_COMMA, K_SEMI,
    K_ADD, K_SUB, K_MUL, K_DIV, K_MOD, K_AND, K_OR, K_XOR, K_TILDE, K_SHL, K_SHR,
    K_EQ, K_NE, K_LT, K_LE, K_GT, K_GE, K_ANDAND, K_OROR, K_BANG, K_ASSIGN,
    K_COLON, K_ARROW                 /* only #rule uses these: `stmt:` and `=>` */
};

/* known directives, in list order: val of a T_DIR token */
enum { D_INCLUDE = 0, D_DEFINE, D_TOKEN, D_INFIX, D_PREFIX, D_RULE, D_SECTION, D_OPCODE };

void tok_init(void);                       /* registers the core lexemes */
int  tok_add(const char *text, int len);   /* finds or creates; returns the id */
const char *tok_text(int id);              /* lexeme for the id (for dumps) */
void lex_init(const char *path);           /* opens the root file; pushes the first one */
/* #include: resolves rel against the current file's directory and pushes; false = already included */
bool lex_include(const char *rel, int line);
void lex_next(Token *t);
const char *lex_file(void);                /* file being read now (top of the stack) */
void dump_tokens(void);

/* ---- AST (ast.c): flat array, nodes referenced by index, 0 = none ---- */
enum { N_NONE = 0, N_INT, N_STR, N_IDENT, N_UNARY, N_BINARY, N_CAST, N_CALL,
       N_RETURN, N_BLOCK, N_EXPRSTMT, N_FUNC, N_PARAM, N_HOLE,
       N_IF, N_LOOP, N_BREAK, N_CONTINUE, N_ASSIGN, N_VAR,
       N_GLOBAL,            /* reserved by the plan for M3 */
       N_EXTERN, N_ADDR,
       N_INDEX,             /* reserved by the plan (there is no p[i] in the core) */
       N_PROTO,             /* type name(params); no body */
       N_KIND_MAX };
enum { TY_VOID = 0, TY_U8, TY_U16, TY_U32, TY_U64, TY_I64, TY_UPTR, TY_MAX };

typedef struct {
    int kind, op, type;      /* op = operator token id (N_UNARY/N_BINARY) */
    i64 val;                 /* N_INT: value; N_STR: length; N_HOLE: number */
    const char *name;        /* N_IDENT/N_FUNC/N_PARAM: name; N_STR: bytes */
    int a, b, c, d;          /* children, always node indices */
    int next;                /* next in the list */
    int sect;                /* N_FUNC/N_GLOBAL: #section index + 1; 0 = default */
    int line;
    const char *file;        /* source file: codegen runs after the lexer */
} Node;

extern Node *nodes; extern int nnodes;
int  node_new(int kind, int line, const char *file);
/* deep copy replacing N_HOLE(i) with holes[i] (i from 1 to nholes) */
int  node_copy_subst(int n, const int *holes, int nholes);
int  node_size(int n);           /* nodes in the subtree + siblings (only --dump-rules) */
[[noreturn]] void err_node(int n, const char *msg);   /* error at the node's file/line */
const char *type_name(int t);
int  type_width(int t);          /* bytes of a type */
void dump_ast(int n);

/* ---- limits shared by parse.c and gen_arm64.c ---- */
#define MAXSECS   32              /* #section entries the source may register */
#define MAXPARAMS 8               /* never passes an argument on the stack */

/* ---- parser (parse.c) ---- */
typedef struct { int tok, prec; bool right; int tmpl; } InfixEnt;  /* tmpl 0 = builtin */
typedef struct { int tok, tmpl; } PrefixEnt;
typedef struct { const char *name; i64 val; } DefEnt;   /* #define, already folded */
/* #opcode: template with the parameters already replaced by N_HOLE numbered 1 to nparams */
typedef struct { const char *name; int nparams, tmpl; } OpcEnt;
/* #section only registers here; the real section is born in gen_sections, in the right order */
typedef struct { const char *seg, *sect; u32 flags, align; } SecEnt;
/* #rule stmt: flat pattern -> template. Item = kind + val*8; kind IT_LIT holds the
 * literal token's id, the others the hole number (for a node) or the name.
 * lead = 1 when the pattern starts with `ident $x` before the dispatch token. */
enum { IT_LIT = 0, IT_EXPR, IT_STMT, IT_BLOCK, IT_IDENT, IT_GEN };
#define MAXITEMS 16               /* items in a pattern */
#define MAXNAMES 8                /* name holes (ident $x and $$t) in a rule */
typedef struct {
    int tok, lead, nitems, nholes, nnames, tmpl;
    int items[MAXITEMS];
    const char *ph[MAXNAMES];     /* placeholder for each name hole */
} RuleEnt;
int  parse_unit(void);       /* returns the top-level N_FUNC list */
void dump_rules(void);       /* --dump-rules: the registered rules, in order */
int  fold(int n);            /* folds constants in place; returns n */
int  opc_find(const char *name);      /* index in the #opcode table, -1 if none */
int  opc_expand(int i, int call);     /* puts the call's args into the template and folds */
int  sec_pending(void);               /* how many #section entries the source registered */
int  sec_make(int i);                 /* creates the real section for #section i */

/* ---- codegen (gen_arm64.c) ---- */
typedef struct { int op, rd, rn, rm; i64 imm; int label, sym; } Ins;
/* sym only applies to I_BL/I_ADRP/I_ADDLO: 0 is a valid symbol index */
/* full enum from the plan; M1 only implements the encoder for what it uses */
enum { I_LABEL = 0, I_MOVZ, I_MOVK, I_MOVN, I_MOV, I_MOVW, I_ADD, I_SUB, I_MUL,
       I_SDIV, I_UDIV, I_MSUB, I_AND, I_ORR, I_EOR, I_MVN, I_NEG, I_LSLV, I_LSRV,
       I_ASRV, I_CMP, I_CMPI, I_CSET, I_ANDI, I_ADDI, I_SUBI, I_STP_PRE, I_LDP_POST,
       I_RET, I_B, I_BCOND, I_CBZ, I_CBNZ, I_BL, I_ADRP, I_ADDLO,
       I_LDR, I_STR, I_LDRB, I_STRB, I_LDRH, I_STRH, I_LDRW, I_STRW, I_EMIT,
       I_NOP,              /* I_NOP: erased in the frame fixup, produces no word */
       I_BLR };            /* blr xN: callp's indirect call */
/* AArch64 conditions used by M1 */
enum { C_EQ = 0, C_NE = 1, C_GE = 10, C_LT = 11, C_GT = 12, C_LE = 13 };
/* local/parameter: address = x29 - off; nelem > 0 marks an array */
typedef struct { const char *name; int type, off, nelem; } Local;
/* global: own symbol in __data or __bss; nelem > 0 marks an array */
typedef struct { const char *name; int type, nelem, sym; } Global;
/* string literal already emitted in __cstring, for content-based deduplication */
typedef struct { const char *bytes; int len, sym; } StrEnt;
/* file signature (N_FUNC, N_EXTERN or N_PROTO), registered before the bodies.
 * def = 0 while there is only a prototype; node is the node that declared it (for the final error) */
typedef struct { const char *name; int type, nparams, def, node; } FuncSig;
/* gen has two halves: gen_lower lowers the AST into each function's Ins buffers
 * (without encoding) and gen_encode_all writes the words into __text. The
 * builtin `macho` backend is gen_lower + gen_encode_all + macho_write; a surface
 * backend replaces the second half using only the accessors below. */
void gen_lower(int unit);
void gen_encode_all(void);
void gen_dump_asm(void);
int  gen_func_count(void);
const char *gen_func_name(int f);   /* the function's symbol name (already with _) */
int  gen_func_sec(int f);
int  gen_func_sym(int f);
int  gen_func_labels(int f);        /* how many labels the function used */
int  gen_ins_count(int f);
Ins *gen_ins_at(int f, int i);
int  gen_prel_count(int f);         /* raw reloc() relocations in the function */
int  gen_prel_ins(int f, int k);    /* instruction index, relative to the function */
int  gen_prel_sym(int f, int k);
int  gen_prel_type(int f, int k);
int  gen_global_count(void);
int  gen_global_sym(int g);
int  gen_str_count(void);
int  gen_str_sym(int s);

/* ---- object model (macho.c) ---- */
enum { R_UNSIGNED = 0, R_SUBTRACTOR = 1, R_BRANCH26 = 2, R_PAGE21 = 3,
       R_PAGEOFF12 = 4, R_ADDEND = 10 };

typedef struct { u32 off; int sym; u8 type, pcrel, len; } Reloc;
typedef struct {
    char seg[16], sect[16];
    u32  flags, align;              /* align in log2 */
    Buf  data;
    u64  zsize;                     /* size if S_ZEROFILL */
    Reloc *rel; int nrel, relcap;
} Section;
typedef struct { const char *name; int sect; u64 value; bool global; } Symbol; /* sect 0 = undef */

#define S_REGULAR                0x0
#define S_ZEROFILL               0x1
#define S_CSTRING_LITERALS       0x2
#define S_ATTR_PURE_INSTRUCTIONS 0x80000000u
#define S_ATTR_SOME_INSTRUCTIONS 0x00000400u
#define TEXT_FLAGS (S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)

extern Section *sections; extern int nsections;
extern Symbol  *symbols;  extern int nsymbols;

int  sec_new(const char *seg, const char *sect, u32 flags, u32 align);
int  sec_find(const char *seg, const char *sect);
int  sym_new(const char *name, int sect, u64 value, bool global);
int  sym_find(const char *name);
int  sym_ref(const char *name);            /* finds or creates undefined */
void sym_set_value(int sym, u64 value);    /* the value is only known when encoding */
void reloc_add(int sec, u32 off, int sym, int type, int pcrel, int len);
/* final symtab order (stable partition): order[k] = creation index */
void sym_order(int *order, int *pos, int *count);
void dump_syms(void);
void macho_write(const char *path);
