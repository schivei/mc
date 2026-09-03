#include "lib/sqlite.mc"

i64 main() {
    i64 ver = sqlite3_libversion_number();
    putnum(ver);
    putnum(10);
    return 0;
}
