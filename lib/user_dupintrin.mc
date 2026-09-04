// user_dupintrin.mc — a user_init that tries to register an intrinsic named
// after a CORE one. The dispatch res_call and gen_call run puts the core
// intrinsics first, so such a registration could never take effect; it is
// refused where it is made instead of failing silently later.
// scripts/check-surface.sh wires this file in and checks the message.
void user_init() {
    intrinsic("ld64", 1, TY_I64, &user_init);
}
