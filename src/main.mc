// main.mc — transliteracao de stage0/main.c: driver do compilador.
// uso: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules]
//         [--backend=NOME|--exe] entrada.mc [-o saida]
// Os modos --dump-* escrevem em stdout e nao geram o objeto.
//
// argv chega como uptr: argv[i] e ld64(argv + i * 8) (nao ha ponteiro tipado).
// Depende de arena.mc (str_eq, out_str, die, die2), de lex.mc (tok_init,
// lex_init, dump_tokens), de parse.mc (parse_unit, fold), de ast.mc (dump_ast),
// de gen_arm64.mc (gen_lower, gen_encode_all, gen_dump_asm), de macho.mc
// (dump_syms, macho_write), de backend_exe.mc (backend_exe), de hooks.mc
// (pass/backend/run_passes/backend_find) e de user.mc (user_init).
//
// M10: o driver chama user_init() antes de qualquer parse (e ali que os modulos
// do usuario registram passes e backends), aplica os passes sobre a AST e
// escolhe o backend por --backend=NOME. O backend `macho` embutido e
// gen_lower + gen_encode_all + macho_write e e o default.
//
// M11: `macho-exe` (gen_lower + gen_encode_all + exe_write) tambem e embutido e
// escreve um MH_EXECUTE assinado, sem `ld`. `--exe` e apelido de
// `--backend=macho-exe`. Este backend so existe no compilador em .mc: o stage0
// em C e semente e continua so com `macho` (docs/surface.md § Tier 2).

#define M_COMPILE 0
#define M_TOKENS  1
#define M_AST     2
#define M_ASM     3
#define M_SYMS    4
#define M_RULES   5

// backend embutido: as duas metades do gen mais a escrita do MH_OBJECT
void backend_macho(i64 unit, uptr out) {
    gen_lower(unit);
    gen_encode_all();
    macho_write(out);
}

// texto depois do prefixo `pre` em `a`, ou 0 se `a` nao comeca por `pre`
uptr opt_val(uptr a, uptr pre) {
    i64 i = 0;
    loop {
        if (ld8(pre + i) == 0) break;
        if (ld8(a + i) != ld8(pre + i)) return 0;
        i = i + 1;
    }
    return a + i;
}

void usage() {
    out_str(2, "uso: mc [--dump-tokens|--dump-ast|--dump-asm|--dump-syms|--dump-rules] [--backend=NOME|--exe] entrada.mc [-o saida]\n");
}

i64 main(i64 argc, uptr argv) {
    uptr in = 0;
    uptr out = "out.o";
    uptr bname = "macho";
    i64 mode = M_COMPILE;

    backend("macho", &backend_macho);           // os embutidos, sempre registrados
    backend("macho-exe", &backend_exe);

    i64 i = 1;
    loop {
        if (i >= argc) break;
        uptr a = ld64(argv + i * 8);
        if (str_eq(a, "--dump-tokens"))     mode = M_TOKENS;
        else if (str_eq(a, "--dump-ast"))   mode = M_AST;
        else if (str_eq(a, "--dump-asm"))   mode = M_ASM;
        else if (str_eq(a, "--dump-syms"))  mode = M_SYMS;
        else if (str_eq(a, "--dump-rules")) mode = M_RULES;
        else if (str_eq(a, "--exe"))        bname = "macho-exe";
        else if (str_eq(a, "-o")) {
            if (i + 1 >= argc) die("-o exige um argumento");
            i = i + 1;
            out = ld64(argv + i * 8);
        } else if (ld8(a) == '-') {
            uptr bn = opt_val(a, "--backend=");
            if (bn == 0) die2("opcao desconhecida", a);
            bname = bn;
        }
        else if (in == 0)          in = a;
        else                       die2("entrada duplicada", a);
        i = i + 1;
    }
    if (in == 0) { usage(); return 1; }

    tok_init();
    lex_init(in);                                      // o lexer abre e empilha o arquivo
    // Tier 2 depois de tok_init(): os ids K_U8..K_EXTERN sao 256..269 fixos, entao
    // um user_init que chame tok_add antes deslocaria a tabela e quebraria o
    // nucleo inteiro. Antes de qualquer token ser lido, porque o lexer e
    // incremental: `#token`/`#rule` do usuario ainda valem para o fonte todo.
    user_init();
    if (mode == M_TOKENS) { dump_tokens(); return 0; }

    i64 unit = parse_unit();
    if (mode == M_RULES) { dump_rules(); return 0; }   // regras que o fonte registrou
    unit = run_passes(unit);                           // Tier 2: passes do usuario
    if (mode == M_AST) { dump_ast(unit); return 0; }   // arvore ja com #rule e passes

    unit = fold(unit);                                 // dobra antes do codegen
    if (mode == M_ASM) { gen_lower(unit); gen_dump_asm(); return 0; }
    if (mode == M_SYMS) { gen_lower(unit); gen_encode_all(); dump_syms(); return 0; }

    i64 bi = backend_find(bname);
    if (bi < 0) backend_die(bname);
    callp(backend_fn_at(bi), unit, out);
    return 0;
}
