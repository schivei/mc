// b.mc — includes the sibling in the parent directory; path_join normalizes
// the .. before the once-only check, so c.mc is included only once.
#include "../c.mc"

i64 via_b() { return common() + 2; }
