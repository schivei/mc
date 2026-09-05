// user.mc -- the six lines a project writes for every compiler-module package
// it uses. A package never defines user_init (M44 D8): it exports <name>_init()
// and this is where the order is decided.
void user_init() {
    teach_init();
}
