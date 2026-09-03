# `examples/desktop` — composing windows with GTK4 from `mc` (M32)

An `mc` program driving a real desktop toolkit, and then the same application
written in a **UI language taught to the compiler from outside `src/`**.

GTK4 is the toolkit because its C API is made of exactly what `mc` already has:
integers, pointers and function pointers. No struct travels by value, no float
travels in `v0..v7`, and every string is a NUL-terminated UTF-8 `const char *`.
So `extern` + `&fn` + `[libs]`/`[externs]` is the whole binding — nothing was
added to the language for this example, and nothing in `src/` or `stage0/`
changed.

```
../../build/mc1 build examples/desktop                                # Part A
../../build/mc1 build examples/desktop --config examples/desktop/ui.toml   # Part B

examples/desktop/build/desktop                # opens the window
examples/desktop/build/desktop --self-test    # no window, prints, exits 0
examples/desktop/build/desktop-ui --self-test # the DSL version: same output

sh examples/desktop/test.sh                   # everything above, checked
```

Requires Homebrew's `gtk4` (`brew install gtk4`). `test.sh` skips itself with
exit 0 when `pkg-config --exists gtk4` fails, which is how CI stays green: the
GitHub runners have no GTK4 and never open a window.

---

## The files

| file | lines | what it is |
|---|---|---|
| `mc.toml` | 48 | Part A's build: `[libs]` + `[externs]` prefix mapping |
| `lib/gtk.mc` | 132 | the GTK4 subset as `extern`s, plus three thin wrappers |
| `main.mc` | 265 | the application in plain `mc` |
| `ui.toml` | 46 | Part B's build: the taught compiler, then `main.ui` |
| `ui.mc` | 498 | the `window` language, taught with one `syntax()` |
| `main.ui` | 207 | the same application, tree written in that language |
| `test.sh` | 182 | the acceptance test (`make check-desktop`) |
| `README.md` | 406 | this file |

---

## Part A — the plain `mc` binding

The window has a header bar, a counter label with `-` / `+` buttons, a check
button that switches the step from 1 to 2, an entry whose text on Enter is
echoed into a label **and** appended to a list box, and an `About` button that
opens a transient modal second window with a `Close` button.

Every callback is an ordinary `mc` function handed to GTK with `&name` (M10):

```c
void on_plus(uptr w, uptr data) {
    counter = counter + ui_step();
    ui_refresh_count();
}

uptr bplus = gtk_button_new_with_label("+");
g_signal_connect_data(bplus, "clicked", &on_plus, 0, 0, 0);
```

### `[libs]` / `[externs]` — where each symbol lives, said from outside

`lib/gtk.mc` contains **no `#dylib`**. Homebrew splits GTK4 across four
libraries, and `mc.toml` maps them by prefix:

```toml
[libs]
gtk4    = "/opt/homebrew/lib/libgtk-4.1.dylib"
gobject = "/opt/homebrew/lib/libgobject-2.0.0.dylib"
gio     = "/opt/homebrew/lib/libgio-2.0.0.dylib"
glib    = "/opt/homebrew/lib/libglib-2.0.0.dylib"

[externs]
"gtk_*"           = "gtk4"
"g_signal_*"      = "gobject"
"g_object_*"      = "gobject"
"g_application_*" = "gio"
"g_*"             = "glib"
```

The first pattern that matches wins, in the order the keys are written, which is
the whole reason the `g_*` fallback is last: written first it would swallow
`g_signal_connect_data`, `g_object_unref` and `g_application_run`. The fallback
is not decoration either — `g_strdup` and `g_free` really are in `libglib`, and
really are needed (see the ABI notes below).

This is a **checkable** claim, not a stylistic one. `mc --exe` binds every
imported symbol to a dylib **ordinal** (M11), so a wrong row here is not a
warning: dyld refuses to start the program with `Symbol not found`. A run that
prints anything at all has already proved the table.

```
$ otool -L build/desktop
build/desktop:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/opt/homebrew/lib/libgtk-4.1.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/opt/homebrew/lib/libgobject-2.0.0.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/opt/homebrew/lib/libgio-2.0.0.dylib (compatibility version 1.0.0, current version 1356.0.0)
	/opt/homebrew/lib/libglib-2.0.0.dylib (compatibility version 1.0.0, current version 1356.0.0)
```

There is no `ld` and no `pkg-config` in the build itself — `mc build` writes the
signed executable directly, and `pkg-config` only appears in `test.sh`, as the
guard that decides whether to run at all.

### `--self-test`

The CI-safe check: build the widget tree, call the handlers by hand, print, exit
0. It never calls `g_application_run`, so no main loop and no window. It does
call `gtk_init()` — widgets need the display — which is what makes it require a
real GTK4 install and a session.

Everything printed is **read back out of the widgets** (`gtk_label_get_text`,
`gtk_list_box_get_row_at_index`), never out of a variable the program keeps on
the side, so the test would fail if the tree were never wired up:

```
$ build/desktop --self-test
count=1              # on_plus, on_plus, on_minus with step 1
echo=hello mc        # the entry set programmatically, then on_entry_activate
rows=1               # ... which also appended a row to the list box
count=3              # the check button turned on: step 2
rows=2               # a second entry
about=About          # the second window built (not presented)
ok
```

### ABI notes

* **No variadic function is bound.** On Apple's arm64 ABI variadic arguments
  travel on the stack, which the core does not set up — it only fills `x0..x7`.
  This is the same limit that makes `lib/sys.mc` use `creat` instead of the
  variadic `open`. Avoided, with what replaced each:

  | avoided | why | used instead |
  |---|---|---|
  | `g_object_new(type, first_prop, ...)` | variadic property list | the typed constructors: `gtk_window_new`, `gtk_label_new`, `gtk_entry_new`, … |
  | `g_object_set` / `g_object_get` | variadic property list | the typed setters: `gtk_label_set_text`, `gtk_window_set_title`, … |
  | `gtk_message_dialog_new(..., format, ...)` | variadic, printf-style | a plain `gtk_window_new` + a box + a label, which is the second window |
  | `g_strdup_printf(format, ...)` | variadic | `ui_itoa` written in `mc`, into a local `u8 buf[24]` |
  | `g_print(format, ...)` | variadic | `puts`/`putnum` from `lib/io.mc`, on `write(2)` |
  | `g_signal_connect(x, s, cb, d)` | a C **macro**, which we do not have | `g_signal_connect_data(x, s, cb, d, 0, 0)`, the real function it expands to |

* **`gboolean` is a C `int`.** The callee leaves it in `w0` and the top half of
  `x0` is undefined, so reading it as `i64` is not safe. `gtk_check_active` in
  `lib/gtk.mc` exists only to do the `(u32)` cast, and `g_application_run`'s
  status goes through the same cast in `main`.

* **A signal handler is an ordinary `mc` function.** GTK calls it with
  `(widget, user_data)` in `x0`/`x1`, so `void on_plus(uptr w, uptr data)`
  matches a `void`-returning handler exactly. A handler GTK expects to return
  `gboolean` would need an `i64` returning 0/1 — none is used here.

* **Strings are UTF-8 `const char *`.** An `mc` string literal already is one,
  and `gtk_label_get_text` comes back as a `uptr` that `puts` prints as is.

* **Ownership matters in one place.** `gtk_editable_get_text` hands back the
  entry's *own* buffer, and `on_entry_activate` clears the entry as its last
  act. The text is therefore snapshotted with `g_strdup` and released with
  `g_free` — the one place the `g_*` glib fallback earns its row in the table.

* **`argc`/`argv` are deliberately 0/NULL** in `g_application_run`. With
  `G_APPLICATION_DEFAULT_FLAGS` a `GApplication` parses the command line itself
  and would reject this program's own `--self-test`; `g_application_run`
  documents `argc == 0` with a `NULL` `argv` as valid.

---

## Part B — a UI language taught by the surface

`ui.mc` is not compiled as a program. `mc build` links it **inside a compiler**
(`build/mc-ui.mc` = `#include <mc/core>` + `#include "../ui.mc"`) and it runs
during the parse of `main.ui`. One registration is the whole language:

```c
void user_init() {
    ui_tok_arrow = tok_add("->", 2);
    syntax("window", &ui_window);
}
```

The grammar:

```
window NAME "title" [size W H] [-> destroy_handler] { ELEMENT... }

ELEMENT := header ;
         | vbox [NAME] [spacing N] [margin N] { ELEMENT... }
         | hbox [NAME] [spacing N] [margin N] { ELEMENT... }
         | label  [NAME] "text" ;
         | button [NAME] "text" [-> handler] ;                  "clicked"
         | entry  [NAME] [placeholder "text"] [-> handler] ;     "activate"
         | check  [NAME] "text" [-> handler] ;                   "toggled"
         | list   [NAME] [-> handler] ;                     "row-activated"
```

`main.ui`'s tree, in full:

```
window w_main "mc desktop" size 360 440 {
    header;
    vbox root spacing 12 margin 12 {
        label l_count "0";
        hbox spacing 6 {
            button "-" -> on_minus;
            button "+" -> on_plus;
        }
        check c_step2 "step by two";
        entry e_name placeholder "type and press Enter" -> on_entry_activate;
        label l_echo "";
        list lb_items;
        button "About" -> on_about;
    }
}
```

### How it lowers

The handler does **not** build AST nodes by hand. It reads the block, writes
ordinary `mc` source into an arena buffer, and hands that buffer back to the
parser with `p_push_source` (M21) — the documented pattern for a `syntax`
handler that produces declarations:

```c
i64 d0 = p_depth();
p_push_source(ui_frame(name, fl, line), buf_p(src), buf_len(src));
p_next();                                    // the lookahead contract
loop {
    if (p_depth() == d0) break;
    top_add(parse_top());
}
```

A widget written with a NAME becomes a `uptr` global of that name, so a handler
reaches it exactly as it would in `main.mc`; an unnamed widget gets a generated
local `ui_tN`, because nothing outside the tree ever needs it. This is the
verbatim text the block above produces:

```c
uptr w_main;
uptr root;
uptr l_count;
uptr c_step2;
uptr e_name;
uptr l_echo;
uptr lb_items;
void ui_build_w_main(uptr app) {
    if (app != 0) { w_main = gtk_application_window_new(app); } else { w_main = gtk_window_new(); }
    gtk_window_set_title(w_main, "mc desktop");
    gtk_window_set_default_size(w_main, 360, 440);
    gtk_window_set_titlebar(w_main, gtk_header_bar_new());
    root = gtk_box_new(1, 12);
    gtk_widget_set_margin(root, 12);
    l_count = gtk_label_new("0");
    gtk_box_append(root, l_count);
    uptr ui_t0 = gtk_box_new(0, 6);
    uptr ui_t1 = gtk_button_new_with_label("-");
    g_signal_connect_data(ui_t1, "clicked", &on_minus, 0, 0, 0);
    gtk_box_append(ui_t0, ui_t1);
    uptr ui_t2 = gtk_button_new_with_label("+");
    g_signal_connect_data(ui_t2, "clicked", &on_plus, 0, 0, 0);
    gtk_box_append(ui_t0, ui_t2);
    gtk_box_append(root, ui_t0);
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
    uptr ui_t3 = gtk_button_new_with_label("About");
    g_signal_connect_data(ui_t3, "clicked", &on_about, 0, 0, 0);
    gtk_box_append(root, ui_t3);
    gtk_window_set_child(w_main, root);
}
```

and it arrives in the unit as ordinary declarations:

```
$ build/mc-ui --dump-ast main.ui | sed -n '269,283p'
GLOBAL type=uptr name=w_main
GLOBAL type=uptr name=root
GLOBAL type=uptr name=l_count
GLOBAL type=uptr name=c_step2
GLOBAL type=uptr name=e_name
GLOBAL type=uptr name=l_echo
GLOBAL type=uptr name=lb_items
FUNC name=ui_build_w_main
  PARAM type=uptr name=app
  BLOCK
    IF
      BINARY op=!=
        IDENT type=i64 name=app
        INT val=0 type=i64
      BLOCK
        ASSIGN name=w_main
          CALL type=i64 name=gtk_application_window_new
```

### Error attribution costs nothing

`p_push_source` binds the module's own frame name to the pushed text, and
`err_at` prints it. A mistake inside a `window` block is blamed on the window
it came from, with the line **inside the generated source**:

```
$ build/mc-ui bad.ui -o bad.o          # `label strlen "x";` inside window w
w (ui) from bad.ui:3:2: global name declared twice
```

### The split between the DSL and the program

Only the tree moved. Everything below the two `window` blocks in `main.ui` is
the same source as `main.mc`, line for line, except two functions that exist
only to call the generated builders:

```c
uptr ui_about_new() { ui_build_w_about(0); return w_about; }
void ui_build(uptr app) { ui_build_w_main(app); }
```

`transient-for` and `modal` are deliberately **not** in the language: they are
policy about how a window is used, not shape, and they stay in `on_about` in
both programs.

### The default compiler refuses it

```
$ ../../build/mc1 main.ui -o /tmp/x.o
main.ui:29: type expected at top level
```

`window` belongs to `ui.mc`, not to the language — which is the point of Tier 3
(`docs/surface.md`).

---

## `make check-desktop`

`test.sh` does six things: builds both, runs both self-tests and diffs them
against each other and against the expected seven lines, checks `otool -L` and
`codesign --verify` on both, checks that the default compiler refuses `main.ui`,
and finally launches each real application for 3 seconds and kills it with
`SIGTERM` — a clean `exit 143` is the proof that the GTK main loop really
started. Set `MC_DESKTOP_NO_GUI=1` to skip only that last step on a machine that
has the libraries but no window server.

```
$ sh examples/desktop/test.sh
== GTK4 4.22.4 ==
== mc build (Part A: main.mc, Part B: main.ui) ==
compile main.mc -> build/desktop
compiler build/mc-ui.mc -> build/mc-ui
compile main.ui -> build/desktop-ui
  ok    .../build/desktop (37444 bytes)
  ok    .../build/mc-ui (493346 bytes)
  ok    .../build/desktop-ui (37543 bytes)
== --self-test ==
  ok    part A: 7 lines, exit 0
  ok    part B: 7 lines, exit 0
  ok    part A and part B print the same self-test output
== otool -L / codesign ==
  ok    part A: libSystem + the four GTK dylibs
  ok    part A: codesign --verify
  ok    part B: libSystem + the four GTK dylibs
  ok    part B: codesign --verify
== the default compiler refuses main.ui ==
  ok    .../main.ui:29: type expected at top level
== 3-second GUI run (SIGTERM) ==
  ok    part A: main loop ran 3 s, SIGTERM -> exit 143
  ok    part B: main loop ran 3 s, SIGTERM -> exit 143

check-desktop: all checks passed
```

---

## Limits, and what a future milestone would need

* **The library paths are absolute and Homebrew-specific.** `mc.toml` names
  `/opt/homebrew/lib/...` directly. `pkg-config` output cannot reach a TOML
  file today; a `[libs]` value computed by running a program would be a driver
  feature, not an example's.
* **`ui.mc` lowers through text, not through nodes.** That is a virtue here (the
  generated source is readable and the error attribution is free), but it means
  the module cannot look at what the core made of it. A pass over the AST
  afterwards is `pass()` (M10) and would be a separate thing.
* **A window takes exactly one child**, which mirrors `gtk_window_set_child`.
  The handler says so rather than silently keeping the last one.
* **Only `window` is reserved.** `vbox`, `label`, `spacing` and the rest are
  matched by lexeme inside the handler and stay usable as identifiers anywhere
  else in the file. `->` is a real token though (`tok_add`), so it is reserved
  program-wide, exactly like the prelude's `+=`.
* **No `.o` + `ld` path.** `#dylib`/`[libs]` bind by ordinal, which only the
  `--exe` backend implements; an object-file build of this example would need
  the linker flags `pkg-config --libs gtk4` prints, through `[linker]`.
* **Linux** (spec § Acceptance) is not covered here: `[target] os = "linux"`
  works (M16) but would need a GTK4 sysroot and `[linker]` args, and the
  self-test would still need a display.

## Running it as a macOS application bundle

A bare Mach-O executable has no bundle identifier, so Launch Services, the window manager's app
list and screenshot tools treat it as an anonymous process. `bundle-app.sh` wraps a built binary in
a minimal `.app` (Info.plist with a bundle id, ad-hoc signed):

```sh
sh examples/desktop/bundle-app.sh examples/desktop/build/desktop-ui \
   "examples/desktop/build/mc desktop.app" dev.minicompiler.desktop "mc desktop"
open "examples/desktop/build/mc desktop.app"
```

Visual check (2026-09-03, macOS 26.6, GTK 4.22): the window renders the header bar, the counter,
`+`/`-`, the "step by two" check button, the entry and the About button; clicks delivered to the
window change the counter label. The automated check stays headless (`--self-test`).
