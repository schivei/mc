// lin.mc — the program the [sysroot] cases of scripts/check-build.sh compile.
//
// It targets linux/aarch64 (the `elf-obj` backend) and needs no system layer at
// all: the point is not what it does, it is that the object is written and the
// LINK line is then assembled, which is where `{sysroot}` is substituted and
// where the resolution chain of src/sysroot.mc runs. The three configs beside
// it use `echo` as the linker, so the case is hermetic -- no ld.lld, no musl,
// no Docker -- and the resolved directory comes out on stdout.
i64 main() { return 0; }
