// main.mc -- includes a file that IS inside geo's tree and is NOT in geo's
// [package].files. The tree hash cannot see it (it hashes what the manifest
// lists), so the once-only list is what catches it, after the parse.
#include <geo/extra.mc>
i64 main() { return geo_extra(); }
