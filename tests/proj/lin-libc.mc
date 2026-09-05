// lin-libc.mc — a linux/aarch64 program that IMPORTS: one libc symbol, called
// once. It is what makes the two dynamic cells of the matrix in
// scripts/check-build.sh real (a PT_INTERP and a DT_NEEDED only exist when
// something is imported) and what the `link = "static"` refusal is asserted
// against -- a static link against a libc needs an archive linker, which mc
// does not have (docs/build.md § Linux targets).
extern i64 write(i64 fd, uptr buf, i64 n);

i64 main() {
    write(1, "hi\n", 3);
    return 0;
}
