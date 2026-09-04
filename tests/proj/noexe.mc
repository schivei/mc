// noexe.mc — a module whose only job is to leave the HOST's target with NO
// direct-executable backend: `target(os, arch, obj, 0)`.
//
// It is the mirror of tests/proj/noobj.mc, for the other slot and the other
// entry point. `--exe` is a single-file CLI flag, and until the post-M41
// review batch it was written in src/cli.mc as the literal backend name
// `macho-exe`: a Linux- or Windows-hosted `mc --exe` produced a Mach-O binary
// its own kernel refuses. The flag resolves the host pair's exe slot now, and
// a 0 there is a registration meaning "this target has no direct executable"
// -- exactly what src/core_writers.mc registers for linux and for windows.
//
// A host that has no exe backend cannot BUILD this compiler with `--exe`, so
// the case is reached the way M39.5 reached the object one: the host pair is
// re-registered here (last registration wins) with the object backend it
// already had -- read out of the registry, so this module names no backend and
// works on any host -- and the exe slot emptied.
//
// Used by scripts/check-build.sh.
void user_init() {
    i64 h = target_find(host_os(), host_arch());
    if (h < 0) die2("the host is not a registered target", host_os());
    target(host_os(), host_arch(), tgt_obj_at(h), 0);
}
