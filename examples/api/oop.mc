// oop.mc — `class` and `interface` taught from outside, via the parser's
// public API (Tier 3, M12). This file is not compiled as a program: it is
// linked INSIDE a compiler (examples/api/mc-api.mc) and runs during the
// parse of the user's source. Nothing here touches `src/`.
//
// What each declaration generates (see the table in the README/report):
//
//   interface Shape {                 #define SHAPE_AREA 0
//       i64 area(self);               #define SHAPE_NAME 8
//       str name(self);               i64  shape_area(uptr self)  -> callp(vtable[0], self)
//   }                                 uptr shape_name(uptr self)  -> callp(vtable[1], self)
//                                     type_alias("Shape", TY_UPTR)
//
//   class Rect : Shape {              #define RECT_W 8   (word 0 is the vtable)
//       i64 w;                        i64  rect_w(uptr self) / void set_rect_w(uptr self, i64 v)
//       i64 area(self) { ... }        i64  rect_area(uptr self)      <- method, implicit self
//   }                                 #define RECT_SIZE 16
//                                     u8   rect_vt[16]
//                                     void rect_vt_init()
//                                     uptr rect_new()   -> rt_alloc(RECT_SIZE) + vtable
//                                     type_alias("Rect", TY_UPTR)
//
// A class with no `: Interface` gets neither a vtable nor `vt_init`, and its
// fields start at offset 0.
//
// The runtime belongs to the program, not to this file: `name_new()` calls
// `rt_alloc(n)`, which the compiled source has to supply and which returns
// `n` ZEROED bytes. A program with no `rt_alloc` fails at codegen with
// "call to unknown function".
//
// Depends on the core plus the prelude (`while`, `+=`) and on three things
// from the compiler that included it: src/parse.mc's public API (p_*,
// parse_*, top_add, def_add, param_new, list_append), src/ast.mc's
// constructors (node_new, nd_*, set_nd_*) and src/hooks.mc's registries
// (type_alias).

#include "../../lib/prelude.mc"

#define MAXIFACE   16                 // interfaces declared in the source
#define MAXIMETH   64                 // interface methods, summed across all of them
#define MAXCMETH   32                 // methods of the class currently being read

// ---- interfaces: name + slice [first, first+count) of the method table ----
uptr if_name[MAXIFACE];
i64  if_first[MAXIFACE];
i64  if_count[MAXIFACE];
i64  nifaces = 0;

uptr im_name[MAXIMETH];               // interface methods, in declaration order
i64  im_np[MAXIMETH];                 // method's parameters, not counting `self`
i64  nimeth = 0;

// ---- methods of the current class; classes do not nest, so a single scratch buffer ----
uptr cm_name[MAXCMETH];
i64  cm_np[MAXCMETH];
i64  ncm = 0;

// position used on generated nodes and on declaration-level errors
i64  oop_line = 0;
uptr oop_file = 0;

// ---- table accessors (no raw ld64/st64 outside this section) ----
uptr if_name_at(i64 i)  { return ld64(if_name + i * 8); }
i64  if_first_at(i64 i) { return ld64(if_first + i * 8); }
i64  if_count_at(i64 i) { return ld64(if_count + i * 8); }
uptr im_name_at(i64 i)  { return ld64(im_name + i * 8); }
i64  im_np_at(i64 i)    { return ld64(im_np + i * 8); }
uptr cm_name_at(i64 i)  { return ld64(cm_name + i * 8); }
i64  cm_np_at(i64 i)    { return ld64(cm_np + i * 8); }

void set_if_name_at(i64 i, uptr v)  { st64(if_name + i * 8, v); }
void set_if_first_at(i64 i, i64 v)  { st64(if_first + i * 8, v); }
void set_if_count_at(i64 i, i64 v)  { st64(if_count + i * 8, v); }
void set_im_name_at(i64 i, uptr v)  { st64(im_name + i * 8, v); }
void set_im_np_at(i64 i, i64 v)     { st64(im_np + i * 8, v); }
void set_cm_name_at(i64 i, uptr v)  { st64(cm_name + i * 8, v); }
void set_cm_np_at(i64 i, i64 v)     { st64(cm_np + i * 8, v); }

// linear search, in declaration order: docs/determinism.md, rule 1
i64 oop_iface_find(uptr name) {
    i64 i = 0;
    while (i < nifaces) {
        if (str_eq(if_name_at(i), name)) return i;
        i += 1;
    }
    return 0 - 1;
}

i64 oop_cm_find(uptr name) {
    i64 i = 0;
    while (i < ncm) {
        if (str_eq(cm_name_at(i), name)) return i;
        i += 1;
    }
    return 0 - 1;
}

void oop_imeth_add(uptr name, i64 np) {
    if (nimeth == MAXIMETH) die("too many interface methods");
    set_im_name_at(nimeth, name);
    set_im_np_at(nimeth, np);
    nimeth += 1;
}

void oop_cm_add(uptr name, i64 np) {
    if (ncm == MAXCMETH) die("too many methods in a class");
    set_cm_name_at(ncm, name);
    set_cm_np_at(ncm, np);
    ncm += 1;
}

void oop_iface_add(uptr name, i64 first, i64 count) {
    if (nifaces == MAXIFACE) die("too many interfaces");
    set_if_name_at(nifaces, name);
    set_if_first_at(nifaces, first);
    set_if_count_at(nifaces, count);
    nifaces += 1;
}

// ---- derived names ----
i64 oop_lower_ch(i64 c) { if (c >= 'A' && c <= 'Z') return c + 32; return c; }
i64 oop_upper_ch(i64 c) { if (c >= 'a' && c <= 'z') return c - 32; return c; }

// copy of `s` with the letters' case swapped: up = 1 uppercase, 0 lowercase
uptr oop_case(uptr s, i64 up) {
    i64 n = cstrlen(s);
    uptr d = xalloc(n + 1);
    i64 i = 0;
    while (i < n) {
        i64 c = ld8(s + i);
        if (up) st8(d + i, oop_upper_ch(c));
        else    st8(d + i, oop_lower_ch(c));
        i += 1;
    }
    st8(d + n, 0);
    return d;
}

uptr oop_join(uptr a, uptr b) {
    i64 la = cstrlen(a);
    i64 lb = cstrlen(b);
    uptr d = xalloc(la + lb + 1);
    mem_copy(d, a, la);
    mem_copy(d + la, b, lb);
    st8(d + la + lb, 0);
    return d;
}

uptr oop_join3(uptr a, uptr b, uptr c) { return oop_join(oop_join(a, b), c); }

// new class or interface name: it has to be an identifier that is still free.
// `type_alias` turns the name into a reserved word, so a second `class Rect`
// (or `class str`) arrives here as a keyword, not as T_IDENT — without this
// guard the error would come out as an unexplained "name expected".
uptr oop_newname(uptr category) {
    if (p_id() == T_IDENT) return p_ident();
    if (alias_find(p_id()) >= 0)
        err_at2(p_file(), p_line(), "the name is already a type (class, interface, or alias)", p_name());
    err_at2(p_file(), p_line(), oop_join3("name of ", category, " expected"), p_name());
    return 0;
}

// Rect + json  ->  rect_json     (generated function)
uptr oop_fname(uptr type, uptr m) { return oop_join3(oop_case(type, 0), "_", m); }
// Rect + w     ->  RECT_W        (#define for the offset / the vtable index)
uptr oop_cname(uptr type, uptr m) { return oop_join3(oop_case(type, 1), "_", oop_case(m, 1)); }

// ---- node constructors: only node_new/set_nd_* from src/ast.mc ----
i64 oop_nd(i64 kind) { return node_new(kind, oop_line, oop_file); }

i64 oop_int(i64 v) {
    i64 n = oop_nd(N_INT);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 oop_id(uptr name) {
    i64 n = oop_nd(N_IDENT);
    set_nd_name(n, name);
    set_nd_type(n, TY_I64);
    return n;
}

// &name of a function: M10's uptr
i64 oop_addr(uptr name) {
    i64 n = oop_nd(N_ADDR);
    set_nd_name(n, name);
    set_nd_type(n, TY_UPTR);
    return n;
}

i64 oop_bin(i64 op, i64 a, i64 b) {
    i64 n = oop_nd(N_BINARY);
    set_nd_op(n, op);
    set_nd_a(n, a);
    set_nd_b(n, b);
    return n;
}

i64 oop_call(uptr name, i64 args) {
    i64 n = oop_nd(N_CALL);
    set_nd_name(n, name);
    set_nd_a(n, args);
    set_nd_type(n, TY_I64);
    return n;
}

i64 oop_ret(i64 e) {
    i64 n = oop_nd(N_RETURN);
    set_nd_a(n, e);
    return n;
}

i64 oop_st(i64 e) {
    i64 n = oop_nd(N_EXPRSTMT);
    set_nd_a(n, e);
    return n;
}

i64 oop_blk(i64 stmts) {
    i64 n = oop_nd(N_BLOCK);
    set_nd_a(n, stmts);
    return n;
}

i64 oop_var(i64 ty, uptr name, i64 init) {
    i64 n = oop_nd(N_VAR);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_a(n, init);
    return n;
}

i64 oop_func(i64 ty, uptr name, i64 params, i64 body) {
    i64 f = oop_nd(N_FUNC);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    set_nd_b(f, body);
    return f;
}

// global with no initializer: goes to __bss, already zeroed
i64 oop_glb(i64 ty, uptr name, i64 nel) {
    i64 n = oop_nd(N_GLOBAL);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_val(n, nel);
    return n;
}

// memory-access intrinsic matching the field type's width
uptr oop_ld(i64 ty) {
    i64 w = type_width(ty);
    if (w == 1) return "ld8";
    if (w == 2) return "ld16";
    if (w == 4) return "ld32";
    return "ld64";
}

uptr oop_stn(i64 ty) {
    i64 w = type_width(ty);
    if (w == 1) return "st8";
    if (w == 2) return "st16";
    if (w == 4) return "st32";
    return "st64";
}

// self + OFF
i64 oop_fieldp(i64 off) { return oop_bin(K_ADD, oop_id("self"), oop_int(off)); }

// ---- parameter list of a method: `(self)` or `(self, type name, ...)`.
// Returns the list of N_PARAM already with `self` (uptr) up front and writes
// to *pnp how many parameters the method has besides `self`. parse_params()
// cannot be used here: `self` comes with no type, and that is exactly the
// sugar being taught.
//
// `extra` is how many argument slots dispatch spends besides the parameters:
// 1 in the interface, because the dispatcher calls `callp(slot, self, ...)`
// and the pointer takes up the first of `callp`'s MAXPARAMS slots; 0 in the
// class, whose method is called directly via `bl`. Without this an interface
// method with self + MAXPARAMS - 1 parameters would get past here and die
// further ahead with "callp expects 1 to 12 arguments", at the wrong line. ----
i64 oop_params(uptr pnp, i64 extra) {
    p_expect(K_LPAR, "expected ( in the method parameter list");
    if (p_id() != T_IDENT || !str_eq(p_name(), "self"))
        err_at(p_file(), p_line(), "the first parameter of a method is `self`");
    p_next();
    i64 head = param_new(TY_UPTR, "self");
    i64 np = 0;
    while (p_accept(K_COMMA)) {
        i64 ty = p_type();
        if (ty == TY_VOID) err_at(p_file(), p_line(), "parameter of type void");
        head = list_append(head, param_new(ty, p_ident()));
        np += 1;
        if (np + 1 + extra > MAXPARAMS)
            err_at(p_file(), p_line(),
                   "method with too many parameters (self counts; in the interface, the vtable pointer does too)");
    }
    p_expect(K_RPAR, "expected ) in the method parameter list");
    st64(pnp, np);
    return head;
}

// ---- interface dispatcher ----
// T iface_method(uptr self, ...) { return callp(ld64(ld64(self) + IDX*8), self, ...); }
// ld64(self) is the vtable (object's word 0); + IDX*8 is the method's slot.
i64 oop_dispatch(i64 ty, uptr iface, uptr m, i64 params, i64 idx) {
    i64 vt = oop_call("ld64", oop_id("self"));
    i64 slot = oop_call("ld64", oop_bin(K_ADD, vt, oop_int(idx * 8)));
    i64 args = slot;                             // callp(p, a1..): the pointer comes first
    i64 p = params;
    while (p != 0) {
        args = list_append(args, oop_id(nd_name(p)));
        p = nd_next(p);
    }
    i64 call = oop_call("callp", args);
    i64 body = oop_blk(oop_ret(call));
    if (ty == TY_VOID) body = oop_blk(oop_st(call));
    return oop_func(ty, oop_fname(iface, m), params, body);
}

// ---- field accessors ----
// T field_name(uptr self) { return ldW(self + FIELD_NAME); }
i64 oop_getter(i64 ty, uptr cls, uptr f, i64 off) {
    i64 body = oop_blk(oop_ret(oop_call(oop_ld(ty), oop_fieldp(off))));
    return oop_func(ty, oop_fname(cls, f), param_new(TY_UPTR, "self"), body);
}

// void set_field_name(uptr self, T v) { stW(self + FIELD_NAME, v); }
i64 oop_setter(i64 ty, uptr cls, uptr f, i64 off) {
    i64 params = list_append(param_new(TY_UPTR, "self"), param_new(ty, "v"));
    i64 args = list_append(oop_fieldp(off), oop_id("v"));
    i64 body = oop_blk(oop_st(oop_call(oop_stn(ty), args)));
    return oop_func(TY_VOID, oop_join("set_", oop_fname(cls, f)), params, body);
}

// ---- vtable ----
// void name_vt_init() { st64(name_vt + 0, &name_m0); ... }
// This is where "interface method not implemented" comes from: the vtable
// can only be filled in if the class has every method, at the declared arity.
i64 oop_vt_init(uptr cls, uptr vt, i64 ifi) {
    i64 first = if_first_at(ifi);
    i64 nm = if_count_at(ifi);
    i64 stmts = 0;
    i64 i = 0;
    while (i < nm) {
        uptr m = im_name_at(first + i);
        i64 j = oop_cm_find(m);
        if (j < 0)
            err_at2(oop_file, oop_line, "interface method not implemented", m);
        if (cm_np_at(j) != im_np_at(first + i))
            err_at2(oop_file, oop_line, "method with arity different from the interface", m);
        i64 dst = oop_bin(K_ADD, oop_id(vt), oop_int(i * 8));
        i64 args = list_append(dst, oop_addr(oop_fname(cls, m)));
        stmts = list_append(stmts, oop_st(oop_call("st64", args)));
        i += 1;
    }
    return oop_func(TY_VOID, oop_join(oop_case(cls, 0), "_vt_init"), 0, oop_blk(stmts));
}

// ---- constructor ----
// uptr name_new() {
//     uptr p = rt_alloc(NAME_SIZE);     // the program supplies rt_alloc; returns zeroed memory
//     name_vt_init();                   // only when the class implements an interface
//     st64(p, name_vt);                 // word 0 = vtable
//     return p;
// }
i64 oop_new(uptr cls, i64 size, uptr vt) {
    i64 stmts = oop_var(TY_UPTR, "p", oop_call("rt_alloc", oop_int(size)));
    if (vt) {
        uptr init = oop_join(oop_case(cls, 0), "_vt_init");
        stmts = list_append(stmts, oop_st(oop_call(init, 0)));
        i64 args = list_append(oop_id("p"), oop_id(vt));
        stmts = list_append(stmts, oop_st(oop_call("st64", args)));
    }
    stmts = list_append(stmts, oop_ret(oop_id("p")));
    return oop_func(TY_UPTR, oop_join(oop_case(cls, 0), "_new"), 0, oop_blk(stmts));
}

// ---- interface Name { T method(self, ...); ... } ----
// Registers a #define per method, publishes a dispatcher per method, and
// turns the name into a type (uptr). Produces no object at all: an interface
// is just the table.
void oop_interface() {
    oop_line = p_line();
    oop_file = p_file();
    i64 head_line = oop_line;                    // position of the `interface` word
    uptr head_file = oop_file;
    p_next();                                    // the `interface` word
    uptr name = oop_newname("interface");
    type_alias(name, TY_UPTR);                   // already valid inside the body itself
    p_expect(K_LBRACE, "expected { in the interface body");
    i64 first = nimeth;
    i64 idx = 0;
    while (p_id() != K_RBRACE) {
        if (p_id() == T_EOF) err_at(head_file, head_line, "unterminated interface");
        oop_line = p_line();                     // errors and nodes for this method, not the interface
        oop_file = p_file();
        i64 ty = p_type();
        uptr m = p_ident();
        i64 np = 0;
        i64 params = oop_params(&np, 1);
        p_expect(K_SEMI, "expected ; after the interface method");
        def_add(oop_cname(name, m), idx * 8, oop_line, oop_file);
        top_add(oop_dispatch(ty, name, m, params, idx));
        oop_imeth_add(m, np);
        idx += 1;
    }
    p_next();                                    // }
    oop_line = head_line;                        // back to the interface's own level
    oop_file = head_file;
    if (idx == 0) err_at2(oop_file, oop_line, "interface with no methods", name);
    oop_iface_add(name, first, idx);
}

// ---- class Name [: Interface] { fields and methods } ----
void oop_class() {
    oop_line = p_line();
    oop_file = p_file();
    i64 head_line = oop_line;                    // position of the `class` word
    uptr head_file = oop_file;
    p_next();                                    // the `class` word
    uptr name = oop_newname("class");
    i64 ifi = 0 - 1;
    if (p_accept(K_COLON)) {
        // the interface name is already a reserved word (type_alias), so it
        // is not T_IDENT: the raw lexeme is read and looked up in the table
        uptr iname = p_name();
        p_next();
        ifi = oop_iface_find(iname);
        if (ifi < 0) err_at2(p_file(), p_line(), "unknown interface", iname);
    }
    type_alias(name, TY_UPTR);                   // the class becomes a type
    p_expect(K_LBRACE, "expected { in the class body");
    i64 off = 0;
    if (ifi >= 0) off = 8;                       // word 0 reserved for the vtable
    ncm = 0;
    while (p_id() != K_RBRACE) {
        if (p_id() == T_EOF) err_at(head_file, head_line, "unterminated class");
        oop_line = p_line();                     // errors and nodes for this member, not the class
        oop_file = p_file();
        i64 ty = p_type();
        uptr m = p_ident();
        if (p_id() == K_LPAR) {
            if (str_eq(m, "new") || str_eq(m, "vt_init"))
                err_at2(p_file(), p_line(), "method name reserved by the class", m);
            i64 np = 0;
            i64 params = oop_params(&np, 0);
            i64 line = p_line();
            uptr fl = p_file();
            i64 f = parse_function(ty, oop_fname(name, m), params);
            set_nd_line(f, line);                // the declaration starts at the {, not at the end
            set_nd_file(f, fl);
            top_add(f);
            oop_cm_add(m, np);
        } else {
            p_expect(K_SEMI, "expected ; after the class field");
            if (ty == TY_VOID) err_at2(p_file(), p_line(), "field of type void", m);
            i64 w = type_width(ty);
            off = (off + w - 1) & ~(w - 1);      // the field's natural alignment
            def_add(oop_cname(name, m), off, oop_line, oop_file);
            top_add(oop_getter(ty, name, m, off));
            top_add(oop_setter(ty, name, m, off));
            off = off + w;
        }
    }
    p_next();                                    // }
    oop_line = head_line;                        // back to the class's own level
    oop_file = head_file;
    off = (off + 7) & ~7;                        // the whole object aligned to 8
    if (off == 0) off = 8;                       // class with no fields: an object still exists
    def_add(oop_join(oop_case(name, 1), "_SIZE"), off, oop_line, oop_file);
    uptr vt = 0;
    if (ifi >= 0) {
        vt = oop_join(oop_case(name, 0), "_vt");
        top_add(oop_glb(TY_U8, vt, if_count_at(ifi) * 8));
        top_add(oop_vt_init(name, vt, ifi));
    }
    top_add(oop_new(name, off, vt));
}
