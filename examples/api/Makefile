# examples/api — o compilador ensinado (`class`/`interface`) e o que ele compila.
#
#   make -C examples/api mc-api     # build/mc-api, o compilador deste diretorio
#   make -C examples/api api        # build/api, o servidor, compilado pelo mc-api
#   make -C examples/api test       # test-oop + tests/lib_test.sh + test.sh
#   make -C examples/api clean
#
# Nada aqui entra nos `check-*` da raiz que rodam o stage0: o `mc0` em C nao
# conhece `syntax`/`type_alias`/`#dylib` e nunca compila este exemplo. O
# compilador de partida e `../../build/mc1`, construido pela raiz se faltar.
# Fora isso, so `curl` e `sqlite3`.

MC      = ../../build/mc1
MCAPI   = build/mc-api
API     = build/api
OOPTEST = build/oop_test

all: api

$(MC):
	$(MAKE) -C ../.. mc1

mc-api: $(MCAPI)

# o `rm -f` nao e enfeite: sobrescrever um executavel assinado no mesmo inode
# faz o kernel matar a proxima execucao dele com SIGKILL (assinatura em cache)
$(MCAPI): mc-api.mc oop.mc $(MC)
	@mkdir -p build
	@rm -f $(MCAPI)
	$(MC) --exe mc-api.mc -o $(MCAPI)

api: $(API)

$(API): main.mc lib/rt.mc lib/http.mc lib/sqlite.mc $(MCAPI)
	@mkdir -p build
	@rm -f $(API)
	$(MCAPI) --exe main.mc -o $(API)

# roda a suite deste exemplo pelo executavel direto (--exe): sem `ld`, com
# assinatura ad-hoc conferida pelo codesign, e exige o exit 42 e a saida exata.
test-oop: $(MCAPI) tests/oop_test.mc
	@mkdir -p build
	@rm -f $(OOPTEST)
	$(MCAPI) --exe tests/oop_test.mc -o $(OOPTEST)
	codesign --verify --verbose=2 $(OOPTEST)
	@printf '[x] comprar pao #10\nrect area=20\ncirc area=12\ntotal=42\n' > build/oop_test.exp
	@$(OOPTEST) > build/oop_test.out; st=$$?; \
	  cat build/oop_test.out; \
	  diff -u build/oop_test.exp build/oop_test.out || exit 1; \
	  if [ $$st -ne 42 ]; then echo "FALHOU: exit $$st, esperado 42"; exit 1; fi; \
	  echo "ok: tests/oop_test.mc saiu 42"

# rt.mc / http.mc / sqlite.mc isoladas: SQLite de verdade e uma requisicao HTTP
test-lib: $(MC)
	sh tests/lib_test.sh

# a API inteira: sobe o servidor numa porta livre e bate em cada rota
test-api: $(API)
	sh test.sh

test: test-oop test-lib test-api

clean:
	rm -rf build

.PHONY: all mc-api api test-oop test-lib test-api test clean
