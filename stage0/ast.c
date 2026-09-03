/* ast.c — nos em array plano na arena, referenciados por indice (0 = nenhum).
 * Nenhum campo guarda ponteiro para no: a e b e c e d e next sao indices. */
#include "mc.h"

Node *nodes; int nnodes; static int nodecap;

static void nodes_grow(void) {
    if (nnodes < nodecap) return;
    int cap = nodecap ? nodecap * 2 : 256;
    Node *n = xalloc(sizeof(Node) * (size_t)cap);
    for (int i = 0; i < nnodes; i++) n[i] = nodes[i];
    nodes = n; nodecap = cap;
}

/* file vem do token que deu a linha: o lexer ja pode ter voltado de um #include */
int node_new(int kind, int line, const char *file) {
    if (nnodes == 0) { nodes_grow(); nnodes = 1; }   /* indice 0 reservado */
    nodes_grow();
    Node *p = &nodes[nnodes];
    *p = (Node){0};
    p->kind = kind;
    p->line = line;
    p->file = file;
    return nnodes++;
}

/* o codegen roda com o lexer ja no fim: o arquivo tem de vir do proprio no */
void err_node(int n, const char *msg) { err_at(nodes[n].file, nodes[n].line, msg); }

/* copia profunda simples, sem substituir buraco nenhum (N_HOLE e copiado como e).
 * Cada chamada devolve subarvore nova: e o que impede dois usos do mesmo buraco
 * de virarem dois apontadores para o mesmo no. */
static int node_copy(int n) {
    if (n == 0) return 0;
    int c = node_new(nodes[n].kind, nodes[n].line, nodes[n].file);
    nodes[c] = nodes[n];
    int a  = node_copy(nodes[c].a);
    int b  = node_copy(nodes[c].b);
    int cc = node_copy(nodes[c].c);
    int d  = node_copy(nodes[c].d);
    int nx = node_copy(nodes[c].next);
    nodes[c].a = a; nodes[c].b = b; nodes[c].c = cc; nodes[c].d = d; nodes[c].next = nx;
    return c;
}

/* copia profunda; N_HOLE(i) vira uma COPIA de holes[i], com i de 1 ate nholes —
 * nunca o proprio indice, senao um buraco usado duas vezes no template daria dois
 * apontadores para o mesmo no. A lista (next) do buraco continua sendo do template.
 * Base do #infix/#prefix agora e do #rule no M9. */
int node_copy_subst(int n, const int *holes, int nholes) {
    if (n == 0) return 0;
    if (nodes[n].kind == N_HOLE) {
        i64 h = nodes[n].val;
        if (h < 1 || h > nholes) err_node(n, "buraco fora de alcance no template");
        int c = node_copy(holes[h]);
        int nx = node_copy_subst(nodes[n].next, holes, nholes);
        nodes[c].next = nx;
        return c;
    }
    int c = node_new(nodes[n].kind, nodes[n].line, nodes[n].file);
    nodes[c] = nodes[n];                         /* campos planos */
    int a  = node_copy_subst(nodes[c].a, holes, nholes);
    int b  = node_copy_subst(nodes[c].b, holes, nholes);
    int cc = node_copy_subst(nodes[c].c, holes, nholes);
    int d  = node_copy_subst(nodes[c].d, holes, nholes);
    int nx = node_copy_subst(nodes[c].next, holes, nholes);
    nodes[c].a = a; nodes[c].b = b; nodes[c].c = cc; nodes[c].d = d; nodes[c].next = nx;
    return c;
}

static const char *kind_names[] = {
    "NONE", "INT", "STR", "IDENT", "UNARY", "BINARY", "CAST", "CALL",
    "RETURN", "BLOCK", "EXPRSTMT", "FUNC", "PARAM", "HOLE",
    "IF", "LOOP", "BREAK", "CONTINUE", "ASSIGN", "VAR", "GLOBAL",
    "EXTERN", "ADDR", "INDEX", "PROTO" };
static const char *type_names[] = { "void", "u8", "u16", "u32", "u64", "i64", "uptr" };

const char *type_name(int t) { return (t >= 0 && t < TY_MAX) ? type_names[t] : "?"; }
/* largura em bytes de um tipo; uptr/i64/u64 sao 8 */
int type_width(int t) {
    if (t == TY_U8)  return 1;
    if (t == TY_U16) return 2;
    if (t == TY_U32) return 4;
    return 8;
}
static const char *kind_name(int k) { return (k >= 0 && k < N_KIND_MAX) ? kind_names[k] : "?"; }

static void dump_node(int n, int ind);
static void dump_list(int n, int ind) { for (int i = n; i; i = nodes[i].next) dump_node(i, ind); }

static void dump_node(int n, int ind) {
    for (int i = 0; i < ind; i++) out_str(1, "  ");
    out_str(1, kind_name(nodes[n].kind));
    if (nodes[n].op)   { out_str(1, " op=");   out_str(1, tok_text(nodes[n].op)); }
    if (nodes[n].kind == N_INT || nodes[n].val) { out_str(1, " val="); out_num(1, nodes[n].val); }
    if (nodes[n].type) { out_str(1, " type="); out_str(1, type_name(nodes[n].type)); }
    if (nodes[n].name) { out_str(1, " name="); out_str(1, nodes[n].name); }
    out_str(1, "\n");
    dump_list(nodes[n].a, ind + 1);
    dump_list(nodes[n].b, ind + 1);
    dump_list(nodes[n].c, ind + 1);
    dump_list(nodes[n].d, ind + 1);
}

void dump_ast(int n) { dump_list(n, 0); }
