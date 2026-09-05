// user_dupcoreop.mc — lib/user_dupop.mc's case for a CORE operator: teaching `+`
// twice is refused exactly as teaching `.+` twice is, and with the same message:
//
//   mc: operator already taught: +
//
// The first registration is allowed (M41.5): a core operator carries no handler,
// so there is nothing to override. Only the second one is a mistake.
// scripts/check-surface.sh wires this file into src/user.mc, builds the compiler
// and checks that it refuses to start.
i64 dco_add(i64 left) { return left; }

void user_init() {
    syntax_infix("+", 9, &dco_add);
    syntax_infix("+", 9, &dco_add);
}
