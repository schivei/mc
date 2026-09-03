// main.mc — a GTK4 desktop application written in plain `mc` (Part A of M32).
//
//   ../../build/mc1 build examples/desktop        # -> examples/desktop/build/desktop
//   examples/desktop/build/desktop                # opens the window
//   examples/desktop/build/desktop --self-test    # builds the tree, drives the
//                                                 # handlers, prints, exits 0
//
// The window: a header bar, a counter label with `-` / `+` buttons, a check
// button that switches the step from 1 to 2, an entry whose text on Enter is
// echoed into a label AND appended to a list box, and an `About` button that
// opens a transient modal second window with a `Close` button.
//
// Every callback below is an ordinary `mc` function handed to GTK as `&name`
// (M10) through `g_signal_connect_data`. GTK calls it with (widget, user_data)
// in x0/x1, so two `uptr` parameters match a `void` handler exactly. State
// lives in globals: `user_data` is 0 everywhere, which keeps the example about
// the toolkit and not about a hand-rolled closure record.

#include <sys>
#include <prelude>
#include "lib/gtk.mc"

// ---- the widgets the handlers need to reach ----
uptr w_main;
uptr w_about;
uptr l_count;
uptr l_echo;
uptr e_name;
uptr lb_items;
uptr c_step2;
i64  counter = 0;

// ---- two small string helpers (lib/io.mc has putnum, but not these) ----

// signed decimal into `buf`, NUL-terminated, returning `buf` so the result can
// be passed straight to gtk_label_set_text
uptr ui_itoa(i64 v, uptr buf) {
    u8 tmp[24];
    i64 i = 24;
    i64 neg = 0;
    if (v < 0) {
        neg = 1;
        v = 0 - v;
    }
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    i64 o = 0;
    if (neg) {
        st8(buf, '-');
        o = 1;
    }
    while (i < 24) {
        st8(buf + o, ld8(tmp + i));
        o = o + 1;
        i = i + 1;
    }
    st8(buf + o, 0);
    return buf;
}

i64 ui_streq(uptr a, uptr b) {
    i64 i = 0;
    loop {
        i64 c = ld8(a + i);
        if (c != ld8(b + i)) return 0;
        if (c == 0) return 1;
        i = i + 1;
    }
}

// ---- behaviour ----

// the check button is read back from the widget, not mirrored in a global:
// gtk_check_active does the u32 cast the gboolean ABI needs (lib/gtk.mc)
i64 ui_step() {
    if (gtk_check_active(c_step2)) return 2;
    return 1;
}

void ui_refresh_count() {
    u8 buf[24];
    gtk_label_set_text(l_count, ui_itoa(counter, buf));
}

void on_plus(uptr w, uptr data) {
    counter = counter + ui_step();
    ui_refresh_count();
}

void on_minus(uptr w, uptr data) {
    counter = counter - ui_step();
    ui_refresh_count();
}

// `gtk_editable_get_text` hands back the entry's own buffer, and the last thing
// this function does is clear the entry -- so the text is snapshotted with
// g_strdup first and released with g_free at the end.
void on_entry_activate(uptr entry, uptr data) {
    uptr text = g_strdup(gtk_editable_get_text(entry));
    if (ld8(text) != 0) {
        gtk_label_set_text(l_echo, text);
        gtk_list_box_append(lb_items, gtk_label_new(text));
        gtk_editable_set_text(entry, "");
    }
    g_free(text);
}

void on_about_close(uptr w, uptr data) {
    gtk_window_close(w_about);
}

// closing a GtkWindow destroys it, so the cached pointer has to go with it
void on_about_destroy(uptr w, uptr data) {
    w_about = 0;
}

// builds the second window into w_about without showing it: whoever presents it
// is on_about. This is the function main.ui replaces with a `window` block --
// everything else in the two programs is the same source.
uptr ui_about_new() {
    w_about = gtk_window_new();
    gtk_window_set_title(w_about, "About");
    gtk_window_set_default_size(w_about, 260, 140);
    g_signal_connect_data(w_about, "destroy", &on_about_destroy, 0, 0, 0);

    uptr box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin(box, 12);
    gtk_box_append(box, gtk_label_new("mc desktop -- GTK4 driven from mc"));
    uptr close = gtk_button_new_with_label("Close");
    g_signal_connect_data(close, "clicked", &on_about_close, 0, 0, 0);
    gtk_box_append(box, close);
    gtk_window_set_child(w_about, box);
    return w_about;
}

// transient-for and modal are POLICY, not tree shape: they stay here in both
// programs, so the `window` block in main.ui has nothing to say about them.
void on_about(uptr w, uptr data) {
    if (w_about == 0) {
        ui_about_new();
        gtk_window_set_transient_for(w_about, w_main);
        gtk_window_set_modal(w_about, 1);
    }
    gtk_window_present(w_about);
}

// ---- the widget tree ----
// `app` is 0 in the self-test: with no GtkApplication the main window is a
// plain GtkWindow, and everything below it is identical.
void ui_build(uptr app) {
    if (app != 0) {
        w_main = gtk_application_window_new(app);
    } else {
        w_main = gtk_window_new();
    }
    gtk_window_set_title(w_main, "mc desktop");
    gtk_window_set_default_size(w_main, 360, 440);
    gtk_window_set_titlebar(w_main, gtk_header_bar_new());

    uptr root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin(root, 12);

    l_count = gtk_label_new("0");
    gtk_box_append(root, l_count);

    uptr row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    uptr bminus = gtk_button_new_with_label("-");
    g_signal_connect_data(bminus, "clicked", &on_minus, 0, 0, 0);
    gtk_box_append(row, bminus);
    uptr bplus = gtk_button_new_with_label("+");
    g_signal_connect_data(bplus, "clicked", &on_plus, 0, 0, 0);
    gtk_box_append(row, bplus);
    gtk_box_append(root, row);

    c_step2 = gtk_check_button_new_with_label("step by two");
    gtk_box_append(root, c_step2);

    e_name = gtk_entry_new();
    gtk_entry_set_placeholder_text(e_name, "type and press Enter");
    g_signal_connect_data(e_name, "activate", &on_entry_activate, 0, 0, 0);
    gtk_box_append(root, e_name);

    l_echo = gtk_label_new("");
    gtk_box_append(root, l_echo);

    lb_items = gtk_list_box_new();
    gtk_box_append(root, lb_items);

    uptr babout = gtk_button_new_with_label("About");
    g_signal_connect_data(babout, "clicked", &on_about, 0, 0, 0);
    gtk_box_append(root, babout);

    gtk_window_set_child(w_main, root);
}

void on_activate(uptr app, uptr data) {
    ui_build(app);
    gtk_window_present(w_main);
}

// ---- --self-test ----
// No GtkApplication and no g_application_run: the tree is built, the handlers
// are called directly, and every value printed is READ BACK OUT OF THE WIDGETS
// (gtk_label_get_text, gtk_list_box_get_row_at_index), never from a variable
// the program keeps on the side. gtk_init() is required -- widgets need the
// display -- and is what makes this test need a real GTK4 install.
i64 ui_self_test() {
    gtk_init();
    ui_build(0);

    on_plus(0, 0);
    on_plus(0, 0);
    on_minus(0, 0);
    puts("count=");
    puts(gtk_label_get_text(l_count));
    puts("\n");

    gtk_editable_set_text(e_name, "hello mc");
    on_entry_activate(e_name, 0);
    puts("echo=");
    puts(gtk_label_get_text(l_echo));
    puts("\n");
    puts("rows=");
    putnum(gtk_list_box_length(lb_items));
    puts("\n");

    gtk_check_button_set_active(c_step2, 1);
    on_plus(0, 0);
    puts("count=");
    puts(gtk_label_get_text(l_count));
    puts("\n");

    gtk_editable_set_text(e_name, "second");
    on_entry_activate(e_name, 0);
    puts("rows=");
    putnum(gtk_list_box_length(lb_items));
    puts("\n");

    uptr about = ui_about_new();
    puts("about=");
    puts(gtk_window_get_title(about));
    puts("\n");

    puts("ok\n");
    return 0;
}

i64 main(i64 argc, uptr argv) {
    if (argc > 1) {
        if (ui_streq(ld64(argv + 8), "--self-test")) return ui_self_test();
    }
    // GtkApplication calls gtk_init() itself during startup, so the app path
    // does not. argc/argv are deliberately 0: with G_APPLICATION_DEFAULT_FLAGS
    // GApplication would refuse this program's own --self-test flag, and
    // g_application_run documents argc == 0 with a NULL argv as valid.
    uptr app = gtk_application_new("dev.minicompiler.desktop", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect_data(app, "activate", &on_activate, 0, 0, 0);
    i64 status = (u32) g_application_run(app, 0, 0);
    g_object_unref(app);
    return status;
}
