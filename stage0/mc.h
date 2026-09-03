/* mc.h — declaracoes compartilhadas do stage0 (C23).
 * Tudo aqui tem a forma que tera em .mc: dados planos, indices no lugar de
 * ponteiros para nos, sem macro esperta. */
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
void *xalloc(size_t n);                    /* zerado, alinhado a 16 */
char *xstrdup(const char *s, size_t n);

typedef struct { u8 *p; size_t len, cap; } Buf;
void buf_put(Buf *b, const void *src, size_t n);
void buf_u8(Buf *b, u8 v);
void buf_u16(Buf *b, u16 v);
void buf_u32(Buf *b, u32 v);
void buf_u64(Buf *b, u64 v);
void buf_pad(Buf *b, size_t align);        /* preenche com zeros ate multiplo de align */
void buf_patch32(Buf *b, size_t off, u32 v);
u32  buf_get32(Buf *b, size_t off);

void out_str(int fd, const char *s);
void out_bytes(int fd, const void *p, size_t n);
void out_num(int fd, i64 v);
void out_hex(int fd, u64 v);
[[noreturn]] void die(const char *msg);
[[noreturn]] void die2(const char *msg, const char *detail);
/* arquivo:linha: msg — o arquivo vem sempre do token/no que deu a linha */
[[noreturn]] void err_at(const char *file, int line, const char *msg);
[[noreturn]] void err_at2(const char *file, int line, const char *msg, const char *detail);
u8  *read_file(const char *path, size_t *len);   /* NUL-terminado; die se falhar */
void write_file(const char *path, Buf *b);
size_t cstrlen(const char *s);
bool str_eq(const char *a, const char *b);
bool mem_eq(const void *a, const void *b, size_t n);

/* ---- tokens (lex.c) ---- */
enum { T_EOF = 0, T_IDENT = 1, T_INT = 2, T_CHAR = 3, T_STR = 4, T_DIR = 5, T_HOLE = 6 };

/* file: arquivo de onde o token saiu; o lexer ja pode ter voltado para outro */
typedef struct { int id; const u8 *start; int len; i64 val; int line; const char *file; } Token;
typedef struct { const char *text; int len; bool word; int id; } TokEnt;

/* ids do nucleo: 256 em diante, na ordem fixa de insercao feita por tok_init */
enum {
    K_U8 = 256, K_U16, K_U32, K_U64, K_I64, K_UPTR, K_VOID,
    K_IF, K_ELSE, K_LOOP, K_BREAK, K_CONTINUE, K_RETURN, K_EXTERN,
    K_LPAR, K_RPAR, K_LBRACE, K_RBRACE, K_LBRACK, K_RBRACK, K_COMMA, K_SEMI,
    K_ADD, K_SUB, K_MUL, K_DIV, K_MOD, K_AND, K_OR, K_XOR, K_TILDE, K_SHL, K_SHR,
    K_EQ, K_NE, K_LT, K_LE, K_GT, K_GE, K_ANDAND, K_OROR, K_BANG, K_ASSIGN,
    K_COLON, K_ARROW                 /* so o #rule usa: `stmt:` e `=>` */
};

/* diretivas conhecidas, na ordem da lista: val de um token T_DIR */
enum { D_INCLUDE = 0, D_DEFINE, D_TOKEN, D_INFIX, D_PREFIX, D_RULE, D_SECTION, D_OPCODE };

void tok_init(void);                       /* registra os lexemas do nucleo */
int  tok_add(const char *text, int len);   /* acha ou cria; devolve o id */
const char *tok_text(int id);              /* lexema do id (para dumps) */
void lex_init(const char *path);           /* abre o arquivo raiz; empilha o primeiro */
/* #include: resolve rel contra o diretorio do arquivo atual e empilha; false = ja incluido */
bool lex_include(const char *rel, int line);
void lex_next(Token *t);
const char *lex_file(void);                /* arquivo sendo lido agora (topo da pilha) */
void dump_tokens(void);

/* ---- AST (ast.c): array plano, nos referenciados por indice, 0 = nenhum ---- */
enum { N_NONE = 0, N_INT, N_STR, N_IDENT, N_UNARY, N_BINARY, N_CAST, N_CALL,
       N_RETURN, N_BLOCK, N_EXPRSTMT, N_FUNC, N_PARAM, N_HOLE,
       N_IF, N_LOOP, N_BREAK, N_CONTINUE, N_ASSIGN, N_VAR,
       N_GLOBAL,            /* reservado pelo plano para o M3 */
       N_EXTERN, N_ADDR,
       N_INDEX,             /* reservado pelo plano (nao ha p[i] no nucleo) */
       N_PROTO,             /* tipo nome(params); sem corpo */
       N_KIND_MAX };
enum { TY_VOID = 0, TY_U8, TY_U16, TY_U32, TY_U64, TY_I64, TY_UPTR, TY_MAX };

typedef struct {
    int kind, op, type;      /* op = id do token do operador (N_UNARY/N_BINARY) */
    i64 val;                 /* N_INT: valor; N_STR: tamanho; N_HOLE: numero */
    const char *name;        /* N_IDENT/N_FUNC/N_PARAM: nome; N_STR: bytes */
    int a, b, c, d;          /* filhos, sempre indices de no */
    int next;                /* proximo da lista */
    int sect;                /* N_FUNC/N_GLOBAL: secao do #section + 1; 0 = default */
    int line;
    const char *file;        /* arquivo de origem: o codegen roda depois do lexer */
} Node;

extern Node *nodes; extern int nnodes;
int  node_new(int kind, int line, const char *file);
/* copia profunda trocando N_HOLE(i) por holes[i] (i de 1 a nholes) */
int  node_copy_subst(int n, const int *holes, int nholes);
int  node_size(int n);           /* nos da subarvore + irmaos (so --dump-rules) */
[[noreturn]] void err_node(int n, const char *msg);   /* erro no arquivo/linha do no */
const char *type_name(int t);
int  type_width(int t);          /* bytes de um tipo */
void dump_ast(int n);

/* ---- limites compartilhados por parse.c e gen_arm64.c ---- */
#define MAXSECS   32              /* #section que o fonte pode registrar */
#define MAXPARAMS 8               /* nunca passa argumento pela pilha */

/* ---- parser (parse.c) ---- */
typedef struct { int tok, prec; bool right; int tmpl; } InfixEnt;  /* tmpl 0 = builtin */
typedef struct { int tok, tmpl; } PrefixEnt;
typedef struct { const char *name; i64 val; } DefEnt;   /* #define ja dobrado */
/* #opcode: template com os parametros ja trocados por N_HOLE numerados de 1 a nparams */
typedef struct { const char *name; int nparams, tmpl; } OpcEnt;
/* #section so registra aqui; a secao real nasce em gen_sections, na ordem certa */
typedef struct { const char *seg, *sect; u32 flags, align; } SecEnt;
/* #rule stmt: padrao plano -> template. Item = kind + val*8; kind IT_LIT guarda o
 * id do token literal, os demais o numero do buraco (de no) ou do nome.
 * lead = 1 quando o padrao comeca por `ident $x` antes do token de despacho. */
enum { IT_LIT = 0, IT_EXPR, IT_STMT, IT_BLOCK, IT_IDENT, IT_GEN };
#define MAXITEMS 16               /* itens de um padrao */
#define MAXNAMES 8                /* buracos de nome (ident $x e $$t) de uma regra */
typedef struct {
    int tok, lead, nitems, nholes, nnames, tmpl;
    int items[MAXITEMS];
    const char *ph[MAXNAMES];     /* placeholder de cada buraco de nome */
} RuleEnt;
int  parse_unit(void);       /* devolve a lista de N_FUNC do topo */
void dump_rules(void);       /* --dump-rules: as regras registradas, em ordem */
int  fold(int n);            /* dobra constantes no lugar; devolve n */
int  opc_find(const char *name);      /* indice na tabela de #opcode, -1 se nao ha */
int  opc_expand(int i, int call);     /* poe os args da chamada no template e dobra */
int  sec_pending(void);               /* quantos #section o fonte registrou */
int  sec_make(int i);                 /* cria a secao real do #section i */

/* ---- codegen (gen_arm64.c) ---- */
typedef struct { int op, rd, rn, rm; i64 imm; int label, sym; } Ins;
/* sym so vale para I_BL/I_ADRP/I_ADDLO: 0 e um indice de simbolo valido */
/* enum completo do plano; o M1 so implementa encoder do que usa */
enum { I_LABEL = 0, I_MOVZ, I_MOVK, I_MOVN, I_MOV, I_MOVW, I_ADD, I_SUB, I_MUL,
       I_SDIV, I_UDIV, I_MSUB, I_AND, I_ORR, I_EOR, I_MVN, I_NEG, I_LSLV, I_LSRV,
       I_ASRV, I_CMP, I_CMPI, I_CSET, I_ANDI, I_ADDI, I_SUBI, I_STP_PRE, I_LDP_POST,
       I_RET, I_B, I_BCOND, I_CBZ, I_CBNZ, I_BL, I_ADRP, I_ADDLO,
       I_LDR, I_STR, I_LDRB, I_STRB, I_LDRH, I_STRH, I_LDRW, I_STRW, I_EMIT,
       I_NOP,              /* I_NOP: apagada no fixup do frame, nao gera palavra */
       I_BLR };            /* blr xN: chamada indireta do callp */
/* condicoes AArch64 usadas pelo M1 */
enum { C_EQ = 0, C_NE = 1, C_GE = 10, C_LT = 11, C_GT = 12, C_LE = 13 };
/* local/parametro: endereco = x29 - off; nelem > 0 marca array */
typedef struct { const char *name; int type, off, nelem; } Local;
/* global: simbolo proprio em __data ou __bss; nelem > 0 marca array */
typedef struct { const char *name; int type, nelem, sym; } Global;
/* literal de string ja emitida em __cstring, para deduplicar por conteudo */
typedef struct { const char *bytes; int len, sym; } StrEnt;
/* assinatura do arquivo (N_FUNC, N_EXTERN ou N_PROTO), registrada antes dos corpos.
 * def = 0 enquanto so ha prototipo; node e o no que a declarou (para o erro final) */
typedef struct { const char *name; int type, nparams, def, node; } FuncSig;
/* o gen tem duas metades: gen_lower baixa a AST para os buffers Ins de cada
 * funcao (sem encodar) e gen_encode_all escreve as palavras no __text. O backend
 * embutido `macho` e gen_lower + gen_encode_all + macho_write; um backend da
 * superficie substitui a segunda metade usando so as acessoras abaixo. */
void gen_lower(int unit);
void gen_encode_all(void);
void gen_dump_asm(void);
int  gen_func_count(void);
const char *gen_func_name(int f);   /* nome do simbolo da funcao (ja com _) */
int  gen_func_sec(int f);
int  gen_func_sym(int f);
int  gen_func_labels(int f);        /* quantos labels a funcao usou */
int  gen_ins_count(int f);
Ins *gen_ins_at(int f, int i);
int  gen_prel_count(int f);         /* relocacoes cruas de reloc() na funcao */
int  gen_prel_ins(int f, int k);    /* indice da instrucao, relativo a funcao */
int  gen_prel_sym(int f, int k);
int  gen_prel_type(int f, int k);
int  gen_global_count(void);
int  gen_global_sym(int g);
int  gen_str_count(void);
int  gen_str_sym(int s);

/* ---- modelo de objeto (macho.c) ---- */
enum { R_UNSIGNED = 0, R_SUBTRACTOR = 1, R_BRANCH26 = 2, R_PAGE21 = 3,
       R_PAGEOFF12 = 4, R_ADDEND = 10 };

typedef struct { u32 off; int sym; u8 type, pcrel, len; } Reloc;
typedef struct {
    char seg[16], sect[16];
    u32  flags, align;              /* align em log2 */
    Buf  data;
    u64  zsize;                     /* tamanho se S_ZEROFILL */
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
int  sym_ref(const char *name);            /* acha ou cria indefinido */
void sym_set_value(int sym, u64 value);    /* o valor so e conhecido ao encodar */
void reloc_add(int sec, u32 off, int sym, int type, int pcrel, int len);
/* ordem final da symtab (particao estavel): order[k] = indice de criacao */
void sym_order(int *order, int *pos, int *count);
void dump_syms(void);
void macho_write(const char *path);
