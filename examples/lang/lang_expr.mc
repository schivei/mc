// lang_expr.mc — the expression side of `lx`: the `.` and `[` operators, `new`,
// `ref`, a qualified name and the use of a generic function.
//
// `syntax_infix(".", 12, &lg_dot)` is the hook a template cannot replace: the
// right operand is a NAME, and what the whole thing lowers to depends on the
// static type of the ALREADY PARSED left operand — a field becomes ldW/stW at an
// offset, a virtual method becomes callp through the vtable, a plain method
// becomes a direct call. Member assignment works because `=` is deliberately
// not in the core's infix table: the Pratt loop has already stopped, so the
// handler reads the `=` itself and the core sees a plain expression statement.

// argument list of a call, `(` already consumed by the caller
i64 lg_args(uptr pn) {
    i64 head = 0;
    i64 n = 0;
    loop {
        if (p_id() == K_RPAR) break;
        head = list_append(head, parse_expr(0));
        n = n + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RPAR, "expected ) after the arguments");
    st64(pn, n);
    return head;
}

// a method call on a class: virtual goes through the vtable, everything else is
// a direct call to the mangled Owner_method
i64 lg_call_method(i64 recv, i64 mi, i64 line, uptr fl) {
    uptr m = mt_at(mi);
    p_expect(K_LPAR, "expected ( in the method call");
    i64 na = 0;
    i64 args = lg_args(&na);
    lg_line = line;
    lg_file = fl;
    if (na != mt_np(m))
        err_at2(fl, line, "wrong number of arguments", mt_name(m));
    i64 r = 0;
    if (mt_slot(m) >= 0) {
        if (na + 2 > MAXPARAMS)
            err_at2(fl, line, "too many arguments for a virtual call", mt_name(m));
        i64 vt = lg_call("ld64", recv);
        i64 slot = lg_call("ld64", lg_bin(K_ADD, vt, lg_int((LG_VT_FIXED + mt_slot(m)) * 8)));
        r = lg_call("callp", list_append(list_append(slot, recv), args));
    } else {
        r = lg_call(mt_fn(m), list_append(recv, args));
    }
    i64 own = 0;
    if (mt_rcls(m) >= 0 || mt_rif(m) >= 0) own = 1;
    lg_xt_set(r, mt_rcls(m), mt_rif(m), own, -1);
    return r;
}

// a method call through an interface: the object's vtable holds a per-class
// interface table, and rt_itab finds the method array of this interface in it
i64 lg_call_iface(i64 recv, i64 fi, uptr mem, i64 line, uptr fl) {
    i64 k = lg_imeth_find(fi, mem);
    if (k < 0) err_at2(fl, line, "unknown interface method", mem);
    uptr im = im_at(lg_imeth_at(fi, k));
    p_expect(K_LPAR, "expected ( in the interface method call");
    i64 na = 0;
    i64 args = lg_args(&na);
    lg_line = line;
    lg_file = fl;
    if (na != im_np(im)) err_at2(fl, line, "wrong number of arguments", mem);
    if (na + 2 > MAXPARAMS) err_at2(fl, line, "too many arguments for a virtual call", mem);
    i64 tab = lg_call2("rt_itab", lg_call("ld64", recv), lg_int(fi));
    i64 slot = lg_call("ld64", lg_bin(K_ADD, tab, lg_int(k * 8)));
    i64 r = lg_call("callp", list_append(list_append(slot, recv), args));
    i64 own = 0;
    if (im_rcls(im) >= 0 || im_rif(im) >= 0) own = 1;
    lg_xt_set(r, im_rcls(im), im_rif(im), own, -1);
    return r;
}

// a scalar field: `p.f`, `p.f = e`, `p.f += e`
i64 lg_field_use(i64 left, i64 fdi, i64 line, uptr fl) {
    uptr f = fd_at(fdi);
    i64 addr = lg_bin(K_ADD, left, lg_int(fd_off(f)));
    i64 isobj = 0;
    if (fd_cls(f) >= 0 || fd_if(f) >= 0) isobj = 1;
    if (p_accept(K_ASSIGN)) {
        i64 v = parse_expr(0);
        lg_line = line;
        lg_file = fl;
        if (isobj) {
            uptr fn = "rt_store";
            if (lg_eown(v)) fn = "rt_store_own";
            return lg_call2(fn, addr, v);
        }
        return lg_call2(lg_stn(fd_ty(f)), addr, v);
    }
    if (p_id() == lg_tok_addassign || p_id() == lg_tok_subassign) {
        i64 op = K_ADD;
        if (p_id() == lg_tok_subassign) op = K_SUB;
        p_next();
        i64 v = parse_expr(0);
        lg_line = line;
        lg_file = fl;
        if (isobj) err_at2(fl, line, "+= on a field of class type", fd_name(f));
        i64 cur = lg_call(lg_ldn(fd_ty(f)), lg_bin(K_ADD, left, lg_int(fd_off(f))));
        return lg_call2(lg_stn(fd_ty(f)), addr, lg_bin(op, cur, v));
    }
    i64 r = lg_call(lg_ldn(fd_ty(f)), addr);
    lg_xt_set(r, fd_cls(f), fd_if(f), 0, -1);
    return r;
}

i64 lg_dot(i64 left) {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    // `base.m(...)`: the parent's implementation, called directly
    if (nd_kind(left) == N_IDENT) {
        if (str_eq(nd_name(left), "base")) {
            if (lg_cur_cls < 0) err_at(fl, line, "`base` outside a method");
            i64 bc = cl_base(cl_at(lg_cur_cls));
            if (bc < 0) err_at(fl, line, "`base` in a class with no base");
            uptr mem = lg_declname("a member");
            i64 mi = lg_method_find(bc, mem);
            if (mi < 0) err_at2(fl, line, "the base class has no such method", mem);
            p_expect(K_LPAR, "expected ( in the base call");
            i64 na = 0;
            i64 args = lg_args(&na);
            lg_line = line;
            lg_file = fl;
            if (na != mt_np(mt_at(mi))) err_at2(fl, line, "wrong number of arguments", mem);
            i64 r = lg_call(mt_fn(mt_at(mi)), list_append(lg_id("self"), args));
            i64 own = 0;
            if (mt_rcls(mt_at(mi)) >= 0 || mt_rif(mt_at(mi)) >= 0) own = 1;
            lg_xt_set(r, mt_rcls(mt_at(mi)), mt_rif(mt_at(mi)), own, -1);
            return r;
        }
    }
    i64 ci = lg_ecls(left);
    i64 fi = lg_eif(left);
    uptr mem = lg_declname("a member");
    if (ci < 0) {
        if (fi < 0)
            err_at2(fl, line, "the static class of the left side is not known here", mem);
        return lg_call_iface(left, fi, mem, line, fl);
    }
    i64 fdi = lg_field_find(ci, mem);
    if (fdi >= 0) {
        uptr f = fd_at(fdi);
        if (fd_nel(f) > 0) {                     // an inline array: hand out its base
            i64 a = lg_bin(K_ADD, left, lg_int(fd_off(f)));
            lg_xt_set(a, fd_cls(f), fd_if(f), 0, fd_ty(f));
            return a;
        }
        return lg_field_use(left, fdi, line, fl);
    }
    i64 mi = lg_method_find(ci, mem);
    if (mi >= 0) return lg_call_method(left, mi, line, fl);
    err_at2(fl, line, lg_cat("unknown member of class ", cl_name(cl_at(ci))), mem);
    return 0;
}

// `a[i]` on an inline array field: `a` is the base address the `.` handler
// produced, and the element width comes from the field's declared type
i64 lg_index(i64 left) {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    i64 x = lg_xt_find(left);
    if (x < 0) err_at(fl, line, "[] on a value that is not an array field");
    i64 ety = xt_ety(xt_at(x));
    if (ety < 0) err_at(fl, line, "[] on a value that is not an array field");
    i64 ecls = xt_cls(xt_at(x));
    i64 eif = xt_if(xt_at(x));
    i64 idx = parse_expr(0);
    p_expect(K_RBRACK, "expected ] after the index");
    lg_line = line;
    lg_file = fl;
    i64 w = type_width(ety);
    i64 addr = lg_bin(K_ADD, left, lg_bin(K_MUL, idx, lg_int(w)));
    if (p_accept(K_ASSIGN)) {
        i64 v = parse_expr(0);
        lg_line = line;
        lg_file = fl;
        if (ecls >= 0 || eif >= 0) {
            uptr fn = "rt_store";
            if (lg_eown(v)) fn = "rt_store_own";
            return lg_call2(fn, addr, v);
        }
        return lg_call2(lg_stn(ety), addr, v);
    }
    i64 r = lg_call(lg_ldn(ety), addr);
    lg_xt_set(r, ecls, eif, 0, -1);
    return r;
}

// `new C(args)` / `new geo.C(args)` / `new Box<Circle, 4>(args)`
i64 lg_new() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `new` word
    i64 kind = -1;
    uptr full = lg_read_uname(&kind);            // instantiates a generic if needed
    if (kind != 0) err_at2(fl, line, "new of a type that is not a class", full);
    i64 ci = lg_class_by_name(full);
    p_expect(K_LPAR, "expected ( after new");
    i64 na = 0;
    i64 args = lg_args(&na);
    lg_line = line;
    lg_file = fl;
    i64 mi = lg_method_find(ci, "init");
    i64 want = 0;
    if (mi >= 0) want = mt_np(mt_at(mi));
    if (na != want) err_at2(fl, line, "wrong number of arguments to new", full);
    i64 c = lg_call(lg_cat(full, "_new"), args);
    lg_xt_set(c, ci, -1, 1, -1);
    return c;
}

// `ref x` at a call site: the address of a local or a parameter, which is
// exactly what the core's `&x` already produces
i64 lg_ref() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `ref` word
    if (p_id() != T_IDENT) err_at(fl, line, "ref expects the name of a local or parameter");
    uptr n = p_ident();
    i64 li = lg_local_find(n);
    if (li < 0) err_at2(fl, line, "ref expects a local or a parameter", n);
    // the same refusal `lg_params` applies to a `ref` parameter declaration:
    // the address of a class-typed slot is indistinguishable from a `ref i64`,
    // and writing through it would corrupt the object pointer
    if (lv_cls(lv_at(li)) >= 0 || lv_if(lv_at(li)) >= 0)
        err_at2(fl, line, "ref of a class type is not allowed", n);
    if (lv_ref(lv_at(li))) {
        i64 r = lg_id(n);                        // already an address: pass it along
        lg_done_add(r);                          // and keep lg_ref_fix off it
        return r;
    }
    return lg_addr(n);
}

// `geo.area(x)` / `a.b.thing` in expression position. The namespace name is a
// reserved word (docs/specs/M21.md § Namespaces records why: one lexer word
// table), so this is a syntax_expr and not a case of the `.` handler.
i64 lg_ns_expr() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    uptr full = lg_declname("namespace");
    loop {
        p_expect(lg_tok_dot, "expected . after a namespace name");
        uptr mem = lg_declname("a name");
        uptr next = lg_qualify(full, mem);
        if (lg_ns_find(next) >= 0) { full = next; continue; }
        full = next;
        break;
    }
    lg_line = line;
    lg_file = fl;
    if (p_id() == K_LPAR) {
        p_next();
        i64 na = 0;
        i64 args = lg_args(&na);
        lg_line = line;
        lg_file = fl;
        return lg_call(full, args);
    }
    return lg_id(full);
}

// `max<i64>(a, b)`: instantiate at the `>` (the lookahead contract lets the
// pushed source be parsed there and parsing resume at the `(`), then read the
// ordinary argument list
i64 lg_geninst_expr() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    uptr nm = lg_declname("a generic function");
    i64 kind = -1;
    i64 gi = lg_resolve(nm, &kind);
    if (gi < 0 || kind != 2) err_at2(fl, line, "unknown generic function", nm);
    uptr mang = lg_read_targs(gi);
    p_expect(K_LPAR, "expected ( after a generic function call");
    i64 na = 0;
    i64 args = lg_args(&na);
    lg_line = line;
    lg_file = fl;
    return lg_call(mang, args);
}
