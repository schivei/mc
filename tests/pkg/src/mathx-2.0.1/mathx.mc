// mathx.mc -- mathx 2.0.1: registered and YANKED, and it is the NEWEST row in
// the fixture registry, so `mc pkg add mathx` with no version picking 2.0.0 is
// the proof that a yanked row is skipped (Go's retract, 1.16).
i64 mathx_sq(i64 x) { return x * x; }
i64 mathx_version() { return 201; }
