// lib_test.mc — acceptance test for the three examples/api/lib libraries.
//
//   no argument : SQLite part — creates /tmp/mc_api_libtest.db, CREATE TABLE,
//                 two INSERT with bind_text/bind_int, a SELECT with
//                 column_text/column_int, checks the content and exits 0.
//   <port>      : HTTP part — brings the server up on the port, answers a
//                 single request (GET / returns "ok") and exits 0.
//
// Only the self-hosted mc compiles this file: stage0 does not know #dylib.
//   build/mc1 --exe examples/api/tests/lib_test.mc -o build/lib_test

#include "../lib/rt.mc"
#include "../lib/sqlite.mc"
#include "../lib/http.mc"

// after sqlite.mc's `#dylib ""` this extern goes back to libSystem
extern i32 unlink(uptr path);            // M45: a C `int`

void perr(uptr s) {
    write(2, s, str_len(s));
}

// prints the failure to stderr and returns 1, for the caller to use in `return`
i64 fail(uptr msg) {
    perr("FAIL: ");
    perr(msg);
    perr("\n");
    return 1;
}

// ---- part 1: SQLite ----

// INSERT with bind_text/bind_int; returns the rowid or 0 on error
i64 insert(uptr db, uptr name, i64 n) {
    uptr s = db_prepare(db, "INSERT INTO t (name, n) VALUES (?, ?);");
    if (s == 0) return 0;
    db_bind_text(s, 1, name);
    db_bind_int(s, 2, n);
    i64 rc = db_step(s);
    db_finalize(s);
    if (rc != SQLITE_DONE) return 0;
    return db_last_id(db);
}

i64 test_sqlite() {
    unlink("/tmp/mc_api_libtest.db");
    uptr db = db_open("/tmp/mc_api_libtest.db");
    if (db == 0) return fail("db_open");

    if (db_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, n INTEGER);") != SQLITE_OK)
        return fail(db_errmsg(db));

    i64 id1 = insert(db, "alpha", 40);
    if (id1 != 1) return fail("first INSERT");
    i64 id2 = insert(db, "beta", 2);
    if (id2 != 2) return fail("second INSERT");

    uptr sel = db_prepare(db, "SELECT name, n FROM t ORDER BY id;");
    if (sel == 0) return fail(db_errmsg(db));
    uptr b = sb_new(64);
    i64 rows = 0;
    i64 sum = 0;
    while (db_step(sel) == SQLITE_ROW) {
        if (rows > 0) sb_put(b, ',');
        sb_puts(b, db_col_text(sel, 0));
        sb_put(b, '=');
        sb_putnum(b, db_col_int(sel, 1));
        sum = sum + db_col_int(sel, 1);
        rows++;
    }
    db_finalize(sel);

    puts("sqlite: ");
    puts(sb_str(b));
    puts("\n");

    if (rows != 2) return fail("number of rows from the SELECT");
    if (!str_eq(sb_str(b), "alpha=40,beta=2")) return fail("SELECT content");
    if (sum != 42) return fail("sum of the integer columns");

    if (db_exec(db, "DELETE FROM t WHERE name = 'beta';") != SQLITE_OK)
        return fail(db_errmsg(db));
    if (db_changes(db) != 1) return fail("db_changes after the DELETE");

    db_close(db);
    puts("sqlite: ok\n");
    return 0;
}

// ---- part 2: HTTP ----

i64 serve(i64 port) {
    i64 fd = http_listen(port);
    if (fd < 0) return fail("http_listen");

    uptr req = http_req_new();
    i64 cfd = http_accept(fd);
    if (cfd < 0) {
        close(fd);
        return fail("http_accept");
    }
    if (!http_read_request(cfd, req)) {
        close(cfd);
        close(fd);
        return fail("http_read_request");
    }

    puts("http: ");
    puts(req_method(req));
    puts(" ");
    puts(req_path(req));
    puts(" clen=");
    putnum(req_clen(req));
    puts(" body=[");
    puts(req_body(req));
    puts("]\n");

    i64 ok = 0;
    if (str_eq(req_method(req), "GET") && str_eq(req_path(req), "/"))
        ok = http_respond(cfd, 200, "text/plain", "ok");
    else
        ok = http_respond(cfd, 404, "text/plain", "not found");

    close(cfd);
    close(fd);
    if (!ok) return fail("http_respond");
    puts("http: ok\n");
    return 0;
}

i64 main(i64 argc, uptr argv) {
    if (argc > 1) return serve(atoi(ld64(argv + 8)));
    return test_sqlite();
}
