// gtk.mc — the GTK4 subset this example needs, declared as ordinary `extern`s.
//
// There is NO `#dylib` in this file, and that is the point: which library each
// symbol comes from is said from OUTSIDE the source, by the `[libs]` and
// `[externs]` prefix tables in mc.toml (M14, docs/build.md):
//
//     [libs]                              [externs]
//     gtk4    = ".../libgtk-4.1.dylib"    "gtk_*"           = "gtk4"
//     gobject = ".../libgobject-2.0.0"    "g_signal_*"      = "gobject"
//     gio     = ".../libgio-2.0.0"        "g_object_*"      = "gobject"
//     glib    = ".../libglib-2.0.0"       "g_application_*" = "gio"
//                                         "g_*"             = "glib"
//
// The first pattern that matches wins, in the order the keys are written, which
// is why the `g_*` fallback has to be last. Because `mc --exe` binds every
// imported symbol to a dylib ORDINAL, a wrong mapping is not a warning: dyld
// refuses to start the program with `Symbol not found`. So `otool -L` plus a
// run that prints something is a real check of the table above.
//
// ---- ABI notes (see README.md § ABI) ----
//
// * Everything here is integers and pointers, which is all the `mc` core has.
//   `uptr` is GTK's `gpointer`/`GtkWidget *`/`const char *` — an opaque 8-byte
//   value. GTK strings are NUL-terminated UTF-8, so an `mc` string literal is
//   already a `const char *` and `gtk_label_get_text` comes back as a `uptr`
//   that `puts` (lib/io.mc) prints as is.
//
// * NO VARIADIC FUNCTION IS DECLARED HERE. On Apple's arm64 ABI variadic
//   arguments travel on the stack, which the core does not set up (it only
//   fills x0..x7) — the same reason `lib/sys.mc` uses `creat` instead of the
//   variadic `open`. That rules out `g_object_new`, `g_object_set`,
//   `g_object_get`, `gtk_message_dialog_new`, `g_strdup_printf` and `g_print`;
//   every one of them has a non-variadic replacement used below.
//
// * `gboolean` is a C `int`: the callee leaves it in w0 and the top half of x0
//   is undefined. Until M45 that had to be handled by hand -- a `(u32)` cast at
//   each of the two call sites -- and now it is the DECLARATION that says so:
//   `extern i32 gtk_check_button_get_active(...)` and
//   `extern i32 g_application_run(...)`, and the compiler extends the result
//   itself (docs/reference/language.md § 6). The two casts are gone; the
//   `gtk_check_active` wrapper stays, because 0/1 out of an arbitrary non-zero
//   is still its job.
//
// * A signal handler is an ordinary `mc` function. GTK calls it with
//   (widget, user_data) in x0/x1, so `void on_plus(uptr w, uptr data)` matches
//   a `void` handler exactly and `&on_plus` is the `GCallback`.

// ---- constants ----
#define GTK_ORIENTATION_HORIZONTAL 0
#define GTK_ORIENTATION_VERTICAL 1
#define G_APPLICATION_DEFAULT_FLAGS 0

// ---- lifecycle (gtk4 / gio / gobject) ----
extern void gtk_init();
extern uptr gtk_application_new(uptr app_id, i64 flags);
extern i32  g_application_run(uptr app, i64 argc, uptr argv);   // M45: an int
extern void g_object_unref(uptr obj);

// g_signal_connect(x, sig, cb, data) is a C MACRO over this function; the macro
// does not exist for us, so the six arguments are written out: the last two are
// the GClosureNotify (none) and the GConnectFlags (none).
extern i64 g_signal_connect_data(uptr instance, uptr signal, uptr handler,
                                 uptr data, uptr destroy, i64 flags);

// ---- windows ----
extern uptr gtk_application_window_new(uptr app);
extern uptr gtk_window_new();
extern void gtk_window_set_title(uptr win, uptr title);
extern uptr gtk_window_get_title(uptr win);
extern void gtk_window_set_default_size(uptr win, i64 w, i64 h);
extern void gtk_window_set_child(uptr win, uptr child);
extern void gtk_window_set_titlebar(uptr win, uptr bar);
extern void gtk_window_set_transient_for(uptr win, uptr parent);
extern void gtk_window_set_modal(uptr win, i64 modal);
extern void gtk_window_present(uptr win);
extern void gtk_window_close(uptr win);

// ---- containers ----
extern uptr gtk_box_new(i64 orientation, i64 spacing);
extern void gtk_box_append(uptr box, uptr child);
extern uptr gtk_header_bar_new();
extern uptr gtk_list_box_new();
extern void gtk_list_box_append(uptr list, uptr child);
extern uptr gtk_list_box_get_row_at_index(uptr list, i64 index);

// ---- widgets ----
extern uptr gtk_label_new(uptr text);
extern void gtk_label_set_text(uptr label, uptr text);
extern uptr gtk_label_get_text(uptr label);
extern uptr gtk_button_new_with_label(uptr text);
extern uptr gtk_entry_new();
extern void gtk_entry_set_placeholder_text(uptr entry, uptr text);
extern uptr gtk_editable_get_text(uptr editable);
extern void gtk_editable_set_text(uptr editable, uptr text);
extern uptr gtk_check_button_new_with_label(uptr text);
extern i32  gtk_check_button_get_active(uptr button);          // M45: a gboolean
extern void gtk_check_button_set_active(uptr button, i64 active);
extern void gtk_widget_set_margin_top(uptr w, i64 n);
extern void gtk_widget_set_margin_bottom(uptr w, i64 n);
extern void gtk_widget_set_margin_start(uptr w, i64 n);
extern void gtk_widget_set_margin_end(uptr w, i64 n);

// ---- glib (the `g_*` fallback: neither gobject nor gio claims these) ----
// g_strdup is not decoration. `gtk_editable_get_text` hands back the entry's
// OWN buffer, so clearing the entry before using the text would read freed
// memory; the snapshot plus g_free is the correct sequence.
extern uptr g_strdup(uptr s);
extern void g_free(uptr p);

// ---- the two thin wrappers ----

// gboolean -> 0/1. Since M45 the extension comes from the `i32` declaration and
// not from a cast here; what is left is the normalisation of any non-zero to 1.
i64 gtk_check_active(uptr button) {
    if (gtk_check_button_get_active(button) != 0) return 1;
    return 0;
}

// the same margin on all four sides, which is all this example ever asks for
void gtk_widget_set_margin(uptr w, i64 n) {
    gtk_widget_set_margin_top(w, n);
    gtk_widget_set_margin_bottom(w, n);
    gtk_widget_set_margin_start(w, n);
    gtk_widget_set_margin_end(w, n);
}

// number of rows currently in a GtkListBox: walk until the index is empty.
// GTK has no "count" call, and this reads the real widget instead of a
// counter the program keeps on the side.
i64 gtk_list_box_length(uptr list) {
    i64 n = 0;
    while (gtk_list_box_get_row_at_index(list, n) != 0) {
        n = n + 1;
    }
    return n;
}
