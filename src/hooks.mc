// hooks.mc — Tier 2 e Tier 3: registro de passes de AST, de backends, de
// sintaxe (syntax/syntax_stmt) e de aliases de tipo (type_alias).
//
// Um pass e uma funcao `i64 f(i64 root)` que devolve a raiz (a mesma ou outra);
// um backend e uma funcao `void f(i64 root, uptr out)` que escreve o objeto.
// As duas entram aqui como `uptr` — o endereco que `&nome` produz — e sao
// chamadas com `callp`. Duas tabelas lineares, percorridas na ordem de registro:
// determinismo pela regra 1 de docs/determinism.md (nada de hash, nada de ordem
// de ponteiro). Ensinar o compilador e editar `src/user.mc` e rodar `make mc1`.
//
// M12 (Tier 3): as mesmas duas ideias — tabela linear + `uptr` de funcao —
// valem para a sintaxe. `syntax(palavra, &f)` diz que aquela palavra abre uma
// declaracao de topo e `syntax_stmt(palavra, &f)` que ela abre um statement; o
// parser consulta as duas tabelas e chama o handler com `callp`. `type_alias`
// e a terceira: um nome novo que `type_of_token` resolve para um tipo do
// nucleo. As tres registram a palavra no lexer (`tok_add`), como `#rule` faz
// com o literal de despacho, e as tres recusam palavra-chave do nucleo.
//
// Depende de arena.mc (str_eq, cstrlen, out_str, die, die2, _exit), de lex.mc
// (tok_add e os ids K_U8..K_EXTERN) e de ast.mc (TY_MAX).

#define MAXPASSES   32
#define MAXBACKENDS 16
#define MAXSYNTAX   32
#define MAXALIAS    64

uptr pass_fn[MAXPASSES];
i64  npasses = 0;
uptr backend_name[MAXBACKENDS];
uptr backend_fn[MAXBACKENDS];
i64  nbackends = 0;

uptr pass_fn_at(i64 i)         { return ld64(pass_fn + i * 8); }
uptr backend_name_at(i64 i)    { return ld64(backend_name + i * 8); }
uptr backend_fn_at(i64 i)      { return ld64(backend_fn + i * 8); }

// pass(&f): f roda sobre a AST do fonte, na ordem em que foi registrado
void pass(uptr fn) {
    if (npasses == MAXPASSES) die("passes demais");
    st64(pass_fn + npasses * 8, fn);
    npasses = npasses + 1;
}

// backend("nome", &f): f escreve o objeto quando `--backend=nome` for pedido.
// O ultimo registro do mesmo nome vence, como na tabela de #rule.
void backend(uptr name, uptr fn) {
    if (nbackends == MAXBACKENDS) die("backends demais");
    st64(backend_name + nbackends * 8, name);
    st64(backend_fn + nbackends * 8, fn);
    nbackends = nbackends + 1;
}

// indice do backend de nome `name`, -1 se nao ha; busca de tras para a frente
// para que o ultimo registro valha
i64 backend_find(uptr name) {
    i64 i = nbackends - 1;
    loop {
        if (i < 0) break;
        if (str_eq(backend_name_at(i), name)) return i;
        i = i - 1;
    }
    return -1;
}

// erro de `--backend=NOME` desconhecido: lista os nomes registrados
void backend_die(uptr name) {
    out_str(2, "backend desconhecido: ");
    out_str(2, name);
    out_str(2, "\nregistrados:");
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

// aplica os passes registrados, em ordem: root = f(root)
i64 run_passes(i64 root) {
    i64 i = 0;
    loop {
        if (i >= npasses) break;
        root = callp(pass_fn_at(i), root);
        i = i + 1;
    }
    return root;
}

// ---- Tier 3: sintaxe ensinada por codigo ----
// Duas tabelas lineares na ordem de registro, uma por posicao gramatical. A
// busca vai de tras para a frente: o ultimo registro da mesma palavra vence,
// como na tabela de backends e na de #rule.
i64  syn_tok[MAXSYNTAX];              // id do token da palavra que abre
uptr syn_fn[MAXSYNTAX];
i64  nsyn = 0;
i64  syns_tok[MAXSYNTAX];
uptr syns_fn[MAXSYNTAX];
i64  nsyns = 0;

i64  syn_tok_at(i64 i)        { return ld64(syn_tok + i * 8); }
uptr syntax_fn_at(i64 i)      { return ld64(syn_fn + i * 8); }
i64  syns_tok_at(i64 i)       { return ld64(syns_tok + i * 8); }
uptr syntax_stmt_fn_at(i64 i) { return ld64(syns_fn + i * 8); }

// palavra nova para o lexer; recusa sequestrar uma palavra-chave do nucleo
// (`if`, `loop`, `i64`, `extern` ...), pelo mesmo motivo que #rule recusa
i64 word_add(uptr word) {
    i64 id = tok_add(word, cstrlen(word));
    if (id >= K_U8 && id <= K_EXTERN)
        die2("nao pode redefinir palavra-chave do nucleo", word);
    return id;
}

// syntax("class", &f): f consome os tokens a partir de `class` (inclusive) na
// posicao de declaracao de topo e produz declaracoes com top_add()
void syntax(uptr word, uptr fn) {
    if (nsyn == MAXSYNTAX) die("sintaxes de topo demais");
    st64(syn_tok + nsyn * 8, word_add(word));
    st64(syn_fn + nsyn * 8, fn);
    nsyn = nsyn + 1;
}

// syntax_stmt("unless", &f): idem na posicao de statement; f devolve o indice
// do no do statement (0 = nenhum)
void syntax_stmt(uptr word, uptr fn) {
    if (nsyns == MAXSYNTAX) die("sintaxes de statement demais");
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

// ---- Tier 3: aliases de tipo ----
// type_alias("bool", TY_U8) faz `bool` valer como tipo em declaracao, parametro,
// cast e p_type(): todos passam por type_of_token, que consulta esta tabela
// depois das palavras do nucleo.
i64 alias_tok[MAXALIAS];
i64 alias_base[MAXALIAS];
i64 nalias = 0;

i64 alias_tok_at(i64 i)  { return ld64(alias_tok + i * 8); }
i64 alias_base_at(i64 i) { return ld64(alias_base + i * 8); }

void type_alias(uptr name, i64 base) {
    if (nalias == MAXALIAS) die("aliases de tipo demais");
    if (base < 0 || base >= TY_MAX) die2("type_alias com tipo invalido", name);
    st64(alias_tok + nalias * 8, word_add(name));
    st64(alias_base + nalias * 8, base);
    nalias = nalias + 1;
}

// tipo do alias `id`, ou -1 se o token nao e um alias; o ultimo registro vence
i64 alias_find(i64 id) {
    i64 i = nalias - 1;
    loop {
        if (i < 0) break;
        if (alias_tok_at(i) == id) return alias_base_at(i);
        i = i - 1;
    }
    return -1;
}

// 1 se `id` e uma palavra ensinada por syntax/syntax_stmt/type_alias. A palavra
// vale no programa INTEIRO, nao so na posicao gramatical do handler: quem
// registra `log` tira `log` do vocabulario de identificadores do fonte. O
// parser usa isto so para dizer isso na cara quando um nome nao vem
// (docs/surface.md § Tier 3, "o registro reserva a palavra no programa todo").
i64 word_is_taught(i64 id) {
    if (syntax_find(id) >= 0) return 1;
    if (syntax_stmt_find(id) >= 0) return 1;
    if (alias_find(id) >= 0) return 1;
    return 0;
}
