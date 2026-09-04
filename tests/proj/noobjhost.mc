// noobjhost.mc — a module that leaves the HOST pair with NO object backend:
// `target(os, arch, 0, exe)`.
//
// tests/proj/noobj.mc registers the same shape on a target of its own and is
// reached through `mc build`; this one puts it where the single-file CLI looks,
// which is the other entry point into the same registry. A 0 there is a
// REGISTRATION -- what a board whose flat image is the whole artefact writes
// (examples/kernel) -- and until the post-M41 review batch it reached
// backend_find(), whose str_eq dereferenced it: SIGSEGV, exit 139, with no
// message at all. It is a diagnostic now, and `--exe` -- the advice the message
// gives -- is the road the same compiler still has, when the host has one.
//
// The exe slot is copied out of the registry unchanged, so on a host with a
// direct executable the advice can be proved and not just asserted.
//
// Used by scripts/check-build.sh.
void user_init() {
    i64 h = target_find(host_os(), host_arch());
    if (h < 0) die2("the host is not a registered target", host_os());
    target(host_os(), host_arch(), 0, tgt_exe_at(h));
}
