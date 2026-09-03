// expect-exit: 0
// expect-stdout: mc bundles this file verbatim.
// #embed name "path" (M15): the file's bytes become `u8 name[]` and two
// #defines, name_size (bytes in the array) and name_raw (the original size).
// Without `lz` the two are equal. The path resolves like #include "x": next to
// the file that wrote the directive.
#include <sys>

#embed greeting "070-embed.txt"

i64 main() {
    if (greeting_size != greeting_raw) return 1;
    if (greeting_size != 31) return 2;
    if (ld8(greeting) != 'm') return 3;
    if (ld8(greeting + greeting_size - 1) != '\n') return 4;
    write(1, greeting, greeting_size);
    return 0;
}
