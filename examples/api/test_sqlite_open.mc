#include "lib/sqlite.mc"

i64 main() {
    // Testa que a ligacao com libsqlite3 funciona
    // sqlite3_open eh do #dylib
    putnum(42);
    putnum(10);
    return 0;
}
