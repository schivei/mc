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

# M11: a suite inteira pelo executavel direto (--exe), sem ld. So o compilador
# em .mc tem esse backend, entao o alvo depende de build/mc1.
test-exe: build/mc1
	scripts/test-exe.sh build/mc1

bootstrap: stage0
	scripts/bootstrap.sh

# M10: liga lib/user_demo.mc em src/user.mc, recompila e compara o backend da
# superficie com o embutido. Devolve src/user.mc como estava.
# M12: o mesmo alvo roda o caso do Tier 3 (lib/mc_syntax_demo.mc), que nao mexe
# em src/user.mc — por isso o build/mc1 na dependencia.
check-surface: build/mc0 build/mc1
	scripts/check-surface.sh build/mc0 build/mc1

# M12: o exemplo completo (examples/api) — compilador ensinado com class/interface,
# #dylib para a libsqlite3 e o servidor HTTP. Nada disto passa pelo stage0: o
# compilador de partida e build/mc1. Depende de curl e do sqlite3 do sistema.
check-examples: build/mc1
	$(MAKE) -C examples/api test

check: budget test check-lex check-ast check-asm check-obj bootstrap check-surface test-exe check-examples

budget:
	scripts/loc-budget.sh $(BUDGET)

clean:
	rm -rf build

.PHONY: all stage0 stage0-san test check-lex check-ast check-asm check-obj mc1 bootstrap check-surface test-exe check-examples check budget clean
