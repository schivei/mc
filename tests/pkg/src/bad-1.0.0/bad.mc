// bad.mc -- one line past the boundary: a relative include that climbs out of
// the package's own directory. mc refuses it at the include's own position:
// `<where this file was installed>/bad.mc:<the line of the #include>: package
// bad reaches outside its tree: <the path the include resolved to>`
// (docs/reference/packages.md § The closure rule). The check-pkg case matches
// the sentence; the prefix and the path are the installed tree's own.
#include "../../outside.mc"

i64 bad_value() { return 1; }
