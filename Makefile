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

# M16: the musl sysroot for linux/aarch64, copied out of alpine:3. Cached: the
# script does nothing when the four files are already there.
sysroot-linux:
	scripts/sysroot-linux.sh

# M16: the whole suite cross-compiled to linux/aarch64 with the `elf-obj`
# backend, linked by ld.lld against musl and run in Docker. Guarded: without
# Docker or without ld.lld there is nothing to run, and `make check` says so
# instead of failing.
test-linux: build/mc1
	@if ! command -v ld.lld > /dev/null 2>&1; then \
	    echo "test-linux: SKIPPED (ld.lld not in PATH; brew install lld)"; \
	elif ! docker info > /dev/null 2>&1; then \
	    echo "test-linux: SKIPPED (docker is not running; see docs/build.md § Linux targets)"; \
	else \
	    scripts/test-linux.sh build/mc1; \
	fi

# M23: the seed guard -- `mc limits src/mc.mc` against the fixed MAX* constants
# still in stage0/mc.h and stage0/*.c. Fails when any of them is over 90% used,
# which is the early warning that the C seed has to be raised before it stops
# being able to compile src/mc.mc.
check-limits: build/mc1
	scripts/check-limits.sh build/mc1

# M12: the full example (examples/api) — a taught compiler with class/interface,
# #dylib for libsqlite3, and the HTTP server. None of this goes through stage0:
# the starting compiler is build/mc1. Depends on curl and the system's sqlite3.
# M14: examples/api/test.sh now compiles the whole directory with `mc build`.
check-examples: build/mc1
	$(MAKE) -C examples/api test

# M22: examples/lang -- the `lx` language taught to `mc` by a prelude (classes,
# interfaces, generics, namespaces, reference counting). Nothing in src/ knows
# any of it; `mc build` assembles the taught compiler from examples/lang/mc.toml
# and test.sh runs the whole tests/ suite through it with --exe.
check-lang: build/mc1
	sh examples/lang/test.sh

# M31: examples/conc -- concurrency taught to `lx` by a SECOND module stacked on
# examples/lang's (`[compiler] modules = ["../lang/lang.mc", "conc.mc"]`):
# spawn/intent/await/lock/chan, a worker pool with steal-on-await, channels that
# transfer ownership, LSE atomics through #opcode. Nothing in src/ knows any of
# it; the two core gaps it needed -- decl_find and on_jump -- are generic.
check-conc: build/mc1
	sh examples/conc/test.sh

# M26: docs/guide + docs/reference against the real compiler -- no undocumented
# public symbol, CLI flag, TOML key or directive; every fenced ```mc sample
# compiled (and run when it declares an expectation); every relative link
# resolving. Runs after check-examples/check-lang because some samples are built
# by the taught compilers of examples/api and examples/lang.
check-docs: build/mc1
	scripts/check-docs.sh build/mc1

# M27: the documentation site. `mc build site` compiles site/gen/*.mc into
# build/mcsite; running it renders docs/ into site/public.
site: build/mc1
	build/mc1 build site
	build/mcsite site

# M27: the site plus its own gate -- every internal link resolved in mc, then
# site/tools/checkhtml.py and contrast.py when python3 is present (skipped, not
# failed, when it is not).
check-site: site
	build/mcsite site --check

check: budget test check-lex check-ast check-bundle check-asm check-obj bootstrap check-surface test-exe check-mc check-standalone check-toml check-build check-limits check-minimal test-linux check-examples check-lang check-conc check-desktop check-docs site check-site

budget:
	scripts/loc-budget.sh $(BUDGET)

clean:
	rm -rf build

.PHONY: all stage0 stage0-san test check-lex check-ast check-asm check-obj mc1 bootstrap check-surface test-exe bundle check-bundle check-mc check-standalone check-toml check-build check-limits sysroot-linux test-linux check-examples check-lang check-conc check-docs site check-site check budget clean check-desktop check-minimal

# M32: examples/desktop -- a GTK4 application written in mc, and the same
# application with its widget tree written in a UI language taught by ui.mc.
# Skips itself with exit 0 when `pkg-config --exists gtk4` fails (CI has no GTK4).
check-desktop: build/mc1
	sh examples/desktop/test.sh

# M34: examples/minimal -- the smallest program built four ways, with the
# ceilings that keep a backend from growing quietly. Skips the Linux rows by
# itself when ld.lld is missing or Docker is not running.
check-minimal: build/mc1
	sh examples/minimal/measure.sh --check
