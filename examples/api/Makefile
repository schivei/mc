# examples/api — the taught compiler (`class`/`interface`) and what it compiles.
#
#   make -C examples/api mc-api     # build/mc-api, this directory's compiler
#   make -C examples/api api        # build/api, the server, compiled by mc-api
#   make -C examples/api test       # test-oop + tests/lib_test.sh + test.sh
#   make -C examples/api clean
#
# Since M14 the same two steps are one command, driven by mc.toml and with no
# make at all (docs/build.md):
#
#   ../../build/mc1 build examples/api      # from the repository root
#
# This Makefile stays as the by-hand path, and test.sh uses `mc build`, so both
# are exercised by `make check`.
#
# None of this enters the root's `check-*` targets that run stage0: the C
# `mc0` does not know `syntax`/`type_alias`/`#dylib` and never compiles this
# example. The starting compiler is `../../build/mc1`, built by the root if
# missing. Besides that, only `curl` and `sqlite3`.

MC      = ../../build/mc1
MCAPI   = build/mc-api
API     = build/api
OOPTEST = build/oop_test

all: api

$(MC):
	$(MAKE) -C ../.. mc1

mc-api: $(MCAPI)

# the `rm -f` is not decoration: overwriting a signed executable on the same
# inode makes the kernel kill its next execution with SIGKILL (cached signature)
$(MCAPI): mc-api.mc oop.mc $(MC)
	@mkdir -p build
	@rm -f $(MCAPI)
	$(MC) --exe mc-api.mc -o $(MCAPI)

api: $(API)

$(API): main.mc lib/rt.mc lib/http.mc lib/sqlite.mc $(MCAPI)
	@mkdir -p build
	@rm -f $(API)
	$(MCAPI) --exe main.mc -o $(API)

# runs this example's suite via the direct executable (--exe): no `ld`, with
# an ad-hoc signature verified by codesign, and requires exit 42 and the exact output.
test-oop: $(MCAPI) tests/oop_test.mc
	@mkdir -p build
	@rm -f $(OOPTEST)
	$(MCAPI) --exe tests/oop_test.mc -o $(OOPTEST)
	codesign --verify --verbose=2 $(OOPTEST)
	@printf '[x] buy bread #10\nrect area=20\ncirc area=12\ntotal=42\n' > build/oop_test.exp
	@$(OOPTEST) > build/oop_test.out; st=$$?; \
	  cat build/oop_test.out; \
	  diff -u build/oop_test.exp build/oop_test.out || exit 1; \
	  if [ $$st -ne 42 ]; then echo "FAILED: exit $$st, expected 42"; exit 1; fi; \
	  echo "ok: tests/oop_test.mc exited 42"

# rt.mc / http.mc / sqlite.mc in isolation: real SQLite and an HTTP request
test-lib: $(MC)
	sh tests/lib_test.sh

# the whole API: brings the server up on a free port and hits every route
test-api: $(API)
	sh test.sh

test: test-oop test-lib test-api

clean:
	rm -rf build

.PHONY: all mc-api api test-oop test-lib test-api test clean
