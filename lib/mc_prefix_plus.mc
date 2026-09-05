// mc_prefix_plus.mc -- a whole taught compiler, in the same two-line shape as
// lib/mc_syntax_demo.mc, existing only so docs/reference/hooks.md § 4 can
// compile its parse_unary() example through `make check-docs`
// (`taught=lib/mc_prefix_plus.mc`). Not in tools/bundle.list, following the
// M41 precedent for check-script-only modules (lib/user_core_min.mc and
// friends): nothing in the repository includes it by name, so it never
// touches src/bundle_data.mc or the goldens.
//
// The whole point is the handler: a prefix `+` taught from OUTSIDE the parser,
// through syntax_expr() and the public parse_unary(). `+x` reaches
// parse_primary() (there is no core prefix `+`), where this handler fires; it
// consumes the operator and parses ONE operand at unary precedence -- exactly
// what a `#prefix` template does for `-`/`!`/`~`/`&` inside the core.
#include "../src/host_macos.mc"
#include "../src/core.mc"

i64 pp_plus() {
    p_next();                // the `+` token
    return parse_unary();    // +x, ++x, +-x ... one operand, unary precedence
}

void user_init() {
    syntax_expr("+", &pp_plus);
}
