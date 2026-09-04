CC      = clang
CFLAGS  = -std=c2x -O1 -Wall -Wextra -Wno-unused-parameter
SRC     = $(wildcard stage0/*.c)
MCSRC   = $(wildcard src/*.mc)
TOOLSRC = $(wildcard tools/*.mc)
BUDGET  = 3000

# M37: which HOST this is. The C seed emits Mach-O and only Mach-O, so a Linux
# host has no `mc0` at all: it bootstraps from a `mc` binary that already exists
# (scripts/bootstrap-linux.sh, docs/guide/90-linux-host.md). Everything below
# that names a compiler names one of these two variables instead, so the same
# cross-check scripts run on both hosts.
#
#   REF   the compiler a cross-check compares AGAINST -- mc0 on macOS (the
#         frozen C seed, the oracle), mc1l on Linux (the stage the seed built)
#   MC    the compiler under test -- mc1 on macOS, mc2l on Linux
#
# M38: the third host is Windows under Git Bash, where `uname -s` says
# MINGW64_NT-... or MSYS_NT-..., so the switch is a findstring and not an ifeq.
# There is no `mc0` there either -- scripts/bootstrap-windows.sh is the chain --
# and every name carries `.exe`, because a file that is not called *.exe cannot
# be launched on Windows (docs/guide/95-windows-host.md).
HOST     := $(shell uname -s)
HOSTARCH := $(shell uname -m | sed -e 's/^arm64$$/aarch64/' -e 's/^amd64$$/x86_64/')
WINHOST  := $(findstring MINGW,$(HOST))$(findstring MSYS,$(HOST))$(findstring CYGWIN,$(HOST))

ifeq ($(HOST),Linux)
REF = build/mc1l
MC  = build/mc2l
else ifneq (,$(WINHOST))
REF = build/mc1w.exe
MC  = build/mc2w.exe
else
REF = build/mc0
MC  = build/mc1
endif

all: stage0

stage0: build/mc0

stage0-san: build/mc0-san

build/mc0: $(SRC) stage0/mc.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $(SRC)

build/mc0-san: $(SRC) stage0/mc.h
	@mkdir -p build
	$(CC) -std=c2x -O0 -g -fwrapv -fno-strict-aliasing -fsanitize=undefined,address -o $@ $(SRC)

ifeq ($(HOST),Linux)
# M37: on Linux the suite goes through `mc build` with [linker] = ld.lld and the
# musl sysroot, and runs natively (scripts/test-linux.sh, native mode). It is
# also what scripts/bootstrap-linux.sh ends with, which is why `check` below
# does not list it a second time.
test: $(MC)
	scripts/test-linux.sh --arch $(HOSTARCH) $(MC)
else ifneq (,$(WINHOST))
# M38: on Windows the suite is cross-compiled by the compiler that is running
# here and then linked and run natively, both halves of scripts/test-windows.sh
# in one go. `make check` does not list it: scripts/bootstrap-windows.sh already
# ends with the --run-only half, run by the compiler it just bootstrapped.
test: $(MC)
	scripts/test-windows.sh --arch $(HOSTARCH) --build-only build/tests-windows-$(HOSTARCH) $(MC)
	scripts/test-windows.sh --arch $(HOSTARCH) --run-only build/tests-windows-$(HOSTARCH)
else
test: build/mc0
	scripts/test.sh build/mc0
endif

# The reference on macOS is the frozen C lexer (mc0): the whole point is that
# the .mc lexer agrees with it. On Linux there is no C seed, so the comparison
# degrades to the compiled-in lexer against the same lexer built as its own
# program -- still a build-and-run gate, no longer an oracle (M37).
check-lex: $(REF)
	scripts/check-lex.sh $(REF)

check-ast: $(REF)
	scripts/check-ast.sh $(REF)

mc1: build/mc1

build/mc1: build/mc0 $(MCSRC)
	@mkdir -p build
	build/mc0 src/mc.mc -o build/mc1.o
	scripts/link.sh build/mc1 build/mc1.o

check-asm: $(REF) $(MC)
	scripts/check-asm.sh $(REF) $(MC)

check-obj: $(REF) $(MC)
	scripts/check-obj.sh $(REF) $(MC)

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
check-bundle: $(MC) $(TOOLSRC)
	scripts/check-bundle.sh $(MC)

# M15: tests/mc/*.mc — #embed and #include <name>, which exist only in the
# self-hosted compiler. Kept out of tests/*.mc so the mc0-vs-mc1 cross-checks
# keep comparing compilers that are supposed to agree.
check-mc: $(MC)
	scripts/check-mc.sh $(MC)

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
check-toml: $(MC)
	scripts/check-toml.sh $(MC)

# M14: `mc build` end to end over tests/proj — [include].paths, [libs]/[externs],
# the built-in --exe backend, an external linker with {out} {obj} {sdk} {libs},
# kind = "obj", and the diagnostics.
check-build: build/mc1
	scripts/check-build.sh build/mc1

# M16: the musl sysroot for linux/aarch64, copied out of alpine:3. Cached: the
# script does nothing when the four files are already there.
sysroot-linux:
	scripts/sysroot-linux.sh

# M17 step B: the same, out of a linux/amd64 alpine:3 (emulated on this host).
sysroot-linux-x86_64:
	scripts/sysroot-linux.sh --arch x86_64

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

# M17 step B: the same suite for linux/x86_64 -- the `elf-obj-x86_64` backend
# over the x86-64 machine, linked by ld.lld against an amd64 musl sysroot and
# run in an emulated linux/amd64 container. Guarded exactly like test-linux.
test-linux-x86_64: build/mc1
	@if ! command -v ld.lld > /dev/null 2>&1; then \
	    echo "test-linux-x86_64: SKIPPED (ld.lld not in PATH; brew install lld)"; \
	elif ! docker info > /dev/null 2>&1; then \
	    echo "test-linux-x86_64: SKIPPED (docker is not running; see docs/build.md § Linux targets)"; \
	else \
	    scripts/test-linux.sh --arch x86_64 build/mc1; \
	fi

# M19: the Windows sysroot -- kernel32.def plus the import library llvm-dlltool
# builds from it. No download and no Windows SDK; cached like the musl one.
sysroot-windows:
	scripts/sysroot-windows.sh

# M20: the same for windows/x86_64. The seven kernel32 exports are undecorated
# on x64 exactly as on ARM64, so only llvm-dlltool's machine changes.
sysroot-windows-x86_64:
	scripts/sysroot-windows.sh --arch x86_64

# M19: the whole suite cross-compiled to windows/aarch64 with the
# `coff-obj-arm64` backend, every object's COFF header checked with
# llvm-readobj when it is available, and three of them linked with lld-link.
# Nothing is EXECUTED
# here -- there is no Windows host on this machine, and the windows-11-arm CI
# leg is the runtime oracle (docs/ci.md). Guarded like test-linux: without the
# LLVM tools there is nothing to check, and `make check` says so instead of
# failing.
test-windows: build/mc1
	@if ! sh -c 'command -v lld-link || [ -x /opt/homebrew/opt/llvm/bin/lld-link ]' > /dev/null 2>&1; then \
	    echo "test-windows: SKIPPED (lld-link not found; brew install lld llvm)"; \
	elif ! sh -c 'command -v llvm-dlltool || [ -x /opt/homebrew/opt/llvm/bin/llvm-dlltool ]' > /dev/null 2>&1; then \
	    echo "test-windows: SKIPPED (llvm-dlltool not found; brew install llvm)"; \
	else \
	    scripts/test-windows.sh build/mc1; \
	fi

# M20: the same suite for windows/x86_64 -- the `coff-obj-x86_64` backend over
# the Win64 half of the x86-64 machine. Nothing is EXECUTED here either; the
# windows-latest CI leg is the runtime oracle. Guarded exactly like test-windows.
test-windows-x86_64: build/mc1
	@if ! sh -c 'command -v lld-link || [ -x /opt/homebrew/opt/llvm/bin/lld-link ]' > /dev/null 2>&1; then \
	    echo "test-windows-x86_64: SKIPPED (lld-link not found; brew install lld llvm)"; \
	elif ! sh -c 'command -v llvm-dlltool || [ -x /opt/homebrew/opt/llvm/bin/llvm-dlltool ]' > /dev/null 2>&1; then \
	    echo "test-windows-x86_64: SKIPPED (llvm-dlltool not found; brew install llvm)"; \
	else \
	    scripts/test-windows.sh --arch x86_64 build/mc1; \
	fi

# M23: the seed guard -- `mc limits src/mc.mc` against the fixed MAX* constants
# still in stage0/mc.h and stage0/*.c. Fails when any of them is over 90% used,
# which is the early warning that the C seed has to be raised before it stops
# being able to compile src/mc.mc.
check-limits: $(MC)
	scripts/check-limits.sh $(MC)

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

# M37: the Linux chain. There is no mc0 here, so `check` starts from
# scripts/bootstrap-linux.sh -- seed -> mc1l -> mc2l -> mc3l, cmp, golden, and
# the suite run with the compiler that came out. SEED is optional: with none the
# script takes build/mc-linux-<target> if it is there and otherwise downloads
# the release asset and verifies its checksum.
bootstrap-linux:
	scripts/bootstrap-linux.sh $(SEED)

build/mc2l:
	scripts/bootstrap-linux.sh $(SEED)

# an empty recipe on purpose: the file is written by the rule above, and without
# one make would try its built-in "link an executable from a .o" rule (clang)
build/mc1l: build/mc2l
	@:

# M38: the Windows chain. Same shape as bootstrap-linux: there is no mc0 here,
# so `check` starts from scripts/bootstrap-windows.sh -- seed -> mc1w -> mc2w ->
# mc3w, cmp, golden, --host, the suite, and the cross proof against build/mc2.o.
# SEED is optional: with none the script takes build/mc-windows-<target>.exe,
# links build/mc-windows-<target>.obj when only the object is there (that is
# what the CI artifact holds), and otherwise downloads the release asset and
# verifies its checksum.
bootstrap-windows:
	scripts/bootstrap-windows.sh $(SEED)

build/mc2w.exe:
	scripts/bootstrap-windows.sh $(SEED)

# an empty recipe on purpose: the file is written by the rule above
build/mc1w.exe: build/mc2w.exe
	@:

# M38: cross-building `mc` itself for a Windows host, from macOS. Two configs,
# two PE executables, each linked by lld-link against the kernel32 import
# library and the two objects a system with no C runtime needs. Unlike the Linux
# pair this needs no Docker at all -- the whole sysroot is one generated .lib.
mc-windows: build/mc1 sysroot-windows mcrt-windows
	build/mc1 build src --config src/mc.windows-aarch64.toml

mc-windows-x86_64: build/mc1 sysroot-windows-x86_64 mcrt-windows-x86_64
	build/mc1 build src --config src/mc.windows-x86_64.toml

# M38: the same cross-build stopped one step earlier -- `kind = "obj"`, so no
# [linker] and no sysroot. This is what CI runs on the macOS runner; the object
# is linked on the Windows runner. It is byte for byte the one the two targets
# above write on their way to the executable.
mc-windows-obj: build/mc1
	build/mc1 build src --config src/mc.windows-aarch64-obj.toml

mc-windows-x86_64-obj: build/mc1
	build/mc1 build src --config src/mc.windows-x86_64-obj.toml

# M38: the two objects every Windows link line carries besides the program --
# the entry point (lib/sys_windows_start.mc) and the POSIX shims over kernel32
# (lib/sys_windows_host.mc). They go into the SYSROOT, beside kernel32.lib,
# because that is the directory that holds everything a link for this target
# needs and is not the program; they travel in the CI artifact for the same
# reason, since the Windows runner has no `mc` until it has linked one.
mcrt-windows: build/mc1
	@mkdir -p build/sysroot/windows-aarch64
	build/mc1 --backend=coff-obj-arm64 lib/sys_windows_start.mc -o build/sysroot/windows-aarch64/winstart.obj
	build/mc1 --backend=coff-obj-arm64 lib/sys_windows_host.mc  -o build/sysroot/windows-aarch64/mcrt.obj

mcrt-windows-x86_64: build/mc1
	@mkdir -p build/sysroot/windows-x86_64
	build/mc1 --backend=coff-obj-x86_64 lib/sys_windows_start.mc -o build/sysroot/windows-x86_64/winstart.obj
	build/mc1 --backend=coff-obj-x86_64 lib/sys_windows_host.mc  -o build/sysroot/windows-x86_64/mcrt.obj

# M37: cross-building `mc` itself for a Linux host, from macOS. Two configs,
# two ELF executables, both statically linked against musl by ld.lld. The
# sysroot prerequisite is what needs Docker: scripts/sysroot-linux.sh copies the
# four musl files out of alpine:3.
mc-linux: build/mc1 sysroot-linux
	build/mc1 build src --config src/mc.linux-aarch64.toml

mc-linux-x86_64: build/mc1 sysroot-linux-x86_64
	build/mc1 build src --config src/mc.linux-x86_64.toml

# M37: the same cross-build stopped one step earlier -- `kind = "obj"`, so no
# [linker], no sysroot, no Docker and no ld.lld. This is what CI runs on the
# macOS runner (docs/ci.md § M37); the object is linked on the Linux runner,
# which has its own musl files. The object is byte for byte the one the two
# targets above write on their way to the executable.
mc-linux-obj: build/mc1
	build/mc1 build src --config src/mc.linux-aarch64-obj.toml

mc-linux-x86_64-obj: build/mc1
	build/mc1 build src --config src/mc.linux-x86_64-obj.toml

# M37: the Linux HOST proof, run from macOS. Cross-builds both compilers and,
# for each architecture, runs the whole Linux chain inside a container of that
# platform: bootstrap-linux.sh to its fixed point, then the Linux `make check`
# subset, then the cross proof that an object written on Linux for macOS is the
# byte-for-byte object macOS writes for itself. Self-skips without Docker.
check-linux-host: build/mc1
	@if ! docker info > /dev/null 2>&1; then \
	    echo "check-linux-host: SKIPPED (docker is not running; see docs/guide/90-linux-host.md)"; \
	else \
	    scripts/check-linux-host.sh; \
	fi

# M37/M38: what a Linux or a Windows host cannot prove, with the reason. Every
# line here is a target `make check` runs on macOS and does not run there.
ifneq (,$(WINHOST))
check-skipped:
	@echo "stage0/mc0: the C seed is macOS-first -- it emits Mach-O only (docs/bootstrap.md)"
	@echo "bootstrap: SKIPPED (macOS chain: mc0 -> mc1 -> mc2 -> mc3; bootstrap-windows is the Windows one)"
	@echo "test: SKIPPED (bootstrap-windows already ran the suite with the compiler it built)"
	@echo "test-exe: SKIPPED (--exe is the Mach-O direct-executable backend; Windows links with lld-link)"
	@echo "check-standalone: SKIPPED (its criterion is a signed Mach-O executable)"
	@echo "check-surface: SKIPPED (its cases build taught compilers with --exe)"
	@echo "check-build: SKIPPED (tests/proj targets macos/aarch64 through ld)"
	@echo "check-minimal: SKIPPED (its ceilings are measured on the macOS backends)"
	@echo "test-linux/test-linux-x86_64: SKIPPED (cross-compilation from macOS, with Docker)"
	@echo "test-windows/test-windows-x86_64: SKIPPED (cross-compilation from macOS; here the suite is native)"
	@echo "check-examples/check-lang/check-conc/check-desktop: SKIPPED (macOS dylibs and --exe)"
	@echo "check-docs/site/check-site: SKIPPED (their samples are built with --exe)"
else
check-skipped:
	@echo "budget/stage0: the C seed is macOS-first -- it emits Mach-O only (docs/bootstrap.md)"
	@echo "bootstrap: SKIPPED (macOS chain: mc0 -> mc1 -> mc2 -> mc3; bootstrap-linux is the Linux one)"
	@echo "test-exe: SKIPPED (--exe is the Mach-O direct-executable backend; Linux links with ld.lld)"
	@echo "check-standalone: SKIPPED (its criterion is a signed Mach-O executable)"
	@echo "check-surface: SKIPPED (its cases build taught compilers with --exe)"
	@echo "check-build: SKIPPED (tests/proj targets macos/aarch64 through ld)"
	@echo "check-minimal: SKIPPED (its ceilings are measured on the macOS backends)"
	@echo "test-linux/test-linux-x86_64: SKIPPED (cross-compilation from macOS; here the suite is native)"
	@echo "test-windows: SKIPPED (cross-compilation from macOS; the windows-11-arm CI leg is the runtime oracle)"
	@echo "test-windows-x86_64: SKIPPED (cross-compilation from macOS; the windows-latest CI leg is the runtime oracle)"
	@echo "check-examples/check-lang/check-conc/check-desktop: SKIPPED (macOS dylibs and --exe)"
	@echo "check-docs/site/check-site: SKIPPED (their samples are built with --exe)"
endif

ifeq ($(HOST),Linux)
check: budget bootstrap-linux check-lex check-ast check-asm check-obj check-bundle check-mc check-toml check-limits check-skipped
else ifneq (,$(WINHOST))
# M38: the Windows subset. Everything not here needs `mc` plus something this
# host does not have -- the C seed, the Mach-O direct-executable backend, GTK4,
# Docker or python3 -- and `check-skipped` prints the reason for each one.
check: budget bootstrap-windows check-lex check-ast check-asm check-obj check-bundle check-mc check-toml check-limits check-skipped
else
check: budget test check-lex check-ast check-bundle check-asm check-obj bootstrap check-surface test-exe check-mc check-standalone check-toml check-build check-limits check-minimal test-linux test-linux-x86_64 test-windows test-windows-x86_64 check-examples check-lang check-conc check-desktop check-docs site check-site
endif

budget:
	scripts/loc-budget.sh $(BUDGET)

clean:
	rm -rf build

.PHONY: bootstrap-linux mc-linux mc-linux-x86_64 mc-linux-obj mc-linux-x86_64-obj
.PHONY: check-linux-host check-skipped
.PHONY: bootstrap-windows mc-windows mc-windows-x86_64 mc-windows-obj mc-windows-x86_64-obj
.PHONY: mcrt-windows mcrt-windows-x86_64
.PHONY: all stage0 stage0-san test check-lex check-ast check-asm check-obj mc1 bootstrap check-surface test-exe bundle check-bundle check-mc check-standalone check-toml check-build check-limits sysroot-linux sysroot-linux-x86_64 sysroot-windows sysroot-windows-x86_64 test-linux test-linux-x86_64 test-windows test-windows-x86_64 check-examples check-lang check-conc check-docs site check-site check budget clean check-desktop check-minimal

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
