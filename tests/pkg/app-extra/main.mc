// main.mc -- includes a file that IS inside geo's tree and is NOT in geo's
// [package].files. The tree hash cannot see it (it hashes what the manifest
// lists), so the once-only list is what catches it, after the parse.
// `extra.mc` is deliberately absent from tests/pkg/src/geo-1.2.0/: the source
// tree's hash must not move, so scripts/check-pkg.sh WRITES the file into the
// installed copy (<libs>/geo/v1.2.0/extra.mc) right before this build and
// removes it after -- read the "undeclared file" case there.
#include <geo/extra.mc>
i64 main() { return geo_extra(); }
