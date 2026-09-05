// bad.mc -- one line past the boundary: a relative include that climbs out of
// the package's own directory. mc refuses it at the include's own position, as
// `bad/bad.mc:4: package bad reaches outside its tree: <the path it resolved
// to>` (docs/reference/packages.md § The closure rule); the check-pkg case
// matches the sentence, the prefix and the path being the tree's own.
#include "../../outside.mc"

i64 bad_value() { return 1; }
