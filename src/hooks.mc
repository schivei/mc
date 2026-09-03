// hooks.mc — Tier 2: registro de passes de AST e de backends.
//
// Um pass e uma funcao `i64 f(i64 root)` que devolve a raiz (a mesma ou outra);
// um backend e uma funcao `void f(i64 root, uptr out)` que escreve o objeto.
// As duas entram aqui como `uptr` — o endereco que `&nome` produz — e sao
// chamadas com `callp`. Duas tabelas lineares, percorridas na ordem de registro:
// determinismo pela regra 1 de docs/determinism.md (nada de hash, nada de ordem
// de ponteiro). Ensinar o compilador e editar `src/user.mc` e rodar `make mc1`.
//
// Depende de arena.mc (str_eq, out_str, die, _exit).

#define MAXPASSES   32
#define MAXBACKENDS 16

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
