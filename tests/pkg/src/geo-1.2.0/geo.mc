// geo.mc -- the `lib` entry of geo 1.2.0.
#include "vec.mc"

i64 geo_dot(i64 ax, i64 ay, i64 bx, i64 by) { return ax * bx + ay * by; }
i64 geo_version() { return 120; }
