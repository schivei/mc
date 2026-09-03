// main.mc — a API de todos que so o compilador deste diretorio compila.
//
//   examples/api/build/mc-api --exe main.mc -o build/api
//   build/api 8080 /tmp/todos.db
//
// Rotas (corpo sempre JSON):
//   GET    /health      -> {"ok":true}
//   GET    /todos       -> [{"id":1,"title":"...","done":false}, ...]
//   POST   /todos       -> corpo da requisicao = titulo; devolve o todo criado (201)
//   DELETE /todos/N     -> {"deleted":N}
//   qualquer outra      -> 404 {"error":"not found"}
//
// O que este arquivo demonstra e o Tier 3 inteiro em uso: `class`, `interface`,
// `bool` e `str` sao ensinados por examples/api/oop.mc e por mc-api.mc, nao pelo
// nucleo; a libsqlite3 entra por `#dylib` (M12) e o binario sai direto pelo
// `--exe` (M11), sem `ld`. Com o compilador padrao (`build/mc1`) o arquivo nao
// passa da primeira linha de `class`.
//
// Uma conexao por vez, sem keep-alive: aceita, le, responde, fecha. A memoria
// vem da arena fixa de lib/rt.mc e nunca e devolvida — ver o README e
// docs/specs/M13.md.

#include "lib/rt.mc"
#include "lib/http.mc"
#include "lib/sqlite.mc"

void perr(str s) {
    write(2, s, str_len(s));
}

// ---- JSON ----

// escreve `s` entre aspas com o escape que o JSON exige; bytes de controle que
// nao tem escape proprio sao descartados
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

// {"error":"..."} pronto para uma resposta de erro
str json_err(str msg) {
    uptr b = sb_new(64);
    sb_puts(b, "{\"error\":");
    json_str(b, msg);
    sb_put(b, '}');
    return sb_str(b);
}

// ---- a requisicao e a resposta como objetos ----
// `Request` embrulha a estrutura plana de lib/http.mc: e o mesmo ponteiro, com
// metodos no lugar das acessoras soltas. `Response` guarda o socket e o ultimo
// status enviado, para o log da conexao.

class Request {
    uptr raw;

    str method(self) { return req_method(request_raw(self)); }
    str path(self)   { return req_path(request_raw(self)); }
    str body(self)   { return req_body(request_raw(self)); }
}

class Response {
    i64 fd;
    i64 status;

    // envia `body` como application/json e lembra o status; 1 = ok
    i64 send(self, i64 status, str body) {
        set_response_status(self, status);
        return http_respond(response_fd(self), status, "application/json", body);
    }
}

// ---- o recurso ----

class Todo {
    i64  id;
    str  title;
    bool done;

    // {"id":1,"title":"comprar pao","done":false}
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

// monta um Todo com a linha corrente do statement (colunas id, title, done).
// O texto do SQLite vale ate o proximo step: str_dup copia para a arena.
Todo row_to_todo(uptr q) {
    Todo t = todo_new();
    set_todo_id(t, db_col_int(q, 0));
    set_todo_title(t, str_dup(db_col_text(q, 1)));
    set_todo_done(t, db_col_int(q, 2));
    return t;
}

// ---- o banco ----
// Uma classe em volta dos wrappers de lib/sqlite.mc: o handle mora no objeto e
// os metodos falam de todos, nao de statements.

class Db {
    uptr h;

    // abre o arquivo e garante a tabela; 1 = ok
    i64 init(self, str path) {
        uptr d = db_open(path);
        if (d == 0) return 0;
        set_db_h(self, d);
        if (db_exec(d, "CREATE TABLE IF NOT EXISTS todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0);") != SQLITE_OK)
            return 0;
        return 1;
    }

    // insere e devolve o id novo, ou 0 em erro
    i64 add(self, str title) {
        uptr q = db_prepare(db_h(self), "INSERT INTO todos (title, done) VALUES (?, 0);");
        if (q == 0) return 0;
        db_bind_text(q, 1, title);
        i64 rc = db_step(q);
        db_finalize(q);
        if (rc != SQLITE_DONE) return 0;
        return db_last_id(db_h(self));
    }

    // um todo pelo id, ou 0 se nao existe
    Todo get(self, i64 id) {
        uptr q = db_prepare(db_h(self), "SELECT id, title, done FROM todos WHERE id = ?;");
        if (q == 0) return 0;
        db_bind_int(q, 1, id);
        Todo t = 0;
        if (db_step(q) == SQLITE_ROW) t = row_to_todo(q);
        db_finalize(q);
        return t;
    }

    // a colecao inteira em JSON, na ordem do id
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

    // apaga um id; devolve quantas linhas sairam (0 = nao existia)
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

// ---- os handlers ----
// Uma interface com um metodo so: o roteador guarda `Handler`, nao TodoHandler
// nem HealthHandler, e o despacho sai pela vtable de cada objeto.

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
                return response_send(res, 400, json_err("corpo vazio: o corpo e o titulo"));
            i64 id = db_add(d, titulo);
            if (id == 0) return response_send(res, 500, json_err(db_errmsg(db_h(d))));
            Todo t = db_get(d, id);
            if (t == 0) return response_send(res, 500, json_err("todo criado sumiu"));
            return response_send(res, 201, todo_json(t));
        }

        if (str_eq(m, "DELETE") && str_ncmp(p, "/todos/", 7) == 0) {
            i64 id = atoi(p + 7);
            if (id <= 0) return response_send(res, 400, json_err("id invalido"));
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

// ---- roteamento ----
// Tabela linear de (prefixo, Handler), na ordem de registro; a primeira que casa
// vence. Guardar `Handler` e nao a classe concreta e o ponto do exercicio: o
// laco principal nunca sabe qual handler esta chamando.

#define MAXROTAS 4

uptr rota_pref[MAXROTAS];
uptr rota_hnd[MAXROTAS];
i64  nrotas = 0;

void rota_add(str pref, Handler h) {
    if (nrotas == MAXROTAS) {
        perr("api: rotas demais\n");
        exit(1);
    }
    st64(rota_pref + nrotas * 8, pref);
    st64(rota_hnd + nrotas * 8, h);
    nrotas++;
}

// casa se o caminho e exatamente o prefixo ou comeca com prefixo + '/'
i64 rota_casa(str pref, str path) {
    i64 n = str_len(pref);
    if (str_ncmp(path, pref, n) != 0) return 0;
    i64 c = ld8(path + n);
    return c == 0 || c == '/';
}

Handler rota_find(str path) {
    i64 i = 0;
    while (i < nrotas) {
        if (rota_casa(ld64(rota_pref + i * 8), path)) return ld64(rota_hnd + i * 8);
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

// ---- laco principal ----

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
        perr("uso: api PORTA CAMINHO_DO_BANCO\n");
        return 2;
    }
    i64 port = atoi(ld64(argv + 8));
    str dbpath = ld64(argv + 16);

    Db db = db_new();
    if (!db_init(db, dbpath)) {
        perr("api: nao abriu o banco\n");
        return 1;
    }

    i64 fd = http_listen(port);
    if (fd < 0) {
        perr("api: nao escutou na porta\n");
        return 1;
    }

    TodoHandler th = todohandler_new();
    set_todohandler_db(th, db);
    rota_add("/todos", th);
    rota_add("/health", healthhandler_new());

    puts("api: porta ");
    putnum(port);
    puts(", banco ");
    puts(dbpath);
    puts("\n");

    uptr raw = http_req_new();
    loop {
        i64 cfd = http_accept(fd);
        if (cfd < 0) break;
        if (http_read_request(cfd, raw)) {
            // a query string sai antes de qualquer roteamento: os handlers
            // comparam caminhos, nao caminhos com sufixo
            set_req_path(raw, path_only(req_path(raw)));

            Request rq = request_new();
            set_request_raw(rq, raw);
            Response rs = response_new();
            set_response_fd(rs, cfd);

            str p = request_path(rq);
            Handler h = rota_find(p);
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
