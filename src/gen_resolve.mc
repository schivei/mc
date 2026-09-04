// gen_resolve.mc — M17 step A (docs/specs/M17.md) and M33 § 1: name resolution
// and typing, split out of the code generator.
//
// Until now the AArch64 walk computed every expression's type as a SIDE EFFECT
// of instruction selection -- 18 `set_nd_type` calls scattered through
// gen_binary/gen_ident/gen_cast/gen_unary -- and resolved every name from the
// middle of the lowering, with local_find/global_find/func_find. A second
// machine (M17 step B) and a backend that consumes the AST directly (M33's
// wasm) both need those answers without the AArch64 walk, so they moved here.
//
// `gen_resolve(unit)` runs before `gen_lower`, which calls it itself: every
// backend written against the old surface -- including lib/backend_arm64.mc --
// keeps working with no change. It writes its answers into a SIDE TABLE indexed
// by node, never into a node field: ND_SIZE stays 104 and `--dump-ast` does not
// move (the dump runs before codegen and never saw these types anyway).
//
//   res_type(n)        the resolved type of an expression node
//   res_kind(n)        what a name resolved to: RK_LOCAL / RK_GLOBAL / RK_FUNC /
//                      RK_INTRIN / RK_OPCODE (RK_NONE when the node binds nothing)
//   res_decl(n)        the index in the table res_kind names
//   res_local_slot(n)  res_decl when the node binds a LOCAL, else -1
//   res_bind(n)        the same binding in M33's encoding: local i,
//                      -(global + 1), or RES_FN + function index
//   res_intrin(n)      the IN_* id of an N_CALL, or IN_NONE
//   res_addr_taken(n)  1 when the DECLARING node (N_PARAM, N_VAR, N_FUNC or
//                      N_EXTERN) is the operand of some `&`
//
// A local's index is the position it occupies in the function's flat local
// stack AT THAT POINT IN THE WALK -- the same number gen_walk.mc's own table
// carries, because both build their table in the same order and both drop a
// block's names at its closing brace. Two sibling blocks therefore reuse the
// same index for different locals, which is why `res_addr_taken` is keyed by
// the DECLARING NODE and not by that index.
//
// It also owns the two module-wide name tables the walk used to own -- the
// signatures (FuncSig) and the globals -- because resolution is what needs
// them. gen_walk.mc fills in each global's symbol when it places the data, so
// the order in which symbols are created (which fixes the symbol table, and
// with it the bytes of the object) is exactly what it was.
//
// Depends on arena.mc (xalloc, mem_zero, str_eq, grow, MAXPARAMS), on ast.mc
// (nodes, err_node) and on parse.mc (opc_find). `cmp_cond` comes from
// gen_walk.mc: "is this token a comparison" has one answer and it lives next to
// the machine vocabulary that consumes it.

#include "../lib/prelude.mc"

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

// ---- FuncSig: file signature (N_FUNC, N_EXTERN or N_PROTO). def = 0
// while there is only a prototype; node is the node that declared it (for the final error) ----
#define FS_NAME    0
#define FS_TYPE    8
#define FS_NPARAMS 16
#define FS_DEF    24
#define FS_NODE   32
#define FS_SIZE   40

// ---- Global: own symbol in __data or __bss; nelem > 0 marks an array ----
#define GLB_NAME  0
#define GLB_TYPE  8
#define GLB_NELEM 16
#define GLB_SYM  24
#define GLB_SIZE 32

// ---- ResLocal: the resolver's own local stack (name, type, nelem, declaring node) ----
#define RL_NAME  0
#define RL_TYPE  8
#define RL_NELEM 16
#define RL_NODE 24
#define RL_SIZE 32

// ---- the side table: one record per node ----
#define RES_TYPE 0
#define RES_KIND 8
#define RES_DECL 16
#define RES_FLAG 24
#define RES_SIZE 32

#define RK_NONE   0
#define RK_LOCAL  1
#define RK_GLOBAL 2
#define RK_FUNC   3
#define RK_INTRIN 4
#define RK_OPCODE 5

// M33's res_bind encoding: local i, -(global + 1), RES_FN + function index
#define RES_FN 1000000

uptr res_tab = 0;                     // nnodes records of RES_SIZE, zeroed
i64  res_n = 0;                       // how many nodes the table covers
i64  res_done = 0;                    // gen_resolve runs at most once

// signatures for the whole file (N_FUNC, N_EXTERN and N_PROTO), registered
// before any body is looked at
uptr funcs;
i64 funccap = 0;
i64 nfuncs = 0;

// globals, in declaration order; GLB_SYM is filled by gen_walk.mc's gen_globals
uptr globals;
i64 globalcap = 0;
i64 nglobals = 0;

// the resolver's local stack, rebuilt per function
uptr rloc;
i64 rloccap = 0;
i64 nrloc = 0;

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

// ---- ResLocal accessors ----
uptr rl_at(i64 i)     { return rloc + i * RL_SIZE; }
uptr rl_name(uptr e)  { return ld64(e + RL_NAME); }
i64  rl_type(uptr e)  { return ld64(e + RL_TYPE); }
i64  rl_nelem(uptr e) { return ld64(e + RL_NELEM); }
i64  rl_node(uptr e)  { return ld64(e + RL_NODE); }

// ---- signatures ----
i64 func_find(uptr name) {
    i64 i = 0;
    while (i < nfuncs) {
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
    funcs = grow(T_FUNCS, funcs, nfuncs, &funccap, FS_SIZE);
    uptr ne = fs_at(nfuncs);
    set_fs_name(ne, name);
    set_fs_type(ne, type);
    set_fs_nparams(ne, nparams);
    set_fs_def(ne, def);
    set_fs_node(ne, n);
    nfuncs = nfuncs + 1;
}

// ---- globals ----
i64 global_find(uptr name) {
    i64 i = 0;
    while (i < nglobals) {
        if (str_eq(glb_name(glb_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

void global_add(uptr name, i64 type, i64 nelem) {
    globals = grow(T_GLOBALS, globals, nglobals, &globalcap, GLB_SIZE);
    uptr e = glb_at(nglobals);
    set_glb_name(e, name);
    set_glb_type(e, type);
    set_glb_nelem(e, nelem);
    set_glb_sym(e, 0);
    nglobals = nglobals + 1;
}

// ---- the resolver's local stack ----
i64 rl_find(uptr name) {
    i64 i = nrloc - 1;
    while (i >= 0) {
        if (str_eq(rl_name(rl_at(i)), name)) return i;
        i = i - 1;
    }
    return -1;
}

void rl_add(uptr name, i64 type, i64 nelem, i64 node) {
    rloc = grow(T_LOCALS, rloc, nrloc, &rloccap, RL_SIZE);
    uptr e = rl_at(nrloc);
    st64(e + RL_NAME, name);
    st64(e + RL_TYPE, type);
    st64(e + RL_NELEM, nelem);
    st64(e + RL_NODE, node);
    nrloc = nrloc + 1;
}

// ---- the side table ----
// Out of range answers neutrally instead of faulting: gen_opcode folds a
// template into FRESH nodes after gen_resolve has sized the table, and a module
// may ask about a node it built itself.
i64 res_in(i64 n) { return n > 0 && n < res_n && res_tab != 0; }

i64 res_type(i64 n) {
    if (!res_in(n)) return TY_VOID;
    return ld64(res_tab + n * RES_SIZE + RES_TYPE);
}

i64 res_kind(i64 n) {
    if (!res_in(n)) return RK_NONE;
    return ld64(res_tab + n * RES_SIZE + RES_KIND);
}

i64 res_decl(i64 n) {
    if (!res_in(n)) return -1;
    return ld64(res_tab + n * RES_SIZE + RES_DECL);
}

i64 res_addr_taken(i64 n) {
    if (!res_in(n)) return 0;
    return ld64(res_tab + n * RES_SIZE + RES_FLAG);
}

void set_res_type(i64 n, i64 v) { if (res_in(n)) st64(res_tab + n * RES_SIZE + RES_TYPE, v); }
void set_res_flag(i64 n, i64 v) { if (res_in(n)) st64(res_tab + n * RES_SIZE + RES_FLAG, v); }

void set_res_bind(i64 n, i64 kind, i64 decl) {
    if (!res_in(n)) return;
    st64(res_tab + n * RES_SIZE + RES_KIND, kind);
    st64(res_tab + n * RES_SIZE + RES_DECL, decl);
}

// the local's index in the frame, or -1 when this node does not bind a local
i64 res_local_slot(i64 n) {
    if (res_kind(n) != RK_LOCAL) return -1;
    return res_decl(n);
}

// M33's encoding, so a backend can branch on one number
i64 res_bind(i64 n) {
    i64 k = res_kind(n);
    if (k == RK_LOCAL)  return res_decl(n);
    if (k == RK_GLOBAL) return 0 - (res_decl(n) + 1);
    if (k == RK_FUNC)   return RES_FN + res_decl(n);
    return RES_FN - 1;
}

i64 res_intrin(i64 n) {
    if (res_kind(n) != RK_INTRIN) return IN_NONE;
    return res_decl(n);
}

// 1 when function fi is the operand of some `&` -- M33's funcref table
i64 res_fn_addr_taken(i64 fi) { return res_addr_taken(fs_node(fs_at(fi))); }

// ---- intrinsics ----
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

i64 arg_count(i64 n) {
    i64 k = 0;
    i64 a = nd_a(n);
    while (a != 0) {
        k = k + 1;
        a = nd_next(a);
    }
    return k;
}

// ---- the walk ----
void res_args(i64 n) {
    i64 a = nd_a(n);
    while (a != 0) {
        res_expr(a);
        a = nd_next(a);
    }
}

// name: local first, then global. An array decays to the address (uptr);
// a scalar reads at the declared width.
void res_ident(i64 n) {
    i64 i = rl_find(nd_name(n));
    if (i >= 0) {
        set_res_bind(n, RK_LOCAL, i);
        uptr e = rl_at(i);
        if (rl_nelem(e)) set_res_type(n, TY_UPTR);
        else             set_res_type(n, rl_type(e));
        return;
    }
    i64 g = global_find(nd_name(n));
    if (g < 0) err_node(n, "unknown name");
    set_res_bind(n, RK_GLOBAL, g);
    uptr ge = glb_at(g);
    if (glb_nelem(ge)) set_res_type(n, TY_UPTR);
    else               set_res_type(n, glb_type(ge));
}

// &name: local, global or -- since M10 -- function/extern. The declaring node
// is marked, which is what res_addr_taken answers.
void res_addr(i64 n) {
    set_res_type(n, TY_UPTR);
    i64 i = rl_find(nd_name(n));
    if (i >= 0) {
        set_res_bind(n, RK_LOCAL, i);
        set_res_flag(rl_node(rl_at(i)), 1);
        return;
    }
    i64 g = global_find(nd_name(n));
    if (g >= 0) { set_res_bind(n, RK_GLOBAL, g); return; }
    i64 fi = func_find(nd_name(n));
    if (fi < 0) err_node(n, "unknown name");
    set_res_bind(n, RK_FUNC, fi);
    set_res_flag(fs_node(fs_at(fi)), 1);
}

// the same dispatch gen_call does, in the same order: intrinsic, then #opcode,
// then a declared signature. emit(), reloc() and a #opcode call take CONSTANTS,
// never lowered expressions, so their arguments are not resolved here either.
void res_call(i64 n) {
    i64 in = intrin_id(nd_name(n));
    if (in) {
        set_res_bind(n, RK_INTRIN, in);
        if (in == IN_EMIT || in == IN_RELOC) { set_res_type(n, TY_VOID); return; }
        if (in == IN_CALLP) {
            i64 na = arg_count(n);
            if (na < 1 || na > MAXPARAMS) err_node(n, "callp expects 1 to 8 arguments");
            res_args(n);
            set_res_type(n, TY_I64);
            return;
        }
        i64 want = 1;
        if (in >= IN_ST8) want = 2;
        if (arg_count(n) != want) err_node(n, "wrong arity in intrinsic");
        res_args(n);
        if (in >= IN_ST8) set_res_type(n, TY_VOID);
        else              set_res_type(n, intrin_type(in));
        return;
    }
    i64 oi = opc_find(nd_name(n));
    if (oi >= 0) { set_res_bind(n, RK_OPCODE, oi); set_res_type(n, TY_VOID); return; }
    i64 fi = func_find(nd_name(n));
    if (fi < 0) err_node(n, "call to unknown function");
    if (arg_count(n) != fs_nparams(fs_at(fi))) err_node(n, "wrong number of arguments");
    set_res_bind(n, RK_FUNC, fi);
    res_args(n);
    set_res_type(n, fs_type(fs_at(fi)));
}

// a comparison yields i64; everything else keeps the left operand's type, which
// is the rule the divide and the shift read to pick their signed form
void res_binary(i64 n) {
    i64 op = nd_op(n);
    res_expr(nd_a(n));
    res_expr(nd_b(n));
    if (op == K_ANDAND || op == K_OROR) { set_res_type(n, TY_I64); return; }
    if (cmp_cond(op) >= 0) { set_res_type(n, TY_I64); return; }
    set_res_type(n, res_type(nd_a(n)));
}

void res_expr(i64 n) {
    i64 k = nd_kind(n);
    if (k == N_INT)   { set_res_type(n, TY_I64); return; }
    if (k == N_STR)   { set_res_type(n, TY_UPTR); return; }
    if (k == N_IDENT) { res_ident(n); return; }
    if (k == N_ADDR)  { res_addr(n); return; }
    if (k == N_CALL)  { res_call(n); return; }
    if (k == N_BINARY) { res_binary(n); return; }
    if (k == N_UNARY) {
        res_expr(nd_a(n));
        if (nd_op(n) == K_BANG) set_res_type(n, TY_I64);
        else                    set_res_type(n, res_type(nd_a(n)));
        return;
    }
    if (k == N_CAST) {                           // the written type, from the parser
        res_expr(nd_a(n));
        set_res_type(n, nd_type(n));
        return;
    }
    err_node(n, "expression with no codegen");
}

// a declaration binds its own node to the slot it is about to take, so a
// consumer can go from the N_VAR to the local without walking the body again
void res_var(i64 n) {
    if (nd_val(n) == 0 && nd_a(n)) res_expr(nd_a(n));   // initializer before the name exists
    set_res_bind(n, RK_LOCAL, nrloc);
    rl_add(nd_name(n), nd_type(n), nd_val(n), n);
}

void res_assign(i64 n) {
    i64 i = rl_find(nd_name(n));
    if (i >= 0) {
        set_res_bind(n, RK_LOCAL, i);
        if (rl_nelem(rl_at(i))) err_node(n, "assignment to array");
    } else {
        i64 g = global_find(nd_name(n));
        if (g < 0) err_node(n, "unknown name");
        set_res_bind(n, RK_GLOBAL, g);
        if (glb_nelem(glb_at(g))) err_node(n, "assignment to array");
    }
    res_expr(nd_a(n));
}

void res_stmt(i64 n) {
    i64 k = nd_kind(n);
    if (k == N_BLOCK) {
        i64 mark = nrloc;                        // scope: the names disappear here
        i64 s = nd_a(n);
        while (s != 0) {
            res_stmt(s);
            s = nd_next(s);
        }
        nrloc = mark;
        return;
    }
    if (k == N_VAR)      { res_var(n);    return; }
    if (k == N_ASSIGN)   { res_assign(n); return; }
    if (k == N_IF) {
        res_expr(nd_a(n));
        res_stmt(nd_b(n));
        if (nd_c(n)) res_stmt(nd_c(n));
        return;
    }
    if (k == N_LOOP)     { res_stmt(nd_a(n)); return; }
    if (k == N_BREAK)    { return; }             // the loop depth is the walker's
    if (k == N_CONTINUE) { return; }
    if (k == N_RETURN)   { if (nd_a(n)) res_expr(nd_a(n)); return; }
    if (k == N_EXPRSTMT) { res_expr(nd_a(n)); return; }
    err_node(n, "statement with no codegen");
}

void res_func(i64 f) {
    nrloc = 0;
    i64 p = nd_a(f);
    while (p != 0) {                             // the parameters are the first locals
        rl_add(nd_name(p), nd_type(p), 0, p);
        p = nd_next(p);
    }
    res_stmt(nd_b(f));
}

// ---- the pass ----
// Signatures, then globals, then every body -- the order gen_lower used, so the
// diagnostics come out in the order they always did. Called by gen_lower, and
// callable on its own by a backend that never lowers to Ins at all.
void gen_resolve(i64 unit) {
    if (res_done) return;
    res_done = 1;
    res_n = nnodes;
    res_tab = xalloc(res_n * RES_SIZE);
    mem_zero(res_tab, res_n * RES_SIZE);

    i64 f = unit;
    while (f != 0) {
        i64 k = nd_kind(f);
        if (k == N_FUNC || k == N_EXTERN || k == N_PROTO) {
            i64 np = 0;
            i64 p = nd_a(f);
            while (p != 0) {
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
    while (i < nfuncs) {                          // prototype with no definition or extern
        if (!fs_def(fs_at(i))) err_node(fs_node(fs_at(i)), "prototype with no definition");
        i = i + 1;
    }
    i64 g = unit;
    while (g != 0) {
        if (nd_kind(g) == N_GLOBAL) {
            if (global_find(nd_name(g)) >= 0 || func_find(nd_name(g)) >= 0)
                err_node(g, "global name declared twice");
            global_add(nd_name(g), nd_type(g), nd_val(g));
        }
        g = nd_next(g);
    }
    f = unit;
    while (f != 0) {
        if (nd_kind(f) == N_FUNC) res_func(f);
        f = nd_next(f);
    }
}
