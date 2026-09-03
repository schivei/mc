CC      = clang
CFLAGS  = -std=c2x -O1 -Wall -Wextra -Wno-unused-parameter
SRC     = $(wildcard stage0/*.c)
MCSRC   = $(wildcard src/*.mc)
TOOLSRC = $(wildcard tools/*.mc)
BUDGET  = 3000

all: stage0

stage0: build/mc0

stage0-san: build/mc0-san

build/mc0: $(SRC) stage0/mc.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC)

build/mc0-san: $(SRC) stage0/mc.h
	@mkdir -p build
	$(CC) -std=c2x -O0 -g -fwrapv -fno-strict-aliasing -fsanitize=undefined,address -o $@ $(SRC)

test: build/mc0
	scripts/test.sh build/mc0

check-lex: build/mc0
	scripts/check-lex.sh build/mc0

check-ast: build/mc0
	scripts/check-ast.sh build/mc0

mc1: build/mc1

build/mc1: build/mc0 $(MCSRC)
	@mkdir -p build
	build/mc0 src/mc.mc -o build/mc1.o
	scripts/link.sh build/mc1 build/mc1.o

check-asm: build/mc0 build/mc1
	scripts/check-asm.sh build/mc0 build/mc1

check-obj: build/mc0 build/mc1
	scripts/check-obj.sh build/mc0 build/mc1

# M11: the standalone executable of the compiler itself, via --exe and no ld.
# scripts/check-standalone.sh copies exactly this file into an empty directory.
build/mc-exe: build/mc1 $(MCSRC)
	@mkdir -p build
	rm -f $@
	build/mc1 --exe src/mc.mc -o $@

# M15: regenerates src/bundle_data.mc from tools/bundle.list. This is the only
# way that file is ever written; `make check` proves the checked-in copy is what
# comes out (scripts/check-bundle.sh).
bundle: build/mc1 $(TOOLSRC) tools/bundle.list
	build/mc1 --exe tools/bundle.mc -o build/bundle
	build/bundle tools/bundle.list src/bundle_data.mc

# M15: the checked-in bundle is reproducible and up to date. Runs BEFORE
# bootstrap, so a stale bundle fails with a message that says `make bundle`
# instead of failing later as a mysterious fixed-point difference.
check-bundle: build/mc1 $(TOOLSRC)
	scripts/check-bundle.sh build/mc1

# M15: tests/mc/*.mc — #embed and #include <name>, which exist only in the
# self-hosted compiler. Kept out of tests/*.mc so the mc0-vs-mc1 cross-checks
# keep comparing compilers that are supposed to agree.
check-mc: build/mc0 build/mc1
	scripts/check-mc.sh build/mc1

# M15: `mc` alone in an empty directory is the whole toolchain. Needs
# build/mc2.o as the byte-for-byte reference, which `make bootstrap` produces.
check-standalone: build/mc-exe bootstrap
	scripts/check-standalone.sh build/mc-exe build/mc2.o

# M11: the whole suite via the direct executable (--exe), no ld. Only the
# .mc compiler has this backend, so the target depends on build/mc1.
test-exe: build/mc1
	scripts/test-exe.sh build/mc1

bootstrap: stage0
	scripts/bootstrap.sh

# M10: wires up lib/user_demo.mc in src/user.mc, rebuilds, and compares the
# surface backend against the built-in one. Restores src/user.mc afterward.
# M12: the same target also runs the Tier 3 case (lib/mc_syntax_demo.mc), which
# does not touch src/user.mc — hence build/mc1 in the dependency.
check-surface: build/mc0 build/mc1
	scripts/check-surface.sh build/mc0 build/mc1

# M14: the TOML subset (src/toml.mc) through src/tomldump.mc, against
# tests/toml/*.expect — well-formed files and the malformed ones, whose .expect
# holds the exact file:line:col error.
check-toml: build/mc1
	scripts/check-toml.sh build/mc1

# M14: `mc build` end to end over tests/proj — [include].paths, [libs]/[externs],
# the built-in --exe backend, an external linker with {out} {obj} {sdk} {libs},
# kind = "obj", and the diagnostics.
check-build: build/mc1
	scripts/check-build.sh build/mc1

# M12: the full example (examples/api) — a taught compiler with class/interface,
# #dylib for libsqlite3, and the HTTP server. None of this goes through stage0:
# the starting compiler is build/mc1. Depends on curl and the system's sqlite3.
# M14: examples/api/test.sh now compiles the whole directory with `mc build`.
check-examples: build/mc1
	$(MAKE) -C examples/api test

check: budget test check-lex check-ast check-bundle check-asm check-obj bootstrap check-surface test-exe check-mc check-standalone check-toml check-build check-examples

budget:
	scripts/loc-budget.sh $(BUDGET)

clean:
	rm -rf build

.PHONY: all stage0 stage0-san test check-lex check-ast check-asm check-obj mc1 bootstrap check-surface test-exe bundle check-bundle check-mc check-standalone check-toml check-build check-examples check budget clean
