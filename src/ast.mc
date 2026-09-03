// ast.mc — transliteration of stage0/ast.c: nodes in a flat array in the arena,
// referenced by index (0 = none). No field holds a pointer to a node:
// a, b, c, d and next are indices. Same functions, same order.
//
// No struct: Node is a flat 104-byte block. The layout below is derived from
// stage0/mc.h's struct Node (the C's current version; the table in
// docs/specs/M6-M7.md is out of date — today the node has sect and file):
//
//   C: typedef struct {
//          int kind, op, type;   // op = operator token id
//          i64 val;              // N_INT: value; N_STR: length; N_HOLE: number
//          const char *name;     // N_IDENT/N_FUNC/N_PARAM: name; N_STR: bytes
//          int a, b, c, d;       // children, always node indices
//          int next;             // next in the list
//          int sect;             // N_FUNC/N_GLOBAL: #section's section + 1
//          int line;
//          const char *file;     // codegen runs after the lexer
//      } Node;
//
// Every field occupies 8 bytes; the order matches C. The accessors take the node's
// INDEX (nd_kind(n)), exactly like `nodes[n].kind` in C — an ld64/st64 on the
// node never appears outside of them.
//
// Depends on arena.mc (xalloc, out_str, out_num, mem_copy, mem_zero, err_at) and on
// lex.mc (tok_text, only for the dump).

// ---- node kinds (mc.h enum, same order) ----
#define N_NONE     0
#define N_INT      1
#define N_STR      2
#define N_IDENT    3
#define N_UNARY    4
#define N_BINARY   5
#define N_CAST     6
#define N_CALL     7
#define N_RETURN   8
#define N_BLOCK    9
#define N_EXPRSTMT 10
#define N_FUNC     11
#define N_PARAM    12
#define N_HOLE     13
#define N_IF       14
#define N_LOOP     15
#define N_BREAK    16
#define N_CONTINUE 17
#define N_ASSIGN   18
#define N_VAR      19
#define N_GLOBAL   20
#define N_EXTERN   21
#define N_ADDR     22
#define N_INDEX    23
#define N_PROTO    24
#define N_KIND_MAX 25

// ---- types ----
#define TY_VOID 0
#define TY_U8   1
#define TY_U16  2
#define TY_U32  3
#define TY_U64  4
#define TY_I64  5
#define TY_UPTR 6
#define TY_MAX  7

// ---- Node: { kind, op, type, val, name, a, b, c, d, next, sect, line, file } ----
#define ND_KIND 0
#define ND_OP   8
#define ND_TYPE 16
#define ND_VAL  24
#define ND_NAME 32
#define ND_A    40
#define ND_B    48
#define ND_C    56
#define ND_D    64
#define ND_NEXT 72
#define ND_SECT 80
#define ND_LINE 88
#define ND_FILE 96
#define ND_SIZE 104

uptr nodes;                           // flat array; grows by doubling
i64  nnodes = 0;
i64  nodecap = 0;

// ---- Node accessors (node index, like nodes[n].field in C) ----
uptr node_at(i64 n)  { return nodes + n * ND_SIZE; }
i64  nd_kind(i64 n)  { return ld64(node_at(n) + ND_KIND); }
i64  nd_op(i64 n)    { return ld64(node_at(n) + ND_OP); }
i64  nd_type(i64 n)  { return ld64(node_at(n) + ND_TYPE); }
i64  nd_val(i64 n)   { return ld64(node_at(n) + ND_VAL); }
uptr nd_name(i64 n)  { return ld64(node_at(n) + ND_NAME); }
i64  nd_a(i64 n)     { return ld64(node_at(n) + ND_A); }
i64  nd_b(i64 n)     { return ld64(node_at(n) + ND_B); }
i64  nd_c(i64 n)     { return ld64(node_at(n) + ND_C); }
i64  nd_d(i64 n)     { return ld64(node_at(n) + ND_D); }
i64  nd_next(i64 n)  { return ld64(node_at(n) + ND_NEXT); }
i64  nd_sect(i64 n)  { return ld64(node_at(n) + ND_SECT); }
i64  nd_line(i64 n)  { return ld64(node_at(n) + ND_LINE); }
uptr nd_file(i64 n)  { return ld64(node_at(n) + ND_FILE); }
void set_nd_kind(i64 n, i64 v)  { st64(node_at(n) + ND_KIND, v); }
void set_nd_op(i64 n, i64 v)    { st64(node_at(n) + ND_OP, v); }
void set_nd_type(i64 n, i64 v)  { st64(node_at(n) + ND_TYPE, v); }
void set_nd_val(i64 n, i64 v)   { st64(node_at(n) + ND_VAL, v); }
void set_nd_name(i64 n, uptr v) { st64(node_at(n) + ND_NAME, v); }
void set_nd_a(i64 n, i64 v)     { st64(node_at(n) + ND_A, v); }
void set_nd_b(i64 n, i64 v)     { st64(node_at(n) + ND_B, v); }
void set_nd_c(i64 n, i64 v)     { st64(node_at(n) + ND_C, v); }
void set_nd_d(i64 n, i64 v)     { st64(node_at(n) + ND_D, v); }
void set_nd_next(i64 n, i64 v)  { st64(node_at(n) + ND_NEXT, v); }
void set_nd_sect(i64 n, i64 v)  { st64(node_at(n) + ND_SECT, v); }
void set_nd_line(i64 n, i64 v)  { st64(node_at(n) + ND_LINE, v); }
void set_nd_file(i64 n, uptr v) { st64(node_at(n) + ND_FILE, v); }

// C's `nodes[d] = nodes[s]` and `*p = (Node){0}`
void node_assign(i64 d, i64 s) { mem_copy(node_at(d), node_at(s), ND_SIZE); }
void node_zero(i64 n)          { mem_zero(node_at(n), ND_SIZE); }

void nodes_grow() {
    nodes = grow(T_NODES, nodes, nnodes, &nodecap, ND_SIZE);
}

// file comes from the token that gave the line: the lexer may already be back from an #include
i64 node_new(i64 kind, i64 line, uptr file) {
    if (nnodes == 0) { nodes_grow(); nnodes = 1; }   // index 0 reserved
    nodes_grow();
    node_zero(nnodes);
    set_nd_kind(nnodes, kind);
    set_nd_line(nnodes, line);
    set_nd_file(nnodes, file);
    nnodes = nnodes + 1;
    return nnodes - 1;
}

// codegen runs with the lexer already at the end: the file has to come from the node itself
void err_node(i64 n, uptr msg) { err_at(nd_file(n), nd_line(n), msg); }

// simple deep copy, without substituting any hole (N_HOLE is copied as-is).
// Each call returns a new subtree: that is what keeps two uses of the same hole
// from becoming two pointers to the same node.
i64 node_copy(i64 n) {
    if (n == 0) return 0;
    i64 c = node_new(nd_kind(n), nd_line(n), nd_file(n));
    node_assign(c, n);
    i64 a  = node_copy(nd_a(c));
    i64 b  = node_copy(nd_b(c));
    i64 cc = node_copy(nd_c(c));
    i64 d  = node_copy(nd_d(c));
    i64 nx = node_copy(nd_next(c));
    set_nd_a(c, a);
    set_nd_b(c, b);
    set_nd_c(c, cc);
    set_nd_d(c, d);
    set_nd_next(c, nx);
    return c;
}

// deep copy; N_HOLE(i) becomes a COPY of holes[i], with i from 1 to nholes —
// never the index itself, or a hole used twice in the template would give two
// pointers to the same node. The hole's list (next) still belongs to the template.
// Base for #infix/#prefix is now #rule as of M9.
i64 node_copy_subst(i64 n, uptr holes, i64 nholes) {
    if (n == 0) return 0;
    if (nd_kind(n) == N_HOLE) {
        i64 h = nd_val(n);
        if (h < 1 || h > nholes) err_node(n, "hole out of range in template");
        i64 c = node_copy(ld64(holes + h * 8));
        i64 nx = node_copy_subst(nd_next(n), holes, nholes);
        set_nd_next(c, nx);
        return c;
    }
    i64 c = node_new(nd_kind(n), nd_line(n), nd_file(n));
    node_assign(c, n);                           // flat fields
    i64 a  = node_copy_subst(nd_a(c), holes, nholes);
    i64 b  = node_copy_subst(nd_b(c), holes, nholes);
    i64 cc = node_copy_subst(nd_c(c), holes, nholes);
    i64 d  = node_copy_subst(nd_d(c), holes, nholes);
    i64 nx = node_copy_subst(nd_next(c), holes, nholes);
    set_nd_a(c, a);
    set_nd_b(c, b);
    set_nd_c(c, cc);
    set_nd_d(c, d);
    set_nd_next(c, nx);
    return c;
}

// how many nodes the subtree has (with the sibling list): only --dump-rules uses this
i64 node_size(i64 n) {
    if (n == 0) return 0;
    return 1 + node_size(nd_a(n)) + node_size(nd_b(n)) + node_size(nd_c(n))
             + node_size(nd_d(n)) + node_size(nd_next(n));
}

// stage0's two pointer arrays, in the same order as the enums
uptr kind_names[] = {
    "NONE", "INT", "STR", "IDENT", "UNARY", "BINARY", "CAST", "CALL",
    "RETURN", "BLOCK", "EXPRSTMT", "FUNC", "PARAM", "HOLE",
    "IF", "LOOP", "BREAK", "CONTINUE", "ASSIGN", "VAR", "GLOBAL",
    "EXTERN", "ADDR", "INDEX", "PROTO" };
uptr type_names[] = { "void", "u8", "u16", "u32", "u64", "i64", "uptr" };

uptr type_name(i64 t) {
    if (t >= 0 && t < TY_MAX) return ld64(type_names + t * 8);
    return "?";
}

// width in bytes of a type; uptr/i64/u64 are 8
i64 type_width(i64 t) {
    if (t == TY_U8)  return 1;
    if (t == TY_U16) return 2;
    if (t == TY_U32) return 4;
    return 8;
}

uptr kind_name(i64 k) {
    if (k >= 0 && k < N_KIND_MAX) return ld64(kind_names + k * 8);
    return "?";
}

void dump_list(i64 n, i64 ind) {
    i64 i = n;
    loop {
        if (i == 0) break;
        dump_node(i, ind);
        i = nd_next(i);
    }
}

void dump_node(i64 n, i64 ind) {
    i64 i = 0;
    loop {
        if (i >= ind) break;
        out_str(1, "  ");
        i = i + 1;
    }
    out_str(1, kind_name(nd_kind(n)));
    if (nd_op(n))   { out_str(1, " op=");   out_str(1, tok_text(nd_op(n))); }
    if (nd_kind(n) == N_INT || nd_val(n)) { out_str(1, " val="); out_num(1, nd_val(n)); }
    if (nd_type(n)) { out_str(1, " type="); out_str(1, type_name(nd_type(n))); }
    if (nd_name(n)) { out_str(1, " name="); out_str(1, nd_name(n)); }
    out_str(1, "\n");
    dump_list(nd_a(n), ind + 1);
    dump_list(nd_b(n), ind + 1);
    dump_list(nd_c(n), ind + 1);
    dump_list(nd_d(n), ind + 1);
}

void dump_ast(i64 n) { dump_list(n, 0); }
