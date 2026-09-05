// conc_stmt.mc -- the four statements the module teaches (`spawn`, `intent`,
// `await`, `lock`), the `chan_recv` expression, the chained `{` handler and the
// on_jump handler that puts an unlock on every edge out of a lock body.
//
// Every registration is a public hook. The two that carry the milestone:
//
//   syntax_stmt("{")  chained over examples/lang's own handler, which is what
//                     lets a SECOND module see scope exits the host already
//                     owns (docs/specs/M31.md section 2.4, row 1)
//   on_jump           the exit edges of a scope, at the moment the core builds
//                     the N_RETURN / N_BREAK / N_CONTINUE and BEFORE the host
//                     rewrites it into a block of releases (section 2.2)

// ---- reading the callee ----

uptr cc_callee(i64 line, uptr fl) {
    if (p_id() != T_IDENT)
        err_at2(fl, line, "the callee of spawn/intent/await must be a named function",
                p_name());
    return p_ident();
}

// Reads `( a, b, ... )` and builds it_arg(...it_arg(it_new(&f, n, flags), 0, a, o0)...),
// the one expression the whole lowering folds into: a syntax_stmt handler
// returns ONE node, and an N_BLOCK around it would scope the binding away.
//
// The callee's declared signature comes from decl_find (M31 section 2.1): the
// return type decides what the result may be bound to, the arity checks the
// call, and the host's own tables say whether that uptr is an object.
i64 cc_build(uptr callee, i64 line, uptr fl, uptr pret, uptr prcls, uptr prif) {
    i64 d = decl_find(callee);
    if (d < 0) err_at2(fl, line, "unknown function", callee);
    i64 ret = decl_ret(d);
    i64 np = decl_nparams(d);
    i64 rcls = 0 - 1;
    i64 rif = 0 - 1;
    cc_ret_class(callee, &rcls, &rif);
    p_expect(K_LPAR, "expected ( in the call");
    i64 av[CC_MAXARG];
    i64 ao[CC_MAXARG];
    i64 na = 0;
    loop {
        if (p_id() == K_RPAR) break;
        i64 e = parse_expr(0);
        // The CALL SITE's count, not the callee's arity, and the two are not the
        // same check: a callee with eight parameters is already refused by the
        // host (`too many parameters`, examples/lang/lang_stmt.mc, MAXPARAMS),
        // but nothing stops a source from writing eight arguments at a call to a
        // seven-parameter function. This fires there -- before `wrong number of
        // arguments` below, and before av/ao (CC_MAXARG words each) overflow.
        // tests/19-too-many-args.lx is the case.
        if (na == CC_MAXARG)
            err_at2(fl, line, "an intent takes at most 7 arguments", callee);
        st64(av + na * 8, e);
        st64(ao + na * 8, cc_arg_own(e));
        na = na + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RPAR, "expected ) after the arguments");
    if (na != np) err_at2(fl, line, "wrong number of arguments", callee);
    i64 flags = 0;
    if (ret == TY_VOID) flags = flags | CC_F_VOID;
    if (rcls >= 0 || rif >= 0) flags = flags | CC_F_OWNRES;
    lg_line = line;
    lg_file = fl;
    i64 n = lg_call("it_new", list_append(list_append(lg_addr(callee), lg_int(na)),
                                          lg_int(flags)));
    i64 i = 0;
    while (i < na) {
        i64 a = list_append(list_append(n, lg_int(i)), ld64(av + i * 8));
        n = lg_call("it_arg", list_append(a, lg_int(ld64(ao + i * 8))));
        i = i + 1;
    }
    st64(pret, ret);
    st64(prcls, rcls);
    st64(prif, rif);
    return n;
}

// declares the local an `intent` or an `await ... =` binds, in the host's own
// local table so that its scope exit, its `break N` and its `return` all work
i64 cc_bind(uptr name, i64 ty, i64 rcls, i64 rif, i64 value) {
    if (rcls >= 0 || rif >= 0) {
        lg_local_add(name, rcls, rif, 0);
        ty = TY_UPTR;
    } else {
        lg_local_add(name, 0 - 1, 0 - 1, 0);
    }
    i64 d = lg_var(ty, name, value);
    lg_done_add(d);                              // lg_note_var must not see it again
    return d;
}

// ---- intent x = f(a, b); ----

i64 cc_intent() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `intent` word
    uptr name = lg_declname("an intent");
    if (!p_accept(K_ASSIGN))
        err_at2(fl, line, "an intent must be initialized by a call", name);
    if (p_id() != T_IDENT)
        err_at2(fl, line, "an intent must be initialized by a call", name);
    uptr callee = p_ident();
    if (p_id() != K_LPAR)
        err_at2(fl, line, "an intent must be initialized by a call", name);
    i64 ret = 0;
    i64 rcls = 0 - 1;
    i64 rif = 0 - 1;
    i64 n = cc_build(callee, line, fl, &ret, &rcls, &rif);
    p_expect(K_SEMI, "expected ; after an intent");
    lg_line = line;
    lg_file = fl;
    cc_il_push(name, ret, rcls, rif, line, fl);
    // the local is an ordinary $Intent object: the host releases it at the end
    // of the scope, and it_release then joins whatever is still running
    lg_local_add(name, cc_intent_cls, 0 - 1, 0);
    i64 d = lg_var(TY_UPTR, name, lg_call("it_submit", n));
    lg_done_add(d);
    return d;
}

// ---- spawn f(a); ----

i64 cc_spawn() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `spawn` word
    uptr callee = cc_callee(line, fl);
    i64 ret = 0;
    i64 rcls = 0 - 1;
    i64 rif = 0 - 1;
    i64 n = cc_build(callee, line, fl, &ret, &rcls, &rif);
    p_expect(K_SEMI, "expected ; after spawn");
    lg_line = line;
    lg_file = fl;
    return lg_stmt(lg_call("it_go", n));
}

// ---- await ----

// the intent local `name` refers to, with the two module errors on it
i64 cc_await_target(uptr name, i64 line, uptr fl) {
    i64 k = cc_il_find(name);
    if (k < 0) err_at2(fl, line, "await expects an intent", name);
    uptr r = il_at(k);
    if (il_await(r)) err_at2(fl, line, "this intent was already awaited", name);
    lg_put(r, IL_AWAIT, 1);
    return k;
}

i64 cc_await() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `await` word
    // the module owns both words, so it keeps the depth itself: waiting while
    // holding a lock is how two intents that await each other deadlock without
    // the wait-for graph ever seeing it
    if (cc_nlk > 0) {
        if (p_blockdepth() >= lk_depth(lk_at(cc_nlk - 1)))
            err_at(fl, line, "await while holding a lock: release it first");
    }
    if (p_id() != T_IDENT) err_at2(fl, line, "await expects an intent", p_name());
    uptr first = p_ident();
    if (p_accept(K_ASSIGN)) {
        uptr src = cc_callee(line, fl);
        if (p_id() == K_LPAR) {                  // await r = f(a);
            i64 ret = 0;
            i64 rcls = 0 - 1;
            i64 rif = 0 - 1;
            i64 n = cc_build(src, line, fl, &ret, &rcls, &rif);
            p_expect(K_SEMI, "expected ; after await");
            lg_line = line;
            lg_file = fl;
            if (ret == TY_VOID)
                err_at2(fl, line, "this intent has no value to bind: use \"await x;\"", src);
            return cc_bind(first, ret, rcls, rif,
                           lg_call("it_call", lg_call("it_submit", n)));
        }
        i64 k = cc_await_target(src, line, fl);  // await r = x;
        p_expect(K_SEMI, "expected ; after await");
        uptr r = il_at(k);
        lg_line = line;
        lg_file = fl;
        if (il_ret(r) == TY_VOID)
            err_at2(fl, line, "this intent has no value to bind: use \"await x;\"", src);
        return cc_bind(first, il_ret(r), il_rcls(r), il_rif(r),
                       lg_call("it_take", lg_id(src)));
    }
    if (p_id() == K_LPAR) {                      // await f(a);
        i64 ret = 0;
        i64 rcls = 0 - 1;
        i64 rif = 0 - 1;
        i64 n = cc_build(first, line, fl, &ret, &rcls, &rif);
        p_expect(K_SEMI, "expected ; after await");
        lg_line = line;
        lg_file = fl;
        return lg_stmt(lg_call("it_calld", lg_call("it_submit", n)));
    }
    cc_await_target(first, line, fl);            // await x;
    p_expect(K_SEMI, "expected ; after await");
    lg_line = line;
    lg_file = fl;
    return lg_stmt(lg_call("it_drop", lg_id(first)));
}

// ---- lock (m) { ... } ----
//
//     { uptr $g = m; mx_lock($g); <body> mx_unlock($g); }
//
// The mutex goes into a gensym first so that the unlock an exit edge needs is a
// LOCAL and not a re-evaluation of the expression -- `lock (self.m)` must not
// load the field twice, and a jump out of the body has no access to the
// expression's own scope anyway.
i64 cc_lock() {
    i64 line = p_line();
    uptr fl = p_file();
    lg_line = line;
    lg_file = fl;
    p_next();                                    // the `lock` word
    p_expect(K_LPAR, "expected ( after lock");
    i64 m = parse_expr(0);
    p_expect(K_RPAR, "expected ) after the lock expression");
    if (p_id() != K_LBRACE) err_at(p_file(), p_line(), "expected { after lock (...)");
    if (cc_nlk == CC_MAXLOCK) err_at(fl, line, "locks nested too deep");
    uptr t = gensym_new();
    uptr f = lk_at(cc_nlk);
    lg_put(f, LK_DEPTH, p_blockdepth() + 1);     // the body's own block
    lg_put(f, LK_LP, lg_nlp);
    lg_put(f, LK_TMP, t);
    cc_nlk = cc_nlk + 1;
    i64 body = parse_stmt();
    cc_nlk = cc_nlk - 1;
    lg_line = line;
    lg_file = fl;
    i64 st = lg_var(TY_UPTR, t, m);
    st = list_append(st, lg_stmt(lg_call("mx_lock", lg_id(t))));
    st = list_append(st, body);
    st = list_append(st, lg_stmt(lg_call("mx_unlock", lg_id(t))));
    return lg_block_of(st);
}

// ---- the exit edges of a lock body ----
//
// on_jump fires where the CORE builds the jump, before any on_stmt hook, which
// is the whole point: examples/lang rewrites a `return` into an N_BLOCK of
// releases, and a module behind it could no longer recognise the jump. Two
// teams built this same `lock` by appending the unlock after the body and both
// reproduced the same defect -- a `return` in the body jumps over the unlock and
// the next call hangs forever.
i64 cc_on_jump(i64 n, i64 kind, i64 depth) {
    if (cc_nlk == 0) return n;
    // Both jumps carry their level in nd_val: `break N` stores N and a bare
    // `break;` stores 1, `continue N` stores N and a bare `continue;` stores
    // 0 -- so the clamp is what reads "no level, i.e. the innermost loop".
    // An N_RETURN leaves every lock and never consults this.
    i64 lvl = 1;
    if (kind != N_RETURN) {
        lvl = nd_val(n);
        if (lvl < 1) lvl = 1;
    }
    lg_line = nd_line(n);
    lg_file = nd_file(n);
    i64 head = 0;
    i64 i = cc_nlk - 1;
    while (i >= 0) {
        uptr f = lk_at(i);
        if (depth < lk_depth(f)) break;          // a body the module is not inside
        if (kind != N_RETURN) {
            if (lg_nlp - lvl >= lk_lp(f)) break; // the jump stays inside this lock
        }
        head = list_append(head, lg_stmt(lg_call("mx_unlock", lg_id(lk_tmp(f)))));
        i = i - 1;
    }
    if (head == 0) return n;
    // `return f();` would otherwise evaluate f() AFTER the unlock, because the
    // host's own lowering wraps the expression in a block of its own. The value
    // goes into a temporary first, and the temporary carries the expression's
    // ownership so the host does not count it a second time.
    if (kind == N_RETURN) {
        i64 e = nd_a(n);
        if (e != 0) {
            i64 ty = TY_I64;
            if (lg_in_fn) ty = lg_fn_ret;
            if (ty != TY_VOID) {
                uptr t = gensym_new();
                i64 idn = lg_id(t);
                lg_xt_set(idn, lg_ecls(e), lg_eif(e), lg_eown(e), 0 - 1);
                head = list_append(lg_var(ty, t, e), head);
                set_nd_a(n, idn);
            }
        }
    }
    return lg_block_of(list_append(head, n));
}

// ---- the chained block ----
//
// examples/lang owns `{` (that is what makes its release happen per scope), and
// a second registration of the same word simply wins the lookup -- syntax_stmt
// searches back to front. Chaining is therefore: remember the host's handler at
// registration time and call it through callp. The host's block is unchanged;
// what this adds is the check that no intent declared in the scope is left
// un-awaited when the scope closes.
i64 cc_block() {
    i64 mark = cc_nil;
    i64 b = callp(cc_lang_block);
    i64 i = cc_nil - 1;
    while (i >= mark) {
        uptr r = il_at(i);
        if (!il_await(r))
            err_at2(il_file(r), il_line(r), "intent is never awaited in this scope",
                    il_name(r));
        i = i - 1;
    }
    cc_nil = mark;
    return b;
}

// ---- chan_recv(c) ----
//
// The only reason this is a registration and not a plain call: the channel
// hands out a reference OF ITS OWN, so the binding must not take a second one.
// lg_xt_set marks the result already-owned and the host's declaration lowering
// reads exactly that (`if (lg_eown(init)) v = init; else v = rt_own(init)`).
i64 cc_recv() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `chan_recv` word
    p_expect(K_LPAR, "expected ( after chan_recv");
    i64 na = 0;
    i64 args = lg_args(&na);
    lg_line = line;
    lg_file = fl;
    if (na != 1) err_at2(fl, line, "wrong number of arguments", "chan_recv");
    i64 r = lg_call("ch_recv", args);
    lg_xt_set(r, 0 - 1, 0 - 1, 1, 0 - 1);
    return r;
}

// ---- the startup check ----
//
// A Tier 2 pass, because the runtime has no other place to run before the first
// rc_inc: LDADDAL on a machine without FEAT_LSE is SIGILL with no diagnostic,
// and the core has no API a module could ask about the target at build time.
i64 cc_pass_boot(i64 root) {
    i64 n = root;
    while (n != 0) {
        if (nd_kind(n) == N_FUNC) {
            if (str_eq(nd_name(n), "main")) {
                i64 body = nd_b(n);
                if (body != 0) {
                    lg_line = nd_line(n);
                    lg_file = nd_file(n);
                    i64 st = lg_stmt(lg_call("conc_boot", 0));
                    set_nd_a(body, list_append(st, nd_a(body)));
                }
                return root;
            }
        }
        n = nd_next(n);
    }
    return root;
}
