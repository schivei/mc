// win.mc — the Windows half of the stub proof (M25, scripts/check-stubs.sh).
//
// Two libraries, and `mc` has to write an import file for each: kernel32,
// which <sys_windows> reaches for its I/O and which every extern that nothing
// claims defaults to, and user32, which [externs] in stub-windows.toml maps
// `MessageBox*` to. The MessageBoxA call is guarded by `if (0)` -- it must be
// LINKED, which is what proves the synthesized user32.lib resolves it, and it
// must not pop a dialog if anyone ever runs this.
#include <sys_windows>

extern i64 MessageBoxA(uptr hwnd, uptr text, uptr caption, i64 type);

i64 main() {
    if (0) MessageBoxA(0, "hi", "mc", 0);
    write(1, "windows stub\n", 13);
    return 0;
}
