// user_uptr2.mc — a compiler whose pointers are two bytes (M41, Acceptance 6).
//
// The probe for the one override of a fixed core decision: a `uptr` local lands
// in a 2-byte frame slot and a `uptr[]` initializer writes 2 bytes per element
// with a 2-byte relocation. The real consumer is M40's AVR module; this file is
// the mechanism on its own, with no machine and no target attached, which is
// what makes it a test and not a demonstration.
void user_init() { type_set_width(TY_UPTR, 2); }
