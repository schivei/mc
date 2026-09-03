// ERROR CASE — not part of scripts/test.sh (that is why it lives in tests/err/).
// The first item of a #rule that is an identifier becomes a reserved keyword
// at definition time (tok_add as word). After that `while` is no longer a
// T_IDENT, so it can no longer be a variable name.
//
// expected: tests/err/055-keyword.mc:10: variable name expected (exit 1)
#include "../../lib/prelude.mc"

i64 main() {
    i64 while = 1;                    // error: `while` became a keyword
    return while;
}
