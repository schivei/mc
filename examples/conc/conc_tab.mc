// conc_tab.mc -- the tables of the concurrency module, as flat records with
// named getters, in the project's mandatory style (docs/determinism.md rule 1:
// linear arrays in declaration order, nothing hashed, nothing iterated for
// output).
//
// The module stacks ON TOP of examples/lang: every lg_* name below comes from
// that module, which the taught compiler includes first
// (`[compiler] modules = ["../lang/lang.mc", "conc.mc"]`). Nothing here reaches
// into src/: the parser API it uses is the public one of
// docs/reference/hooks.md, and the host's API is whatever examples/lang exports
// to its own files.

#define CC_MAXINT   64                // intent locals live at once
#define CC_MAXLOCK  16                // `lock` bodies open at once
#define CC_MAXARG   7                 // callp takes the pointer plus 7 words

// The layout of the intent object, which lib/conc_rt.mc owns. Only the size is
// needed here: the class record below has to declare how many bytes rt_free
// gives back, and the module never touches a field.
#define CC_IT_SIZE  208

#define CC_F_OWNRES 1                 // the result carries a reference
#define CC_F_VOID   2                 // the callee returns nothing

// ---- one intent local ----
// Pushed when `intent x = f(...)` declares it, popped when the block that
// declared it closes. `IL_AWAIT` is what makes `intent is never awaited in this
// scope` and `this intent was already awaited` two different sentences.
#define IL_NAME  0
#define IL_RET   8                    // the callee's declared return type, TY_*
#define IL_RCLS  16                   // its class, -1
#define IL_RIF   24                   // its interface, -1
#define IL_AWAIT 32
#define IL_LINE  40                   // where it was declared: the error's position
#define IL_FILE  48
#define IL_REC   56

u8  cc_il[CC_MAXINT * IL_REC];
i64 cc_nil = 0;

uptr il_at(i64 i)     { return cc_il + i * IL_REC; }
uptr il_name(uptr r)  { return ld64(r + IL_NAME); }
i64  il_ret(uptr r)   { return ld64(r + IL_RET); }
i64  il_rcls(uptr r)  { return ld64(r + IL_RCLS); }
i64  il_rif(uptr r)   { return ld64(r + IL_RIF); }
i64  il_await(uptr r) { return ld64(r + IL_AWAIT); }
i64  il_line(uptr r)  { return ld64(r + IL_LINE); }
uptr il_file(uptr r)  { return ld64(r + IL_FILE); }

// ---- one open `lock` body ----
// LK_DEPTH is p_blockdepth() inside the body, so a jump the parser reports at a
// SMALLER depth is not in this body at all -- that is how a declaration the
// host generates mid-body (p_push_source + top_add, which parse_function
// rebases to 0) keeps its own returns out of an enclosing lock.
// LK_LP is lg_nlp, the host's loop nesting, which says whether a `break N`
// leaves the lock or stays inside a loop the body opened.
#define LK_DEPTH 0
#define LK_LP    8
#define LK_TMP   16                   // the gensym holding the mutex
#define LK_REC   24

u8  cc_lk[CC_MAXLOCK * LK_REC];
i64 cc_nlk = 0;

uptr lk_at(i64 i)     { return cc_lk + i * LK_REC; }
i64  lk_depth(uptr r) { return ld64(r + LK_DEPTH); }
i64  lk_lp(uptr r)    { return ld64(r + LK_LP); }
uptr lk_tmp(uptr r)   { return ld64(r + LK_TMP); }

// ---- module state ----
uptr cc_lang_block = 0;               // examples/lang's own `{` handler
i64  cc_intent_cls = -1;              // the $Intent tag class in the host's table

// The class the `intent` word widens to must be UNNAMEABLE, or `fn h() -> Intent`
// smuggles an intent out of a function and past every restriction. It is
// registered with neither type_alias nor syntax_stmt -- it is a row in the
// host's class table and nothing else -- so the word exists in no grammar
// position.
//
// The name is `$Intent$` and not the spec's `$Intent`, and the extra `$` is the
// whole point. The lexer really never forms an IDENTIFIER containing `$`, but it
// does form `$Intent` as one T_HOLE token whose LEXEME is exactly "$Intent" --
// and examples/lang's type reader resolves a name by lexeme (lg_read_type ->
// lg_is_uname -> lg_resolve), so `fn h() -> $Intent` was accepted and returned
// the tag. A trailing `$` cannot be part of any single token: a hole is `$`
// followed by identifier characters, and `$` is not one. Measured, not assumed:
// tests/13-tag-unnameable.lx is the case, and README.md records it.
//
// The record needs no vtable, no `_new` and no `_release`: lib/conc_rt.mc's
// it_new writes the vtable itself and slot 0 of it is it_release, which is all
// rc_dec ever looks at. What the row buys is everything else the host already
// does for an object: an intent local is released at scope exit, at `break N`
// and before `return`, and `ref` of one is refused.
void cc_make_intent_class() {
    if (lg_ncls == LG_MAXCLASS) die2("too many classes", "$Intent$");
    uptr c = cl_at(lg_ncls);
    lg_put(c, CL_NAME, "$Intent$");
    lg_put(c, CL_BASE, 0 - 1);
    lg_put(c, CL_SZ, CC_IT_SIZE);
    lg_put(c, CL_V0, lg_nvs);
    lg_put(c, CL_NV, 0);
    cc_intent_cls = lg_ncls;
    lg_ncls = lg_ncls + 1;
}

// ---- intent locals ----

// the innermost live intent local called `name`, or -1
i64 cc_il_find(uptr name) {
    i64 i = cc_nil - 1;
    while (i >= 0) {
        if (str_eq(il_name(il_at(i)), name)) return i;
        i = i - 1;
    }
    return -1;
}

void cc_il_push(uptr name, i64 ret, i64 rcls, i64 rif, i64 line, uptr fl) {
    if (cc_nil == CC_MAXINT) err_at(fl, line, "too many intents live at once");
    uptr r = il_at(cc_nil);
    lg_put(r, IL_NAME, name);
    lg_put(r, IL_RET, ret);
    lg_put(r, IL_RCLS, rcls);
    lg_put(r, IL_RIF, rif);
    lg_put(r, IL_AWAIT, 0);
    lg_put(r, IL_LINE, line);
    lg_put(r, IL_FILE, fl);
    cc_nil = cc_nil + 1;
}

// ---- the class of a callee's result ----
// decl_find/decl_ret (M31 section 2.1) answer with the CORE type; whether that
// uptr is an object is the host's own bookkeeping, so both of its tables are
// consulted: plain `fn`s first, then the methods a class or an instantiation
// generated (that is what makes `spawn Box__Circle__4_push(b, c)` carry `self`).
void cc_ret_class(uptr name, uptr prcls, uptr prif) {
    st64(prcls, 0 - 1);
    st64(prif, 0 - 1);
    i64 f = lg_fn_by_name(name);
    if (f >= 0) {
        st64(prcls, fnr_rcls(fn_at(f)));
        st64(prif, fnr_rif(fn_at(f)));
        return;
    }
    i64 i = 0;
    while (i < lg_nmth) {
        uptr m = mt_at(i);
        if (str_eq(mt_fn(m), name)) {
            st64(prcls, mt_rcls(m));
            st64(prif, mt_rif(m));
            return;
        }
        i = i + 1;
    }
    i64 ci = lg_ctor_class(name);
    if (ci >= 0) st64(prcls, ci);
}

// 1 when the expression carries an object, so an intent that captures it has to
// take a reference of its own
i64 cc_arg_own(i64 e) {
    if (lg_ecls(e) < 0) {
        if (lg_eif(e) < 0) return 0;
    }
    if (lg_eown(e)) return 2;                    // an owned temporary: it moves in
    return 1;                                    // borrowed: the intent counts it
}
