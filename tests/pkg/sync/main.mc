// main.mc -- the consumer of a registry: everything here arrived through
// `mc pkg sync`, and `<plot>` is plot's `lib` entry, read out of the lock.
//
// expect-exit: 42
// expect-stdout: plot 110
#include <sys>
#include <plot>

i64 main() {
    if (plot_area(10) != 314) return 1;
    if (plot_mathx() != 110) return 2;      // mathx 1.1.0, never 1.0.0 or 2.0.0
    puts("plot ");
    putnum(plot_mathx());
    puts("\n");
    return 42;
}
