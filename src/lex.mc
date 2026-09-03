// lex.mc — transliteracao de stage0/lex.c: tabela de tokens mutavel e lexer
// incremental. O lexer entrega um token por chamada (lex_next); o parser guarda
// um lookahead de 1, de modo que um #token registrado agora ja vale para o
// proximo lexema. --dump-tokens roda o lexer puro, sem parser, e portanto nao
// processa #token nem #include — cada diretiva vira apenas um token T_DIR.
//
// Mesmas funcoes, mesma ordem, mesma tabela na mesma ordem de insercao e ids.
// Sem struct: Token, TokEnt e OpenFile sao registros planos (TOK_*, TE_*, OF_*).
// Layouts (campos de 8 bytes, na ordem dos structs de stage0/mc.h):
//   TokEnt   { text, len, word, id }                       — 32 B
//   Token    { id, start, len, val, line, file }            — 48 B
//   OpenFile { cp, cend, line, name }                       — 32 B
// Depende de arena.mc (xalloc, cstrlen, str_eq, mem_eq, buf_*, out_*, die,
// die2, err_at, read_file).
// err_at(arquivo, linha, msg) e o mesmo de arena.mc/stage0: o arquivo vem de
// lex_file() (topo da pilha de #include) ou do proprio token, como no stage0.

#define MAXTOK  512
#define MAXOPEN 16                    // profundidade maxima de #include
#define MAXINC  256                   // arquivos ja incluidos (once-only)

// ---- ids de token nao tabelados (enum de mc.h) ----
#define T_EOF   0
#define T_IDENT 1
#define T_INT   2
#define T_CHAR  3
#define T_STR   4
#define T_DIR   5
#define T_HOLE  6

// ---- diretivas conhecidas, na ordem da lista: val de um token T_DIR ----
#define D_INCLUDE 0
#define D_DEFINE  1
#define D_TOKEN   2
#define D_INFIX   3
#define D_PREFIX  4
#define D_RULE    5
#define D_SECTION 6
#define D_OPCODE  7
#define D_DYLIB   8       // M12: no fim da lista, para nao renumerar as anteriores

// ---- ids do nucleo: 256 em diante, na ordem fixa de insercao de tok_init ----
#define K_U8       256
#define K_U16      257
#define K_U32      258
#define K_U64      259
#define K_I64      260
#define K_UPTR     261
#define K_VOID     262
#define K_IF       263
#define K_ELSE     264
#define K_LOOP     265
#define K_BREAK    266
#define K_CONTINUE 267
#define K_RETURN   268
#define K_EXTERN   269
#define K_LPAR     270
#define K_RPAR     271
#define K_LBRACE   272
#define K_RBRACE   273
#define K_LBRACK   274
#define K_RBRACK   275
#define K_COMMA    276
#define K_SEMI     277
#define K_ADD      278
#define K_SUB      279
#define K_MUL      280
#define K_DIV      281
#define K_MOD      282
#define K_AND      283
#define K_OR       284
#define K_XOR      285
#define K_TILDE    286
#define K_SHL      287
#define K_SHR      288
#define K_EQ       289
#define K_NE       290
#define K_LT       291
#define K_LE       292
#define K_GT       293
#define K_GE       294
#define K_ANDAND   295
#define K_OROR     296
#define K_BANG     297
#define K_ASSIGN   298
#define K_COLON    299       // so o #rule usa: `stmt:`
#define K_ARROW    300       // so o #rule usa: `=>`

// ---- TokEnt: { text, len, word, id } ----
#define TE_TEXT 0
#define TE_LEN  8
#define TE_WORD 16
#define TE_ID   24
#define TE_SIZE 32

// ---- Token: { id, start, len, val, line, file } ----
#define TOK_ID    0
#define TOK_START 8
#define TOK_LEN   16
#define TOK_VAL   24
#define TOK_LINE  32
#define TOK_FILE  40
#define TOK_SIZE  48

// ---- OpenFile: { cp, cend, line, name } ----
#define OF_CP   0
#define OF_CEND 8
#define OF_LINE 16
#define OF_NAME 24
#define OF_SIZE 32

u8  toktab[MAXTOK * TE_SIZE];
i64 ntok = 0;

uptr cp;                              // cursor do arquivo atual
uptr cend;                            // fim do arquivo atual
i64  cline = 0;

// pilha de arquivos: o topo e o que esta sendo lido; os de baixo guardam onde pararam
u8  fstack[MAXOPEN * OF_SIZE];
i64 nopen = 0;
u8  inclist[MAXINC * 8];              // caminhos ja incluidos, em ordem
i64 ninc = 0;

// ---- acessoras de TokEnt ----
uptr te_at(i64 i)   { return toktab + i * TE_SIZE; }
uptr te_text(uptr e) { return ld64(e + TE_TEXT); }
i64  te_len(uptr e)  { return ld64(e + TE_LEN); }
i64  te_word(uptr e) { return ld64(e + TE_WORD); }
i64  te_id(uptr e)   { return ld64(e + TE_ID); }
void set_te_text(uptr e, uptr v) { st64(e + TE_TEXT, v); }
void set_te_len(uptr e, i64 v)   { st64(e + TE_LEN, v); }
void set_te_word(uptr e, i64 v)  { st64(e + TE_WORD, v); }
void set_te_id(uptr e, i64 v)    { st64(e + TE_ID, v); }

// ---- acessoras de Token ----
i64  tok_id(uptr t)    { return ld64(t + TOK_ID); }
uptr tok_start(uptr t) { return ld64(t + TOK_START); }
i64  tok_len(uptr t)   { return ld64(t + TOK_LEN); }
i64  tok_val(uptr t)   { return ld64(t + TOK_VAL); }
i64  tok_line(uptr t)  { return ld64(t + TOK_LINE); }
uptr tok_file(uptr t)  { return ld64(t + TOK_FILE); }
void set_tok_id(uptr t, i64 v)     { st64(t + TOK_ID, v); }
void set_tok_start(uptr t, uptr v) { st64(t + TOK_START, v); }
void set_tok_len(uptr t, i64 v)    { st64(t + TOK_LEN, v); }
void set_tok_val(uptr t, i64 v)    { st64(t + TOK_VAL, v); }
void set_tok_line(uptr t, i64 v)   { st64(t + TOK_LINE, v); }
void set_tok_file(uptr t, uptr v)  { st64(t + TOK_FILE, v); }

// ---- acessoras de OpenFile e da lista de includes ----
uptr of_at(i64 i)   { return fstack + i * OF_SIZE; }
uptr of_cp(uptr f)   { return ld64(f + OF_CP); }
uptr of_cend(uptr f) { return ld64(f + OF_CEND); }
i64  of_line(uptr f) { return ld64(f + OF_LINE); }
uptr of_name(uptr f) { return ld64(f + OF_NAME); }
void set_of_cp(uptr f, uptr v)   { st64(f + OF_CP, v); }
void set_of_cend(uptr f, uptr v) { st64(f + OF_CEND, v); }
void set_of_line(uptr f, i64 v)  { st64(f + OF_LINE, v); }
void set_of_name(uptr f, uptr v) { st64(f + OF_NAME, v); }

uptr inc_at(i64 i)            { return ld64(inclist + i * 8); }
void set_inc_at(i64 i, uptr v) { st64(inclist + i * 8, v); }

// ---- classificacao de caracteres ----
i64 is_alpha(i64 c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
i64 is_digit(i64 c) { return c >= '0' && c <= '9'; }
i64 is_alnum(i64 c) { return is_alpha(c) || is_digit(c); }

i64 hex_val(i64 c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// ---- tabela de tokens: ordem de insercao, ids a partir de 256 ----
i64 tok_add(uptr text, i64 len) {
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        uptr e = te_at(i);
        if (te_len(e) == len && mem_eq(te_text(e), text, len)) return te_id(e);
        i = i + 1;
    }
    if (len <= 0) die("lexema vazio");
    if (ntok == MAXTOK) die("tabela de tokens cheia");
    uptr ne = te_at(ntok);
    set_te_text(ne, text);
    set_te_len(ne, len);
    set_te_word(ne, is_alpha(ld8(text)));
    set_te_id(ne, 256 + ntok);
    ntok = ntok + 1;
    return 256 + ntok - 1;
}

uptr tok_text(i64 id) {
    if (id == T_IDENT) return "IDENT";
    if (id == T_INT)   return "INT";
    if (id == T_CHAR)  return "CHAR";
    if (id == T_STR)   return "STR";
    if (id == T_DIR)   return "DIR";
    if (id == T_HOLE)  return "HOLE";
    if (id == T_EOF)   return "EOF";
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        if (te_id(te_at(i)) == id) return te_text(te_at(i));
        i = i + 1;
    }
    return "?";
}

// A lista `core[]` do stage0 e um array de ponteiros inicializado; o nucleo nao
// tem isso, entao a ordem de insercao vira uma sequencia de chamadas. Mesma
// ordem, mesmos ids: K_U8 = 256 ate K_ASSIGN = 298.
void tok_init() {
    tok_add("u8", 2);
    tok_add("u16", 3);
    tok_add("u32", 3);
    tok_add("u64", 3);
    tok_add("i64", 3);
    tok_add("uptr", 4);
    tok_add("void", 4);
    tok_add("if", 2);
    tok_add("else", 4);
    tok_add("loop", 4);
    tok_add("break", 5);
    tok_add("continue", 8);
    tok_add("return", 6);
    tok_add("extern", 6);
    tok_add("(", 1);
    tok_add(")", 1);
    tok_add("{", 1);
    tok_add("}", 1);
    tok_add("[", 1);
    tok_add("]", 1);
    tok_add(",", 1);
    tok_add(";", 1);
    tok_add("+", 1);
    tok_add("-", 1);
    tok_add("*", 1);
    tok_add("/", 1);
    tok_add("%", 1);
    tok_add("&", 1);
    tok_add("|", 1);
    tok_add("^", 1);
    tok_add("~", 1);
    tok_add("<<", 2);
    tok_add(">>", 2);
    tok_add("==", 2);
    tok_add("!=", 2);
    tok_add("<", 1);
    tok_add("<=", 2);
    tok_add(">", 1);
    tok_add(">=", 2);
    tok_add("&&", 2);
    tok_add("||", 2);
    tok_add("!", 1);
    tok_add("=", 1);
    tok_add(":", 1);         // so o #rule usa; no fim para nao renumerar
    tok_add("=>", 2);
}

// identificador: so casa com entradas word=true
i64 word_id(uptr s, i64 len) {
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        uptr e = te_at(i);
        if (te_word(e) && te_len(e) == len && mem_eq(te_text(e), s, len)) return te_id(e);
        i = i + 1;
    }
    return -1;
}

// pontuacao/operador: maior prefixo, varredura linear e determinista
i64 punct_id(uptr s, i64 avail, uptr plen) {
    i64 best = -1;
    i64 blen = 0;
    i64 i = 0;
    loop {
        if (i >= ntok) break;
        uptr e = te_at(i);
        if (te_word(e) || te_len(e) > avail || te_len(e) <= blen) { i = i + 1; continue; }
        if (mem_eq(te_text(e), s, te_len(e))) {
            best = te_id(e);
            blen = te_len(e);
        }
        i = i + 1;
    }
    st64(plen, blen);
    return best;
}

// dir_names[] do stage0: array de ponteiros inicializado nao existe no nucleo,
// entao a busca linear vira comparacoes explicitas — mesma ordem, mesmos indices.
i64 dir_index(uptr s, i64 nl) {
    if (nl == 7 && mem_eq("include", s, 7)) return D_INCLUDE;
    if (nl == 6 && mem_eq("define", s, 6))  return D_DEFINE;
    if (nl == 5 && mem_eq("token", s, 5))   return D_TOKEN;
    if (nl == 5 && mem_eq("infix", s, 5))   return D_INFIX;
    if (nl == 6 && mem_eq("prefix", s, 6))  return D_PREFIX;
    if (nl == 4 && mem_eq("rule", s, 4))    return D_RULE;
    if (nl == 7 && mem_eq("section", s, 7)) return D_SECTION;
    if (nl == 6 && mem_eq("opcode", s, 6))  return D_OPCODE;
    if (nl == 5 && mem_eq("dylib", s, 5))   return D_DYLIB;
    return -1;
}

// ---- pilha de arquivos ----
#define MAXSEG 64

// normaliza . e .. lexicamente (sem tocar no filesystem), para que dois caminhos
// que nomeiam o mesmo arquivo virem a mesma string e o once-only funcione
uptr path_norm(uptr p) {
    i64 sb[MAXSEG];                    // inicio de cada segmento
    i64 sl[MAXSEG];                    // tamanho de cada segmento
    i64 nseg = 0;
    i64 n = cstrlen(p);
    i64 i = 0;
    i64 abs = ld8(p) == '/';
    loop {
        if (i >= n) break;
        loop {
            if (i >= n) break;
            if (ld8(p + i) != '/') break;
            i = i + 1;
        }
        i64 b = i;
        loop {
            if (i >= n) break;
            if (ld8(p + i) == '/') break;
            i = i + 1;
        }
        i64 l = i - b;
        if (l == 0 || (l == 1 && ld8(p + b) == '.')) continue;
        i64 up = l == 2 && ld8(p + b) == '.' && ld8(p + b + 1) == '.';
        uptr pb = sb + (nseg - 1) * 8;     // ultimo segmento; so lido se nseg > 0
        i64 prev_up = nseg && ld64(sl + (nseg - 1) * 8) == 2
                      && ld8(p + ld64(pb)) == '.' && ld8(p + ld64(pb) + 1) == '.';
        i64 drop = 0;                  // o ternario do C vira um if explicito
        if (up) {
            if (nseg) { if (!prev_up) drop = 1; }
            else if (abs) drop = 1;
        }
        if (drop) {
            if (nseg) nseg = nseg - 1;
            continue;
        }
        if (nseg == MAXSEG) die2("caminho com segmentos demais", p);
        st64(sb + nseg * 8, b);
        st64(sl + nseg * 8, l);
        nseg = nseg + 1;
    }
    uptr s = xalloc(n + 2);
    i64 w = 0;
    if (abs) { st8(s + w, '/'); w = w + 1; }
    i64 k = 0;
    loop {
        if (k >= nseg) break;
        if (k) { st8(s + w, '/'); w = w + 1; }
        i64 j = 0;
        loop {
            if (j >= ld64(sl + k * 8)) break;
            st8(s + w, ld8(p + ld64(sb + k * 8) + j));
            w = w + 1;
            j = j + 1;
        }
        k = k + 1;
    }
    if (w == 0) { st8(s + w, '.'); w = w + 1; }
    st8(s + w, 0);
    return s;
}

// junta o diretorio de base com rel e normaliza; caminho absoluto ignora a base
uptr path_join(uptr base, uptr rel) {
    i64 cut = 0;
    i64 bl = cstrlen(base);
    i64 rl = cstrlen(rel);
    if (ld8(rel) == '/') bl = 0;
    i64 i = 0;
    loop {
        if (i >= bl) break;
        if (ld8(base + i) == '/') cut = i + 1;
        i = i + 1;
    }
    uptr s = xalloc(cut + rl + 1);
    i = 0;
    loop {
        if (i >= cut) break;
        st8(s + i, ld8(base + i));
        i = i + 1;
    }
    i = 0;
    loop {
        if (i >= rl) break;
        st8(s + cut + i, ld8(rel + i));
        i = i + 1;
    }
    st8(s + cut + rl, 0);
    return path_norm(s);
}

void lex_push(uptr path, i64 line) {
    if (nopen == MAXOPEN) err_at(lex_file(), line, "includes aninhados demais");
    if (nopen) {
        uptr prev = of_at(nopen - 1);
        set_of_cp(prev, cp);
        set_of_cend(prev, cend);
        set_of_line(prev, cline);
    }
    i64 len = 0;
    uptr src = read_file(path, &len);
    set_of_name(of_at(nopen), path);
    nopen = nopen + 1;
    cp = src;
    cend = src + len;
    cline = 1;
}

void lex_pop() {
    nopen = nopen - 1;
    uptr top = of_at(nopen - 1);
    cp = of_cp(top);
    cend = of_cend(top);
    cline = of_line(top);
}

uptr lex_file() {
    if (nopen) return of_name(of_at(nopen - 1));
    return "?";
}

void lex_init(uptr path) {
    nopen = 0;
    ninc = 0;
    path = path_norm(path);
    set_inc_at(ninc, path);            // o raiz tambem conta para o once-only
    ninc = ninc + 1;
    lex_push(path, 0);
}

// #include: resolve rel contra o diretorio do arquivo atual e empilha; 0 = ja incluido
i64 lex_include(uptr rel, i64 line) {
    uptr path = path_join(of_name(of_at(nopen - 1)), rel);
    i64 i = 0;
    loop {
        if (i >= ninc) break;
        if (str_eq(inc_at(i), path)) return 0;
        i = i + 1;
    }
    if (ninc == MAXINC) err_at(lex_file(), line, "includes demais");
    set_inc_at(ninc, path);
    ninc = ninc + 1;
    lex_push(path, line);
    return 1;
}

// ---- lexer ----

void skip_space() {
    loop {
        loop {
            if (cp >= cend) break;
            i64 c = ld8(cp);
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
            if (c == '\n') cline = cline + 1;
            cp = cp + 1;
        }
        if (cp + 1 < cend && ld8(cp) == '/' && ld8(cp + 1) == '/') {
            loop {
                if (cp >= cend) break;
                if (ld8(cp) == '\n') break;
                cp = cp + 1;
            }
            continue;
        }
        if (cp + 1 < cend && ld8(cp) == '/' && ld8(cp + 1) == '*') {
            i64 open_line = cline;
            cp = cp + 2;
            loop {
                if (cp + 1 >= cend) break;
                if (ld8(cp) == '*' && ld8(cp + 1) == '/') break;
                if (ld8(cp) == '\n') cline = cline + 1;
                cp = cp + 1;
            }
            if (cp + 1 >= cend) err_at(lex_file(), open_line, "comentario nao terminado");
            cp = cp + 2;
            continue;
        }
        return;
    }
}

// le um caractere de literal, decodificando escape. Em string \0 e proibido:
// __cstring e S_CSTRING_LITERALS e o ld funde literais pelo primeiro NUL.
i64 read_char(i64 in_str) {
    if (cp >= cend) err_at(lex_file(), cline, "literal nao terminado");
    i64 c = ld8(cp);
    cp = cp + 1;
    if (c == '\n') { cline = cline + 1; return c; }
    if (c != '\\') return c;
    if (cp >= cend) err_at(lex_file(), cline, "escape nao terminado");
    i64 e = ld8(cp);
    cp = cp + 1;
    if (e == 'n')  return '\n';
    if (e == 't')  return '\t';
    if (e == 'r')  return '\r';
    if (e == '0')  {
        if (in_str) err_at(lex_file(), cline, "\\0 nao permitido em string");
        return 0;
    }
    if (e == '\\') return '\\';
    if (e == '\'') return '\'';
    if (e == '"')  return '"';
    err_at(lex_file(), cline, "escape desconhecido");
    return 0;
}

void lex_number(uptr t) {
    u64 v = 0;
    if (ld8(cp) == '0' && cp + 1 < cend && (ld8(cp + 1) == 'x' || ld8(cp + 1) == 'X')) {
        cp = cp + 2;
        if (cp >= cend || hex_val(ld8(cp)) < 0) err_at(lex_file(), cline, "hexadecimal invalido");
        loop {
            if (cp >= cend) break;
            if (hex_val(ld8(cp)) < 0) break;
            v = v * 16 + hex_val(ld8(cp));
            cp = cp + 1;
        }
    } else {
        loop {
            if (cp >= cend) break;
            if (!is_digit(ld8(cp))) break;
            v = v * 10 + (ld8(cp) - '0');
            cp = cp + 1;
        }
    }
    set_tok_id(t, T_INT);
    set_tok_val(t, v);
}

void lex_string(uptr t) {
    u8 b[BUF_SIZE];
    buf_init(b);
    cp = cp + 1;                       // aspas de abertura
    loop {
        if (cp >= cend) break;
        if (ld8(cp) == '"') break;
        buf_u8(b, read_char(1));
    }
    if (cp >= cend) err_at(tok_file(t), tok_line(t), "string nao terminada");
    cp = cp + 1;
    buf_u8(b, 0);                      // sentinela; o len nao a conta
    set_tok_id(t, T_STR);
    set_tok_start(t, buf_p(b));
    set_tok_len(t, buf_len(b) - 1);
}

void lex_directive(uptr t) {
    cp = cp + 1;                       // #
    uptr ns = cp;
    loop {
        if (cp >= cend) break;
        if (!is_alnum(ld8(cp))) break;
        cp = cp + 1;
    }
    i64 nl = cp - ns;
    i64 d = dir_index(ns, nl);
    if (d < 0) err_at(tok_file(t), tok_line(t), "diretiva desconhecida");
    set_tok_id(t, T_DIR);
    set_tok_val(t, d);
}

// $1 / $2 -> val = numero; $nome -> val = -1; $$nome -> val = -2 (gensym, so reservado)
void lex_hole(uptr t) {
    cp = cp + 1;
    i64 gensym = 0;
    if (cp < cend && ld8(cp) == '$') { cp = cp + 1; gensym = 1; }
    if (cp < cend && is_digit(ld8(cp))) {
        i64 v = 0;
        loop {
            if (cp >= cend) break;
            if (!is_digit(ld8(cp))) break;
            v = v * 10 + (ld8(cp) - '0');
            cp = cp + 1;
        }
        set_tok_val(t, v);
    } else if (cp < cend && is_alpha(ld8(cp))) {
        loop {
            if (cp >= cend) break;
            if (!is_alnum(ld8(cp))) break;
            cp = cp + 1;
        }
        set_tok_val(t, -1);
    } else {
        err_at(tok_file(t), tok_line(t), "buraco invalido");
    }
    if (gensym) set_tok_val(t, -2);
    set_tok_id(t, T_HOLE);
}

void lex_next(uptr t) {
    skip_space();
    loop {                             // fim de um #include
        if (cp < cend) break;
        if (nopen <= 1) break;
        lex_pop();
        skip_space();
    }
    set_tok_line(t, cline);
    set_tok_val(t, 0);
    set_tok_start(t, cp);
    set_tok_len(t, 0);
    set_tok_file(t, lex_file());
    if (cp >= cend) {
        set_tok_id(t, T_EOF);
        set_tok_start(t, "EOF");
        set_tok_len(t, 3);
        return;
    }

    if (is_digit(ld8(cp))) {
        lex_number(t);
        set_tok_len(t, cp - tok_start(t));
        return;
    }
    if (is_alpha(ld8(cp))) {
        loop {
            if (cp >= cend) break;
            if (!is_alnum(ld8(cp))) break;
            cp = cp + 1;
        }
        set_tok_len(t, cp - tok_start(t));
        i64 wid = word_id(tok_start(t), tok_len(t));
        if (wid >= 0) set_tok_id(t, wid);
        else          set_tok_id(t, T_IDENT);
        return;
    }
    if (ld8(cp) == '\'') {
        cp = cp + 1;
        set_tok_val(t, read_char(0));
        if (cp >= cend || ld8(cp) != '\'') err_at(tok_file(t), tok_line(t), "char literal nao terminado");
        cp = cp + 1;
        set_tok_id(t, T_CHAR);
        set_tok_len(t, cp - tok_start(t));
        return;
    }
    if (ld8(cp) == '"') { lex_string(t); return; }        // start aponta para a arena
    if (ld8(cp) == '#') { lex_directive(t); set_tok_len(t, cp - tok_start(t)); return; }
    if (ld8(cp) == '$') { lex_hole(t);      set_tok_len(t, cp - tok_start(t)); return; }

    i64 plen = 0;
    i64 pid = punct_id(cp, cend - cp, &plen);
    if (pid < 0) err_at(tok_file(t), tok_line(t), "caractere inesperado");
    cp = cp + plen;
    set_tok_len(t, plen);
    set_tok_id(t, pid);
}

// ---- dump ----
void dump_escaped(uptr s, i64 len) {
    out_str(1, "\"");
    i64 i = 0;
    loop {
        if (i >= len) break;
        i64 c = ld8(s + i);
        if (c == '\n')      out_str(1, "\\n");
        else if (c == '\t') out_str(1, "\\t");
        else if (c == '\r') out_str(1, "\\r");
        else if (c == 0)    out_str(1, "\\0");
        else if (c == '\\') out_str(1, "\\\\");
        else if (c == '"')  out_str(1, "\\\"");
        else                out_bytes(1, s + i, 1);
        i = i + 1;
    }
    out_str(1, "\"");
}

// uma linha por token: LINHA ID TEXTO (INT/CHAR imprimem o valor)
void dump_tokens() {
    u8 t[TOK_SIZE];
    loop {
        lex_next(t);
        out_num(1, tok_line(t)); out_str(1, " "); out_num(1, tok_id(t)); out_str(1, " ");
        if (tok_id(t) == T_INT || tok_id(t) == T_CHAR) out_num(1, tok_val(t));
        else if (tok_id(t) == T_STR)                   dump_escaped(tok_start(t), tok_len(t));
        else                                           out_bytes(1, tok_start(t), tok_len(t));
        out_str(1, "\n");
        if (tok_id(t) == T_EOF) return;
    }
}
