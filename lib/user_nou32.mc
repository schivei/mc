// user_nou32.mc — a compiler with no `u32` (M41, Acceptance 5).
//
// type_disable removes the WORD from the surface: `u32 x;` is refused with
// `u32: removed by this compiler`. The TYPE is untouched -- ld32() still yields
// TY_U32 internally and type_width(TY_U32) is still 4 -- which is the sentence
// docs/reference/hooks.md repeats for exactly this reason.
void user_init() { type_disable(TY_U32); }
