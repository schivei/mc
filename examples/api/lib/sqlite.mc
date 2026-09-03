// sqlite.mc — ligacao com a libsqlite3 do sistema, pela diretiva #dylib do M12.
//
// Antes do M12 o unico jeito de chamar uma dylib que nao fosse a libSystem era
// linkar com o `ld`. Com `#dylib "caminho"` o proprio `mc --exe` emite o
// LC_LOAD_DYLIB e o bind opcode com o ordinal certo — ver docs/surface.md.
//
// O caminho nao precisa existir em disco: no macOS moderno a libsqlite3 vive no
// dyld shared cache. O `.o` + `ld` ignora `#dylib` (mesma troca do M11).
//
//   #include "lib/sqlite.mc"

#include "rt.mc"

#define SQLITE_OK    0
#define SQLITE_ROW   100
#define SQLITE_DONE  101

// sqlite3_bind_text: o destrutor SQLITE_TRANSIENT e (void*)-1 e manda a libsqlite3
// copiar o texto na hora — assim o buffer do chamador pode morrer logo depois.
#define SQLITE_TRANSIENT 0 - 1

#dylib "/usr/lib/libsqlite3.dylib"

extern i64  sqlite3_open(uptr path, uptr ppdb);
extern i64  sqlite3_close(uptr db);
extern i64  sqlite3_exec(uptr db, uptr sql, uptr cb, uptr arg, uptr perrmsg);
extern i64  sqlite3_prepare_v2(uptr db, uptr sql, i64 nbyte, uptr ppstmt, uptr ptail);
extern i64  sqlite3_step(uptr stmt);
extern i64  sqlite3_finalize(uptr stmt);
extern i64  sqlite3_bind_int(uptr stmt, i64 idx, i64 v);
extern i64  sqlite3_bind_text(uptr stmt, i64 idx, uptr s, i64 n, uptr dtor);
extern i64  sqlite3_column_int(uptr stmt, i64 col);
extern uptr sqlite3_column_text(uptr stmt, i64 col);
extern uptr sqlite3_errmsg(uptr db);
extern i64  sqlite3_last_insert_rowid(uptr db);
extern i64  sqlite3_changes(uptr db);

// volta para a libSystem: sem este reset todo extern declarado depois de um
// #include "sqlite.mc" iria parar na libsqlite3
#dylib ""

// ---- wrappers ----
// O handle da conexao e do statement saem por ponteiro-para-ponteiro na API do
// SQLite; aqui o endereco vem de um `uptr` local (`&h`), e o wrapper devolve o
// handle direto — 0 quer dizer erro.

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

// roda um SQL sem resultado; devolve SQLITE_OK ou o codigo de erro
i64 db_exec(uptr db, uptr sql) {
    return sqlite3_exec(db, sql, 0, 0, 0);
}

// compila o SQL; 0 = erro (a mensagem sai em db_errmsg). nbyte = -1: ate o NUL
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

// parametros sao 1-indexados na API do SQLite
i64 db_bind_int(uptr stmt, i64 idx, i64 v) {
    return sqlite3_bind_int(stmt, idx, v);
}

i64 db_bind_text(uptr stmt, i64 idx, uptr s) {
    return sqlite3_bind_text(stmt, idx, s, str_len(s), SQLITE_TRANSIENT);
}

// colunas sao 0-indexadas
i64 db_col_int(uptr stmt, i64 col) {
    return sqlite3_column_int(stmt, col);
}

// texto da coluna; NULL vira string vazia para o chamador nao precisar testar
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
