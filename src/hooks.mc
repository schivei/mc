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
void syntax_infix(uptr word, i64 prec, uptr fn) {
    if (prec < 1 || prec > 100) die2("precedence out of 1..100", word);
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

void type_alias(uptr name, i64 base) {
    if (base < 0 || base >= TY_MAX) die2("type_alias with invalid type", name);
    i64 oc = aliascap;
    alias_tok = grow(T_ALIAS, alias_tok, nalias, &aliascap, 8);
    if (aliascap != oc) alias_base = grow_to(alias_base, nalias, aliascap, 8);
    st64(alias_tok + nalias * 8, word_add(name));
    st64(alias_base + nalias * 8, base);
    nalias = nalias + 1;
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

uptr mach_names_at(i64 i) { return ld64(mach_names + i * 8); }
uptr mach_tabs_at(i64 i)  { return ld64(mach_tabs + i * 8); }

// machine("arm64", tab): tab is MT_COUNT entries of `&fn`, in MT_* order
void machine(uptr name, uptr tab) {
    if (nmachines >= MAXMACHINES) die2("too many machines", name);
    st64(mach_names + nmachines * 8, name);
    st64(mach_tabs + nmachines * 8, tab);
    nmachines = nmachines + 1;
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
// that a target a module registers appears in it. With macos and linux
// registered this is exactly `only macos and linux (see docs/build.md)`, the
// message the driver printed when the list was written out by hand.
void tgt_word(uptr b, uptr w, i64 n) {
    if (n) buf_put(b, " and ", 5);
    buf_put(b, w, cstrlen(w));
}

uptr target_os_list() {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, "only ", 5);
    i64 n = 0;
    i64 i = 0;
    loop {
        if (i >= ntargets) break;
        i64 seen = 0;
        i64 j = 0;
        loop {                                   // first occurrence only
            if (j >= i) break;
            if (str_eq(tgt_os_at(j), tgt_os_at(i))) seen = 1;
            j = j + 1;
        }
        if (!seen) { tgt_word(b, tgt_os_at(i), n); n = n + 1; }
        i = i + 1;
    }
    buf_put(b, " (see docs/build.md)", 20);
    buf_u8(b, 0);
    return buf_p(b);
}

// the same, restricted to the architectures one os was registered with
uptr target_arch_list(uptr os) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_put(b, "only ", 5);
    i64 n = 0;
    i64 i = 0;
    loop {
        if (i >= ntargets) break;
        i64 seen = !str_eq(tgt_os_at(i), os);
        i64 j = 0;
        loop {
            if (j >= i) break;
            if (str_eq(tgt_os_at(j), os) && str_eq(tgt_arch_at(j), tgt_arch_at(i))) seen = 1;
            j = j + 1;
        }
        if (!seen) { tgt_word(b, tgt_arch_at(i), n); n = n + 1; }
        i = i + 1;
    }
    buf_put(b, " (see docs/build.md)", 20);
    buf_u8(b, 0);
    return buf_p(b);
}
