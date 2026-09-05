// bad.mc -- one line past the boundary: a relative include that climbs out of
// the package's own directory. mc refuses it with `package bad reaches outside
// its tree` (docs/reference/packages.md § The closure rule).
#include "../../outside.mc"

i64 bad_value() { return 1; }
