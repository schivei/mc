// plot.mc -- the `lib` entry of plot 1.0.0.
#include <mathx/mathx.mc>

i64 plot_area(i64 r) { return mathx_sq(r) * 314 / 100; }
i64 plot_mathx() { return mathx_version(); }
