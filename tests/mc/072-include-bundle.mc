// expect-exit: 42
// expect-stdout: 42 from <sys> and <prelude>
// `#include <name>` served by the bundle inside the binary (M15): no file on
// disk, no repository. <sys> pulls <io> in by its own relative #include, which
// the lexer resolves by name because the includer is itself bundled.
#include <sys>
#include <prelude>

i64 main() {
    i64 n = 0;
    for (i64 i = 0; i < 7; i = i + 1) { n += 6; }
    putnum(n);
    puts(" from <sys> and <prelude>\n");
    return n;
}
