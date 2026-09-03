// lang_type.mc — how `lx` reads a type, resolves a name through the namespaces
// in scope, and instantiates a generic.
//
// The core has no notion of any of this. What it lends is exactly four things:
// `p_skip_balanced` to record a body, `p_subst_*` to bind the parameters,
// `p_push_source` to replay it and `p_resplit_punct` to undo the `>>` the lexer
// built by longest match. Mangling, memoization, constraints and the meaning of
// an argument are all decided here.

i64 lg_is_core_ty(i64 id) {
    if (id == K_U8 || id == K_U16 || id == K_U32) return 1;
    if (id == K_U64 || id == K_I64 || id == K_UPTR || id == K_VOID) return 1;
    return 0;
}

// a member name on the right of a `.` or after a type: an identifier, or a word
// some registration has already reserved (a class name used as a field name)
uptr lg_word() {
    if (p_id() == T_IDENT) return p_ident();
    uptr s = p_name();
    p_next();
    return s;
}

// kind: 0 class, 1 interface, 2 generic. -1 (returned) = the name is none of them.
i64 lg_lookup1(uptr full, uptr pkind) {
    i64 i = lg_class_by_name(full);
    if (i >= 0) { st64(pkind, 0); return i; }
    i = lg_iface_by_name(full);
    if (i >= 0) { st64(pkind, 1); return i; }
    i = lg_gen_by_name(full);
    if (i >= 0) { st64(pkind, 2); return i; }
    st64(pkind, -1);
    return -1;
}

// resolves an UNQUALIFIED name against the namespaces in scope: the namespace
// being declared wins outright; otherwise the top level and every `using`
// prefix are candidates and two winners are the ambiguity M22 asks to report.
i64 lg_resolve(uptr name, uptr pkind) {
    i64 k = -1;
    if (lg_cur_ns != 0) {
        if (ld8(lg_cur_ns) != 0) {
            i64 r = lg_lookup1(lg_qualify(lg_cur_ns, name), &k);
            if (r >= 0) { st64(pkind, k); return r; }
        }
    }
    i64 found = -1;
    i64 fk = -1;
    i64 n = 0;
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, name, cstrlen(name));
    buf_put(b, " (", 2);
    i64 r0 = lg_lookup1(name, &k);
    if (r0 >= 0) {
        found = r0;
        fk = k;
        n = 1;
        buf_put(b, "top level", 9);
    }
    i64 i = 0;
    while (i < lg_nus) {
        i64 r = lg_lookup1(lg_qualify(us_at(i), name), &k);
        if (r >= 0) {
            if (n > 0) buf_put(b, ", ", 2);
            buf_put(b, us_at(i), cstrlen(us_at(i)));
            if (n == 0) { found = r; fk = k; }
            n = n + 1;
        }
        i = i + 1;
    }
    if (n > 1) {
        buf_u8(b, ')');
        buf_u8(b, 0);
        err_at2(p_file(), p_line(), "ambiguous name", buf_p(b));
    }
    st64(pkind, fk);
    return found;
}

// 1 if the name is a class, an interface or a generic somewhere in scope
i64 lg_is_uname(uptr name) {
    i64 k = -1;
    if (lg_resolve(name, &k) >= 0) return 1;
    return 0;
}

// closes an argument list: a `>>` here is one token the lexer built by longest
// match, and p_resplit_punct is the only way to take it apart again
void lg_expect_gt() {
    if (p_id() == K_SHR) p_resplit_punct(1);
    p_expect(K_GT, "expected > to close the type arguments");
}

// ---- generic instantiation ----

// builds `Box__Circle__4` from the argument LEXEMES, in source order: that is
// what makes the generation order a function of first use and nothing else
uptr lg_mangle(uptr base, uptr args, i64 na) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, base, cstrlen(base));
    i64 i = 0;
    while (i < na) {
        uptr a = ld64(args + i * 8);
        buf_put(b, "__", 2);
        buf_put(b, a, cstrlen(a));
        i = i + 1;
    }
    buf_u8(b, 0);
    return buf_p(b);
}

// "Box__Circle__4 instantiated from main.lx:27" — the provenance is a string the
// module composes, and err_at prints it for everything inside the frame
uptr lg_frame(uptr mang, uptr fl, i64 line) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, mang, cstrlen(mang));
    buf_put(b, " instantiated from ", 19);
    buf_put(b, fl, cstrlen(fl));
    buf_u8(b, ':');
    uptr d = lg_num(line);
    buf_put(b, d, cstrlen(d));
    buf_u8(b, 0);
    return buf_p(b);
}

// pushes `header + recorded body` as a second source and drives the
// declarations it produces into the unit. The caller must already be sitting on
// the LAST token of its own construct: the p_next() below discards exactly that
// token (docs/surface.md § the lookahead contract).
void lg_replay(i64 gi, uptr mang, uptr args, i64 na, uptr fl, i64 line) {
    uptr g = gn_at(gi);
    u8 b[BUF_SIZE];
    buf_init(b);
    if (gn_kind(g) == 0) buf_put(b, "class ", 6);
    else                 buf_put(b, "fn ", 3);
    buf_put(b, mang, cstrlen(mang));
    buf_u8(b, ' ');
    buf_put(b, gn_body(g), gn_blen(g));
    lg_inst_add(mang);
    p_subst_reset();
    i64 i = 0;
    while (i < na) {
        uptr a = ld64(args + i * 8);
        if (gn_k(g, i) == 0) p_subst_name(gn_p(g, i), a);
        else                 p_subst_int(gn_p(g, i), atoi_lg(a));
        i = i + 1;
    }
    i64 d0 = p_depth();
    // the namespace of the DECLARATION, not of the use: a generic declared
    // inside `namespace geo` produces geo's names wherever it is instantiated
    uptr saved = lg_cur_ns;
    lg_cur_ns = gn_ns(g);
    p_push_source(lg_frame(mang, fl, line), buf_p(b), buf_len(b));
    p_next();
    loop {
        if (p_depth() == d0) break;
        top_add(parse_top());
    }
    lg_cur_ns = saved;
}

// decimal in a string back to an integer: the const arguments travel as lexemes
// so that the mangled name and the substitution come from the same text
i64 atoi_lg(uptr s) {
    i64 v = 0;
    i64 i = 0;
    i64 sig = 1;
    if (ld8(s) == '-') { sig = -1; i = 1; }
    while (ld8(s + i) >= '0') {
        if (ld8(s + i) > '9') break;
        v = v * 10 + (ld8(s + i) - '0');
        i = i + 1;
    }
    return v * sig;
}

// reads one type argument and returns its LEXEME (`i64`, `Circle`,
// `geo__Circle`), which is both what gets substituted and what gets mangled
uptr lg_read_targ() {
    if (lg_is_core_ty(p_id())) {
        uptr s = p_name();
        p_next();
        return s;
    }
    i64 kind = -1;
    uptr full = lg_read_uname(&kind);
    return full;
}

// reads `< a, b >` for generic `gi`, instantiates if needed and returns the
// mangled name. On return the parser sits ON the closing `>`, because that is
// the token the replay's p_next() has to discard.
uptr lg_read_targs(i64 gi) {
    uptr g = gn_at(gi);
    i64 line = p_line();
    uptr fl = p_file();
    uptr args[LG_MAXGP];
    p_expect(K_LT, "expected < after a generic name");
    i64 n = gn_np(g);
    i64 i = 0;
    while (i < n) {
        if (i > 0) p_expect(K_COMMA, "expected , between type arguments");
        if (gn_k(g, i) == 0) {
            st64(args + i * 8, lg_read_targ());
        } else {
            if (p_id() != T_INT)
                err_at(p_file(), p_line(), "a const generic argument must be an integer literal");
            st64(args + i * 8, lg_num(p_val()));
            p_next();
        }
        i = i + 1;
    }
    if (p_id() == K_SHR) p_resplit_punct(1);
    if (p_id() != K_GT) err_at(p_file(), p_line(), "expected > to close the type arguments");
    uptr mang = lg_mangle(gn_name(g), args, n);
    if (lg_inst_find(mang) >= 0) {
        p_next();                                // memoized: nothing to generate
        return mang;
    }
    lg_replay(gi, mang, args, n, fl, line);      // consumes the `>` through the push
    return mang;
}

// reads `Name`, `ns.Name`, `Name<args>` or `ns.Name<args>` and returns the
// resolved full name; *pkind is 0 for a class and 1 for an interface
uptr lg_read_uname(uptr pkind) {
    i64 line = p_line();
    uptr fl = p_file();
    uptr nm = lg_word();
    i64 kind = -1;
    i64 idx = -1;
    if (lg_ns_find(nm) >= 0) {
        uptr full = nm;
        loop {                                   // `a.b.Circle`: walk while the
            p_expect(lg_tok_dot, "expected . after a namespace name");
            uptr mem = lg_word();                // accumulated prefix is still a
            full = lg_qualify(full, mem);        // namespace
            if (lg_ns_find(full) < 0) break;
        }
        idx = lg_lookup1(full, &kind);
        if (idx < 0) err_at2(fl, line, "unknown name in namespace", full);
    } else {
        idx = lg_resolve(nm, &kind);
        if (idx < 0) err_at2(fl, line, "unknown type", nm);
    }
    if (kind == 2) {
        uptr mang = lg_read_targs(idx);
        i64 ci = lg_class_by_name(mang);
        if (ci < 0) err_at2(fl, line, "the generic did not produce a class", mang);
        st64(pkind, 0);
        return mang;
    }
    st64(pkind, kind);
    if (kind == 0) return cl_name(cl_at(idx));
    return if_name(if_at(idx));
}

// reads a type at the current position. Returns TY_*, and writes the class
// index to *pcls and the interface index to *pif (-1 when neither).
i64 lg_read_type(uptr pcls, uptr pif) {
    st64(pcls, -1);
    st64(pif, -1);
    if (lg_is_core_ty(p_id())) return p_type();
    uptr nm = p_name();
    if (lg_ns_find(nm) >= 0 || lg_is_uname(nm)) {
        i64 kind = -1;
        uptr full = lg_read_uname(&kind);
        if (kind == 0) st64(pcls, lg_class_by_name(full));
        else           st64(pif, lg_iface_by_name(full));
        return TY_UPTR;
    }
    return p_type();                             // str, bool, or a plain alias
}

// ---- `where` constraints ----

// `where A : B [, C : D]`, C# style. Checked here and nowhere else: at an
// instantiation A has already been substituted, so this runs on real names.
void lg_check_where() {
    loop {
        i64 line = p_line();
        uptr fl = p_file();
        uptr an = p_name();
        i64 ac = -1;
        i64 ai = -1;
        lg_read_type(&ac, &ai);
        p_expect(K_COLON, "expected : in a where clause");
        uptr bn = p_name();
        i64 bc = -1;
        i64 bi = -1;
        lg_read_type(&bc, &bi);
        i64 ok = 0;
        if (bc >= 0) {
            ok = lg_is_sub(ac, bc);
        } else if (bi >= 0) {
            if (ai == bi) ok = 1;
            else          ok = lg_implements(ac, bi);
        } else {
            err_at2(fl, line, "a where clause needs a class or an interface on the right", bn);
        }
        if (!ok) err_at2(fl, line, "constraint not satisfied", lg_cat3(an, " : ", bn));
        if (!p_accept(K_COMMA)) break;
    }
}

// skips `where ...` without checking anything: at a generic DECLARATION the
// type parameters are not classes yet, so there is nothing to check
void lg_skip_where() {
    loop {
        if (p_id() == K_LBRACE) break;
        if (p_id() == T_EOF) err_at(p_file(), p_line(), "unterminated where clause");
        p_next();
    }
}
