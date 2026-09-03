// lang_stmt.mc — `fn`, the block, `while`/`for`, the declaration of a local of
// class type, and the two rewrites the memory model needs: reference counting
// injected at scope exits and at every `return`, and `ref` parameters turned
// into loads and stores.
//
// The block is where all of it hangs together. `syntax_stmt("{", &lg_block)` is
// accepted because K_LBRACE is not a core keyword, and it gives the module
// every statement-position block, nested ones included — which is what makes
// release happen per SCOPE and not per function.

// ---- the module's function table ----

i64 lg_fn_by_name(uptr name) {
    i64 i = 0;
    while (i < lg_nfns) {
        if (str_eq(fnr_name(fn_at(i)), name)) return i;
        i = i + 1;
    }
    return -1;
}

// resolves an unqualified function name the same way lg_resolve does for a
// type: the namespace being declared wins, then the top level and each `using`
// prefix, and two winners are an ambiguity
uptr lg_fn_resolve(uptr sname) {
    if (lg_cur_ns != 0) {
        if (ld8(lg_cur_ns) != 0) {
            uptr q = lg_qualify(lg_cur_ns, sname);
            if (lg_fn_by_name(q) >= 0) return q;
        }
    }
    uptr found = 0;
    i64 n = 0;
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, sname, cstrlen(sname));
    buf_put(b, " (", 2);
    if (lg_fn_by_name(sname) >= 0) {
        found = sname;
        n = 1;
        buf_put(b, "top level", 9);
    }
    i64 i = 0;
    while (i < lg_nus) {
        uptr q = lg_qualify(us_at(i), sname);
        if (lg_fn_by_name(q) >= 0) {
            if (n > 0) buf_put(b, ", ", 2);
            buf_put(b, us_at(i), cstrlen(us_at(i)));
            if (n == 0) found = q;
            n = n + 1;
        }
        i = i + 1;
    }
    if (n > 1) {
        buf_u8(b, ')');
        buf_u8(b, 0);
        err_at2(p_file(), p_line(), "ambiguous name", buf_p(b));
    }
    if (n == 0) err_at2(p_file(), p_line(), "unknown function", sname);
    return found;
}

// `area(3, 4)` where `area` was declared inside a namespace and brought into
// scope by `using`/`import`. The short name is reserved for the whole program,
// like every Tier 3 registration.
i64 lg_nsfn_expr() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    uptr sname = lg_declname("a function");
    uptr full = lg_fn_resolve(sname);
    p_expect(K_LPAR, "expected ( in the call");
    i64 na = 0;
    i64 args = lg_args(&na);
    lg_line = line;
    lg_file = fl;
    return lg_call(full, args);
}

void lg_fn_add(uptr name, i64 rc, i64 ri) {
    if (lg_fn_by_name(name) >= 0) err_at2(lg_file, lg_line, "function already declared", name);
    if (lg_nfns == LG_MAXFN) err_at(lg_file, lg_line, "too many functions");
    uptr f = fn_at(lg_nfns);
    lg_put(f, FN_NAME, name);
    lg_put(f, FN_RCLS, rc);
    lg_put(f, FN_RIF, ri);
    lg_nfns = lg_nfns + 1;
}

// the class a generated constructor `C_new` builds, or -1
i64 lg_ctor_class(uptr name) {
    i64 i = 0;
    while (i < lg_ncls) {
        if (str_eq(lg_cat(cl_name(cl_at(i)), "_new"), name)) return i;
        i = i + 1;
    }
    return -1;
}

// ---- the static type of an expression ----
// The module knows only what it built or declared; anything else is opaque,
// which is exactly the gap docs/specs/M21.md § 4 records.

i64 lg_ecls(i64 n) {
    if (n == 0) return -1;
    i64 x = lg_xt_find(n);
    if (x >= 0) return xt_cls(xt_at(x));
    if (nd_kind(n) == N_IDENT) {
        i64 li = lg_local_find(nd_name(n));
        if (li >= 0) return lv_cls(lv_at(li));
        return -1;
    }
    if (nd_kind(n) == N_CALL) {
        i64 f = lg_fn_by_name(nd_name(n));
        if (f >= 0) return fnr_rcls(fn_at(f));
        return lg_ctor_class(nd_name(n));
    }
    return -1;
}

i64 lg_eif(i64 n) {
    if (n == 0) return -1;
    i64 x = lg_xt_find(n);
    if (x >= 0) return xt_if(xt_at(x));
    if (nd_kind(n) == N_IDENT) {
        i64 li = lg_local_find(nd_name(n));
        if (li >= 0) return lv_if(lv_at(li));
        return -1;
    }
    if (nd_kind(n) == N_CALL) {
        i64 f = lg_fn_by_name(nd_name(n));
        if (f >= 0) return fnr_rif(fn_at(f));
    }
    return -1;
}

// 1 when the value already carries a reference of its own: `new C()`, or a call
// to a function that returns a class (every `lx` function returning a class
// hands out an owned reference — see lg_lower_return)
i64 lg_eown(i64 n) {
    if (n == 0) return 0;
    i64 x = lg_xt_find(n);
    if (x >= 0) return xt_own(xt_at(x));
    if (nd_kind(n) == N_CALL) {
        i64 f = lg_fn_by_name(nd_name(n));
        if (f >= 0) {
            uptr r = fn_at(f);
            if (fnr_rcls(r) >= 0) return 1;
            if (fnr_rif(r) >= 0) return 1;
            return 0;
        }
        if (lg_ctor_class(nd_name(n)) >= 0) return 1;
    }
    return 0;
}

// ---- parameters ----

// reads `( ... )`. selfcls >= 0 means a method: `self` comes first, with the
// class it belongs to, so the body's `self.x` knows what it is looking at.
i64 lg_params(i64 selfcls, uptr pnp) {
    p_expect(K_LPAR, "expected ( in the parameter list");
    i64 head = 0;
    i64 np = 0;
    if (selfcls >= 0) {
        if (!lg_kw("self")) err_at(p_file(), p_line(), "the first parameter of a method is `self`");
        p_next();
        head = param_new(TY_UPTR, "self");
        lg_local_add("self", selfcls, -1, 1);
        if (p_id() != K_COMMA) {
            p_expect(K_RPAR, "expected ) in the parameter list");
            st64(pnp, 0);
            return head;
        }
        p_next();
    }
    loop {
        if (p_id() == K_RPAR) break;
        i64 isref = 0;
        if (p_id() == lg_tok_ref) { isref = 1; p_next(); }
        i64 pc = -1;
        i64 pi = -1;
        i64 ty = lg_read_type(&pc, &pi);
        if (ty == TY_VOID) err_at(p_file(), p_line(), "parameter of type void");
        if (isref) {
            if (pc >= 0 || pi >= 0)
                err_at(p_file(), p_line(), "ref of a class type is not allowed");
        }
        uptr pn = lg_declname("a parameter");
        i64 pty = ty;
        if (isref) pty = TY_UPTR;
        head = list_append(head, param_new(pty, pn));
        i64 li = lg_local_add(pn, pc, pi, 1);
        if (isref) {
            lg_put(lv_at(li), LV_REF, 1);
            lg_put(lv_at(li), LV_RW, type_width(ty));
        }
        np = np + 1;
        if (np + 1 > MAXPARAMS) err_at(p_file(), p_line(), "too many parameters");
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RPAR, "expected ) in the parameter list");
    st64(pnp, np);
    return head;
}

// ---- `ref` parameters: the body is rewritten in place ----
// `ref i64 x` arrived as a uptr parameter; every use of `x` in the body becomes
// ldW(x) and every `x = e` becomes stW(x, e). This also covers `x += 1`, which
// the prelude expands to `x = x + 1` before we get here.
void lg_ref_fix(i64 n, uptr name, i64 w) {
    if (n == 0) return;
    i64 nx = nd_next(n);
    i64 k = nd_kind(n);
    if (k == N_IDENT) {
        // `bump(ref x)` inside a function whose own `x` is already a ref: the
        // module built that N_IDENT to pass the address on, and lg_ref marked
        // it, so it must stay the raw address
        if (lg_done_has(n)) {
            lg_ref_fix(nx, name, w);
            return;
        }
        if (str_eq(nd_name(n), name)) {
            i64 inner = node_new(N_IDENT, nd_line(n), nd_file(n));
            set_nd_name(inner, name);
            set_nd_type(inner, TY_UPTR);
            set_nd_kind(n, N_CALL);
            set_nd_name(n, lg_ldn_w(w));
            set_nd_a(n, inner);
            set_nd_type(n, TY_I64);
            lg_ref_fix(nx, name, w);
            return;
        }
    }
    if (k == N_ASSIGN) {
        if (str_eq(nd_name(n), name)) {
            lg_ref_fix(nd_a(n), name, w);        // the value first
            i64 slot = node_new(N_IDENT, nd_line(n), nd_file(n));
            set_nd_name(slot, name);
            set_nd_type(slot, TY_UPTR);
            i64 call = node_new(N_CALL, nd_line(n), nd_file(n));
            set_nd_name(call, lg_stn_w(w));
            set_nd_a(call, list_append(slot, nd_a(n)));
            set_nd_type(call, TY_I64);
            set_nd_kind(n, N_EXPRSTMT);
            set_nd_name(n, 0);
            set_nd_a(n, call);
            lg_ref_fix(nx, name, w);
            return;
        }
    }
    lg_ref_fix(nd_a(n), name, w);
    lg_ref_fix(nd_b(n), name, w);
    lg_ref_fix(nd_c(n), name, w);
    lg_ref_fix(nd_d(n), name, w);
    lg_ref_fix(nx, name, w);
}

uptr lg_ldn_w(i64 w) {
    if (w == 1) return "ld8";
    if (w == 2) return "ld16";
    if (w == 4) return "ld32";
    return "ld64";
}

uptr lg_stn_w(i64 w) {
    if (w == 1) return "st8";
    if (w == 2) return "st16";
    if (w == 4) return "st32";
    return "st64";
}

// ---- the function body ----

i64 lg_fnbody(i64 ty, uptr name, i64 params, i64 rc, i64 ri) {
    i64 line = p_line();
    uptr fl = p_file();
    i64 np0 = lg_nlv;                            // the parameters, and nothing else yet
    i64 s1 = lg_in_fn;
    i64 s2 = lg_fn_ret;
    i64 s3 = lg_fn_rcls;
    i64 s4 = lg_fn_rif;
    i64 s5 = lg_fn_lv0;
    lg_in_fn = 1;
    lg_fn_ret = ty;
    lg_fn_rcls = rc;
    lg_fn_rif = ri;
    lg_fn_lv0 = np0;
    if (p_id() != K_LBRACE) err_at(fl, line, "expected { in the function body");
    i64 body = parse_stmt();
    i64 i = lg_lv_floor;
    while (i < np0) {
        uptr l = lv_at(i);
        if (lv_ref(l)) lg_ref_fix(body, lv_name(l), lv_rw(l));
        i = i + 1;
    }
    lg_in_fn = s1;
    lg_fn_ret = s2;
    lg_fn_rcls = s3;
    lg_fn_rif = s4;
    lg_fn_lv0 = s5;
    i64 f = node_new(N_FUNC, line, fl);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    set_nd_b(f, body);
    return f;
}

// ---- releases ----

// rc_dec for every class-typed local from `base` on, in reverse declaration
// order; parameters are borrowed and never appear here
i64 lg_decs_from(i64 base) {
    i64 head = 0;
    i64 i = lg_nlv - 1;
    while (i >= base) {
        uptr l = lv_at(i);
        if (!lv_param(l)) {
            if (lv_cls(l) >= 0 || lv_if(l) >= 0)
                head = list_append(head, lg_stmt(lg_call("rc_dec", lg_id(lv_name(l)))));
        }
        i = i - 1;
    }
    return head;
}

// `return e` becomes `{ T $t = e; [rc_inc($t);] releases...; return $t; }`.
// The temporary is what makes the releases safe: the value is already computed
// when the locals go away, and a returned local is incremented first, so the
// caller receives a reference of its own.
void lg_lower_return(i64 n) {
    lg_line = nd_line(n);
    lg_file = nd_file(n);
    i64 e = nd_a(n);
    i64 st = 0;
    i64 rv = 0;
    if (lg_fn_ret == TY_VOID) {
        if (e != 0) st = lg_stmt(e);
    } else if (e != 0) {
        uptr t = gensym_new();
        st = lg_var(lg_fn_ret, t, e);
        if (lg_fn_rcls >= 0 || lg_fn_rif >= 0) {
            if (!lg_eown(e)) st = list_append(st, lg_stmt(lg_call("rc_inc", lg_id(t))));
        }
        rv = lg_id(t);
    }
    st = list_append(st, lg_decs_from(lg_fn_lv0));
    i64 r = lg_ret(rv);
    lg_done_add(r);
    st = list_append(st, r);
    set_nd_kind(n, N_BLOCK);
    set_nd_op(n, 0);
    set_nd_type(n, 0);
    set_nd_val(n, 0);
    set_nd_name(n, 0);
    set_nd_a(n, st);
    set_nd_b(n, 0);
    set_nd_c(n, 0);
    set_nd_d(n, 0);
}

// `break`/`continue` leave every scope opened inside the loop they jump out of.
// Only `while` and `for` push a mark: a bare core `loop` is not tracked, which
// README.md lists as a known limit.
void lg_lower_jump(i64 n) {
    if (lg_nlp == 0) return;
    i64 lvl = 1;
    if (nd_kind(n) == N_BREAK) lvl = nd_val(n);
    if (lvl < 1) lvl = 1;
    i64 idx = lg_nlp - lvl;
    if (idx < 0) return;
    lg_line = nd_line(n);
    lg_file = nd_file(n);
    i64 decs = lg_decs_from(lp_at(idx));
    if (decs == 0) return;
    i64 j = node_new(nd_kind(n), nd_line(n), nd_file(n));
    set_nd_val(j, nd_val(n));
    lg_done_add(j);
    decs = list_append(decs, j);
    set_nd_kind(n, N_BLOCK);
    set_nd_val(n, 0);
    set_nd_a(n, decs);
}

// `x = e` on a class-typed local: one call keeps both counts straight, and the
// core never sees an assignment it would have to understand.
// A class-typed PARAMETER (`self` included) is borrowed: the caller's reference
// was never counted on entry, so `rt_store` would release an object the caller
// still holds. Refused, which keeps "parameters are borrowed: no rc traffic".
void lg_lower_assign(i64 n) {
    lg_line = nd_line(n);
    lg_file = nd_file(n);
    uptr nm = nd_name(n);
    i64 li = lg_local_find(nm);
    if (li >= 0 && lv_param(lv_at(li)))
        err_at2(lg_file, lg_line, "cannot reassign a borrowed parameter of class type", nm);
    i64 e = nd_a(n);
    uptr f = "rt_store";
    if (lg_eown(e)) f = "rt_store_own";
    i64 call = lg_call2(f, lg_addr(nd_name(n)), e);
    set_nd_kind(n, N_EXPRSTMT);
    set_nd_name(n, 0);
    set_nd_a(n, call);
}

i64 lg_assign_is_ref(uptr name) {
    i64 li = lg_local_find(name);
    if (li < 0) return 0;
    uptr l = lv_at(li);
    if (lv_cls(l) >= 0) return 1;
    if (lv_if(l) >= 0) return 1;
    return 0;
}

// walks a statement just parsed and lowers what the memory model owns. Runs at
// the innermost block that contains the node, which is why the live set is
// simply "every local from the function's first one to now".
void lg_lower(i64 n) {
    if (n == 0) return;
    i64 nx = nd_next(n);
    i64 k = nd_kind(n);
    if (k == N_RETURN) {
        if (!lg_done_has(n)) lg_lower_return(n);
    } else if (k == N_BREAK || k == N_CONTINUE) {
        if (!lg_done_has(n)) lg_lower_jump(n);
    } else if (k == N_ASSIGN && lg_assign_is_ref(nd_name(n))) {
        lg_lower_assign(n);
    } else {
        lg_lower(nd_a(n));
        lg_lower(nd_b(n));
        lg_lower(nd_c(n));
        lg_lower(nd_d(n));
    }
    lg_lower(nx);
}

// A local the CORE declared (`i64 n = 0;`): the module still has to know its
// name, or `ref n` and a later `n = e` would not find it. lg_declstmt marks the
// N_VAR it built as already handled, so it is not registered twice.
void lg_note_var(i64 s) {
    if (s == 0) return;
    if (nd_kind(s) != N_VAR) return;
    if (lg_done_has(s)) return;
    lg_local_add(nd_name(s), -1, -1, 0);
}

// ---- the block ----

i64 lg_block() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // {
    i64 mark = lg_nlv;
    i64 head = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        if (p_id() == T_EOF) err_at(fl, line, "unterminated block");
        i64 s = parse_stmt();
        if (lg_in_fn) {
            lg_lower(s);
            lg_note_var(s);
        }
        head = list_append(head, s);
    }
    p_next();                                    // }
    if (lg_in_fn) {
        lg_line = line;
        lg_file = fl;
        head = list_append(head, lg_decs_from(mark));
    }
    lg_nlv = mark;
    i64 b = node_new(N_BLOCK, line, fl);
    set_nd_a(b, head);
    return b;
}

// ---- while / for ----
// The module owns them so that the body goes through lg_block (a `#rule`'s
// `block` hole calls the core's parse_block and would skip it) and so that a
// `break` knows how many scopes it is leaving.

i64 lg_while() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `while` word
    p_expect(K_LPAR, "expected ( after while");
    i64 c = parse_expr(0);
    p_expect(K_RPAR, "expected ) after the while condition");
    if (lg_nlp == LG_MAXLOOP) err_at(fl, line, "loops nested too deep");
    lg_puta(lg_lp, lg_nlp, lg_nlv);
    lg_nlp = lg_nlp + 1;
    i64 body = parse_stmt();
    if (lg_in_fn) lg_lower(body);
    lg_nlp = lg_nlp - 1;
    i64 neg = node_new(N_UNARY, line, fl);
    set_nd_op(neg, K_BANG);
    set_nd_a(neg, c);
    i64 br = node_new(N_BREAK, line, fl);
    set_nd_val(br, 1);
    lg_done_add(br);
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, neg);
    set_nd_b(iff, br);
    i64 blk = node_new(N_BLOCK, line, fl);
    set_nd_a(blk, list_append(iff, body));
    i64 lp = node_new(N_LOOP, line, fl);
    set_nd_a(lp, blk);
    return lp;
}

// `x = e`, `x += e` or `x -= e` in the third slot of a `for` header
i64 lg_step() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    if (p_id() != T_IDENT) err_at(fl, line, "the for step must assign to a name");
    uptr x = p_ident();
    i64 v = 0;
    if (p_accept(K_ASSIGN)) {
        v = parse_expr(0);
    } else if (p_id() == lg_tok_addassign) {
        p_next();
        v = lg_bin(K_ADD, lg_id(x), parse_expr(0));
    } else if (p_id() == lg_tok_subassign) {
        p_next();
        v = lg_bin(K_SUB, lg_id(x), parse_expr(0));
    } else {
        err_at(fl, line, "expected =, += or -= in the for step");
    }
    i64 a = node_new(N_ASSIGN, line, fl);
    set_nd_name(a, x);
    set_nd_a(a, v);
    return a;
}

i64 lg_for() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `for` word
    p_expect(K_LPAR, "expected ( after for");
    i64 mark = lg_nlv;
    i64 init = parse_stmt();                     // consumes its own `;`
    if (lg_in_fn) {
        lg_lower(init);
        lg_note_var(init);
    }
    i64 cond = parse_expr(0);
    p_expect(K_SEMI, "expected ; in the for header");
    i64 step = lg_step();
    p_expect(K_RPAR, "expected ) in the for header");
    if (lg_nlp == LG_MAXLOOP) err_at(fl, line, "loops nested too deep");
    lg_puta(lg_lp, lg_nlp, lg_nlv);
    lg_nlp = lg_nlp + 1;
    i64 body = parse_stmt();
    if (lg_in_fn) lg_lower(body);
    lg_nlp = lg_nlp - 1;
    i64 neg = node_new(N_UNARY, line, fl);
    set_nd_op(neg, K_BANG);
    set_nd_a(neg, cond);
    i64 br = node_new(N_BREAK, line, fl);
    set_nd_val(br, 1);
    lg_done_add(br);
    i64 iff = node_new(N_IF, line, fl);
    set_nd_a(iff, neg);
    set_nd_b(iff, br);
    i64 inner = node_new(N_BLOCK, line, fl);
    set_nd_a(inner, list_append(list_append(iff, body), step));
    i64 lp = node_new(N_LOOP, line, fl);
    set_nd_a(lp, inner);
    i64 stmts = list_append(init, lp);
    lg_line = line;
    lg_file = fl;
    stmts = list_append(stmts, lg_decs_from(mark));
    lg_nlv = mark;
    i64 outer = node_new(N_BLOCK, line, fl);
    set_nd_a(outer, stmts);
    return outer;
}

// ---- local declaration of class, interface or namespace-qualified type ----

i64 lg_declstmt() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    i64 c = -1;
    i64 i = -1;
    i64 ty = lg_read_type(&c, &i);
    uptr name = lg_declname("a variable");
    if (p_id() == K_LBRACK)
        err_at2(p_file(), p_line(), "an array of class type is only allowed as a class field", name);
    i64 init = 0;
    if (p_accept(K_ASSIGN)) init = parse_expr(0);
    p_expect(K_SEMI, "expected ; after a declaration");
    lg_line = line;
    lg_file = fl;
    if (c < 0 && i < 0) {                        // an ordinary local, reached by qualified name
        lg_local_add(name, -1, -1, 0);
        i64 d0 = lg_var(ty, name, init);
        lg_done_add(d0);
        return d0;
    }
    i64 v = lg_int(0);
    if (init != 0) {
        if (lg_eown(init)) v = init;
        else               v = lg_call("rt_own", init);
    }
    lg_local_add(name, c, i, 0);
    i64 d = lg_var(TY_UPTR, name, v);
    lg_done_add(d);                              // lg_note_var must not see it again
    return d;
}

// a function declared inside a namespace also answers to its short name, so
// `using geo;` reaches it. Same reservation rule as every other registration.
void lg_fn_register(uptr sname) {
    if (lg_reg_has(sname)) return;
    syntax_expr(sname, &lg_nsfn_expr);
    lg_reg_add(sname);
}

// ---- fn ----

void lg_fn() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `fn` word
    uptr sname = lg_declname("fn");
    if (p_id() == K_LT) {
        lg_gen_record(sname, 1, line, fl);
        return;
    }
    uptr full = lg_qualify(lg_cur_ns, sname);
    i64 slv = lg_nlv;                            // the locals of whoever is parsing
    i64 sfloor = lg_lv_floor;                    // stay above them, never on top of them
    lg_lv_floor = lg_nlv;
    i64 np = 0;
    i64 params = lg_params(-1, &np);
    if (lg_kw("where")) {
        p_next();
        lg_check_where();
    }
    i64 ret = TY_VOID;
    i64 rc = -1;
    i64 ri = -1;
    if (p_id() == lg_tok_arrow) {
        p_next();
        ret = lg_read_type(&rc, &ri);
    }
    lg_fn_add(full, rc, ri);                // before the body: recursion sees the type
    if (!str_eq(full, sname)) lg_fn_register(sname);
    i64 f = lg_fnbody(ret, full, params, rc, ri);
    set_nd_line(f, line);
    set_nd_file(f, fl);
    top_add(f);
    lg_nlv = slv;
    lg_lv_floor = sfloor;
}
