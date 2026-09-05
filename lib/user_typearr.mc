// user_typearr.mc — the smallest module that teaches something in the type
// position: `i64[]`, a suffix on a word the core owns.
//
// It is here for a reason lib/user_syntax_demo.mc cannot cover. The demo also
// registers a syntax_param handler, and that handler claims every typed
// parameter, so in the demo compiler a parameter's type is read by the MODULE
// (through the public p_type()) and the core's own site inside parse_params is
// never the one that answers. This module registers syntax_type and nothing
// else, so all six sites are the core's: p_type(), a local, a cast, a
// parameter, an `extern` and a top-level declaration.
//
// The type is a pointer-sized handle -- 8 bytes, TK_INT, so the core's
// operators fit it and ld64/st64 work on it unchanged. Everything a real
// container would carry is left out on purpose: what is being shown is the
// grammar position, not a library.
i64 ta_arr = 0;

i64 ta_type(i64 ty) {
    if (ty != TY_I64) return 0;                  // only i64 has an array form here
    if (p_id() != K_LBRACK) return 0;            // no suffix: not ours, `ty` stands
    p_next();
    p_expect(K_RBRACK, "expected ] after i64[");
    return ta_arr;
}

void user_init() {
    ta_arr = type_new("i64[]", 8, 8, TK_INT);
    syntax_type(&ta_type);
}
