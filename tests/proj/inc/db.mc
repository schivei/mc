// db.mc — reachable ONLY through [include].paths.
//
// tests/proj/app.mc writes `#include "db.mc"`, and this file is not next to it:
// it is in inc/. Without `[include] paths = ["inc"]` in the TOML the build stops
// at `mc: cannot open: tests/proj/db.mc`. That is the whole point of the file.
#include "../../../lib/sys.mc"

// libsqlite3, not libSystem: which one it comes from is decided by [libs] and
// [externs] in the TOML, with no `#dylib` anywhere in this source.
extern uptr sqlite3_libversion();

uptr db_version() { return sqlite3_libversion(); }
