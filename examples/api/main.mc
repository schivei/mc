// main.mc — the todos API that only this directory's compiler compiles.
//
//   examples/api/build/mc-api --exe main.mc -o build/api
//   build/api 8080 /tmp/todos.db
//
// Routes (body always JSON):
//   GET    /health      -> {"ok":true}
//   GET    /todos       -> [{"id":1,"title":"...","done":false}, ...]
//   POST   /todos       -> request body = title; returns the created todo (201)
//   DELETE /todos/N     -> {"deleted":N}
//   anything else       -> 404 {"error":"not found"}
//
// What this file demonstrates is the whole Tier 3 in use: `class`,
// `interface`, `bool` and `str` are taught by examples/api/oop.mc and by
// mc-api.mc, not by the core; libsqlite3 comes in via `#dylib` (M12) and the
// binary comes out directly via `--exe` (M11), without `ld`. With the default
// compiler (`build/mc1`) the file does not get past the first `class` line.
//
// One connection at a time, no keep-alive: accept, read, respond, close. The
// memory comes from lib/rt.mc's fixed arena and is never returned — see the
// README and docs/specs/M13.md.

#include "lib/rt.mc"
#include "lib/http.mc"
#include "lib/sqlite.mc"

void perr(str s) {
    write(2, s, str_len(s));
}

// ---- JSON ----

// writes `s` between quotes with the escaping JSON requires; control bytes
// with no escape of their own are dropped
void json_str(uptr b, str s) {
    sb_put(b, '"');
    i64 i = 0;
    while (ld8(s + i) != 0) {
        i64 c = ld8(s + i);
        if (c == '"' || c == '\\') {
            sb_put(b, '\\');
            sb_put(b, c);
        } else if (c == '\n') {
            sb_puts(b, "\\n");
        } else if (c == '\r') {
            sb_puts(b, "\\r");
        } else if (c == '\t') {
            sb_puts(b, "\\t");
        } else if (c >= 32) {
            sb_put(b, c);
        }
        i++;
    }
    sb_put(b, '"');
}

// {"error":"..."} ready for an error response
str json_err(str msg) {
    uptr b = sb_new(64);
    sb_puts(b, "{\"error\":");
    json_str(b, msg);
    sb_put(b, '}');
    return sb_str(b);
}

// ---- the request and the response as objects ----
// `Request` wraps lib/http.mc's flat structure: it is the same pointer, with
// methods in place of the loose accessors. `Response` holds the socket and
// the last status sent, for the connection log.

class Request {
    uptr raw;

    str method(self) { return req_method(request_raw(self)); }
    str path(self)   { return req_path(request_raw(self)); }
    str body(self)   { return req_body(request_raw(self)); }
}

class Response {
    i64 fd;
    i64 status;

    // sends `body` as application/json and remembers the status; 1 = ok
    i64 send(self, i64 status, str body) {
        set_response_status(self, status);
        return http_respond(response_fd(self), status, "application/json", body);
    }
}

// ---- the resource ----

class Todo {
    i64  id;
    str  title;
    bool done;

    // {"id":1,"title":"buy bread","done":false}
    str json(self) {
        uptr b = sb_new(128);
        sb_puts(b, "{\"id\":");
        sb_putnum(b, todo_id(self));
        sb_puts(b, ",\"title\":");
        json_str(b, todo_title(self));
        sb_puts(b, ",\"done\":");
        if (todo_done(self)) sb_puts(b, "true");
        else sb_puts(b, "false");
        sb_put(b, '}');
        return sb_str(b);
    }
}

// builds a Todo from the statement's current row (columns id, title, done).
// SQLite's text is valid only until the next step: str_dup copies it into the arena.
Todo row_to_todo(uptr q) {
    Todo t = todo_new();
    set_todo_id(t, db_col_int(q, 0));
    set_todo_title(t, str_dup(db_col_text(q, 1)));
    set_todo_done(t, db_col_int(q, 2));
    return t;
}

// ---- the database ----
// A class around lib/sqlite.mc's wrappers: the handle lives in the object and
// the methods talk about todos, not statements.

class Db {
    uptr h;

    // opens the file and ensures the table; 1 = ok
    i64 init(self, str path) {
        uptr d = db_open(path);
        if (d == 0) return 0;
        set_db_h(self, d);
        if (db_exec(d, "CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0);") != SQLITE_OK)
            return 0;
        return 1;
    }

    // inserts and returns the new id, or 0 on error
    i64 add(self, str title) {
        uptr q = db_prepare(db_h(self), "INSERT INTO todos (title, done) VALUES (?, 0);");
        if (q == 0) return 0;
        db_bind_text(q, 1, title);
        i64 rc = db_step(q);
        db_finalize(q);
        if (rc != SQLITE_DONE) return 0;
        return db_last_id(db_h(self));
    }

    // a todo by id, or 0 if it does not exist
    Todo get(self, i64 id) {
        uptr q = db_prepare(db_h(self), "SELECT id, title, done FROM todos WHERE id = ?;");
        if (q == 0) return 0;
        db_bind_int(q, 1, id);
        Todo t = 0;
        if (db_step(q) == SQLITE_ROW) t = row_to_todo(q);
        db_finalize(q);
        return t;
    }

    // the whole collection in JSON, ordered by id
    str list(self) {
        uptr b = sb_new(256);
        sb_put(b, '[');
        uptr q = db_prepare(db_h(self), "SELECT id, title, done FROM todos ORDER BY id;");
        if (q == 0) {
            sb_put(b, ']');
            return sb_str(b);
        }
        i64 n = 0;
        while (db_step(q) == SQLITE_ROW) {
            if (n > 0) sb_put(b, ',');
            sb_puts(b, todo_json(row_to_todo(q)));
            n++;
        }
        db_finalize(q);
        sb_put(b, ']');
        return sb_str(b);
    }

    // deletes an id; returns how many rows were removed (0 = did not exist)
    i64 del(self, i64 id) {
        uptr q = db_prepare(db_h(self), "DELETE FROM todos WHERE id = ?;");
        if (q == 0) return 0;
        db_bind_int(q, 1, id);
        i64 rc = db_step(q);
        db_finalize(q);
        if (rc != SQLITE_DONE) return 0;
        return db_changes(db_h(self));
    }
}

// ---- the handlers ----
// An interface with a single method: the router holds `Handler`, not
// TodoHandler or HealthHandler, and dispatch happens via each object's vtable.

interface Handler {
    i64 handle(self, Request req, Response res);
}

class TodoHandler : Handler {
    Db db;

    i64 handle(self, Request req, Response res) {
        str m = request_method(req);
        str p = request_path(req);
        Db d = todohandler_db(self);

        if (str_eq(m, "GET") && str_eq(p, "/todos"))
            return response_send(res, 200, db_list(d));

        if (str_eq(m, "POST") && str_eq(p, "/todos")) {
            str titulo = request_body(req);
            if (str_len(titulo) == 0)
                return response_send(res, 400, json_err("empty body: the body is the title"));
            i64 id = db_add(d, titulo);
            if (id == 0) return response_send(res, 500, json_err(db_errmsg(db_h(d))));
            Todo t = db_get(d, id);
            if (t == 0) return response_send(res, 500, json_err("created todo went missing"));
            return response_send(res, 201, todo_json(t));
        }

        if (str_eq(m, "DELETE") && str_ncmp(p, "/todos/", 7) == 0) {
            i64 id = atoi(p + 7);
            if (id <= 0) return response_send(res, 400, json_err("invalid id"));
            if (db_del(d, id) == 0) return response_send(res, 404, json_err("not found"));
            uptr b = sb_new(64);
            sb_puts(b, "{\"deleted\":");
            sb_putnum(b, id);
            sb_put(b, '}');
            return response_send(res, 200, sb_str(b));
        }

        return response_send(res, 404, json_err("not found"));
    }
}

class HealthHandler : Handler {
    i64 handle(self, Request req, Response res) {
        if (!str_eq(request_method(req), "GET"))
            return response_send(res, 405, json_err("method not allowed"));
        return response_send(res, 200, "{\"ok\":true}");
    }
}

// ---- routing ----
// Linear table of (prefix, Handler), in registration order; the first one
// that matches wins. Holding `Handler` and not the concrete class is the
// point of the exercise: the main loop never knows which handler it is calling.

#define MAXROUTES 4

uptr route_pref[MAXROUTES];
uptr route_hnd[MAXROUTES];
i64  nroutes = 0;

void route_add(str pref, Handler h) {
    if (nroutes == MAXROUTES) {
        perr("api: too many routes\n");
        exit(1);
    }
    st64(route_pref + nroutes * 8, pref);
    st64(route_hnd + nroutes * 8, h);
    nroutes++;
}

// matches if the path is exactly the prefix or starts with prefix + '/'
i64 route_matches(str pref, str path) {
    i64 n = str_len(pref);
    if (str_ncmp(path, pref, n) != 0) return 0;
    i64 c = ld8(path + n);
    return c == 0 || c == '/';
}

Handler route_find(str path) {
    i64 i = 0;
    while (i < nroutes) {
        if (route_matches(ld64(route_pref + i * 8), path)) return ld64(route_hnd + i * 8);
        i++;
    }
    return 0;
}

// "/todos?x=1" -> "/todos"
str path_only(str p) {
    i64 i = str_find(p, "?");
    if (i < 0) return p;
    return str_ndup(p, i);
}

// ---- main loop ----

void log_req(str m, str p, i64 status) {
    puts(m);
    puts(" ");
    puts(p);
    puts(" -> ");
    putnum(status);
    puts("\n");
}

i64 main(i64 argc, uptr argv) {
    if (argc < 3) {
        perr("usage: api PORT DB_PATH\n");
        return 2;
    }
    i64 port = atoi(ld64(argv + 8));
    str dbpath = ld64(argv + 16);

    Db db = db_new();
    if (!db_init(db, dbpath)) {
        perr("api: could not open the database\n");
        return 1;
    }

    i64 fd = http_listen(port);
    if (fd < 0) {
        perr("api: could not listen on the port\n");
        return 1;
    }

    TodoHandler th = todohandler_new();
    set_todohandler_db(th, db);
    route_add("/todos", th);
    route_add("/health", healthhandler_new());

    puts("api: port ");
    putnum(port);
    puts(", db ");
    puts(dbpath);
    puts("\n");

    uptr raw = http_req_new();
    loop {
        i64 cfd = http_accept(fd);
        if (cfd < 0) break;
        if (http_read_request(cfd, raw)) {
            // the query string is stripped before any routing: the handlers
            // compare paths, not paths with a suffix
            set_req_path(raw, path_only(req_path(raw)));

            Request rq = request_new();
            set_request_raw(rq, raw);
            Response rs = response_new();
            set_response_fd(rs, cfd);

            str p = request_path(rq);
            Handler h = route_find(p);
            if (h != 0) handler_handle(h, rq, rs);
            else response_send(rs, 404, json_err("not found"));

            log_req(request_method(rq), p, response_status(rs));
        }
        close(cfd);
    }
    close(fd);
    db_close(db_h(db));
    return 0;
}
