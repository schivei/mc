// objswap.mc — a module that re-registers the HOST pair with a different
// OBJECT backend, and nothing else.
//
// The single-file CLI's default object backend is the obj slot of
// `target(host_os(), host_arch(), ...)`. Until the post-M41 review batch
// src/cli.mc resolved it while the flags were being read -- BEFORE `user_init()`
// -- so this registration was read too late and `mc x.mc -o x.o` silently wrote
// the format the compiler was born with. `mc build` never had the defect: the
// driver resolves the pair inside `drv_parse`, after `user_init()` (M39.5).
//
// The swap has to be OBSERVABLE on any host, so the module picks a format the
// host does not use: ELF everywhere, Mach-O on Linux. The first four bytes of
// the object are the whole assertion (scripts/check-build.sh).
//
// The exe slot is copied out of the registry unchanged: this module is about
// one slot, and `--exe` must keep working exactly as it did.
void user_init() {
    i64 h = target_find(host_os(), host_arch());
    if (h < 0) die2("the host is not a registered target", host_os());
    uptr b = "elf-obj";
    if (str_eq(host_os(), "linux")) b = "macho";
    target(host_os(), host_arch(), b, tgt_exe_at(h));
}
