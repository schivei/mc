// app.mc — the program `mc build` compiles in tests/proj.
// expect-exit: 0
// expect-stdout: sqlite ok
//
// Three things are being proved here, all of them coming from the TOML and not
// from this source: the include below only resolves through [include].paths;
// sqlite3_libversion is bound to libsqlite3 through [libs] + [externs] (no
// `#dylib` in sight); and the same source builds with the built-in --exe backend
// (exe.toml), through `ld` (link.toml) and as a plain object (obj.toml).
#include "db.mc"

i64 main() {
    uptr v = db_version();
    if (ld8(v) < '0' || ld8(v) > '9') return 1;   // "3.x.y"
    puts("sqlite ok\n");
    return 0;
}
