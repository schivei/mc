// lib_test.mc — aceite das tres bibliotecas de examples/api/lib.
//
//   sem argumento : parte SQLite — cria /tmp/mc_api_libtest.db, CREATE TABLE,
//                   dois INSERT com bind_text/bind_int, um SELECT com
//                   column_text/column_int, confere o conteudo e sai 0.
//   <porta>       : parte HTTP — sobe o servidor na porta, responde uma unica
//                   requisicao (GET / devolve "ok") e sai 0.
//
// So o mc auto-hospedado compila este arquivo: o stage0 nao conhece #dylib.
//   build/mc1 --exe examples/api/tests/lib_test.mc -o build/lib_test

#include "../lib/rt.mc"
#include "../lib/sqlite.mc"
#include "../lib/http.mc"

// depois do `#dylib ""` de sqlite.mc este extern volta para a libSystem
extern i64 unlink(uptr path);

void perr(uptr s) {
    write(2, s, str_len(s));
}

// imprime a falha em stderr e devolve 1, para o chamador usar em `return`
i64 falha(uptr msg) {
    perr("FALHA: ");
    perr(msg);
    perr("\n");
    return 1;
}

// ---- parte 1: SQLite ----

// INSERT com bind_text/bind_int; devolve o rowid ou 0 em erro
i64 insere(uptr db, uptr nome, i64 n) {
    uptr s = db_prepare(db, "INSERT INTO t (nome, n) VALUES (?, ?);");
    if (s == 0) return 0;
    db_bind_text(s, 1, nome);
    db_bind_int(s, 2, n);
    i64 rc = db_step(s);
    db_finalize(s);
    if (rc != SQLITE_DONE) return 0;
    return db_last_id(db);
}

i64 teste_sqlite() {
    unlink("/tmp/mc_api_libtest.db");
    uptr db = db_open("/tmp/mc_api_libtest.db");
    if (db == 0) return falha("db_open");

    if (db_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, nome TEXT, n INTEGER);") != SQLITE_OK)
        return falha(db_errmsg(db));

    i64 id1 = insere(db, "alfa", 40);
    if (id1 != 1) return falha("primeiro INSERT");
    i64 id2 = insere(db, "beta", 2);
    if (id2 != 2) return falha("segundo INSERT");

    uptr sel = db_prepare(db, "SELECT nome, n FROM t ORDER BY id;");
    if (sel == 0) return falha(db_errmsg(db));
    uptr b = sb_new(64);
    i64 linhas = 0;
    i64 soma = 0;
    while (db_step(sel) == SQLITE_ROW) {
        if (linhas > 0) sb_put(b, ',');
        sb_puts(b, db_col_text(sel, 0));
        sb_put(b, '=');
        sb_putnum(b, db_col_int(sel, 1));
        soma = soma + db_col_int(sel, 1);
        linhas++;
    }
    db_finalize(sel);

    puts("sqlite: ");
    puts(sb_str(b));
    puts("\n");

    if (linhas != 2) return falha("numero de linhas do SELECT");
    if (!str_eq(sb_str(b), "alfa=40,beta=2")) return falha("conteudo do SELECT");
    if (soma != 42) return falha("soma das colunas inteiras");

    if (db_exec(db, "DELETE FROM t WHERE nome = 'beta';") != SQLITE_OK)
        return falha(db_errmsg(db));
    if (db_changes(db) != 1) return falha("db_changes depois do DELETE");

    db_close(db);
    puts("sqlite: ok\n");
    return 0;
}

// ---- parte 2: HTTP ----

i64 serve(i64 port) {
    i64 fd = http_listen(port);
    if (fd < 0) return falha("http_listen");

    uptr req = http_req_new();
    i64 cfd = http_accept(fd);
    if (cfd < 0) {
        close(fd);
        return falha("http_accept");
    }
    if (!http_read_request(cfd, req)) {
        close(cfd);
        close(fd);
        return falha("http_read_request");
    }

    puts("http: ");
    puts(req_method(req));
    puts(" ");
    puts(req_path(req));
    puts(" clen=");
    putnum(req_clen(req));
    puts(" corpo=[");
    puts(req_body(req));
    puts("]\n");

    i64 ok = 0;
    if (str_eq(req_method(req), "GET") && str_eq(req_path(req), "/"))
        ok = http_respond(cfd, 200, "text/plain", "ok");
    else
        ok = http_respond(cfd, 404, "text/plain", "nao encontrado");

    close(cfd);
    close(fd);
    if (!ok) return falha("http_respond");
    puts("http: ok\n");
    return 0;
}

i64 main(i64 argc, uptr argv) {
    if (argc > 1) return serve(atoi(ld64(argv + 8)));
    return teste_sqlite();
}
