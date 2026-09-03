// expect-exit: 42
// expect-stdout: 12,30,
// A rule that uses a rule: the `repeat` template is parsed with the normal
// parser, which already knows the prelude's `while` and `+=`. The expansion
// happens AT DEFINITION TIME — what gets stored is a tree of
// `loop`/`if`/`break`, so there is no textual re-expansion and infinite
// recursion is impossible by construction.
#include "../lib/sys.mc"
#include "../lib/prelude.mc"

#rule stmt: repeat ( expr $n ) block $b
    => { i64 $$i = 0; while ($$i < $n) { $b $$i += 1; } }

i64 main() {
    i64 s = 0;
    repeat (4) { s += 3; }
    putnum(s);  write(1, ",", 1);     // 12

    // two expansions in the same block: each one has its own counter
    repeat (3) { s += 6; }
    putnum(s);  write(1, ",", 1);     // 30

    return s + 12;                    // 42
}
