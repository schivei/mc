// sqlite.mc — binding to the system's libsqlite3, via M12's #dylib directive.
//
// Before M12 the only way to call a dylib other than libSystem was to link
// with `ld`. With `#dylib "path"`, `mc --exe` itself emits the LC_LOAD_DYLIB
// and the bind opcode with the right ordinal — see docs/surface.md.
//
// The path does not need to exist on disk: on modern macOS libsqlite3 lives
// in the dyld shared cache. `.o` + `ld` ignores `#dylib` (the same trade-off
// as M11).
//
//   #include "lib/sqlite.mc"

#include "rt.mc"

#define SQLITE_OK    0
#define SQLITE_ROW   100
#define SQLITE_DONE  101

// sqlite3_bind_text: the SQLITE_TRANSIENT destructor is (void*)-1 and tells
// libsqlite3 to copy the text right away — so the caller's buffer can die
// right after.
#define SQLITE_TRANSIENT 0 - 1

#dylib "/usr/lib/libsqlite3.dylib"

// M45: everything SQLite declares `int` is `i32` here. Nothing in this file is
// compiled by the frozen seed, so it says the truthful word rather than
// `u32` + `c_int` the way src/*.mc has to. `sqlite3_last_insert_rowid` returns
// a `sqlite3_int64` and stays `i64`; the two text accessors return pointers.
//
// One behaviour change to know about: `sqlite3_column_int` of a NEGATIVE column
// used to come back as a large positive number and now comes back negative,
// which is what it always was in C (examples/api/README.md).
extern i32  sqlite3_open(uptr path, uptr ppdb);
extern i32  sqlite3_close(uptr db);
extern i32  sqlite3_exec(uptr db, uptr sql, uptr cb, uptr arg, uptr perrmsg);
extern i32  sqlite3_prepare_v2(uptr db, uptr sql, i64 nbyte, uptr ppstmt, uptr ptail);
extern i32  sqlite3_step(uptr stmt);
extern i32  sqlite3_finalize(uptr stmt);
extern i32  sqlite3_bind_int(uptr stmt, i64 idx, i64 v);
extern i32  sqlite3_bind_text(uptr stmt, i64 idx, uptr s, i64 n, uptr dtor);
extern i32  sqlite3_column_int(uptr stmt, i64 col);
extern uptr sqlite3_column_text(uptr stmt, i64 col);
extern uptr sqlite3_errmsg(uptr db);
extern i64  sqlite3_last_insert_rowid(uptr db);
extern i32  sqlite3_changes(uptr db);

// back to libSystem: without this reset every extern declared after a
// #include "sqlite.mc" would end up in libsqlite3
#dylib ""

// ---- wrappers ----
// The connection's and the statement's handles come out via pointer-to-pointer
// in SQLite's API; here the address comes from a local `uptr` (`&h`), and the
// wrapper returns the handle directly — 0 means error.

uptr db_open(uptr path) {
    uptr h = 0;
    i64 rc = sqlite3_open(path, &h);
    if (rc != SQLITE_OK) {
        if (h != 0) sqlite3_close(h);
        return 0;
    }
    return h;
}

i64 db_close(uptr db) {
    return sqlite3_close(db);
}

// runs a SQL statement with no result; returns SQLITE_OK or the error code
i64 db_exec(uptr db, uptr sql) {
    return sqlite3_exec(db, sql, 0, 0, 0);
}

// compiles the SQL; 0 = error (the message comes out via db_errmsg). nbyte = -1: up to the NUL
uptr db_prepare(uptr db, uptr sql) {
    uptr h = 0;
    i64 rc = sqlite3_prepare_v2(db, sql, 0 - 1, &h, 0);
    if (rc != SQLITE_OK) return 0;
    return h;
}

i64 db_step(uptr stmt) {
    return sqlite3_step(stmt);
}

i64 db_finalize(uptr stmt) {
    return sqlite3_finalize(stmt);
}

// parameters are 1-indexed in SQLite's API
i64 db_bind_int(uptr stmt, i64 idx, i64 v) {
    return sqlite3_bind_int(stmt, idx, v);
}

i64 db_bind_text(uptr stmt, i64 idx, uptr s) {
    return sqlite3_bind_text(stmt, idx, s, str_len(s), SQLITE_TRANSIENT);
}

// columns are 0-indexed
i64 db_col_int(uptr stmt, i64 col) {
    return sqlite3_column_int(stmt, col);
}

// column text; NULL becomes an empty string so the caller need not check for it
uptr db_col_text(uptr stmt, i64 col) {
    uptr p = sqlite3_column_text(stmt, col);
    if (p == 0) return "";
    return p;
}

uptr db_errmsg(uptr db) {
    return sqlite3_errmsg(db);
}

i64 db_last_id(uptr db) {
    return sqlite3_last_insert_rowid(db);
}

i64 db_changes(uptr db) {
    return sqlite3_changes(db);
}
