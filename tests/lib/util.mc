// util.mc — test library for 022: included twice, processed only once.
#define UTIL_EXTRA 6

i64 triple(i64 x) { return x * 3; }

i64 util_extra() { return UTIL_EXTRA; }
