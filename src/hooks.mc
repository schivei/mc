// hooks.mc — Tier 2 and Tier 3: registry of AST passes, of backends, of
// syntax (syntax/syntax_stmt) and of type aliases (type_alias).
//
// A pass is a function `i64 f(i64 root)` that returns the root (the same or another);
// a backend is a function `void f(i64 root, uptr out)` that writes the object.
// Both enter here as `uptr` — the address that `&name` produces — and are
// called with `callp`. Two linear tables, walked in registration order:
// determinism via rule 1 of docs/determinism.md (no hashing, no pointer
// order). Teaching the compiler means editing `src/user.mc` and running `make mc1`.
//
// M12 (Tier 3): the same two ideas — linear table + function `uptr` —
// apply to syntax. `syntax(word, &f)` says that word opens a
// top-level declaration and `syntax_stmt(word, &f)` that it opens a statement; the
// parser consults both tables and calls the handler with `callp`. `type_alias`
// is the third: a new name that `type_of_token` resolves to a core
// type. All three register the word in the lexer (`tok_add`), like `#rule` does
// with the dispatch literal, and all three refuse a core keyword.
//
// M21.5: `on_stmt(&f)` is the fourth kind of registration and the only one that
// is not keyed by a word: f sees every statement the parser produces, core or
// taught. `syntax_stmt("{", &f)` now also catches the blocks parse_function and
// a `#rule` block hole parse, so a module that tracks scopes sees all of them.
//
// M31: `on_jump(&f)` is the second registration keyed by nothing. It fires on
// the EXIT EDGES -- return, break, continue -- at the moment the core builds the
// node, ahead of every on_stmt hook, which is the only place a scope guard can
// put code that must run on every edge out of a block.
//
// M41.5: `syntax_param(&f)` is the parameter position -- the one place on the
// parse path that had no hook at all. It is keyed by nothing, like syntax_lit,
// because the token it must beat is `i64`, a core word no keyed table may own.
//
// M21: two more grammar positions, same shape. `syntax_expr(word, &f)` says the
// word opens an EXPRESSION (`parse_primary` consults it first) and
// `syntax_infix(word, prec, &f)` teaches a binary operator — that one keeps no
// table of its own, it adds a column to the `#infix` table so a taught operator
// and a `#infix` one sit in a single comparable precedence order.
//
// Depends on arena.mc (str_eq, cstrlen, out_str, die, die2, _exit), on lex.mc
// (tok_add and the ids K_U8..K_EXTERN) and on ast.mc (TY_MAX).

// M23: the four registries below are arena blocks that double on demand
// (arena.mc grow()); the MAX* ceilings they used to carry are gone.
uptr pass_fn;
i64  passcap = 0;
i64  npasses = 0;
uptr backend_name;
uptr backend_fn;
i64  backendcap = 0;
i64  nbackends = 0;

uptr pass_fn_at(i64 i)         { return ld64(pass_fn + i * 8); }
uptr backend_name_at(i64 i)    { return ld64(backend_name + i * 8); }
uptr backend_fn_at(i64 i)      { return ld64(backend_fn + i * 8); }

// pass(&f): f runs over the source AST, in the order it was registered
void pass(uptr fn) {
    pass_fn = grow(T_PASSES, pass_fn, npasses, &passcap, 8);
    st64(pass_fn + npasses * 8, fn);
    npasses = npasses + 1;
}

// backend("name", &f): f writes the object when `--backend=name` is requested.
// The last registration of the same name wins, as in the #rule table.
void backend(uptr name, uptr fn) {
    i64 oc = backendcap;
    backend_name = grow(T_BACKENDS, backend_name, nbackends, &backendcap, 8);
    if (backendcap != oc) backend_fn = grow_to(backend_fn, nbackends, backendcap, 8);
    st64(backend_name + nbackends * 8, name);
    st64(backend_fn + nbackends * 8, fn);
    nbackends = nbackends + 1;
}

// index of the backend named `name`, -1 if none; searches back to front
// so that the last registration applies
i64 backend_find(uptr name) {
    i64 i = nbackends - 1;
    loop {
        if (i < 0) break;
        if (str_eq(backend_name_at(i), name)) return i;
        i = i - 1;
    }
    return -1;
}

// error for an unknown `--backend=NAME`: lists the registered names
void backend_die(uptr name) {
    out_str(2, "unknown backend: ");
    out_str(2, name);
    out_str(2, "\nregistered:");
    i64 i = 0;
    loop {
        if (i >= nbackends) break;
        out_str(2, " ");
        out_str(2, backend_name_at(i));
        i = i + 1;
    }
    out_str(2, "\n");
    _exit(1);
}

// ---- M41: the default backend ----
// `mc x.mc -o x.o` with no --backend writes an object for the target this
// binary is RUNNING on, looked up in the target registry (src/cli.mc). A
// recreated compiler may have no target registry at all -- one machine, one
// writer, nothing to look up -- and backend_default("name") is what it says
// instead. The registry still wins when the host is in it, so `mc` itself is
// unchanged; with neither, mc_main says `no backend: use --backend=NAME`.
//
// No "if exactly one backend is registered" magic: the module says which one.
uptr backend_dflt = 0;

void backend_default(uptr name) { backend_dflt = name; }

// the name backend_default() recorded, or 0 when nobody called it
uptr backend_default_name() { return backend_dflt; }

// ---- M21.5: on_stmt, the statement hook ----
// `on_stmt(&f)` registers `i64 f(i64 n)`, called by parse_stmt after EVERY
// statement node is produced -- core or taught -- with the node's index. The
// handler returns the same node, a replacement, or 0 to drop it (parse_stmt
// then puts an empty N_BLOCK in its place, the same convention a syntax_stmt
// handler that returns 0 already had: a statement position always has a node).
//
// Order, and it is fixed: the taught `syntax_stmt` handler for the word runs
// FIRST and builds the node, then every on_stmt hook runs over the result, in
// registration order. So a module can teach `unless` and observe it in the same
// compiler without the two racing.
//
// Why it exists: wrapping, rewriting or merely watching the CORE statements
// (`return`, `break`, `continue`, `i64 x = ...`) is otherwise impossible
// without re-teaching them -- scope tracking, instrumentation, ownership rules
// and coverage all had to walk the tree afterwards instead. A core-declared
// local is observable here as the N_VAR node, which is the intended way (there
// is no separate hook for it).
uptr onstmt_fn;
i64  onstmtcap = 0;
i64  nonstmt = 0;

uptr onstmt_fn_at(i64 i) { return ld64(onstmt_fn + i * 8); }

void on_stmt(uptr fn) {
    onstmt_fn = grow(T_ONSTMT, onstmt_fn, nonstmt, &onstmtcap, 8);
    st64(onstmt_fn + nonstmt * 8, fn);
    nonstmt = nonstmt + 1;
}

// n through every hook, in registration order; 0 short-circuits (a dropped
// statement is not offered to the hooks behind it)
i64 run_on_stmt(i64 n) {
    i64 i = 0;
    loop {
        if (i >= nonstmt) break;
        if (n == 0) break;
        n = callp(onstmt_fn_at(i), n);
        i = i + 1;
    }
    return n;
}

// ---- M31 (2.2): on_jump, the exit edges of a scope ----
// `on_jump(&f)` registers `i64 f(i64 n, i64 kind, i64 depth)`, called by
// parse_stmt_core at the moment it builds an N_RETURN, an N_BREAK or an
// N_CONTINUE -- BEFORE any on_stmt hook and before any other module can wrap
// the node. `kind` is that node kind and `depth` how many blocks are open in
// the current function (docs/reference/hooks.md). The handler returns the same
// node, a replacement, or 0 to drop the jump.
//
// Why on_stmt is not a substitute: the first module to see a `return` normally
// rewrites it -- examples/lang turns it into an N_BLOCK of releases -- so a
// module registered behind it can no longer recognise the jump, let alone place
// code on that edge. A scope guard (`lock (m) { ... }`, `defer`) has to cover
// EVERY exit edge or it is a deadlock waiting to happen, which is why Go, Swift,
// Zig and D all put this at language level.
uptr onjump_fn;
i64  onjumpcap = 0;
i64  nonjump = 0;

uptr onjump_fn_at(i64 i) { return ld64(onjump_fn + i * 8); }

void on_jump(uptr fn) {
    onjump_fn = grow(T_ONJUMP, onjump_fn, nonjump, &onjumpcap, 8);
    st64(onjump_fn + nonjump * 8, fn);
    nonjump = nonjump + 1;
}

// the jump through every hook, in registration order; 0 short-circuits, exactly
// as run_on_stmt's does
i64 run_on_jump(i64 n, i64 kind, i64 depth) {
    i64 i = 0;
    loop {
        if (i >= nonjump) break;
        if (n == 0) break;
        n = callp(onjump_fn_at(i), n, kind, depth);
        i = i + 1;
    }
    return n;
}

// applies the registered passes, in order: root = f(root)
i64 run_passes(i64 root) {
    i64 i = 0;
    loop {
        if (i >= npasses) break;
        root = callp(pass_fn_at(i), root);
        i = i + 1;
    }
    return root;
}

// ---- Tier 3: syntax taught by code ----
// Two linear tables in registration order, one per grammar position. The
// search goes back to front: the last registration of the same word wins,
// as in the backend table and the #rule table.
uptr syn_tok;                         // token id of the word that opens
uptr syn_fn;
i64  syncap = 0;
i64  nsyn = 0;
uptr syns_tok;
uptr syns_fn;
i64  synscap = 0;
i64  nsyns = 0;
uptr syne_tok;                        // M21: the same, at the expression position
uptr syne_fn;
i64  synecap = 0;
i64  nsyne = 0;

i64  syn_tok_at(i64 i)        { return ld64(syn_tok + i * 8); }
uptr syntax_fn_at(i64 i)      { return ld64(syn_fn + i * 8); }
i64  syns_tok_at(i64 i)       { return ld64(syns_tok + i * 8); }
uptr syntax_stmt_fn_at(i64 i) { return ld64(syns_fn + i * 8); }
i64  syne_tok_at(i64 i)       { return ld64(syne_tok + i * 8); }
uptr syntax_expr_fn_at(i64 i) { return ld64(syne_fn + i * 8); }

// new word for the lexer; refuses to hijack a core keyword
// (`if`, `loop`, `i64`, `extern` ...), for the same reason #rule refuses
i64 word_add(uptr word) {
    i64 id = tok_add(word, cstrlen(word));
    if (id >= K_U8 && id <= K_EXTERN)
        die2("cannot redefine core keyword", word);
    return id;
}

// syntax("class", &f): f consumes the tokens starting at `class` (inclusive) in the
// top-level declaration position and produces declarations with top_add()
void syntax(uptr word, uptr fn) {
    i64 oc = syncap;
    syn_tok = grow(T_SYNTAX, syn_tok, nsyn, &syncap, 8);
    if (syncap != oc) syn_fn = grow_to(syn_fn, nsyn, syncap, 8);
    st64(syn_tok + nsyn * 8, word_add(word));
    st64(syn_fn + nsyn * 8, fn);
    nsyn = nsyn + 1;
}

// syntax_stmt("unless", &f): same at the statement position; f returns the index
// of the statement node (0 = none)
void syntax_stmt(uptr word, uptr fn) {
    i64 oc = synscap;
    syns_tok = grow(T_SYNTAX, syns_tok, nsyns, &synscap, 8);
    if (synscap != oc) syns_fn = grow_to(syns_fn, nsyns, synscap, 8);
    st64(syns_tok + nsyns * 8, word_add(word));
    st64(syns_fn + nsyns * 8, fn);
    nsyns = nsyns + 1;
}

i64 syntax_find(i64 tok) {
    i64 i = nsyn - 1;
    loop {
        if (i < 0) break;
        if (syn_tok_at(i) == tok) return i;
        i = i - 1;
    }
    return -1;
}

i64 syntax_stmt_find(i64 tok) {
    i64 i = nsyns - 1;
    loop {
        if (i < 0) break;
        if (syns_tok_at(i) == tok) return i;
        i = i - 1;
    }
    return -1;
}

// M21. syntax_expr("bits", &f): f consumes the tokens starting at `bits`
// (inclusive) in the EXPRESSION position and returns the node's index. This is
// the position `#prefix` cannot reach: its template parses exactly one operand
// with parse_unary into a fixed tree, so it reads neither a type (`bits i64`)
// nor an argument list (`pipe(x, f, g)`).
void syntax_expr(uptr word, uptr fn) {
    i64 oc = synecap;
    syne_tok = grow(T_SYNTAX, syne_tok, nsyne, &synecap, 8);
    if (synecap != oc) syne_fn = grow_to(syne_fn, nsyne, synecap, 8);
    st64(syne_tok + nsyne * 8, word_add(word));
    st64(syne_fn + nsyne * 8, fn);
    nsyne = nsyne + 1;
}

i64 syntax_expr_find(i64 tok) {
    i64 i = nsyne - 1;
    loop {
        if (i < 0) break;
        if (syne_tok_at(i) == tok) return i;
        i = i - 1;
    }
    return -1;
}

// ---- M24 (Tier 4): syntax_lit, the numeric-literal position ----
// syntax_lit(&f) registers `i64 f()`, consulted by parse_primary at the one
// point where it is about to build the N_INT/N_CHAR node. The handler returns
// the node it built -- or 0, meaning "the core handles this one", which is what
// makes a module that only wants `1.5` leave `1` alone.
//
// This is the one grammar position Tier 3 genuinely cannot reach: every other
// hook is keyed by a token word_add() created, and word_add can never yield
// T_INT. It is generic on purpose -- it says "numeric literal", not "float" --
// so the decimal-to-binary conversion lives in the MODULE and lex_number stays
// exactly what the frozen stage0/lex.c does, which is what keeps --dump-tokens
// comparable over the whole tree (scripts/check-lex.sh).
//
// The handler reads the raw source with p_start(), consumes what the lexer did
// not with p_take_lit(), and returns an ordinary node. The documented
// fallback -- `#token "."` plus syntax_infix(".", prec, &f) -- costs zero core
// lines and is rejected as the mechanism because it reserves `.` program-wide
// (colliding head-on with examples/lang, whose lg_dot owns it) and cannot spell
// `1e-3` at all.
//
// Shaped like on_stmt and short-circuited by `nonlit == 0`, so an untaught
// compiler does not even make the callp.
uptr synlit_fn;
i64  synlitcap = 0;
i64  nonlit = 0;

uptr synlit_fn_at(i64 i) { return ld64(synlit_fn + i * 8); }

void syntax_lit(uptr fn) {
    synlit_fn = grow(T_SYNTAX, synlit_fn, nonlit, &synlitcap, 8);
    st64(synlit_fn + nonlit * 8, fn);
    nonlit = nonlit + 1;
}

// the handlers in registration order; the first non-zero node wins, so the last
// module to register is NOT the one that wins -- unlike the keyed tables, a
// literal handler that answers 0 is saying "not mine", not "not registered"
i64 run_syntax_lit() {
    i64 i = 0;
    loop {
        if (i >= nonlit) break;
        i64 n = callp(synlit_fn_at(i));
        if (n) return n;
        i = i + 1;
    }
    return 0;
}

// ---- M41.5: syntax_param, the parameter position ----
// syntax_param(&f) registers `i64 f()`, consulted by parse_params at the HEAD
// of its loop -- right after the `)` test and BEFORE type_of_token. The handler
// returns the index of an N_PARAM it built, or 0 meaning "the core handles this
// one", the same convention syntax_lit has.
//
// The placement is the whole point. A parameter that opens with a word a module
// taught (`params i64 xs`) has to reach the handler before the core demands a
// type, and a parameter that wants a trailer (`i64 y = 10`) has to be read as a
// WHOLE by whoever records the trailer -- p_type(), p_ident(), then the `=` and
// parse_expr(0) the module keeps for itself. Neither is reachable from the
// hooks that existed: `syntax` sees only the declaration's first token, and
// `word_add` refuses the core type words, so no keyed table can ever fire on
// `i64`.
//
// Not keyed by a word, and not an `on_*` hook: the `on_*` family runs AFTER a
// node exists and cannot consume tokens, which is exactly what a parameter with
// a default has to do. Handlers run in registration order and the first
// non-zero answer wins.
//
// Shaped like on_stmt and short-circuited by `nsynp == 0` in parse_params, so
// an untaught compiler does not even make the callp.
uptr synp_fn;
i64  synpcap = 0;
i64  nsynp = 0;

uptr synp_fn_at(i64 i) { return ld64(synp_fn + i * 8); }

void syntax_param(uptr fn) {
    synp_fn = grow(T_SYNPARAM, synp_fn, nsynp, &synpcap, 8);
    st64(synp_fn + nsynp * 8, fn);
    nsynp = nsynp + 1;
}

// the handlers in registration order; the first non-zero node wins. The two
// guards a returned node has to pass -- it advanced, and it is an N_PARAM --
// live in parse.mc, next to the position they defend.
i64 run_syntax_param() {
    i64 i = 0;
    loop {
        if (i >= nsynp) break;
        i64 p = callp(synp_fn_at(i));
        if (p) return p;
        i = i + 1;
    }
    return 0;
}

// M21. syntax_infix(".+", 9, &f): a binary operator taught by code. There is no
// new table: the `#infix` entry gains one column (INF_FN), which is what puts a
// taught operator and a `#infix` one in a SINGLE comparable precedence order.
// `f(lhs)` receives the left side already parsed and returns the resulting node;
// the core consumes the operator before calling, so the handler owns everything
// to the right — a name, a type, an argument list, or an `=` it decides to read
// itself.
//
// Teaching the same token twice is an error, like a repeated `#define` or two
// `#rule`s with the same dispatch literal: the second registration is a mistake,
// not an override. `#infix` on the same token afterwards is not an error — it
// goes through infix_set, which clears the handler (the template wins, and
// docs/surface.md says so).
//
// M41.5: a CORE operator may be taught too. `word_add` refuses `if` and `i64`
// but not `+` -- punctuation is outside K_U8..K_EXTERN -- so the registration
// was already accepted; what it was not was EFFECTIVE, because ops_init() ran
// later, as parse_unit's first statement, and rewrote the entry handler
// included. ops_init() is now idempotent and is called from HERE, so the core
// entry exists before the lookup below: the duplicate test sees it (a core
// operator carries no handler, so the first registration is allowed and only a
// second one is refused), and infix_set re-declares it with the module's
// precedence. The module's `prec` wins, exactly as a `#infix` on the same token
// would: this is a re-declaration of the operator, not a decoration of the
// core's. docs/reference/hooks.md § syntax_infix lists the core precedences a
// module has to repeat if it wants to keep them.
void syntax_infix(uptr word, i64 prec, uptr fn) {
    if (prec < 1 || prec > 100) die2("precedence out of 1..100", word);
    ops_init();                              // M41.5: the core table, before the lookup
    i64 tok = word_add(word);
    i64 i = infix_find(tok);
    if (i >= 0 && ie_fn(ie_at(i))) die2("operator already taught", word);
    infix_set(tok, prec, 0, 0);              // creates or reuses the entry, clearing INF_FN
    set_ie_fn(ie_at(infix_find(tok)), fn);
}

// ---- Tier 3: type aliases ----
// type_alias("bool", TY_U8) makes `bool` valid as a type in declaration, parameter,
// cast and p_type(): all of them go through type_of_token, which consults this table
// after the core words.
uptr alias_tok;
uptr alias_base;
i64 aliascap = 0;
i64 nalias = 0;

i64 alias_tok_at(i64 i)  { return ld64(alias_tok + i * 8); }
i64 alias_base_at(i64 i) { return ld64(alias_base + i * 8); }

// the append side of that table, shared with type_new: reserving the word and
// pointing it at a type id is the same operation in both cases
void alias_add(uptr name, i64 base) {
    i64 oc = aliascap;
    alias_tok = grow(T_ALIAS, alias_tok, nalias, &aliascap, 8);
    if (aliascap != oc) alias_base = grow_to(alias_base, nalias, aliascap, 8);
    st64(alias_tok + nalias * 8, word_add(name));
    st64(alias_base + nalias * 8, base);
    nalias = nalias + 1;
}

// M24: the guard widened from TY_MAX to type_count(), so an alias may name a
// type another module registered -- `type_alias("double", ty_f64)`.
void type_alias(uptr name, i64 base) {
    if (base < 0 || base >= type_count()) die2("type_alias with invalid type", name);
    alias_add(name, base);
}

// ---- M24 (Tier 4): type_new, a PRIMITIVE the core has never heard of ----
// type_new("f64", 8, 8, TK_FLOAT) appends to the registry in src/ast.mc and
// reserves the word in the SAME table type_alias uses, which is what makes the
// name valid in all seven type positions at once -- globals, locals,
// parameters, extern, casts, array elements and p_type() -- for one line in
// type_of_token that was already there. It is an ordinary function called from
// user_init(): no keyword, no directive, so tok_init() is untouched, the ids
// K_U8..K_EXTERN do not shift and check-lex keeps cross-checking the two lexers
// over the whole tree.
//
// What the core then does with the id: type_width and type_align size globals,
// arrays and frame slots; type_name puts it in --dump-ast; type_kind is for the
// machine. Nothing else. Arithmetic, literals, the ABI and the instructions are
// the module's, through syntax_lit, intrinsic and a derived machine table.
//
// The word is reserved PROGRAM-WIDE, exactly as type_alias's is: loading a
// module that teaches `f32` removes `f32` from the source's identifier
// vocabulary. That is why <float> is not in lib/user_default.mc.
i64 type_new(uptr name, i64 width, i64 align, i64 kind) {
    if (width < 1) die2("type_new with a width below 1", name);
    if (align < 1) die2("type_new with an alignment below 1", name);
    if (kind < TK_INT || kind > TK_OPAQUE) die2("type_new with an unknown kind", name);
    i64 t = ty_reg_add(name, width, align, kind);
    alias_add(name, t);                  // word_add refuses a core keyword here
    return t;
}

// ---- M41: the machine-declared width of uptr ----
// The one fixed decision of the core a module may override, and the reason M24
// D8 (which refused type_set_width for having no caller) is reversed: M40's AVR
// module is the caller. It follows into src/gen_walk.mc's slot granule, frame
// alignment and pointer initializer, and into src/parse.mc's array bound --
// M40 § 1b C1/C3/C4/C5, and nothing else.
//
// Every other type refuses, deliberately: `i64` folds in 64 bits at parse time
// (src/parse.mc, fold_binary) and would disagree with the machine, and u8/u16/
// u32/u64 are their own names. A module that wants a different primitive
// registers one with type_new().
//
// Declared from user_init(), before a byte of the source is read, and inert
// when nobody calls it: the width stays 8, the granule 8 and the alignment 16.
void type_set_width(i64 ty, i64 w) {
    if (ty != TY_UPTR) die("type_set_width only declares the width of uptr");
    if (w != 1 && w != 2 && w != 4 && w != 8) die("uptr width must be 1, 2, 4 or 8");
    ty_set_uptr_width(w);
}

// ---- M41: removing a core primitive ----
// Two removals, both consulted before the core's own answer, both meant for a
// RECREATED compiler that does not want a word its target cannot honour.
//
// type_disable(TY_U32) removes the WORD `u32` from the surface: every position
// that goes through type_of_token refuses it with `u32: removed by this
// compiler`, at the token. It does NOT remove the type from the model -- ld8()
// still yields TY_U8, type_width(TY_U32) is still 4 and a machine still sees
// the id -- so read it as "this dialect has no such declaration" and never as
// "the type is gone".
//
// Disabling i64, uptr or void is permitted and makes the language unusable: a
// literal is TY_I64, `&f` and every pointer are TY_UPTR, and a function with no
// result is TY_VOID. There is no special case; a compiler that does it finds
// out on its first declaration.
void type_disable(i64 ty) {
    if (ty < 0 || ty >= type_count()) die("type_disable with an unknown type");
    ty_disable_set(ty);
}

// intrinsic_disable("ld64") removes the NAME: a call is refused with
// `ld64: removed by this compiler`, at the call site. It covers the core
// intrinsics (src/gen_resolve.mc's IN_*) and the ones intrinsic() registered,
// by name, so the rule is the same for both. The named caller is M40 § 2B: on a
// two-byte word `ld64`/`st64` are silently wrong, and a portable source uses
// the module's own `ldw`/`stw` instead -- which only works if the wide pair can
// be made unreachable.
//
// Fixed ceiling, like the subcommand table: what a compiler removes is a
// property of the compiler.
#define MAXNOINTRIN 32

uptr nointrin[MAXNOINTRIN];
i64  nnointrin = 0;

void intrinsic_disable(uptr name) {
    if (nnointrin >= MAXNOINTRIN) die2("too many intrinsic_disable", name);
    st64(nointrin + nnointrin * 8, name);
    nnointrin = nnointrin + 1;
}

// 1 when `name` was passed to intrinsic_disable; src/gen_resolve.mc asks before
// it dispatches a call to anything at all
i64 intrin_disabled(uptr name) {
    i64 i = 0;
    loop {
        if (i >= nnointrin) break;
        if (str_eq(ld64(nointrin + i * 8), name)) return 1;
        i = i + 1;
    }
    return 0;
}

// type of alias `id`, or -1 if the token is not an alias; the last registration wins
i64 alias_find(i64 id) {
    i64 i = nalias - 1;
    loop {
        if (i < 0) break;
        if (alias_tok_at(i) == id) return alias_base_at(i);
        i = i - 1;
    }
    return -1;
}

// 1 if `id` is a word taught by a Tier 3 registration. The word applies in the
// WHOLE program, not just the handler's grammar position: whoever registers
// `log` removes `log` from the source's identifier vocabulary. The parser uses
// this only to say so plainly when a name does not come (docs/surface.md
// § Tier 3, "registration reserves the word for the whole program").
// infix_is_taught only answers for an operator that carries a HANDLER: `+` is in
// the same table and is never blamed.
i64 word_is_taught(i64 id) {
    if (syntax_find(id) >= 0) return 1;
    if (syntax_stmt_find(id) >= 0) return 1;
    if (syntax_expr_find(id) >= 0) return 1;
    if (infix_is_taught(id)) return 1;
    if (alias_find(id) >= 0) return 1;
    return 0;
}

// M24 (M7)'s intrinsic registry lives in src/gen_resolve.mc, beside intrin_id
// and the IN_* list it has to refuse to shadow: the call dispatch is the
// resolver's, not the registry's -- the same reason machine_slot lives in
// src/gen_walk.mc, beside the MTASK_* list it bounds-checks.

// ---- M17: the machine table ----
// The code generator is two halves since M17: src/gen_walk.mc walks the AST and
// src/machine_arm64.mc selects instructions. The seam between them is a table of
// `&fn`, one per task (docs/reference/machine.md), registered here. Same shape
// as `backend()` -- a linear table in registration order, the last registration
// of a name wins -- with one difference: registering a machine also MAKES IT THE
// ONE IN EFFECT, because a machine is not chosen by a command-line flag but by
// the target, and the compiler always has exactly one.
//
// The ceiling is fixed on purpose. A machine does not scale with the program
// being compiled (M23's rule for the tables that do): the compiler is built with
// the machines it has, and a taught compiler adds one or two.
#define MAXMACHINES 8

uptr mach_names[MAXMACHINES];
uptr mach_tabs[MAXMACHINES];
i64  nmachines = 0;
uptr mach_tab = 0;                    // the table gen_walk.mc drives
// M24 (M9): a SNAPSHOT of the machines that were registered before user_init()
// ran -- their names and their tables. It is what lets --dump-machine say
// `bundled arm64` or `taught` for each slot with no runtime symbol table: a slot
// is bundled when its pointer is the pointer a bundled table has for that task.
//
// A snapshot and not just a count, because a module that re-registers `arm64`
// REUSES that name's registry slot (D5), so the registry no longer remembers
// what was there. main() takes it; a compiler that never does reports every slot
// as taught, which is the honest answer for a registry it cannot vouch for.
uptr mach_bnames[MAXMACHINES];
uptr mach_btabs[MAXMACHINES];
i64  mach_builtin = 0;

uptr mach_bnames_at(i64 i) { return ld64(mach_bnames + i * 8); }
uptr mach_btabs_at(i64 i)  { return ld64(mach_btabs + i * 8); }

void machine_freeze() {
    mach_builtin = nmachines;
    i64 i = 0;
    loop {
        if (i >= nmachines) break;
        st64(mach_bnames + i * 8, mach_names_at(i));
        st64(mach_btabs + i * 8, mach_tabs_at(i));
        i = i + 1;
    }
}

uptr mach_names_at(i64 i) { return ld64(mach_names + i * 8); }
uptr mach_tabs_at(i64 i)  { return ld64(mach_tabs + i * 8); }

// machine("arm64", tab): tab is MTASK_COUNT entries of `&fn`, in MTASK_* order.
// M24 (D5): a registration that SHADOWS an existing name reuses that name's
// slot instead of appending. `machine_find` already searched back to front, so
// nothing observable changes -- what changes is that a module stacking a second
// taught machine on `arm64` no longer walks the table towards `too many
// machines`, which is the failure a user would have discovered by stacking two
// modules that each teach a type family.
void machine(uptr name, uptr tab) {
    i64 i = machine_find(name);
    if (i < 0) {
        if (nmachines >= MAXMACHINES) die2("too many machines", name);
        i = nmachines;
        nmachines = nmachines + 1;
        st64(mach_names + i * 8, name);
    }
    st64(mach_tabs + i * 8, tab);
    mach_tab = tab;
}

i64 machine_find(uptr name) {
    i64 i = nmachines - 1;
    loop {
        if (i < 0) break;
        if (str_eq(mach_names_at(i), name)) return i;
        i = i - 1;
    }
    return -1;
}

// picks the machine a target asked for; the walker reads mach_tab and nothing else
void machine_use(uptr name) {
    i64 i = machine_find(name);
    if (i < 0) die2("unknown machine", name);
    mach_tab = mach_tabs_at(i);
}

// M41: like machine_use, but a name that is not registered is not an error --
// 1 when it was found and is now current, 0 when there is nothing by that name.
// src/cli.mc uses it for the HOST's machine, which a compiler built for a
// foreign target does not have and must not die at startup for.
i64 machine_use_if(uptr name) {
    i64 i = machine_find(name);
    if (i < 0) return 0;
    mach_tab = mach_tabs_at(i);
    return 1;
}

// ---- M24: deriving a machine ----
// The published recipe used to be "copy the table, overwrite the slot with
// machine_task, register the copy" -- but `machine_task` writes the GLOBAL
// m_arm64 by name (src/machine_arm64.mc), so following it corrupted arm64's own
// table for the rest of the compilation. These two are the recipe, and the doc
// was corrected with them (docs/reference/hooks.md).
//
// machine_tab(name) is the registered table, to copy FROM; machine_slot writes
// one slot of a table the caller owns. Nothing new is possible -- the Win64
// machine already derives with ld64/st64 (src/machine_x86_64.mc) -- this is
// contract and safety.
//
// Delegation needs no further names: the module copies the table first, so the
// bundled implementation of every slot is a pointer it holds and can `callp`.
// That is what keeps a taught machine from having to reimplement integer
// codegen, and what keeps a64_bin/a64_const from becoming frozen surface.
uptr machine_tab(uptr name) {
    i64 i = machine_find(name);
    if (i < 0) die2("unknown machine", name);
    return mach_tabs_at(i);
}

// machine_slot lives in src/gen_walk.mc, beside mach() and the MTASK_* list it
// has to bound-check: the task vocabulary is the walker's, not the registry's.

// ---- M17/M33: the target registry ----
// `src/driver.mc` used to carry the whitelist itself -- an `i64 drv_linux` flag,
// `if (drv_linux) return "elf-obj"; return "macho";` and two hardcoded
// `toml_err_key` messages. A third operating system or a second architecture
// could not be reached from `mc.toml` without editing the driver, which is
// exactly what the non-negotiable of docs/specs/M33.md forbids.
//
// target(os, arch, obj, exe): compiling for that pair writes objects with the
// `obj` backend and direct executables with the `exe` one; `exe = 0` says the
// target has no direct executable and always goes through `[linker]`. Same
// linear table, same "last registration wins" as the rest of this file. The
// ceiling is fixed for the same reason the machines' is.
#define MAXTARGETS 16

uptr tgt_os[MAXTARGETS];
uptr tgt_arch[MAXTARGETS];
uptr tgt_obj[MAXTARGETS];
uptr tgt_exe[MAXTARGETS];
i64  ntargets = 0;

uptr tgt_os_at(i64 i)   { return ld64(tgt_os + i * 8); }
uptr tgt_arch_at(i64 i) { return ld64(tgt_arch + i * 8); }
uptr tgt_obj_at(i64 i)  { return ld64(tgt_obj + i * 8); }
uptr tgt_exe_at(i64 i)  { return ld64(tgt_exe + i * 8); }

void target(uptr os, uptr arch, uptr obj, uptr exe) {
    if (ntargets >= MAXTARGETS) die2("too many targets", os);
    st64(tgt_os + ntargets * 8, os);
    st64(tgt_arch + ntargets * 8, arch);
    st64(tgt_obj + ntargets * 8, obj);
    st64(tgt_exe + ntargets * 8, exe);
    ntargets = ntargets + 1;
}

// index of the (os, arch) pair, -1 if none; searches back to front so that the
// last registration applies
i64 target_find(uptr os, uptr arch) {
    i64 i = ntargets - 1;
    loop {
        if (i < 0) break;
        if (str_eq(tgt_os_at(i), os) && str_eq(tgt_arch_at(i), arch)) return i;
        i = i - 1;
    }
    return -1;
}

i64 target_os_known(uptr os) {
    i64 i = 0;
    loop {
        if (i >= ntargets) break;
        if (str_eq(tgt_os_at(i), os)) return 1;
        i = i + 1;
    }
    return 0;
}

// the diagnostic for an unrecognised [target] value, built FROM the registry so
// that a target a module registers appears in it. With macos, linux and windows
// registered this is exactly `only macos, linux and windows (see
// docs/build.md)` -- a comma between every pair but the last, which is why the
// walk below has to know the total before it writes the first word.
//
// `os == 0` walks the distinct operating systems, otherwise the distinct
// architectures registered for that one; `b == 0` counts them without writing.
i64 tgt_walk(uptr b, uptr os, i64 total) {
    i64 n = 0;
    i64 i = 0;
    loop {
        if (i >= ntargets) break;
        uptr w = tgt_os_at(i);
        i64 seen = 0;
        if (os) {
            w = tgt_arch_at(i);
            seen = !str_eq(tgt_os_at(i), os);
        }
        i64 j = 0;
        loop {                                   // first occurrence only
            if (j >= i) break;
            if (os) {
                if (str_eq(tgt_os_at(j), os) && str_eq(tgt_arch_at(j), w)) seen = 1;
            } else {
                if (str_eq(tgt_os_at(j), w)) seen = 1;
            }
            j = j + 1;
        }
        if (!seen) {
            if (b) {
                if (n) {
                    if (n == total - 1) buf_put(b, " and ", 5);
                    else                buf_put(b, ", ", 2);
                }
                buf_put(b, w, cstrlen(w));
            }
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}

uptr tgt_list(uptr os) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, "only ", 5);
    tgt_walk(b, os, tgt_walk(0, os, 0));
    buf_put(b, " (see docs/build.md)", 20);
    buf_u8(b, 0);
    return buf_p(b);
}

uptr target_os_list() { return tgt_list(0); }

// the same, restricted to the architectures one os was registered with
uptr target_arch_list(uptr os) { return tgt_list(os); }

// ---- M41: subcommands ----
// `mc build`, `mc limits` and `mc sysroot` are not flags: each is the first
// argument, and each belongs to a PART (<mc/core_build>). The eighth registry
// of the same shape -- linear table, registration order, the last registration
// of a name wins -- is what lets src/cli.mc dispatch them without naming the
// driver, and what makes `mc` with no argument print one usage entry per
// subcommand that exists in THIS binary.
//
// `use` is the exact text usage() prints for the subcommand, newline included;
// a subcommand whose usage takes more than one line carries them all in that
// one string. Nothing here reformats it -- which is what keeps the text byte
// for byte what src/driver.mc's drv_usage() printed before M41.
//
// The ceiling is fixed on purpose, like machine() and target(): the number of
// subcommands is a property of the compiler, not of the program it compiles,
// so M23's growable-table rule does not apply (docs/determinism.md § capacity).
#define MAXSUBCMD 16

uptr sub_names[MAXSUBCMD];
uptr sub_fns[MAXSUBCMD];
uptr sub_uses[MAXSUBCMD];
i64  nsubcmd = 0;

uptr sub_name_at(i64 i) { return ld64(sub_names + i * 8); }
uptr sub_fn_at(i64 i)   { return ld64(sub_fns + i * 8); }
uptr sub_use_at(i64 i)  { return ld64(sub_uses + i * 8); }

// subcommand("build", &drv_build, "usage: mc build ...\n"): f is
// `i64 f(i64 argc, uptr argv)` and its result is mc_main's result.
void subcommand(uptr name, uptr fn, uptr use) {
    if (nsubcmd >= MAXSUBCMD) die2("too many subcommands", name);
    st64(sub_names + nsubcmd * 8, name);
    st64(sub_fns + nsubcmd * 8, fn);
    st64(sub_uses + nsubcmd * 8, use);
    nsubcmd = nsubcmd + 1;
}

// index of the subcommand named `name`, -1 if none; back to front, so that the
// last registration of a name applies
i64 subcommand_find(uptr name) {
    i64 i = nsubcmd - 1;
    loop {
        if (i < 0) break;
        if (str_eq(sub_name_at(i), name)) return i;
        i = i - 1;
    }
    return -1;
}

// the usage text of every registered subcommand, in registration order
void subcommand_usage() {
    i64 i = 0;
    loop {
        if (i >= nsubcmd) break;
        out_str(2, sub_use_at(i));
        i = i + 1;
    }
}

// ---- M41: on_plan, the pre-scan hook ----
// M23's lim_plan sizes every table before the first one exists, and it lives in
// <mc/core_build>: a compiler assembled without that part has no planner at
// all, and its tables simply grow from the seeds in src/arena.mc -- which is
// what src/astdump.mc has always done. on_plan(&f) registers
// `void f(uptr src, uptr label)`, called by src/cli.mc exactly where the
// lim_plan call used to be, and by nothing else.
//
// Fixed ceiling, for the same reason as the subcommand table: the number of
// planners is a property of the compiler.
#define MAXONPLAN 8

uptr onplan_fns[MAXONPLAN];
i64  nonplan = 0;

uptr onplan_fn_at(i64 i) { return ld64(onplan_fns + i * 8); }

void on_plan(uptr fn) {
    if (nonplan >= MAXONPLAN) die("too many on_plan hooks");
    st64(onplan_fns + nonplan * 8, fn);
    nonplan = nonplan + 1;
}

// every planner, in registration order; nothing when none is registered
void run_on_plan(uptr src, uptr label) {
    i64 i = 0;
    loop {
        if (i >= nonplan) break;
        callp(onplan_fn_at(i), src, label);
        i = i + 1;
    }
}
