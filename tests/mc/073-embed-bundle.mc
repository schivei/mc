// expect-exit: 0
// expect-stdout: hello from the bundle
// `#embed` inside a BUNDLED include: <embed_demo> is served from the binary and
// its own `#embed demo_payload "embed_demo.txt"` is served from the bundle too.
// Before the fix, do_embed always joined the path against the CURRENT file's
// name -- which for a bundled level is a bundle name, not a directory -- and the
// compiler died with `mc: cannot open: embed_demo.txt`.
#include <sys>
#include <embed_demo>

i64 main() {
    if (demo_payload_size != demo_payload_raw) return 1;
    if (demo_payload_size != 22) return 2;
    write(1, demo_payload, demo_payload_size);
    return 0;
}
