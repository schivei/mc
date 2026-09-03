// expect-exit: 0
// expect-stdout: hello
// String literal em __cstring, deduplicada por conteudo, impressa por puts.
#include "../lib/sys.mc"

i64 main() {
    uptr a = "hello\n";
    uptr b = "hello\n";
    if (a != b) return 1;               // dedup: o mesmo literal, o mesmo endereco
    puts(a);
    return 0;
}
