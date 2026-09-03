// lang_util.mc — names, node builders and the linear lookups over the tables of
// lang_tab.mc. Nothing here touches the parser: it is the part of the module
// that would be identical in a language with a completely different syntax.

// ---- names ----

uptr lg_cat(uptr a, uptr b) {
    i64 la = cstrlen(a);
    i64 lb = cstrlen(b);
    uptr d = xalloc(la + lb + 1);
    mem_copy(d, a, la);
    mem_copy(d + la, b, lb);
    st8(d + la + lb, 0);
    return d;
}

uptr lg_cat3(uptr a, uptr b, uptr c) { return lg_cat(lg_cat(a, b), c); }

// v >= 0 in decimal, in the arena
uptr lg_num(i64 v) {
    u8 tmp[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    return xstrdup(tmp + i, 24 - i);
}

// the namespace prefix applied to a declared name: geo + Circle -> geo__Circle
uptr lg_qualify(uptr ns, uptr name) {
    if (ns == 0 || ld8(ns) == 0) return name;
    return lg_cat3(ns, "__", name);
}

// Circle + area -> Circle_area, the generated function of a method
uptr lg_mfn(uptr cls, uptr m) { return lg_cat3(cls, "_", m); }

// ---- lookups: linear, in declaration order (docs/determinism.md, rule 1) ----

i64 lg_class_by_name(uptr name) {
    i64 i = 0;
    while (i < lg_ncls) {
        if (str_eq(cl_name(cl_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

i64 lg_iface_by_name(uptr name) {
    i64 i = 0;
    while (i < lg_nifc) {
        if (str_eq(if_name(if_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

i64 lg_gen_by_name(uptr name) {
    i64 i = 0;
    while (i < lg_ngen) {
        if (str_eq(gn_name(gn_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

i64 lg_inst_find(uptr name) {
    i64 i = 0;
    while (i < lg_ninst) {
        if (str_eq(inst_at(i), name)) return i;
        i = i + 1;
    }
    return -1;
}

void lg_inst_add(uptr name) {
    if (lg_ninst == LG_MAXINST) err_at(lg_file, lg_line, "too many generic instantiations");
    lg_puta(lg_inst, lg_ninst, name);
    lg_ninst = lg_ninst + 1;
}

i64 lg_ns_find(uptr name) {
    i64 i = 0;
    while (i < lg_nns) {
        if (str_eq(ns_at(i), name)) return i;
        i = i + 1;
    }
    return -1;
}

i64 lg_using_has(uptr name) {
    i64 i = 0;
    while (i < lg_nus) {
        if (str_eq(us_at(i), name)) return 1;
        i = i + 1;
    }
    return 0;
}

// a field of `ci`, looking through the base chain; -1 if there is none.
// The scan is over the whole table filtered by owner, not over a contiguous
// slice: an instantiation triggered inside a class body appends its own
// records in the middle, and a slice would have swallowed them.
i64 lg_field_own(i64 ci, uptr name) {
    i64 i = 0;
    while (i < lg_nfld) {
        uptr f = fd_at(i);
        if (fd_own(f) == ci) {
            if (str_eq(fd_name(f), name)) return i;
        }
        i = i + 1;
    }
    return -1;
}

i64 lg_field_find(i64 ci, uptr name) {
    while (ci >= 0) {
        i64 r = lg_field_own(ci, name);
        if (r >= 0) return r;
        ci = cl_base(cl_at(ci));
    }
    return -1;
}

// a method declared by `ci` itself, ignoring the base chain
i64 lg_method_own(i64 ci, uptr name) {
    i64 i = 0;
    while (i < lg_nmth) {
        uptr m = mt_at(i);
        if (mt_cls(m) == ci) {
            if (str_eq(mt_name(m), name)) return i;
        }
        i = i + 1;
    }
    return -1;
}

// a method of `ci`, looking through the base chain (the most derived one wins)
i64 lg_method_find(i64 ci, uptr name) {
    while (ci >= 0) {
        i64 r = lg_method_own(ci, name);
        if (r >= 0) return r;
        ci = cl_base(cl_at(ci));
    }
    return -1;
}

// slot of `name` inside interface `fi`, in declaration order; -1 if absent
i64 lg_imeth_find(i64 fi, uptr name) {
    i64 k = 0;
    i64 i = 0;
    while (i < lg_nimth) {
        uptr m = im_at(i);
        if (im_own(m) == fi) {
            if (str_eq(im_name(m), name)) return k;
            k = k + 1;
        }
        i = i + 1;
    }
    return -1;
}

// the record index of interface `fi`'s slot `k`
i64 lg_imeth_at(i64 fi, i64 k) {
    i64 n = 0;
    i64 i = 0;
    while (i < lg_nimth) {
        if (im_own(im_at(i)) == fi) {
            if (n == k) return i;
            n = n + 1;
        }
        i = i + 1;
    }
    return -1;
}

// 1 if `sub` is `base` or descends from it
i64 lg_is_sub(i64 sub, i64 base) {
    if (sub < 0 || base < 0) return 0;
    while (sub >= 0) {
        if (sub == base) return 1;
        sub = cl_base(cl_at(sub));
    }
    return 0;
}

// 1 if class `ci` (or one of its bases) implements interface `fi`
i64 lg_implements(i64 ci, i64 fi) {
    if (ci < 0 || fi < 0) return 0;
    while (ci >= 0) {
        i64 i = 0;
        while (i < lg_nci) {
            if (ci_own(ci_at(i)) == ci) {
                if (ci_if(ci_at(i)) == fi) return 1;
            }
            i = i + 1;
        }
        ci = cl_base(cl_at(ci));
    }
    return 0;
}

// ---- locals ----

// searches down to lg_lv_floor and no further: a generic instantiated in the
// middle of a function body parses its methods with their own locals stacked on
// top of the ones already there, and must not see them
i64 lg_local_find(uptr name) {
    i64 i = lg_nlv - 1;
    while (i >= lg_lv_floor) {
        if (str_eq(lv_name(lv_at(i)), name)) return i;
        i = i - 1;
    }
    return -1;
}

i64 lg_local_add(uptr name, i64 ci, i64 fi, i64 isparam) {
    if (lg_nlv == LG_MAXLOCAL) err_at(lg_file, lg_line, "too many locals in one function");
    uptr l = lv_at(lg_nlv);
    lg_put(l, LV_NAME, name);
    lg_put(l, LV_CLS, ci);
    lg_put(l, LV_IF, fi);
    lg_put(l, LV_REF, 0);
    lg_put(l, LV_RW, 8);
    lg_put(l, LV_PARAM, isparam);
    lg_nlv = lg_nlv + 1;
    return lg_nlv - 1;
}

// ---- static type of an expression the module built ----

i64 lg_xt_find(i64 n) {
    i64 i = lg_nxt - 1;
    while (i >= 0) {
        if (xt_n(xt_at(i)) == n) return i;
        i = i - 1;
    }
    return -1;
}

void lg_xt_set(i64 n, i64 ci, i64 fi, i64 own, i64 ety) {
    if (lg_nxt == LG_MAXXT) err_at(lg_file, lg_line, "too many typed expressions");
    uptr x = xt_at(lg_nxt);
    lg_put(x, XT_N, n);
    lg_put(x, XT_CLS, ci);
    lg_put(x, XT_IF, fi);
    lg_put(x, XT_OWN, own);
    lg_put(x, XT_ETY, ety);
    lg_nxt = lg_nxt + 1;
}

// ---- nodes the module has already lowered ----

i64 lg_done_has(i64 n) {
    i64 i = lg_ndone - 1;
    while (i >= 0) {
        if (done_at(i) == n) return 1;
        i = i - 1;
    }
    return 0;
}

void lg_done_add(i64 n) {
    if (lg_ndone == LG_MAXDONE) err_at(lg_file, lg_line, "too many lowered returns");
    lg_puta(lg_done, lg_ndone, n);
    lg_ndone = lg_ndone + 1;
}

// ---- node builders: node_new/set_nd_* from src/ast.mc, nothing else ----

i64 lg_nd(i64 kind) { return node_new(kind, lg_line, lg_file); }

i64 lg_int(i64 v) {
    i64 n = lg_nd(N_INT);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 lg_id(uptr name) {
    i64 n = lg_nd(N_IDENT);
    set_nd_name(n, name);
    set_nd_type(n, TY_I64);
    return n;
}

i64 lg_addr(uptr name) {
    i64 n = lg_nd(N_ADDR);
    set_nd_name(n, name);
    set_nd_type(n, TY_UPTR);
    return n;
}

i64 lg_bin(i64 op, i64 a, i64 b) {
    i64 n = lg_nd(N_BINARY);
    set_nd_op(n, op);
    set_nd_a(n, a);
    set_nd_b(n, b);
    return n;
}

i64 lg_call(uptr name, i64 args) {
    i64 n = lg_nd(N_CALL);
    set_nd_name(n, name);
    set_nd_a(n, args);
    set_nd_type(n, TY_I64);
    return n;
}

i64 lg_call2(uptr name, i64 a, i64 b)  { return lg_call(name, list_append(a, b)); }

i64 lg_stmt(i64 e) {
    i64 n = lg_nd(N_EXPRSTMT);
    set_nd_a(n, e);
    return n;
}

i64 lg_block_of(i64 stmts) {
    i64 n = lg_nd(N_BLOCK);
    set_nd_a(n, stmts);
    return n;
}

i64 lg_ret(i64 e) {
    i64 n = lg_nd(N_RETURN);
    set_nd_a(n, e);
    return n;
}

i64 lg_var(i64 ty, uptr name, i64 init) {
    i64 n = lg_nd(N_VAR);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_a(n, init);
    return n;
}

i64 lg_func(i64 ty, uptr name, i64 params, i64 body) {
    i64 f = lg_nd(N_FUNC);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    set_nd_b(f, body);
    return f;
}

// global array with no initializer: a reservation in __bss, already zeroed
i64 lg_glob(i64 ty, uptr name, i64 nel) {
    i64 n = lg_nd(N_GLOBAL);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_val(n, nel);
    return n;
}

// the load/store intrinsic matching a type's width
uptr lg_ldn(i64 ty) {
    i64 w = type_width(ty);
    if (w == 1) return "ld8";
    if (w == 2) return "ld16";
    if (w == 4) return "ld32";
    return "ld64";
}

uptr lg_stn(i64 ty) {
    i64 w = type_width(ty);
    if (w == 1) return "st8";
    if (w == 2) return "st16";
    if (w == 4) return "st32";
    return "st64";
}
