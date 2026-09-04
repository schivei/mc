// main.mc — the smallest program the language can express: a `main` that
// returns 0. Nothing is included, nothing is called, nothing is allocated.
//
// Every byte the variants weigh is therefore the *format*, not the program:
// the page size, the signature, the entry stub, the loader's tables. The
// sibling mc.toml files compile this same file four ways and measure.sh prints
// what each floor costs. See README.md and docs/guide/80-footprint.md.
//
// expect-exit: 0
i64 main() { return 0; }
