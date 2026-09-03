// lang.mc — the `lx` language, taught to `mc` from outside `src/`.
//
// This file is not compiled as a program: it is linked INSIDE a compiler
// (`mc build` writes `build/mc-lang.mc` = `#include <mc/core>` + this file) and
// runs during the parse of a `.lx` source. Nothing here touches `src/`; every
// registration below is a public hook from M12 and M21, and everything the
// language produces is an ordinary `mc` declaration handed to the core through
// `top_add`.
//
//   class / interface / namespace / import / using / fn   syntax        (M12)
//   {  while  for  <every class and interface name>       syntax_stmt   (M12)
//   every statement, for the reference counting            on_stmt       (M21.5)
//   new  ref  <every generic function name>               syntax_expr   (M21)
//   .  [                                                  syntax_infix  (M21)
//   str  bool  <every class and interface name>           type_alias    (M12)
//   the body of a generic, replayed per argument tuple    p_skip_balanced,
//                                                         p_push_source,
//                                                         p_subst_*,
//                                                         p_resplit_punct (M21)
//
// See README.md for the language and docs/surface.md § Tier 3 for the hooks.

#include "lang_tab.mc"
#include "lang_util.mc"
#include "lang_type.mc"
#include "lang_class.mc"
#include "lang_stmt.mc"
#include "lang_expr.mc"

void user_init() {
    lg_cur_ns  = "";
    lg_cur_cls = -1;
    lg_fn_rcls = -1;
    lg_fn_rif  = -1;
    lg_file    = "lx";

    // the two aliases the language leans on. A class or an interface adds one
    // of these per name, at the point it is declared.
    type_alias("str",  TY_UPTR);
    type_alias("bool", TY_U8);

    // punctuation the language needs and the core does not have. tok_add is
    // idempotent, so the `#token "+="` in lib/prelude.lx lands on the same id.
    lg_tok_dot       = tok_add(".", 1);
    lg_tok_arrow     = tok_add("->", 2);
    lg_tok_addassign = tok_add("+=", 2);
    lg_tok_subassign = tok_add("-=", 2);

    syntax("class",     &lg_class);
    syntax("interface", &lg_interface);
    syntax("namespace", &lg_namespace);
    syntax("import",    &lg_import);
    syntax("using",     &lg_using);
    syntax("fn",        &lg_fn);
    lg_tok_fn = word_id("fn", 2);

    // M21.5: every statement the parser produces, wherever it produced it. The
    // memory model hangs off this instead of the three hand-written calls
    // lg_block, lg_while and lg_for used to make.
    on_stmt(&lg_on_stmt);

    // K_LBRACE is 272, outside the core keywords word_add refuses, so the
    // module owns every block -- which is what makes the release of a reference
    // happen per scope instead of per function. Since M21.5 that includes the
    // blocks nobody wrote in a statement position: a function body and the
    // `block $b` hole of a `#rule` come through parse_block, which dispatches here.
    syntax_stmt("{",     &lg_block);
    syntax_stmt("while", &lg_while);
    syntax_stmt("for",   &lg_for);

    syntax_expr("new", &lg_new);
    syntax_expr("ref", &lg_ref);
    lg_tok_ref = word_id("ref", 3);

    syntax_infix(".", 12, &lg_dot);
    syntax_infix("[", 13, &lg_index);
}
