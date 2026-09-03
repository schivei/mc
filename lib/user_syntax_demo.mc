// user_syntax_demo.mc — a demonstracao do Tier 3 (M12): sintaxe ensinada por
// codigo. Tres coisas que o nucleo nao tem e que `#rule` nao alcanca, escritas
// de fora, sem tocar em `src/`:
//
//   unless (cond) { ... }        statement novo   (syntax_stmt)
//   enum Nome { A, B, C }        declaracao nova  (syntax)
//   bool                         tipo novo        (type_alias)
//
// `unless` caberia num `#rule stmt:`; esta aqui de proposito, para mostrar o
// mesmo resultado pelos dois caminhos. `enum` nao cabe: e posicao de topo, a
// lista tem tamanho variavel e o efeito e registrar constantes, nao produzir um
// no. `bool` tambem nao: `#rule` nao tem buraco `type $t`.
//
// Este modulo nao entra em src/: quem o liga e lib/mc_syntax_demo.mc, um
// compilador proprio que inclui `src/core.mc` e define o `user_init` abaixo.
// Ver docs/surface.md § Tier 3 e scripts/check-surface.sh.

// unless (cond) block  ->  if (!cond) block
// O handler recebe o parse parado na palavra `unless` e devolve o indice do no
// do statement; consumir a palavra e com ele.
i64 sd_unless() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // a palavra `unless`
    p_expect(K_LPAR, "esperado ( apos unless");
    i64 c = parse_expr(0);
    p_expect(K_RPAR, "esperado ) apos a condicao do unless");
    i64 b = parse_block();
    i64 neg = node_new(N_UNARY, line, fl);       // !cond
    set_nd_op(neg, K_BANG);
    set_nd_a(neg, c);
    i64 n = node_new(N_IF, line, fl);
    set_nd_a(n, neg);
    set_nd_b(n, b);
    return n;
}

// enum Nome { A, B, C }  ->  #define A 0, #define B 1, #define C 2
// e `Nome` vira alias de i64, para que `Nome c = B;` seja uma declaracao valida.
// Nao produz declaracao nenhuma: o handler nao chama top_add e parse_top devolve
// 0. O efeito todo esta na tabela de #define e na de aliases.
void sd_enum() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // a palavra `enum`
    uptr nome = p_ident();
    p_expect(K_LBRACE, "esperado { no enum");
    i64 v = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        def_add(p_ident(), v, line, fl);         // recusa nome ja definido
        v = v + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RBRACE, "esperado } no enum");
    if (v == 0) err_at(fl, line, "enum sem membros");
    type_alias(nome, TY_I64);
}

void user_init() {
    syntax("enum", &sd_enum);                    // posicao de topo
    syntax_stmt("unless", &sd_unless);           // posicao de statement
    type_alias("bool", TY_U8);                   // tipo novo, sem sintaxe nova
}
