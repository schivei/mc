#include "lib/sqlite.mc"

i64 main() {
    // Tests that the binding with libsqlite3 works
    // sqlite3_open comes from #dylib
    putnum(42);
    putnum(10);
    return 0;
}
