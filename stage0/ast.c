/* ast.c — nodes in a flat array in the arena, referenced by index (0 = none).
 * No field holds a pointer to a node: a, b, c, d and next are all indices. */
#include "mc.h"

Node *nodes; int nnodes; static int nodecap;

static void nodes_grow(void) {
    if (nnodes < nodecap) return;
    int cap = nodecap ? nodecap * 2 : 256;
    Node *n = xalloc(sizeof(Node) * (size_t)cap);
    for (int i = 0; i < nnodes; i++) n[i] = nodes[i];
    nodes = n; nodecap = cap;
}

/* file comes from the token that gave the line: the lexer may already be back from an #include */
int node_new(int kind, int line, const char *file) {
    if (nnodes == 0) { nodes_grow(); nnodes = 1; }   /* index 0 reserved */
    nodes_grow();
    Node *p = &nodes[nnodes];
    *p = (Node){0};
    p->kind = kind;
    p->line = line;
    p->file = file;
    return nnodes++;
}

/* codegen runs with the lexer already at the end: the file has to come from the node itself */
void err_node(int n, const char *msg) { err_at(nodes[n].file, nodes[n].line, msg); }

/* simple deep copy, without substituting any hole (N_HOLE is copied as is).
 * Each call returns a new subtree: that is what keeps two uses of the same hole
 * from becoming two pointers to the same node. */
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

/* deep copy; N_HOLE(i) becomes a COPY of holes[i], with i from 1 to nholes —
 * never the index itself, otherwise a hole used twice in the template would give two
 * pointers to the same node. The hole's list (next) still belongs to the template.
 * Base of #infix/#prefix now comes from #rule in M9. */
int node_copy_subst(int n, const int *holes, int nholes) {
    if (n == 0) return 0;
    if (nodes[n].kind == N_HOLE) {
        i64 h = nodes[n].val;
        if (h < 1 || h > nholes) err_node(n, "hole out of range in template");
        int c = node_copy(holes[h]);
        int nx = node_copy_subst(nodes[n].next, holes, nholes);
        nodes[c].next = nx;
        return c;
    }
    int c = node_new(nodes[n].kind, nodes[n].line, nodes[n].file);
    nodes[c] = nodes[n];                         /* flat fields */
    int a  = node_copy_subst(nodes[c].a, holes, nholes);
    int b  = node_copy_subst(nodes[c].b, holes, nholes);
    int cc = node_copy_subst(nodes[c].c, holes, nholes);
    int d  = node_copy_subst(nodes[c].d, holes, nholes);
    int nx = node_copy_subst(nodes[c].next, holes, nholes);
    nodes[c].a = a; nodes[c].b = b; nodes[c].c = cc; nodes[c].d = d; nodes[c].next = nx;
    return c;
}

/* how many nodes the subtree has (with the sibling list): only --dump-rules uses this */
int node_size(int n) {
    if (n == 0) return 0;
    return 1 + node_size(nodes[n].a) + node_size(nodes[n].b) + node_size(nodes[n].c)
             + node_size(nodes[n].d) + node_size(nodes[n].next);
}

static const char *kind_names[] = {
    "NONE", "INT", "STR", "IDENT", "UNARY", "BINARY", "CAST", "CALL",
    "RETURN", "BLOCK", "EXPRSTMT", "FUNC", "PARAM", "HOLE",
    "IF", "LOOP", "BREAK", "CONTINUE", "ASSIGN", "VAR", "GLOBAL",
    "EXTERN", "ADDR", "INDEX", "PROTO" };
static const char *type_names[] = { "void", "u8", "u16", "u32", "u64", "i64", "uptr" };

const char *type_name(int t) { return (t >= 0 && t < TY_MAX) ? type_names[t] : "?"; }
/* width in bytes of a type; uptr/i64/u64 are 8 */
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
