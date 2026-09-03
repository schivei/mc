// expect-exit: 0
// expect-stdout: hello
// String literal in __cstring, deduplicated by content, printed via puts.
#include "../lib/sys.mc"

i64 main() {
    uptr a = "hello\n";
    uptr b = "hello\n";
    if (a != b) return 1;               // dedup: the same literal, the same address
    puts(a);
    return 0;
}
