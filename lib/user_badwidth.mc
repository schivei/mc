// user_badwidth.mc — the refusal half of M41's Acceptance 6: type_set_width
// declares the width of `uptr` and of nothing else. `i64` folds in 64 bits at
// parse time and u8/u16/u32/u64 are their own names; a module that wants a
// different primitive registers one with type_new().
//
// This compiler dies in user_init(), before it reads a byte of any source.
void user_init() { type_set_width(TY_U64, 2); }
