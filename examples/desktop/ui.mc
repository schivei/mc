// ui.mc — a declarative UI language taught to `mc` from outside `src/`
// (Part B of M32).
//
// This file is not compiled as a program: `mc build` links it INSIDE a compiler
// (`build/mc-ui.mc` = `#include <mc/core>` + this file) and it runs during the
// parse of `main.ui`. Nothing in `src/` changes. One registration is all it
// takes:
//
//     syntax("window", &ui_window)          top-level declaration position (M12)
//
// and the shape of the answer is the M21 record/replay pair: the handler reads
// the block, WRITES ORDINARY `mc` SOURCE into a buffer, and hands that buffer
// back to the parser with `p_push_source`. So the module never builds an AST
// node by hand — it is a front end that lowers to the Part A calls, and every
// error inside the generated text is attributed to the window it came from
// ("w_main (ui) from main.ui:24"), because `err_at` prints the frame name the
// module chose.
//
//     window w_main "mc desktop" size 360 440 {
//         header;
//         vbox root spacing 12 margin 12 {
//             label l_count "0";
//             hbox spacing 6 {
//                 button "-" -> on_minus;
//                 button "+" -> on_plus;
//             }
//             entry e_name placeholder "type and press Enter" -> on_entry_activate;
//             list lb_items;
//         }
//     }
//
// becomes, textually:
//
//     uptr w_main;
//     uptr root;
//     ...
//     void ui_build_w_main(uptr app) {
//         if (app != 0) { w_main = gtk_application_window_new(app); }
//         else { w_main = gtk_window_new(); }
//         gtk_window_set_title(w_main, "mc desktop");
//         ...
//     }
//
// A widget written with a NAME becomes a global of that name, so a handler in
// `main.ui` reaches it exactly as it would in `main.mc`. A widget with no name
// gets a local `ui_tN` and is only ever appended to its parent.
//
// The grammar, in full:
//
//     window NAME "title" [size W H] [-> destroy_handler] { ELEMENT... }
//
//     ELEMENT := header ;
//              | vbox [NAME] [spacing N] [margin N] { ELEMENT... }
//              | hbox [NAME] [spacing N] [margin N] { ELEMENT... }
//              | label  [NAME] "text" ;
//              | button [NAME] "text" [-> handler] ;      signal "clicked"
//              | entry  [NAME] [placeholder "text"] [-> handler] ;  "activate"
//              | check  [NAME] "text" [-> handler] ;      signal "toggled"
//              | list   [NAME] [-> handler] ;             signal "row-activated"
//
// Only `window` is registered, so only `window` is reserved for the whole
// program (docs/surface.md § Tier 3). `vbox`, `label`, `spacing` and the rest
// are ordinary identifiers matched by lexeme inside the handler, and stay usable
// as names everywhere else in the file.

// GtkOrientation, repeated here on purpose: this module lives INSIDE the
// compiler and lib/gtk.mc lives inside the compiled program, so the two never
// share a header. These are the only two GTK values the generator has to know.
#define UI_HORIZONTAL 0
#define UI_VERTICAL 1

// `->` is not a core token; the lexer learns it here, like lib/prelude.mc's
// `#token` does for `+=`. tok_add is idempotent.
i64 ui_tok_arrow;

// the two halves of the generated source: globals, and the build function's
// body. A Buf descriptor is BUF_SIZE bytes (src/arena.mc) and the bytes it
// collects live in the arena, which is what lets the text outlive this handler.
u8 ui_decl[BUF_SIZE];
u8 ui_body[BUF_SIZE];

i64 ui_ntmp = 0;                   // fresh-local counter, unique per file
uptr ui_win;                       // the window variable currently being built

// ---- writing the generated source ----

void ui_s(uptr b, uptr s) {
    buf_put(b, s, cstrlen(s));
}

// v >= 0 in decimal, in the arena
uptr ui_dec(i64 v) {
    u8 tmp[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    return xstrdup(tmp + i, 24 - i);
}

void ui_num(uptr b, i64 v) {
    if (v < 0) {
        buf_u8(b, '-');
        v = 0 - v;
    }
    ui_s(b, ui_dec(v));
}

// a `mc` string literal from the DECODED text of a `.ui` string token. The
// lexer already turned `\n` into a byte, so the escaping has to be redone here;
// bytes above 126 are UTF-8 and go through untouched, which is what lets a
// label carry any text GTK can render.
void ui_str(uptr b, uptr s) {
    buf_u8(b, '"');
    i64 i = 0;
    loop {
        i64 c = ld8(s + i);
        if (c == 0) break;
        if (c == '"' || c == '\\') {
            buf_u8(b, '\\');
            buf_u8(b, c);
        } else if (c == '\n') {
            buf_u8(b, '\\');
            buf_u8(b, 'n');
        } else if (c == '\t') {
            buf_u8(b, '\\');
            buf_u8(b, 't');
        } else if (c == '\r') {
            buf_u8(b, '\\');
            buf_u8(b, 'r');
        } else {
            buf_u8(b, c);
        }
        i = i + 1;
    }
    buf_u8(b, '"');
}

// "w_main (ui) from main.ui:24" — the name p_push_source binds to the frame,
// and therefore what err_at prints for every error inside the generated text
uptr ui_frame(uptr name, uptr fl, i64 line) {
    u8 b[BUF_SIZE];
    buf_init(b);
    ui_s(b, name);
    ui_s(b, " (ui) from ");
    ui_s(b, fl);
    buf_u8(b, ':');
    ui_s(b, ui_dec(line));
    buf_u8(b, 0);
    return buf_p(b);
}

// a fresh local for an unnamed widget
uptr ui_tmp() {
    u8 b[BUF_SIZE];
    buf_init(b);
    ui_s(b, "ui_t");
    ui_s(b, ui_dec(ui_ntmp));
    buf_u8(b, 0);
    ui_ntmp = ui_ntmp + 1;
    return buf_p(b);
}

void ui_declare(uptr name) {
    ui_s(ui_decl, "uptr ");
    ui_s(ui_decl, name);
    ui_s(ui_decl, ";\n");
}

// `    NAME = ` for a DSL-named widget (assigning the global), or
// `    uptr ui_tN = ` for an anonymous one
void ui_bind(uptr var, i64 is_global) {
    if (is_global) {
        ui_s(ui_body, "    ");
    } else {
        ui_s(ui_body, "    uptr ");
    }
    ui_s(ui_body, var);
    ui_s(ui_body, " = ");
}

void ui_append(uptr parent, uptr child) {
    if (parent == 0) return;                     // window level: set_child, later
    ui_s(ui_body, "    gtk_box_append(");
    ui_s(ui_body, parent);
    ui_s(ui_body, ", ");
    ui_s(ui_body, child);
    ui_s(ui_body, ");\n");
}

// `-> handler`, optional: one g_signal_connect_data with the element's signal
void ui_signal(uptr var, uptr signal) {
    if (p_id() != ui_tok_arrow) return;
    p_next();
    uptr h = p_ident();
    ui_s(ui_body, "    g_signal_connect_data(");
    ui_s(ui_body, var);
    ui_s(ui_body, ", \"");
    ui_s(ui_body, signal);
    ui_s(ui_body, "\", &");
    ui_s(ui_body, h);
    ui_s(ui_body, ", 0, 0, 0);\n");
}

// ---- reading the `.ui` source ----

uptr ui_want_str(uptr msg) {
    if (p_id() != T_STR) err_at(p_file(), p_line(), msg);
    uptr s = p_name();                           // the DECODED bytes of the literal
    p_next();
    return s;
}

i64 ui_want_int(uptr msg) {
    if (p_id() != T_INT) err_at(p_file(), p_line(), msg);
    i64 v = p_val();
    p_next();
    return v;
}

// 1 if the current token is the identifier `w` (without consuming it)
i64 ui_at_word(uptr w) {
    if (p_id() != T_IDENT) return 0;
    return str_eq(p_name(), w);
}

// the modifier words that may follow a widget keyword; an identifier in that
// position is one of these, or it is the widget's name
i64 ui_is_mod(uptr s) {
    if (str_eq(s, "spacing")) return 1;
    if (str_eq(s, "margin")) return 1;
    if (str_eq(s, "placeholder")) return 1;
    return 0;
}

// an optional widget name, or 0
uptr ui_opt_name() {
    if (p_id() != T_IDENT) return 0;
    uptr s = p_name();
    if (ui_is_mod(s)) return 0;
    p_next();
    return s;
}

// picks the variable for an element: the DSL name (a global, declared here) or
// a fresh local. `pglobal` receives 1 or 0.
uptr ui_var(uptr nm, uptr pglobal) {
    if (nm != 0) {
        ui_declare(nm);
        st64(pglobal, 1);
        return nm;
    }
    st64(pglobal, 0);
    return ui_tmp();
}

// `gtk_widget_set_margin(var, n);`, only when a margin was written
void ui_margin(uptr var, i64 n) {
    if (n == 0) return;
    ui_s(ui_body, "    gtk_widget_set_margin(");
    ui_s(ui_body, var);
    ui_s(ui_body, ", ");
    ui_num(ui_body, n);
    ui_s(ui_body, ");\n");
}

uptr ui_element(uptr parent);                    // recursive: a box holds elements

// vbox / hbox: the only element with children
uptr ui_box(uptr parent, i64 orientation) {
    uptr nm = ui_opt_name();
    i64 spacing = 0;
    i64 margin = 0;
    loop {
        if (ui_at_word("spacing")) {
            p_next();
            spacing = ui_want_int("ui: spacing expects a number");
        } else if (ui_at_word("margin")) {
            p_next();
            margin = ui_want_int("ui: margin expects a number");
        } else {
            break;
        }
    }
    u8 g[8];
    uptr var = ui_var(nm, g);
    ui_bind(var, ld64(g));
    ui_s(ui_body, "gtk_box_new(");
    ui_num(ui_body, orientation);
    ui_s(ui_body, ", ");
    ui_num(ui_body, spacing);
    ui_s(ui_body, ");\n");
    ui_margin(var, margin);

    p_expect(K_LBRACE, "ui: expected { to open a box");
    loop {
        if (p_id() == K_RBRACE) break;
        ui_element(var);
    }
    p_expect(K_RBRACE, "ui: expected } to close a box");
    ui_append(parent, var);
    return var;
}

// a leaf widget: `KEYWORD [NAME] <ctor> [-> handler] ;`
uptr ui_leaf(uptr parent, uptr ctor, uptr text, uptr signal) {
    u8 g[8];
    uptr nm = ui_opt_name();
    uptr var = ui_var(nm, g);
    ui_bind(var, ld64(g));
    ui_s(ui_body, ctor);
    ui_s(ui_body, "(");
    if (text != 0) ui_str(ui_body, text);
    ui_s(ui_body, ");\n");
    ui_signal(var, signal);
    p_expect(K_SEMI, "ui: expected ; after a widget");
    ui_append(parent, var);
    return var;
}

// one element. Returns its variable, or 0 for `header`, which is not a child of
// anything: it is the window's title bar.
uptr ui_element(uptr parent) {
    i64 line = p_line();
    uptr fl = p_file();
    if (p_id() != T_IDENT) err_at(fl, line, "ui: a widget keyword was expected");
    uptr kw = p_name();
    p_next();

    if (str_eq(kw, "header")) {
        p_expect(K_SEMI, "ui: expected ; after header");
        ui_s(ui_body, "    gtk_window_set_titlebar(");
        ui_s(ui_body, ui_win);
        ui_s(ui_body, ", gtk_header_bar_new());\n");
        return 0;
    }
    if (str_eq(kw, "vbox")) return ui_box(parent, UI_VERTICAL);
    if (str_eq(kw, "hbox")) return ui_box(parent, UI_HORIZONTAL);

    if (str_eq(kw, "label")) {
        uptr nm = ui_opt_name();
        uptr text = ui_want_str("ui: label expects a text");
        u8 g[8];
        uptr var = ui_var(nm, g);
        ui_bind(var, ld64(g));
        ui_s(ui_body, "gtk_label_new(");
        ui_str(ui_body, text);
        ui_s(ui_body, ");\n");
        p_expect(K_SEMI, "ui: expected ; after label");
        ui_append(parent, var);
        return var;
    }
    if (str_eq(kw, "button")) {
        uptr nm = ui_opt_name();
        uptr text = ui_want_str("ui: button expects a text");
        u8 g[8];
        uptr var = ui_var(nm, g);
        ui_bind(var, ld64(g));
        ui_s(ui_body, "gtk_button_new_with_label(");
        ui_str(ui_body, text);
        ui_s(ui_body, ");\n");
        ui_signal(var, "clicked");
        p_expect(K_SEMI, "ui: expected ; after button");
        ui_append(parent, var);
        return var;
    }
    if (str_eq(kw, "check")) {
        uptr nm = ui_opt_name();
        uptr text = ui_want_str("ui: check expects a text");
        u8 g[8];
        uptr var = ui_var(nm, g);
        ui_bind(var, ld64(g));
        ui_s(ui_body, "gtk_check_button_new_with_label(");
        ui_str(ui_body, text);
        ui_s(ui_body, ");\n");
        ui_signal(var, "toggled");
        p_expect(K_SEMI, "ui: expected ; after check");
        ui_append(parent, var);
        return var;
    }
    if (str_eq(kw, "entry")) {
        uptr nm = ui_opt_name();
        uptr ph = 0;
        if (ui_at_word("placeholder")) {
            p_next();
            ph = ui_want_str("ui: placeholder expects a text");
        }
        u8 g[8];
        uptr var = ui_var(nm, g);
        ui_bind(var, ld64(g));
        ui_s(ui_body, "gtk_entry_new();\n");
        if (ph != 0) {
            ui_s(ui_body, "    gtk_entry_set_placeholder_text(");
            ui_s(ui_body, var);
            ui_s(ui_body, ", ");
            ui_str(ui_body, ph);
            ui_s(ui_body, ");\n");
        }
        ui_signal(var, "activate");
        p_expect(K_SEMI, "ui: expected ; after entry");
        ui_append(parent, var);
        return var;
    }
    if (str_eq(kw, "list")) {
        return ui_leaf(parent, "gtk_list_box_new", 0, "row-activated");
    }
    err_at2(fl, line, "ui: unknown widget", kw);
    return 0;
}

// ---- the registration ----
// window NAME "title" [size W H] [-> destroy] { ELEMENT... }
void ui_window() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `window` word
    uptr name = p_ident();
    uptr title = ui_want_str("ui: window expects a title");
    i64 w = 360;
    i64 h = 240;
    if (ui_at_word("size")) {
        p_next();
        w = ui_want_int("ui: size expects a width");
        h = ui_want_int("ui: size expects a height");
    }

    buf_init(ui_decl);
    buf_init(ui_body);
    ui_declare(name);
    ui_win = name;

    // the window itself. `app` is the build function's only parameter: with a
    // GtkApplication the window belongs to it, without one (the self-test) it
    // is a plain GtkWindow and everything below is identical.
    ui_s(ui_body, "    if (app != 0) { ");
    ui_s(ui_body, name);
    ui_s(ui_body, " = gtk_application_window_new(app); } else { ");
    ui_s(ui_body, name);
    ui_s(ui_body, " = gtk_window_new(); }\n    gtk_window_set_title(");
    ui_s(ui_body, name);
    ui_s(ui_body, ", ");
    ui_str(ui_body, title);
    ui_s(ui_body, ");\n    gtk_window_set_default_size(");
    ui_s(ui_body, name);
    ui_s(ui_body, ", ");
    ui_num(ui_body, w);
    ui_s(ui_body, ", ");
    ui_num(ui_body, h);
    ui_s(ui_body, ");\n");
    ui_signal(name, "destroy");

    p_expect(K_LBRACE, "ui: expected { after the window header");
    uptr child = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        uptr v = ui_element(0);
        if (v != 0) {
            if (child != 0) err_at(fl, line, "ui: a window takes a single child");
            child = v;
        }
    }
    // the lookahead contract (docs/surface.md § p_push_source): the handler has
    // to be sitting on the LAST token of its own construct when it pushes, so
    // the closing } is checked and NOT consumed here.
    if (p_id() != K_RBRACE) err_at(p_file(), p_line(), "ui: expected } to close the window");
    if (child != 0) {
        ui_s(ui_body, "    gtk_window_set_child(");
        ui_s(ui_body, name);
        ui_s(ui_body, ", ");
        ui_s(ui_body, child);
        ui_s(ui_body, ");\n");
    }

    u8 src[BUF_SIZE];
    buf_init(src);
    buf_put(src, buf_p(ui_decl), buf_len(ui_decl));
    ui_s(src, "void ui_build_");
    ui_s(src, name);
    ui_s(src, "(uptr app) {\n");
    buf_put(src, buf_p(ui_body), buf_len(ui_body));
    ui_s(src, "}\n");

    i64 d0 = p_depth();
    p_push_source(ui_frame(name, fl, line), buf_p(src), buf_len(src));
    p_next();                                    // the contract: discards the }
    loop {                                       // drives the generated
        if (p_depth() == d0) break;              // declarations into the unit
        top_add(parse_top());
    }
}

void user_init() {
    ui_tok_arrow = tok_add("->", 2);
    syntax("window", &ui_window);
}
