// lang_class.mc — the declarations of `lx`: `class`, `interface`, `namespace`,
// `import`, `using`, and the recording of a generic.
//
// Everything a class produces is an ORDINARY declaration handed to the core
// through top_add: a global for the vtable, a global per interface method
// table, `C_vt_init`, `C_new` and `C_release`. The core never learns what a
// class is; it only ever sees globals and functions.

// a name being declared: an identifier, or a word this module has already
// reserved (a class reopened in another namespace, an instantiation)
uptr lg_declname(uptr what) {
    if (p_id() == T_IDENT) return p_ident();
    uptr s = p_name();
    i64 c = ld8(s);
    i64 alpha = 0;
    if (c >= 'a' && c <= 'z') alpha = 1;
    if (c >= 'A' && c <= 'Z') alpha = 1;
    if (c == '_') alpha = 1;
    if (alpha) {
        if (p_id() >= K_U8 && p_id() <= K_EXTERN)
            err_at2(p_file(), p_line(), "cannot redefine a core keyword", s);
        p_next();
        return s;
    }
    err_at2(p_file(), p_line(), lg_cat("name expected after ", what), s);
    return 0;
}

// 1 if the current token is the identifier `w` (a contextual keyword such as
// `virtual`, `override` or `where`, which this module deliberately does NOT
// reserve: they stay usable as ordinary names everywhere else)
i64 lg_kw(uptr w) {
    if (p_id() != T_IDENT) return 0;
    return str_eq(p_name(), w);
}

i64 lg_reg_has(uptr name) {
    i64 i = 0;
    while (i < lg_nreg) {
        if (str_eq(reg_at(i), name)) return 1;
        i = i + 1;
    }
    return 0;
}

void lg_reg_add(uptr name) {
    if (lg_nreg == LG_MAXREG) die2("too many reserved names", name);
    lg_puta(lg_reg, lg_nreg, name);
    lg_nreg = lg_nreg + 1;
}

// a class, an interface or a generic becomes BOTH a type (params, casts,
// fields) and a statement opener (the module owns the local declaration, so it
// learns the local's class). docs/surface.md § "Registration reserves the word
// for the whole program" applies: from here on the name is not an identifier.
void lg_register_type(uptr name) {
    if (lg_reg_has(name)) return;
    i64 id = word_id(name, cstrlen(name));
    if (id >= 0) {
        if (alias_find(id) >= 0)
            err_at2(lg_file, lg_line, "the name is already a type", name);
    }
    type_alias(name, TY_UPTR);
    syntax_stmt(name, &lg_declstmt);
    lg_reg_add(name);
}

// ---- generic: record the body, create nothing ----

// `class Box<T, const N: i64> ...` / `fn max<T>(...) ...`: reads the parameter
// list, records everything from just after the `>` to the end of the body with
// p_skip_balanced, and produces no declaration at all.
void lg_gen_record(uptr sname, i64 kind, i64 line, uptr fl) {
    if (lg_ngen == LG_MAXGEN) err_at(fl, line, "too many generics");
    uptr g = gn_at(lg_ngen);
    uptr full = lg_qualify(lg_cur_ns, sname);
    lg_put(g, GN_NAME, full);
    lg_put(g, GN_NS, lg_cur_ns);
    lg_put(g, GN_KIND, kind);
    p_expect(K_LT, "expected < in the generic parameter list");
    i64 n = 0;
    loop {
        if (n == LG_MAXGP) err_at(fl, line, "too many generic parameters");
        if (lg_kw("const")) {
            p_next();
            set_gn_p(g, n, lg_declname("const"));
            p_expect(K_COLON, "expected : after a const generic parameter");
            p_type();                            // the declared type, i64 in practice
            set_gn_k(g, n, 1);
        } else {
            set_gn_p(g, n, lg_declname("a generic parameter"));
            set_gn_k(g, n, 0);
        }
        n = n + 1;
        if (!p_accept(K_COMMA)) break;
    }
    lg_put(g, GN_NP, n);
    lg_expect_gt();
    uptr start = p_start();                      // the `:` / `where` / `(` / `{`
    lg_skip_where();                             // walks forward to the body's `{`
    i64 blen = 0;
    uptr body = p_skip_balanced(K_LBRACE, K_RBRACE, &blen);
    lg_put(g, GN_BODY, start);
    lg_put(g, GN_BLEN, body + blen - start);
    lg_ngen = lg_ngen + 1;
    if (kind == 0) {
        lg_register_type(full);                  // `Box<Circle, 4> b;` is a declaration
        if (!str_eq(full, sname)) lg_register_type(sname);
    } else {
        lg_gen_register_fn(full);                // `max<i64>(a, b)` is an expression
        if (!str_eq(full, sname)) lg_gen_register_fn(sname);
    }
}

void lg_gen_register_fn(uptr name) {
    if (lg_reg_has(name)) return;
    syntax_expr(name, &lg_geninst_expr);
    lg_reg_add(name);
}

// ---- interface ----

void lg_interface() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `interface` word
    uptr sname = lg_declname("interface");
    uptr full = lg_qualify(lg_cur_ns, sname);
    if (lg_iface_by_name(full) >= 0) err_at2(fl, line, "interface already declared", full);
    if (lg_nifc == LG_MAXIFACE) err_at(fl, line, "too many interfaces");
    uptr f = if_at(lg_nifc);
    lg_put(f, IF_NAME, full);
    lg_put(f, IF_NM, 0);
    i64 fi = lg_nifc;
    lg_nifc = lg_nifc + 1;
    lg_register_type(full);
    if (!str_eq(full, sname)) lg_register_type(sname);
    p_expect(K_LBRACE, "expected { in the interface body");
    i64 nm = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        if (p_id() == T_EOF) err_at(fl, line, "unterminated interface");
        lg_line = p_line();
        lg_file = p_file();
        i64 rc = -1;
        i64 ri = -1;
        i64 ret = TY_VOID;
        uptr mn = 0;
        if (p_id() == lg_tok_fn) {
            p_next();
            mn = lg_declname("a method");
        } else {
            ret = lg_read_type(&rc, &ri);
            mn = lg_declname("a method");
        }
        i64 np = lg_count_sig();                 // `(self, T a, ...)` without binding
        if (p_id() == lg_tok_arrow) {
            p_next();
            ret = lg_read_type(&rc, &ri);
        }
        p_expect(K_SEMI, "expected ; after an interface method");
        if (lg_nimth == LG_MAXIMETH) err_at(fl, line, "too many interface methods");
        uptr m = im_at(lg_nimth);
        lg_put(m, IM_NAME, mn);
        lg_put(m, IM_OWN, fi);
        lg_put(m, IM_RET, ret);
        lg_put(m, IM_RCLS, rc);
        lg_put(m, IM_RIF, ri);
        lg_put(m, IM_NP, np);
        lg_nimth = lg_nimth + 1;
        nm = nm + 1;
    }
    p_next();                                    // }
    if (nm == 0) err_at2(fl, line, "interface with no methods", full);
    lg_put(if_at(fi), IF_NM, nm);
}

// reads `(self, T a, ...)` in an interface, where only the arity matters
i64 lg_count_sig() {
    p_expect(K_LPAR, "expected ( in the method signature");
    if (!lg_kw("self")) err_at(p_file(), p_line(), "the first parameter of a method is `self`");
    p_next();
    i64 np = 0;
    while (p_accept(K_COMMA)) {
        i64 c = -1;
        i64 i = -1;
        if (p_id() == lg_tok_ref) p_next();
        lg_read_type(&c, &i);
        lg_declname("a parameter");
        np = np + 1;
    }
    p_expect(K_RPAR, "expected ) in the method signature");
    return np;
}

// ---- class ----

// every interface implemented by `ci` or by one of its bases, deduplicated and
// in declaration order; returns how many were written to `out`
i64 lg_collect_ifaces(i64 ci, uptr out) {
    i64 n = 0;
    while (ci >= 0) {
        i64 i = 0;
        while (i < lg_nci) {
            if (ci_own(ci_at(i)) == ci) {
                i64 fi = ci_if(ci_at(i));
                i64 j = 0;
                i64 dup = 0;
                while (j < n) {
                    if (ld64(out + j * 8) == fi) dup = 1;
                    j = j + 1;
                }
                if (!dup) {
                    if (n == 8) err_at(lg_file, lg_line, "too many interfaces on one class");
                    st64(out + n * 8, fi);
                    n = n + 1;
                }
            }
            i = i + 1;
        }
        ci = cl_base(cl_at(ci));
    }
    return n;
}

// resolves the class's virtual table: the base's slots first (prefix layout),
// then `override` filling an inherited slot and `virtual` taking a new one
void lg_resolve_slots(i64 ci) {
    uptr c = cl_at(ci);
    i64 v0 = lg_nvs;
    i64 base = cl_base(c);
    if (base >= 0) {
        uptr b = cl_at(base);
        i64 i = 0;
        while (i < cl_nv(b)) {
            if (lg_nvs == LG_MAXVSLOT) err_at(lg_file, lg_line, "too many virtual slots");
            uptr src = vs_at(cl_v0(b) + i);
            uptr dst = vs_at(lg_nvs);
            lg_put(dst, VS_M, vs_m(src));
            lg_put(dst, VS_FN, vs_fn(src));
            lg_nvs = lg_nvs + 1;
            i = i + 1;
        }
    }
    i64 nv = lg_nvs - v0;
    i64 k = 0;
    while (k < lg_nmth) {
        uptr m = mt_at(k);
        if (mt_cls(m) == ci) {
            i64 j = 0;
            i64 slot = -1;
            while (j < nv) {
                if (str_eq(vs_m(vs_at(v0 + j)), mt_name(m))) slot = j;
                j = j + 1;
            }
            if (mt_kind(m) == 2) {
                if (slot < 0)
                    err_at2(lg_file, lg_line, "override of a method the base does not declare", mt_name(m));
                lg_put(vs_at(v0 + slot), VS_FN, mt_fn(m));
                lg_put(m, MT_SLOT, slot);
            } else if (mt_kind(m) == 1) {
                if (slot >= 0)
                    err_at2(lg_file, lg_line, "virtual redeclares an inherited slot; use override", mt_name(m));
                if (lg_nvs == LG_MAXVSLOT) err_at(lg_file, lg_line, "too many virtual slots");
                uptr dst = vs_at(lg_nvs);
                lg_put(dst, VS_M, mt_name(m));
                lg_put(dst, VS_FN, mt_fn(m));
                lg_put(m, MT_SLOT, nv);
                lg_nvs = lg_nvs + 1;
                nv = nv + 1;
            } else {
                if (slot >= 0)
                    err_at2(lg_file, lg_line, "method hides an inherited virtual; use override", mt_name(m));
                lg_put(m, MT_SLOT, -1);
            }
        }
        k = k + 1;
    }
    lg_put(c, CL_V0, v0);
    lg_put(c, CL_NV, nv);
}

// void C_vt_init(): fills the vtable, the interface method tables and the
// interface table. This is where "interface method not implemented" comes from.
void lg_gen_vtinit(i64 ci, uptr ifs, i64 ni) {
    uptr c = cl_at(ci);
    uptr cn = cl_name(c);
    uptr vt = lg_cat(cn, "_vt");
    uptr itab = 0;
    if (ni > 0) itab = lg_cat(cn, "_itab");
    i64 st = lg_stmt(lg_call2("st64", lg_id(vt), lg_addr(lg_cat(cn, "_release"))));
    if (itab)
        st = list_append(st, lg_stmt(lg_call2("st64",
                 lg_bin(K_ADD, lg_id(vt), lg_int(8)), lg_id(itab))));
    i64 k = 0;
    while (k < cl_nv(c)) {
        st = list_append(st, lg_stmt(lg_call2("st64",
                 lg_bin(K_ADD, lg_id(vt), lg_int((LG_VT_FIXED + k) * 8)),
                 lg_addr(vs_fn(vs_at(cl_v0(c) + k))))));
        k = k + 1;
    }
    if (itab)
        st = list_append(st, lg_stmt(lg_call2("st64", lg_id(itab), lg_int(ni))));
    i64 i = 0;
    while (i < ni) {
        i64 fi = ld64(ifs + i * 8);
        uptr f = if_at(fi);
        uptr mt = lg_cat3(cn, "_", lg_cat(if_name(f), "_mt"));
        i64 j = 0;
        while (j < if_nm(f)) {
            uptr im = im_at(lg_imeth_at(fi, j));
            i64 mi = lg_method_find(ci, im_name(im));
            if (mi < 0)
                err_at2(lg_file, lg_line, "interface method not implemented", im_name(im));
            if (mt_np(mt_at(mi)) != im_np(im))
                err_at2(lg_file, lg_line, "method with arity different from the interface", im_name(im));
            if (mt_ret(mt_at(mi)) != im_ret(im) || mt_rcls(mt_at(mi)) != im_rcls(im)
                || mt_rif(mt_at(mi)) != im_rif(im))
                err_at2(lg_file, lg_line, "method with a return type different from the interface",
                        im_name(im));
            st = list_append(st, lg_stmt(lg_call2("st64",
                     lg_bin(K_ADD, lg_id(mt), lg_int(j * 8)),
                     lg_addr(mt_fn(mt_at(mi))))));
            j = j + 1;
        }
        st = list_append(st, lg_stmt(lg_call2("st64",
                 lg_bin(K_ADD, lg_id(itab), lg_int(8 + i * 16)), lg_int(fi))));
        st = list_append(st, lg_stmt(lg_call2("st64",
                 lg_bin(K_ADD, lg_id(itab), lg_int(16 + i * 16)), lg_id(mt))));
        i = i + 1;
    }
    top_add(lg_func(TY_VOID, lg_cat(cn, "_vt_init"), 0, lg_block_of(st)));
}

// uptr C_new(...): allocates, installs the vtable, sets the count to 1 and
// calls `init` when the class declares one. The parameters are init's.
void lg_gen_new(i64 ci) {
    uptr c = cl_at(ci);
    uptr cn = cl_name(c);
    i64 mi = lg_method_find(ci, "init");
    i64 params = 0;
    i64 args = lg_id("p");
    if (mi >= 0) {
        i64 pp = nd_next(mt_params(mt_at(mi)));
        while (pp != 0) {
            params = list_append(params, param_new(nd_type(pp), nd_name(pp)));
            args = list_append(args, lg_id(nd_name(pp)));
            pp = nd_next(pp);
        }
    }
    i64 st = lg_var(TY_UPTR, "p", lg_call("rt_alloc", lg_int(cl_sz(c))));
    st = list_append(st, lg_stmt(lg_call(lg_cat(cn, "_vt_init"), 0)));
    st = list_append(st, lg_stmt(lg_call2("st64", lg_id("p"), lg_id(lg_cat(cn, "_vt")))));
    st = list_append(st, lg_stmt(lg_call2("st64",
             lg_bin(K_ADD, lg_id("p"), lg_int(8)), lg_int(1))));
    if (mi >= 0) st = list_append(st, lg_stmt(lg_call(mt_fn(mt_at(mi)), args)));
    st = list_append(st, lg_ret(lg_id("p")));
    top_add(lg_func(TY_UPTR, lg_cat(cn, "_new"), params, lg_block_of(st)));
}

// void C_release(uptr self): `dispose` first, then the class-typed fields (the
// most derived class's first), then the block goes back to its size class
void lg_gen_release(i64 ci) {
    uptr c = cl_at(ci);
    uptr cn = cl_name(c);
    i64 st = 0;
    i64 di = lg_method_find(ci, "dispose");
    if (di >= 0) st = lg_stmt(lg_call(mt_fn(mt_at(di)), lg_id("self")));
    i64 k = ci;
    while (k >= 0) {
        i64 i = 0;
        while (i < lg_nfld) {
            uptr f = fd_at(i);
            if (fd_own(f) == k) {
                if (fd_cls(f) >= 0 || fd_if(f) >= 0) {
                    i64 addr = lg_bin(K_ADD, lg_id("self"), lg_int(fd_off(f)));
                    if (fd_nel(f) > 0)
                        st = list_append(st, lg_stmt(lg_call2("rt_release_array", addr, lg_int(fd_nel(f)))));
                    else
                        st = list_append(st, lg_stmt(lg_call("rc_dec", lg_call("ld64", addr))));
                }
            }
            i = i + 1;
        }
        k = cl_base(cl_at(k));
    }
    st = list_append(st, lg_stmt(lg_call2("rt_free", lg_id("self"), lg_int(cl_sz(c)))));
    top_add(lg_func(TY_VOID, lg_cat(cn, "_release"), param_new(TY_UPTR, "self"),
                    lg_block_of(st)));
}

// one member: a field, or a method in either spelling
void lg_member(i64 ci, uptr poff) {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    i64 kind = 0;
    if (lg_kw("virtual"))       { kind = 1; p_next(); }
    else if (lg_kw("override")) { kind = 2; p_next(); }
    i64 ret = TY_VOID;
    i64 rc = -1;
    i64 ri = -1;
    uptr mn = 0;
    i64 isfn = 0;
    if (p_id() == lg_tok_fn) {
        p_next();
        isfn = 1;
        mn = lg_declname("a method");
    } else {
        ret = lg_read_type(&rc, &ri);
        mn = lg_declname("a member");
    }
    if (!isfn && p_id() != K_LPAR) {             // ---- field ----
        if (kind != 0) err_at2(fl, line, "virtual/override on a field", mn);
        if (ret == TY_VOID) err_at2(fl, line, "field of type void", mn);
        i64 nel = 0;
        if (p_accept(K_LBRACK)) {
            if (p_id() != T_INT)
                err_at(p_file(), p_line(), "an array field size must be an integer literal");
            nel = p_val();
            if (nel < 1) err_at(p_file(), p_line(), "an array field size must be positive");
            p_next();
            p_expect(K_RBRACK, "expected ] in the array field size");
        }
        p_expect(K_SEMI, "expected ; after a class field");
        if (lg_field_own(ci, mn) >= 0) err_at2(fl, line, "field already declared", mn);
        if (lg_nfld == LG_MAXFIELD) err_at(fl, line, "too many fields");
        i64 w = type_width(ret);
        i64 off = ld64(poff);
        off = (off + w - 1) & ~(w - 1);
        uptr f = fd_at(lg_nfld);
        lg_put(f, FD_NAME, mn);
        lg_put(f, FD_OWN, ci);
        lg_put(f, FD_TY, ret);
        lg_put(f, FD_CLS, rc);
        lg_put(f, FD_IF, ri);
        lg_put(f, FD_OFF, off);
        lg_put(f, FD_NEL, nel);
        lg_nfld = lg_nfld + 1;
        if (nel > 0) off = off + w * nel;
        else         off = off + w;
        st64(poff, off);
        return;
    }
    // ---- method ----
    if (str_eq(mn, "new") || str_eq(mn, "vt_init") || str_eq(mn, "release"))
        err_at2(fl, line, "method name reserved by the class", mn);
    if (lg_method_own(ci, mn) >= 0) err_at2(fl, line, "method already declared", mn);
    i64 slv = lg_nlv;                            // the locals of whoever is parsing
    i64 sfloor = lg_lv_floor;                    // stay above them, never on top of them
    lg_lv_floor = lg_nlv;
    i64 np = 0;
    i64 params = lg_params(ci, &np);
    if (p_id() == lg_tok_arrow) {
        p_next();
        ret = lg_read_type(&rc, &ri);
    }
    if (lg_nmth == LG_MAXMETH) err_at(fl, line, "too many methods");
    uptr m = mt_at(lg_nmth);
    uptr fname = lg_mfn(cl_name(cl_at(ci)), mn);
    lg_put(m, MT_NAME, mn);
    lg_put(m, MT_FN, fname);
    lg_put(m, MT_CLS, ci);
    lg_put(m, MT_RET, ret);
    lg_put(m, MT_RCLS, rc);
    lg_put(m, MT_RIF, ri);
    lg_put(m, MT_SLOT, -1);
    lg_put(m, MT_NP, np);
    lg_put(m, MT_KIND, kind);
    lg_put(m, MT_PARAMS, params);
    lg_nmth = lg_nmth + 1;
    i64 f = lg_fnbody(ret, fname, params, rc, ri);
    set_nd_line(f, line);
    set_nd_file(f, fl);
    top_add(f);
    lg_nlv = slv;
    lg_lv_floor = sfloor;
}

void lg_class() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `class` word
    uptr sname = lg_declname("class");
    if (p_id() == K_LT) {
        lg_gen_record(sname, 0, line, fl);
        return;
    }
    uptr full = lg_qualify(lg_cur_ns, sname);
    if (lg_class_by_name(full) >= 0) err_at2(fl, line, "class already declared", full);
    i64 base = -1;
    i64 ifs[8];
    i64 nif = 0;
    if (p_accept(K_COLON)) {
        loop {
            i64 k = -1;
            uptr n = lg_read_uname(&k);
            if (k == 0) {
                if (base >= 0) err_at2(fl, line, "a class has at most one base", n);
                base = lg_class_by_name(n);
            } else {
                if (nif == 8) err_at(fl, line, "too many interfaces on one class");
                st64(ifs + nif * 8, lg_iface_by_name(n));
                nif = nif + 1;
            }
            if (!p_accept(K_COMMA)) break;
        }
    }
    if (lg_kw("where")) {
        p_next();
        lg_check_where();
    }
    if (lg_ncls == LG_MAXCLASS) err_at(fl, line, "too many classes");
    uptr c = cl_at(lg_ncls);
    lg_put(c, CL_NAME, full);
    lg_put(c, CL_BASE, base);
    lg_put(c, CL_V0, 0);
    lg_put(c, CL_NV, 0);
    i64 off = LG_HEADER;
    if (base >= 0) off = cl_sz(cl_at(base));
    lg_put(c, CL_SZ, off);
    i64 ci = lg_ncls;
    lg_ncls = lg_ncls + 1;
    i64 i = 0;
    while (i < nif) {
        if (lg_nci == LG_MAXCI) err_at(fl, line, "too many class/interface pairs");
        lg_put(ci_at(lg_nci), CI_OWN, ci);
        lg_put(ci_at(lg_nci), CI_IF, ld64(ifs + i * 8));
        lg_nci = lg_nci + 1;
        i = i + 1;
    }
    lg_register_type(full);
    if (!str_eq(full, sname)) lg_register_type(sname);
    p_expect(K_LBRACE, "expected { in the class body");
    i64 scls = lg_cur_cls;
    lg_cur_cls = ci;
    loop {
        if (p_id() == K_RBRACE) break;
        if (p_id() == T_EOF) err_at(fl, line, "unterminated class");
        lg_member(ci, &off);
    }
    p_next();                                    // }
    lg_cur_cls = scls;
    lg_line = line;
    lg_file = fl;
    lg_put(cl_at(ci), CL_SZ, (off + 7) & ~7);
    lg_resolve_slots(ci);
    i64 ni = lg_collect_ifaces(ci, ifs);
    top_add(lg_glob(TY_U8, lg_cat(full, "_vt"), (LG_VT_FIXED + cl_nv(cl_at(ci))) * 8));
    i = 0;
    while (i < ni) {
        i64 fi = ld64(ifs + i * 8);
        top_add(lg_glob(TY_U8, lg_cat3(full, "_", lg_cat(if_name(if_at(fi)), "_mt")),
                        if_nm(if_at(fi)) * 8));
        i = i + 1;
    }
    if (ni > 0) top_add(lg_glob(TY_U8, lg_cat(full, "_itab"), 8 + ni * 16));
    lg_gen_vtinit(ci, ifs, ni);
    lg_gen_new(ci);
    lg_gen_release(ci);
}

// ---- namespaces ----

void lg_ns_register(uptr name) {
    if (lg_reg_has(name)) return;
    syntax_stmt(name, &lg_declstmt);
    syntax_expr(name, &lg_ns_expr);
    lg_reg_add(name);
}

void lg_ns_add(uptr full) {
    if (lg_ns_find(full) >= 0) return;
    if (lg_nns == LG_MAXNS) die2("too many namespaces", full);
    lg_puta(lg_ns, lg_nns, full);
    lg_nns = lg_nns + 1;
}

// `namespace geo { ... }` / `namespace a.b { ... }`: sets the prefix every
// declaration inside is mangled with, and merges when the name is reopened
void lg_namespace() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `namespace` word
    uptr first = lg_declname("namespace");
    lg_ns_register(first);
    uptr full = first;
    lg_ns_add(full);                             // every prefix of `a.b` is one too,
    loop {                                       // so `a.b.Circle` resolves segment
        if (p_id() != lg_tok_dot) break;         // by segment
        p_next();
        uptr seg = lg_declname("namespace");
        full = lg_cat3(full, "__", seg);
        lg_ns_add(full);
    }
    p_expect(K_LBRACE, "expected { in the namespace body");
    uptr saved = lg_cur_ns;
    lg_cur_ns = full;
    loop {
        if (p_id() == K_RBRACE) break;
        if (p_id() == T_EOF) err_at(fl, line, "unterminated namespace");
        top_add(parse_top());
    }
    p_next();                                    // }
    lg_cur_ns = saved;
}

void lg_using_add(uptr prefix) {
    if (lg_using_has(prefix)) return;
    if (lg_nus == LG_MAXUSING) die2("too many using clauses", prefix);
    lg_puta(lg_us, lg_nus, prefix);
    lg_nus = lg_nus + 1;
}

// reads `a` / `a.b` after `using` or `import` and returns the mangled prefix;
// *ppath, when not 0, receives the file path `a.lx` / `a/b.lx`
uptr lg_ns_path(uptr ppath) {
    uptr full = lg_declname("namespace");
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, full, cstrlen(full));
    loop {
        if (p_id() != lg_tok_dot) break;
        p_next();
        uptr seg = lg_declname("namespace");
        full = lg_cat3(full, "__", seg);
        buf_u8(b, '/');
        buf_put(b, seg, cstrlen(seg));
    }
    if (ppath) {
        buf_put(b, ".lx", 3);
        buf_u8(b, 0);
        st64(ppath, buf_p(b));
    }
    return full;
}

// `using geo;` — the prefix joins the search list used for unqualified names
void lg_using() {
    p_next();                                    // the `using` word
    uptr pre = lg_ns_path(0);
    p_expect(K_SEMI, "expected ; after using");
    lg_using_add(pre);
}

// `import geo;` — exactly `#include "geo.lx"` plus an implicit `using geo;`.
// The include goes through lex_include, so it obeys the includer's directory,
// then [include].paths, and it is once-only: reopening the namespace in a
// second file merges by construction.
void lg_import() {
    i64 line = p_line();
    p_next();                                    // the `import` word
    u8 path[8];
    st64(path, 0);
    uptr pre = lg_ns_path(path);
    if (p_id() != K_SEMI) err_at(p_file(), p_line(), "expected ; after import");
    lg_using_add(pre);
    lex_include(ld64(path), line);               // the lookahead contract: still on the `;`
    p_next();
}
