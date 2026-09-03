// user_dupop.mc — the negative case of decision 7.3 of docs/specs/M21.md:
// teaching the same operator twice is an error, not an override. Like a
// repeated `#define` or two `#rule`s with the same dispatch literal, the second
// registration is a mistake, and the compiler says so before reading the first
// token of any source:
//
//   mc: operator already taught: .+
//
// scripts/check-surface.sh wires this file into src/user.mc, builds the
// compiler and checks that it refuses to start. `#infix` on the same token is a
// different case and is NOT an error: it goes through infix_set, which drops
// the handler (tests/err/066-infix-drops-handler.mc).
i64 dup_add(i64 left) { return left; }

void user_init() {
    syntax_infix(".+", 9, &dup_add);
    syntax_infix(".+", 9, &dup_add);
}
