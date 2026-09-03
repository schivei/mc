CC      = clang
CFLAGS  = -std=c2x -O1 -Wall -Wextra -Wno-unused-parameter
SRC     = $(wildcard stage0/*.c)
MCSRC   = $(wildcard src/*.mc)
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

# M12: the full example (examples/api) — a taught compiler with class/interface,
# #dylib for libsqlite3, and the HTTP server. None of this goes through stage0:
# the starting compiler is build/mc1. Depends on curl and the system's sqlite3.
check-examples: build/mc1
	$(MAKE) -C examples/api test

check: budget test check-lex check-ast check-asm check-obj bootstrap check-surface test-exe check-examples

budget:
	scripts/loc-budget.sh $(BUDGET)

clean:
	rm -rf build

.PHONY: all stage0 stage0-san test check-lex check-ast check-asm check-obj mc1 bootstrap check-surface test-exe check-examples check budget clean
