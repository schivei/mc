// oop.mc — `class` e `interface` ensinados de fora, pela API publica do parser
// (Tier 3, M12). Este arquivo nao e compilado como programa: ele e ligado
// DENTRO de um compilador (examples/api/mc-api.mc) e roda durante o parse do
// fonte do usuario. Nada aqui toca `src/`.
//
// O que cada declaracao gera (ver a tabela do README/relatorio):
//
//   interface Shape {                 #define SHAPE_AREA 0
//       i64 area(self);               #define SHAPE_NOME 8
//       str nome(self);               i64  shape_area(uptr self)  -> callp(vtable[0], self)
//   }                                 uptr shape_nome(uptr self)  -> callp(vtable[1], self)
//                                     type_alias("Shape", TY_UPTR)
//
//   class Rect : Shape {              #define RECT_W 8   (a palavra 0 e a vtable)
//       i64 w;                        i64  rect_w(uptr self) / void set_rect_w(uptr self, i64 v)
//       i64 area(self) { ... }        i64  rect_area(uptr self)      <- metodo, self implicito
//   }                                 #define RECT_SIZE 16
//                                     u8   rect_vt[16]
//                                     void rect_vt_init()
//                                     uptr rect_new()   -> rt_alloc(RECT_SIZE) + vtable
//                                     type_alias("Rect", TY_UPTR)
//
// Uma classe sem `: Interface` nao ganha vtable nem `vt_init`, e os campos
// comecam no deslocamento 0.
//
// O runtime e do programa, nao daqui: `nome_new()` chama `rt_alloc(n)`, que o
// fonte compilado tem de fornecer e que devolve `n` bytes ZERADOS. Um programa
// sem `rt_alloc` falha no codegen com "chamada a funcao desconhecida".
//
// Depende do nucleo mais o prelude (`while`, `+=`) e de tres coisas do
// compilador que o incluiu: a API publica de src/parse.mc (p_*, parse_*,
// top_add, def_add, param_new, list_append), os construtores de src/ast.mc
// (node_new, nd_*, set_nd_*) e os registros de src/hooks.mc (type_alias).

#include "../../lib/prelude.mc"

#define MAXIFACE   16                 // interfaces declaradas no fonte
#define MAXIMETH   64                 // metodos de interface, somando todas
#define MAXCMETH   32                 // metodos da classe que esta sendo lida

// ---- interfaces: nome + fatia [first, first+count) da tabela de metodos ----
uptr if_name[MAXIFACE];
i64  if_first[MAXIFACE];
i64  if_count[MAXIFACE];
i64  nifaces = 0;

uptr im_name[MAXIMETH];               // metodos de interface, na ordem da declaracao
i64  im_np[MAXIMETH];                 // parametros do metodo, sem contar `self`
i64  nimeth = 0;

// ---- metodos da classe corrente; classe nao aninha, entao um so rascunho ----
uptr cm_name[MAXCMETH];
i64  cm_np[MAXCMETH];
i64  ncm = 0;

// posicao usada nos nos gerados e nos erros de nivel de declaracao
i64  oop_line = 0;
uptr oop_file = 0;

// ---- acessoras das tabelas (nenhum ld64/st64 cru fora daqui) ----
uptr if_name_at(i64 i)  { return ld64(if_name + i * 8); }
i64  if_first_at(i64 i) { return ld64(if_first + i * 8); }
i64  if_count_at(i64 i) { return ld64(if_count + i * 8); }
uptr im_name_at(i64 i)  { return ld64(im_name + i * 8); }
i64  im_np_at(i64 i)    { return ld64(im_np + i * 8); }
uptr cm_name_at(i64 i)  { return ld64(cm_name + i * 8); }
i64  cm_np_at(i64 i)    { return ld64(cm_np + i * 8); }

void set_if_name_at(i64 i, uptr v)  { st64(if_name + i * 8, v); }
void set_if_first_at(i64 i, i64 v)  { st64(if_first + i * 8, v); }
void set_if_count_at(i64 i, i64 v)  { st64(if_count + i * 8, v); }
void set_im_name_at(i64 i, uptr v)  { st64(im_name + i * 8, v); }
void set_im_np_at(i64 i, i64 v)     { st64(im_np + i * 8, v); }
void set_cm_name_at(i64 i, uptr v)  { st64(cm_name + i * 8, v); }
void set_cm_np_at(i64 i, i64 v)     { st64(cm_np + i * 8, v); }

// busca linear, na ordem de declaracao: docs/determinism.md, regra 1
i64 oop_iface_find(uptr name) {
    i64 i = 0;
    while (i < nifaces) {
        if (str_eq(if_name_at(i), name)) return i;
        i += 1;
    }
    return 0 - 1;
}

i64 oop_cm_find(uptr name) {
    i64 i = 0;
    while (i < ncm) {
        if (str_eq(cm_name_at(i), name)) return i;
        i += 1;
    }
    return 0 - 1;
}

void oop_imeth_add(uptr name, i64 np) {
    if (nimeth == MAXIMETH) die("metodos de interface demais");
    set_im_name_at(nimeth, name);
    set_im_np_at(nimeth, np);
    nimeth += 1;
}

void oop_cm_add(uptr name, i64 np) {
    if (ncm == MAXCMETH) die("metodos demais numa classe");
    set_cm_name_at(ncm, name);
    set_cm_np_at(ncm, np);
    ncm += 1;
}

void oop_iface_add(uptr name, i64 first, i64 count) {
    if (nifaces == MAXIFACE) die("interfaces demais");
    set_if_name_at(nifaces, name);
    set_if_first_at(nifaces, first);
    set_if_count_at(nifaces, count);
    nifaces += 1;
}

// ---- nomes derivados ----
i64 oop_lower_ch(i64 c) { if (c >= 'A' && c <= 'Z') return c + 32; return c; }
i64 oop_upper_ch(i64 c) { if (c >= 'a' && c <= 'z') return c - 32; return c; }

// copia de `s` com as letras trocadas de caixa: up = 1 maiuscula, 0 minuscula
uptr oop_case(uptr s, i64 up) {
    i64 n = cstrlen(s);
    uptr d = xalloc(n + 1);
    i64 i = 0;
    while (i < n) {
        i64 c = ld8(s + i);
        if (up) st8(d + i, oop_upper_ch(c));
        else    st8(d + i, oop_lower_ch(c));
        i += 1;
    }
    st8(d + n, 0);
    return d;
}

uptr oop_join(uptr a, uptr b) {
    i64 la = cstrlen(a);
    i64 lb = cstrlen(b);
    uptr d = xalloc(la + lb + 1);
    mem_copy(d, a, la);
    mem_copy(d + la, b, lb);
    st8(d + la + lb, 0);
    return d;
}

uptr oop_join3(uptr a, uptr b, uptr c) { return oop_join(oop_join(a, b), c); }

// nome novo de classe ou de interface: tem de ser um identificador ainda livre.
// `type_alias` faz do nome uma palavra reservada, entao um segundo `class Rect`
// (ou `class str`) chega aqui como palavra, nao como T_IDENT — sem este guarda
// o erro sairia como um "nome esperado" sem explicacao.
uptr oop_newname(uptr que) {
    if (p_id() == T_IDENT) return p_ident();
    if (alias_find(p_id()) >= 0)
        err_at2(p_file(), p_line(), "o nome ja e um tipo (classe, interface ou alias)", p_name());
    err_at2(p_file(), p_line(), oop_join3("nome de ", que, " esperado"), p_name());
    return 0;
}

// Rect + json  ->  rect_json     (funcao gerada)
uptr oop_fname(uptr tipo, uptr m) { return oop_join3(oop_case(tipo, 0), "_", m); }
// Rect + w     ->  RECT_W        (#define do deslocamento / do indice na vtable)
uptr oop_cname(uptr tipo, uptr m) { return oop_join3(oop_case(tipo, 1), "_", oop_case(m, 1)); }

// ---- construtores de no: so node_new/set_nd_* de src/ast.mc ----
i64 oop_nd(i64 kind) { return node_new(kind, oop_line, oop_file); }

i64 oop_int(i64 v) {
    i64 n = oop_nd(N_INT);
    set_nd_val(n, v);
    set_nd_type(n, TY_I64);
    return n;
}

i64 oop_id(uptr name) {
    i64 n = oop_nd(N_IDENT);
    set_nd_name(n, name);
    set_nd_type(n, TY_I64);
    return n;
}

// &nome de funcao: o uptr do M10
i64 oop_addr(uptr name) {
    i64 n = oop_nd(N_ADDR);
    set_nd_name(n, name);
    set_nd_type(n, TY_UPTR);
    return n;
}

i64 oop_bin(i64 op, i64 a, i64 b) {
    i64 n = oop_nd(N_BINARY);
    set_nd_op(n, op);
    set_nd_a(n, a);
    set_nd_b(n, b);
    return n;
}

i64 oop_call(uptr name, i64 args) {
    i64 n = oop_nd(N_CALL);
    set_nd_name(n, name);
    set_nd_a(n, args);
    set_nd_type(n, TY_I64);
    return n;
}

i64 oop_ret(i64 e) {
    i64 n = oop_nd(N_RETURN);
    set_nd_a(n, e);
    return n;
}

i64 oop_st(i64 e) {
    i64 n = oop_nd(N_EXPRSTMT);
    set_nd_a(n, e);
    return n;
}

i64 oop_blk(i64 stmts) {
    i64 n = oop_nd(N_BLOCK);
    set_nd_a(n, stmts);
    return n;
}

i64 oop_var(i64 ty, uptr name, i64 init) {
    i64 n = oop_nd(N_VAR);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_a(n, init);
    return n;
}

i64 oop_func(i64 ty, uptr name, i64 params, i64 body) {
    i64 f = oop_nd(N_FUNC);
    set_nd_name(f, name);
    set_nd_type(f, ty);
    set_nd_a(f, params);
    set_nd_b(f, body);
    return f;
}

// global sem inicializador: vai para __bss, ja zerada
i64 oop_glb(i64 ty, uptr name, i64 nel) {
    i64 n = oop_nd(N_GLOBAL);
    set_nd_name(n, name);
    set_nd_type(n, ty);
    set_nd_val(n, nel);
    return n;
}

// intrinsic de acesso a memoria conforme a largura do tipo do campo
uptr oop_ld(i64 ty) {
    i64 w = type_width(ty);
    if (w == 1) return "ld8";
    if (w == 2) return "ld16";
    if (w == 4) return "ld32";
    return "ld64";
}

uptr oop_stn(i64 ty) {
    i64 w = type_width(ty);
    if (w == 1) return "st8";
    if (w == 2) return "st16";
    if (w == 4) return "st32";
    return "st64";
}

// self + OFF
i64 oop_fieldp(i64 off) { return oop_bin(K_ADD, oop_id("self"), oop_int(off)); }

// ---- lista de parametros de um metodo: `(self)` ou `(self, tipo nome, ...)`.
// Devolve a lista de N_PARAM ja com `self` (uptr) na frente e escreve em *pnp
// quantos parametros o metodo tem alem de `self`. Nao da para usar
// parse_params(): `self` vem sem tipo, e e exatamente esse o acucar.
//
// `extra` e quantas vagas de argumento o despacho gasta alem dos parametros:
// 1 na interface, porque o despachante chama `callp(slot, self, ...)` e o
// ponteiro ocupa a primeira das 8 vagas de `callp`; 0 na classe, cujo metodo e
// chamado direto por `bl`. Sem isso um metodo de interface com self + 7
// parametros passa aqui e morre la na frente com "callp espera de 1 a 8
// argumentos", na linha errada. ----
i64 oop_params(uptr pnp, i64 extra) {
    p_expect(K_LPAR, "esperado ( na lista de parametros do metodo");
    if (p_id() != T_IDENT || !str_eq(p_name(), "self"))
        err_at(p_file(), p_line(), "o primeiro parametro de um metodo e `self`");
    p_next();
    i64 head = param_new(TY_UPTR, "self");
    i64 np = 0;
    while (p_accept(K_COMMA)) {
        i64 ty = p_type();
        if (ty == TY_VOID) err_at(p_file(), p_line(), "parametro de tipo void");
        head = list_append(head, param_new(ty, p_ident()));
        np += 1;
        if (np + 1 + extra > MAXPARAMS)
            err_at(p_file(), p_line(),
                   "metodo com parametros demais (self conta; na interface, o ponteiro da vtable tambem)");
    }
    p_expect(K_RPAR, "esperado ) na lista de parametros do metodo");
    st64(pnp, np);
    return head;
}

// ---- despachante de interface ----
// T iface_metodo(uptr self, ...) { return callp(ld64(ld64(self) + IDX*8), self, ...); }
// ld64(self) e a vtable (palavra 0 do objeto); + IDX*8 e o slot do metodo.
i64 oop_dispatch(i64 ty, uptr iface, uptr m, i64 params, i64 idx) {
    i64 vt = oop_call("ld64", oop_id("self"));
    i64 slot = oop_call("ld64", oop_bin(K_ADD, vt, oop_int(idx * 8)));
    i64 args = slot;                             // callp(p, a1..a7): o ponteiro vem primeiro
    i64 p = params;
    while (p != 0) {
        args = list_append(args, oop_id(nd_name(p)));
        p = nd_next(p);
    }
    i64 call = oop_call("callp", args);
    i64 body = oop_blk(oop_ret(call));
    if (ty == TY_VOID) body = oop_blk(oop_st(call));
    return oop_func(ty, oop_fname(iface, m), params, body);
}

// ---- acessoras de campo ----
// T nome_campo(uptr self) { return ldW(self + NOME_CAMPO); }
i64 oop_getter(i64 ty, uptr cls, uptr f, i64 off) {
    i64 body = oop_blk(oop_ret(oop_call(oop_ld(ty), oop_fieldp(off))));
    return oop_func(ty, oop_fname(cls, f), param_new(TY_UPTR, "self"), body);
}

// void set_nome_campo(uptr self, T v) { stW(self + NOME_CAMPO, v); }
i64 oop_setter(i64 ty, uptr cls, uptr f, i64 off) {
    i64 params = list_append(param_new(TY_UPTR, "self"), param_new(ty, "v"));
    i64 args = list_append(oop_fieldp(off), oop_id("v"));
    i64 body = oop_blk(oop_st(oop_call(oop_stn(ty), args)));
    return oop_func(TY_VOID, oop_join("set_", oop_fname(cls, f)), params, body);
}

// ---- vtable ----
// void nome_vt_init() { st64(nome_vt + 0, &nome_m0); ... }
// E aqui que "metodo da interface nao implementado" aparece: a vtable so pode
// ser preenchida se a classe tem todos os metodos, na aridade declarada.
i64 oop_vt_init(uptr cls, uptr vt, i64 ifi) {
    i64 first = if_first_at(ifi);
    i64 nm = if_count_at(ifi);
    i64 stmts = 0;
    i64 i = 0;
    while (i < nm) {
        uptr m = im_name_at(first + i);
        i64 j = oop_cm_find(m);
        if (j < 0)
            err_at2(oop_file, oop_line, "metodo da interface nao implementado", m);
        if (cm_np_at(j) != im_np_at(first + i))
            err_at2(oop_file, oop_line, "metodo com aridade diferente da interface", m);
        i64 dst = oop_bin(K_ADD, oop_id(vt), oop_int(i * 8));
        i64 args = list_append(dst, oop_addr(oop_fname(cls, m)));
        stmts = list_append(stmts, oop_st(oop_call("st64", args)));
        i += 1;
    }
    return oop_func(TY_VOID, oop_join(oop_case(cls, 0), "_vt_init"), 0, oop_blk(stmts));
}

// ---- construtor ----
// uptr nome_new() {
//     uptr p = rt_alloc(NOME_SIZE);     // o programa fornece rt_alloc; devolve zerado
//     nome_vt_init();                   // so quando a classe implementa interface
//     st64(p, nome_vt);                 // palavra 0 = vtable
//     return p;
// }
i64 oop_new(uptr cls, i64 size, uptr vt) {
    i64 stmts = oop_var(TY_UPTR, "p", oop_call("rt_alloc", oop_int(size)));
    if (vt) {
        uptr init = oop_join(oop_case(cls, 0), "_vt_init");
        stmts = list_append(stmts, oop_st(oop_call(init, 0)));
        i64 args = list_append(oop_id("p"), oop_id(vt));
        stmts = list_append(stmts, oop_st(oop_call("st64", args)));
    }
    stmts = list_append(stmts, oop_ret(oop_id("p")));
    return oop_func(TY_UPTR, oop_join(oop_case(cls, 0), "_new"), 0, oop_blk(stmts));
}

// ---- interface Nome { T metodo(self, ...); ... } ----
// Registra um #define por metodo, publica um despachante por metodo e faz do
// nome um tipo (uptr). Nao produz objeto nenhum: interface e so a tabela.
void oop_interface() {
    oop_line = p_line();
    oop_file = p_file();
    i64 head_line = oop_line;                    // posicao da palavra `interface`
    uptr head_file = oop_file;
    p_next();                                    // a palavra `interface`
    uptr name = oop_newname("interface");
    type_alias(name, TY_UPTR);                   // ja vale dentro do proprio corpo
    p_expect(K_LBRACE, "esperado { no corpo da interface");
    i64 first = nimeth;
    i64 idx = 0;
    while (p_id() != K_RBRACE) {
        if (p_id() == T_EOF) err_at(head_file, head_line, "interface nao terminada");
        oop_line = p_line();                     // erros e nos deste metodo, nao da interface
        oop_file = p_file();
        i64 ty = p_type();
        uptr m = p_ident();
        i64 np = 0;
        i64 params = oop_params(&np, 1);
        p_expect(K_SEMI, "esperado ; apos o metodo da interface");
        def_add(oop_cname(name, m), idx * 8, oop_line, oop_file);
        top_add(oop_dispatch(ty, name, m, params, idx));
        oop_imeth_add(m, np);
        idx += 1;
    }
    p_next();                                    // }
    oop_line = head_line;                        // de volta ao nivel da interface
    oop_file = head_file;
    if (idx == 0) err_at2(oop_file, oop_line, "interface sem metodos", name);
    oop_iface_add(name, first, idx);
}

// ---- class Nome [: Interface] { campos e metodos } ----
void oop_class() {
    oop_line = p_line();
    oop_file = p_file();
    i64 head_line = oop_line;                    // posicao da palavra `class`
    uptr head_file = oop_file;
    p_next();                                    // a palavra `class`
    uptr name = oop_newname("classe");
    i64 ifi = 0 - 1;
    if (p_accept(K_COLON)) {
        // o nome da interface ja e palavra reservada (type_alias), entao nao e
        // T_IDENT: le-se o lexema cru e resolve-se na tabela
        uptr iname = p_name();
        p_next();
        ifi = oop_iface_find(iname);
        if (ifi < 0) err_at2(p_file(), p_line(), "interface desconhecida", iname);
    }
    type_alias(name, TY_UPTR);                   // a classe vira um tipo
    p_expect(K_LBRACE, "esperado { no corpo da classe");
    i64 off = 0;
    if (ifi >= 0) off = 8;                       // palavra 0 reservada para a vtable
    ncm = 0;
    while (p_id() != K_RBRACE) {
        if (p_id() == T_EOF) err_at(head_file, head_line, "classe nao terminada");
        oop_line = p_line();                     // erros e nos deste membro, nao da classe
        oop_file = p_file();
        i64 ty = p_type();
        uptr m = p_ident();
        if (p_id() == K_LPAR) {
            if (str_eq(m, "new") || str_eq(m, "vt_init"))
                err_at2(p_file(), p_line(), "nome de metodo reservado pela classe", m);
            i64 np = 0;
            i64 params = oop_params(&np, 0);
            i64 line = p_line();
            uptr fl = p_file();
            i64 f = parse_function(ty, oop_fname(name, m), params);
            set_nd_line(f, line);                // a declaracao comeca no {, nao no fim
            set_nd_file(f, fl);
            top_add(f);
            oop_cm_add(m, np);
        } else {
            p_expect(K_SEMI, "esperado ; apos o campo da classe");
            if (ty == TY_VOID) err_at2(p_file(), p_line(), "campo de tipo void", m);
            i64 w = type_width(ty);
            off = (off + w - 1) & ~(w - 1);      // alinhamento natural do campo
            def_add(oop_cname(name, m), off, oop_line, oop_file);
            top_add(oop_getter(ty, name, m, off));
            top_add(oop_setter(ty, name, m, off));
            off = off + w;
        }
    }
    p_next();                                    // }
    oop_line = head_line;                        // de volta ao nivel da classe
    oop_file = head_file;
    off = (off + 7) & ~7;                        // o objeto inteiro alinhado a 8
    if (off == 0) off = 8;                       // classe sem campos: um objeto ainda existe
    def_add(oop_join(oop_case(name, 1), "_SIZE"), off, oop_line, oop_file);
    uptr vt = 0;
    if (ifi >= 0) {
        vt = oop_join(oop_case(name, 0), "_vt");
        top_add(oop_glb(TY_U8, vt, if_count_at(ifi) * 8));
        top_add(oop_vt_init(name, vt, ifi));
    }
    top_add(oop_new(name, off, vt));
}
