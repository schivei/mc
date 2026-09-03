# mc — a self-hosting mini compiler, teachable through its surface

Read `docs/plan.md` before any work: it fixes the language, the teaching surface,
the architecture, the budget, and the milestones. This file only summarizes the operating rules.

## Roles
The user is the owner; the main session is the **architect** and **delegates all creation** to
agents (`.claude/agents/`): `stage0-dev` (C23), `mc-dev` (`.mc` code), `reviewer`, `verifier`,
`docs-writer`. Agents report facts (commands run + output), never assumptions.

## Inviolable rules
- `stage0/*.c` ≤ 3000 lines total (`make budget`). Exceeding it is a build failure.
- stage0 uses **only** `open/read/write/close/_exit` from libc (arena.c). No stdio/malloc/qsort.
- Every file field is written byte by byte in little-endian via `buf_u8/u16/u32/u64`. Never `fwrite(&struct)`.
- Determinism (`docs/plan.md` § Determinism): no pointer hashing, no iterating hash tables for
  output, stable partitioning of symbols, no `__FILE__`/dates/paths, zeroed padding.
- C code has the **same shape** it will have in `.mc`: small functions, flat data in an arena,
  no struct-as-file-layout, no clever textual macros. stage0 will be transliterated 1:1 into `src/*.mc`.
- Comments, messages and docs in English; ASCII identifiers; no emojis.
- Do not look at or copy code from the user's other projects (`~/projects/langs` is off-limits).

## Commands
- `make stage0` → `build/mc0` · `make stage0-san` (sanitizers) · `make budget` · `make test`
- `make mc1` → `build/mc1` · `make check` runs everything · `make test-exe` runs the suite via `--exe`.
- `scripts/link.sh OUT IN.o` links with `ld -lSystem` (`ld` is allowed; gcc/cc/clang only for stage0).
  Since M11 it's optional: `build/mc1 --exe prog.mc -o prog` writes the signed executable directly.
- Inspection: `otool -hlv X.o`, `otool -r X.o`, `nm -m X.o`; for the executable, `otool -l`,
  `codesign -dvvv`, `codesign --verify --verbose=4`.

## State
- M0 done (manual `.o`, exit 42) · M0.5 done (svc works under dyld; static is killed by the kernel)
- M1 done, verified and reviewed (lexer, Pratt, AST, dumps, constant codegen)
- M2 done, verified and reviewed (locals, calls, extern, ld/st, spill)
- M3 done (globals, arrays, strings, `&x`, `#include`, `#define`, `extern`, arena)
- M4 done (tokenizer in `.mc`; `make check-lex` cross-checks `--dump-tokens` against `src/lexdump.mc`)
- M5 done (4 relocations, `#section`, `#opcode`, `emit()`/`reloc()`, `lib/sys_svc.mc`)
- M5.5 done (`\0` forbidden in a string, `path_join` normalizes `.`/`..`, token carries its file,
  `#define` vs a name, section order, initialized global array, `udiv`, prototype)
  — 2492/3000 lines, `make test` 24/24, `make check-lex` 31/31
- M5.6 done (`reloc()` only attaches to a raw word; `__data` and `#section` with no ALIGN default
  to 16-byte alignment; `MAXSECS`/`MAXPARAMS` only in `mc.h`; `creat` instead of variadic `open`
  when writing a file — `stage0/arena.c`, `lib/sys.mc`, `lib/sys_svc.mc`, `src/arena.mc`;
  `cmp_cond` via table)
  — 2497/3000 lines, `make test` 24/24, `make check-lex` 36/36
- M6 done (`docs/specs/M6-M7.md`): `src/mc.mc` complete (`arena.mc`, `macho.mc`, `lex.mc`, `ast.mc`,
  `parse.mc`, `gen_arm64.mc`, `main.mc`) — 4310 lines of `.mc` against 2678 of C (`stage0/*.c` +
  `mc.h`), a factor of 1.6. `MAXDEFS 512` on both sides (`stage0/parse.c` and `src/parse.mc`).
  stage0 at 2500/3000 lines (`make budget`). `make mc1` builds `build/mc1`; `check-asm` 39/39,
  `check-obj` 24/24, `scripts/test.sh build/mc1` 24/24.
- M7 done (fixed point, `scripts/bootstrap.sh` + `make bootstrap`): `mc0→mc1.o`, `mc1→mc2.o`,
  `mc2→mc3.o`, `cmp mc2.o mc3.o` identical (163632 bytes). Golden recorded in
  `tests/golden/mc2.sha256` (see `tests/golden/README.md` for when to update it).
- M8 done (`docs/bootstrap.md`): `clang` only compiles stage0 (`CC = clang` in the Makefile,
  targets `build/mc0`/`build/mc0-san`); confirmed with `grep -rn clang scripts/ Makefile`. `ld`
  is still used via `scripts/link.sh`. Binaries are not versioned (`build/` in `.gitignore`).
- M9 done (`docs/specs/M9.md`): `#rule stmt:` implemented in stage0 **and** in `src/parse.mc` —
  a linear table indexed by the opening token, items `{literal | nt $name}` with
  `nt ∈ {expr,stmt,block,ident}`, template parsed at definition time (`N_HOLE` for a node, a name
  marker for `ident $x`/gensym), backtracking-free matching, deterministic gensym (`__g<N>` in M9,
  fixed to `$g<N>` in M10 — see the M10 entry),
  `--dump-rules`. `lib/prelude.mc` (36 lines) provides `while`/`for`/`+=`/`-=`/`++`/`--`; tests
  `050`–`054` in the suite and `tests/err/055-keyword.mc` as an error case outside it.
  `src/macho.mc` migrated to the prelude (a leaf module). Out of scope by spec decision:
  `#rule expr:` (reserved), the `type $t` hole and therefore `struct`.
  — stage0 2747/3000 lines; `make check` green: `test` 29/29, `check-lex` 45/45,
  `check-ast` 45/45, `check-asm` 45/45, `check-obj` 29/29, `bootstrap` at a fixed point
  (`mc2.o == mc3.o`, 181504 bytes) and golden re-recorded in `tests/golden/mc2.sha256`.
- M10 done (`docs/specs/M10.md`): **Tier 2 — passes and backends taught through the surface**.
  Core (on both sides): `&name` of a function/extern becomes `uptr` (adrp/add with `PAGE21`+
  `PAGEOFF12`; an undefined symbol when `extern`) and the intrinsic `callp(p, a1..a7)` (args in
  `x0..x6`, `p` in `x16`, `blr x16`, the same live-depth saving as `bl`, `i64` result) —
  `tests/060-callp.mc`. `gen` split into two public halves: `gen_lower(root)` (AST → per-function
  `Ins` buffer, sections, globals, strings and symbols, without encoding) and `gen_encode_all()`,
  plus ~16 accessors (`gen_func_count/gen_ins_at/gen_prel_*`…). Symbol-creation order was
  preserved on purpose: the 29 prior `.o` files come out **byte for byte identical** to `mc0`'s
  pre-M10 output.
  Hooks only in `.mc` (`src/hooks.mc` with `pass`/`backend`, `src/user.mc` → `lib/user_default.mc`);
  the driver calls `user_init()` before parsing, applies the passes over the AST, and picks the
  backend via `--backend=NAME` (default `macho` = `gen_lower`+`gen_encode_all`+`macho_write`).
  Stage0 in C is **not** teachable: it only accepts `--backend=macho` (documented in
  `docs/surface.md` § Tier 2).
  Proof: `lib/backend_arm64.mc` (the `arm64-surface` backend, reimplementing the whole encoder in
  `.mc` on top of the public API) and `lib/pass_demo.mc` (`x * 1` → `x`), wired together by
  `lib/user_demo.mc`; `make check-surface` wires up the demo, rebuilds, and compares — **32/32**
  objects identical to the built-in backend, then reverts `src/user.mc` to the default (the demo
  is opt-in).
  Along with it came three fixes from the M9 review: gensym changed from `__g<N>` to `$g<N>`
  (the lexer never forms an identifier containing `$`, so capture is impossible —
  `tests/056-gensym-nocapture.mc`), a `#rule` whose dispatch literal is a core keyword or type is
  now rejected (`cannot redefine a core keyword`), and an overflowed `MAXRULES` now uses `err_at`
  with a position.
  — stage0 2843/3000 lines (M10 cost +89 and the M9 fixes +7, for a total of +96 over 2747);
  `make check` green: `test` 32/32, `check-lex` 54/54, `check-ast` 54/54, `check-asm` 54/54,
  `check-obj` 32/32, `check-surface` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`,
  191368 bytes) and golden re-recorded in `tests/golden/mc2.sha256`.
- M11 done, verified and reviewed; the plan is complete; see `docs/bootstrap.md`
  (`docs/specs/M11.md`): **direct executable (`mc --exe`), no `ld`**. The executable is a
  backend written in `.mc` — `src/backend_exe.mc` (858 lines), registered by default in the
  driver as `macho-exe`, with `--exe` as its alias. It reuses `gen_lower` + `gen_encode_all` (the
  same encoder and the same sections/relocs as the `macho` backend) and does what `ld` used to
  do: segment layout with 16 KiB pages (`__PAGEZERO`/`__TEXT`/`__DATA`/`__LINKEDIT`, one
  `LC_SEGMENT_64` per distinct segname), its own resolution of
  `BRANCH26`/`PAGE21`/`PAGEOFF12`/`UNSIGNED`, `__TEXT,__stubs` + `__DATA,__got` per imported
  symbol with **bind opcodes** (`LC_DYLD_INFO_ONLY`, no lazy/weak/export), **rebase** for every
  `UNSIGNED` (PIE), the 13 load commands (`LC_MAIN`, `LC_LOAD_DYLINKER`, `LC_LOAD_DYLIB
  libSystem`, `LC_UUID` derived from a SHA-256 of the content, `LC_CODE_SIGNATURE`) and an
  **ad-hoc signature** (`CS_SuperBlob`/`CS_CodeDirectory` v0x20400, SHA-256 per 4 KiB page,
  `CS_ADHOC`, `execSeg*`, identifier = the output's basename). `src/sha256.mc` (177 lines) is
  SHA-256 written in the language, checked against `shasum -a 256` on 7 vectors. Fields verified
  one by one against the `ld` reference (`-no_fixup_chains`) — see `docs/macho-notes.md` § M11.
  `--exe` **does not exist in stage0**: the C code is the seed and stays with just
  `--backend=macho`.
  Proofs: `scripts/test-exe.sh` (target `make test-exe`, inside `make check`) runs the whole
  suite via `--exe` — **32/32**, with `codesign --verify` on each binary; `codesign -dvvv` shows
  `flags=0x2(adhoc)`. Self-hosting without `ld`: `build/mc1 --exe src/mc.mc -o build/mc-exe`
  (210835 bytes), `build/mc-exe src/mc.mc -o x.o` identical to `build/mc2.o`, and
  `build/mc-exe --exe src/mc.mc -o build/fix/mc-exe` byte-for-byte identical to `build/mc-exe`
  (the executable's fixed point only holds for the same *basename*: the signature's identifier
  is the output file's name, same as `codesign` — see `docs/bootstrap.md` § M11).
  Along with it came two fixes from the M10 review, both only in `src/`: `MAXFUNCS` went from 512
  to 1024 (the C side was already 1024; with the two new files `mc1 → mc2` would have died with
  `too many functions`) and `user_init()` is now called **after** `tok_init()`/`lex_init()`
  (before that, a `user_init` calling `tok_add` would shift `K_U8..K_EXTERN` and break the core —
  `lib/user_tokadd.mc` plus the new case in `scripts/check-surface.sh` guard against this).
  — stage0 **untouched**, 2843/3000 lines; `make check` green: `test` 32/32, `check-lex` 57/57,
  `check-ast` 57/57, `check-asm` 57/57, `check-obj` 32/32, `check-surface` 32/32, `test-exe` 32/32,
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, 225424 bytes) and golden re-recorded in
  `tests/golden/mc2.sha256` (the `--dump-asm` diff between `mc1` and `mc2` comes out empty).
- Post-M11 batch (review): `reloc(UNSIGNED, "sym")` followed by `emit()`/`#opcode` used to be
  accepted and would record an 8-byte relocation (`length 3`) over a 4-byte word, overwriting the
  following instruction — reproduced on both backends (`otool -r`: `address 00000008, length 3`).
  `gen_word` now rejects it on both sides with the same message, `reloc UNSIGNED requires 8
  bytes: use a global array initializer` (`stage0/gen_arm64.c` +3 lines, `src/gen_arm64.mc` +3);
  `tests/err/062-reloc-unsigned.mc` documents the case (outside `scripts/test.sh`, like `055`).
  Docs: `docs/surface.md` § `emit()`/`reloc()`; the `--exe` trade-off with an undefined symbol
  (`.o` + `ld` refuses at link time; `--exe` builds the binary and `dyld` kills it with
  `Symbol not found`, exit 134) in `docs/bootstrap.md` § M11, `docs/core-language.md` § `extern`
  and `docs/specs/M11.md` § Risks — decision recorded: no heuristic symbol list.
  — stage0 2846/3000 lines; `make check` green: `test` 32/32, `check-lex` 57/57, `check-ast` 57/57,
  `check-asm` 57/57, `check-obj` 32/32, `check-surface` 32/32, `test-exe` 32/32, `bootstrap` at a
  fixed point (`mc2.o == mc3.o`, 225640 bytes; the `--dump-asm` diff between `mc1` and `mc2` comes
  out empty) and golden re-recorded once in `tests/golden/mc2.sha256` — the codegen delta is just
  the new guard in `gen_word` (17 instructions) plus a +1 shift in the `l_strN` indices starting
  from 285.
- Arena at 32 MiB (was 256): `HEAP_SIZE` dropped on both sides (`stage0/arena.c`, `src/arena.mc`)
  because self-compiling only touches 14.5 MiB (`vmmap`; `/usr/bin/time -l build/mc1 src/mc.mc`
  gives a peak RSS of 16744448 bytes = 15.97 MiB). Single codegen delta: the `HEAP_SIZE` immediate
  in `xalloc` (`movk x10, #4096, lsl #16` → `movk x10, #512, lsl #16`); `mc2.o`'s `__bss` went
  from `0x1002ed70` to `0x0202ed70` and `build/mc1`'s from `__DATA vmsize 0x10030000` to
  `0x2030000`. `mc2.o` stays at 225640 bytes (zerofill doesn't take up file space) and golden was
  re-recorded in `tests/golden/mc2.sha256` (`ddc21ac6…b829a` → `f42cda85…39c28`). Overflow fails
  cleanly: `arena exhausted`, exit 1 (a synthetic case of 1000 functions × 12 statements, 14001
  lines; with 11 statements, 13001 lines, it still compiles). `make check` green: `test` 32/32,
  `check-lex`/`check-ast`/`check-asm` 57/57, `check-obj` 32/32, `check-surface` 32/32,
  `test-exe` 32/32, `bootstrap` at a fixed point.
- M12-core done (section A of `docs/specs/M12.md`): **Tier 3 — syntax taught through code**. `.mc`
  only; `stage0/` untouched (2846/3000). `src/core.mc` (41 lines) is the compiler **without**
  `user.mc`, and `src/mc.mc` became `#include "core.mc"` + `#include "user.mc"`: a taught compiler
  is no longer an edit to `src/user.mc` but its own file (`#include "../src/core.mc"` + modules +
  `void user_init()`). `src/astdump.mc` gained `#include "hooks.mc"` because `parse.mc` now
  consults the tables that live there.
  New registries in `src/hooks.mc` (+109 lines): `syntax(word, &f)` (top-level position,
  `MAXSYNTAX 32`), `syntax_stmt(word, &f)` (statement position), and
  `type_alias(name, TY_*)` (`MAXALIAS 64`) — linear tables, last registration wins, and all three
  reject core keywords (`word_add`, tested with `type_alias("if",…)` and
  `syntax_stmt("return",…)`: `cannot redefine a core keyword`).
  `src/parse.mc` (+219): `parse_top` consults `syntax_find` before requiring a type and returns 0
  (the handler delivers via `top_add`); `parse_stmt` consults `syntax_stmt_find` before dispatching
  `#rule` and accepts the returned node (0 → an empty `N_BLOCK`); `type_of_token` falls back to
  `alias_find`, which makes the alias apply uniformly in globals, locals, parameters, `extern`,
  casts, and `p_type`.
  Fixed public API: `p_id/p_val/p_name/p_line/p_file/p_next/p_accept/p_expect/p_ident/p_type`,
  `parse_expr(0)/parse_stmt()/parse_block()/parse_params()`, `parse_function(ty,name,params)`,
  `top_add(n)`, `def_add(name,val,line,fl)`, `param_new(ty,name)`, `list_append(head,n)`.
  `#dylib "path"` (`D_DYLIB 8`, at the end of `lex.mc`'s list): a path table
  (`MAXDYLIBS 8`, ordinal = index + 2), `cur_dylib`, `extern_lib_find(name)` (default 1);
  `#dylib ""` reverts to libSystem. `src/backend_exe.mc` (+56) emits one `LC_LOAD_DYLIB` per
  dylib, puts the ordinal in `n_desc`, and swaps in `BIND_SET_DYLIB_ORD_IMM` per symbol. Verified
  against `/usr/lib/libsqlite3.dylib`: `otool -L` shows both, `nm -m` shows `(from libsqlite3)`,
  `dyld_info -fixups` shows the three binds against the right dylibs, and the program prints
  `3051000` (= SQLite 3.51.0, matching the system's `sqlite3 --version`). `.o` + `ld` ignores
  `#dylib` (`ld` refuses with `symbol(s) not found`), as already documented for M11.
  Proofs: `lib/user_syntax_demo.mc` (64 lines: `unless` via `syntax_stmt`, `enum Name { … }` via
  `syntax` generating `#define`s + an alias, `type_alias("bool", TY_U8)`),
  `lib/syntax_demo_test.mc` (uses all three, exits 42), and the entry point `lib/mc_syntax_demo.mc`
  (`#include "../src/core.mc"` + the demo). New case in `scripts/check-surface.sh` (now
  `check-surface.sh MC0 MC1`, and the target depends on `build/mc1`): `mc1 --exe
  lib/mc_syntax_demo.mc`, the binary compiles the test via `--exe`, runs it, and exits 42 — and
  the default compiler **refuses** the same source (`expected type at the top level`).
  — `make check` green: `budget` 2846/3000, `test` 32/32, `check-lex` 61/61, `check-ast` 61/61,
  `check-asm` 61/61, `check-obj` 32/32, `check-surface` 32/32 + Tier 3, `test-exe` 32/32,
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, 235960 bytes; `--dump-asm` diff between `mc1` and
  `mc2` empty) and golden re-recorded once in `tests/golden/mc2.sha256`
  (`f42cda85…39c28` → `905f52c1…fbbc4`). Self-hosting without `ld` still holds:
  `build/mc1 --exe src/mc.mc -o build/mc-exe` and `build/mc-exe src/mc.mc` identical to `build/mc2.o`.
- M12 done (section B of `docs/specs/M12.md`): **`examples/api`** — a to-do-list HTTP API with SQLite
  persistence, written using `class`, `interface`, `bool`, and `str` — four things the language
  doesn't have. `src/` and `stage0/` **untouched** by this section: the whole surface comes from
  `examples/api/oop.mc` (458 lines, running inside the compiler through the parser's public API)
  plus `examples/api/mc-api.mc` (20 lines: `#include "../../src/core.mc"` + `oop.mc` +
  `user_init()` with two `syntax` and two `type_alias`). The program: `main.mc` (359 lines) with
  `class Request`/`Response`/`Todo`/`Db`, `interface Handler`, and `class TodoHandler : Handler` /
  `class HealthHandler : Handler`; routing via a linear (prefix, `Handler`) table dispatched
  through the vtable (`callp`, M10) — the main loop never knows which handler it is calling. The
  seven `class`/`interface` declarations become **39** ordinary declarations (`--dump-ast`), with
  `TODO_ID=0 TODO_TITLE=8 TODO_DONE=16 TODO_SIZE=24 HANDLER_HANDLE=0 TODOHANDLER_SIZE=8` checked
  by a program that prints them. Libraries from the other agent: `lib/rt.mc` (a fixed 4 MiB arena,
  strbuf, strings), `lib/http.mc` (sockets, HTTP/1.1 request/response), and `lib/sqlite.mc`
  (`#dylib "/usr/lib/libsqlite3.dylib"` + 13 externs + wrappers). Routes: `GET /health` →
  `{"ok":true}`, `GET /todos` → a JSON list, `POST /todos` (body = title) → `201` with the created
  todo, `DELETE /todos/N` → `{"deleted":N}`, 404 for everything else; arguments `PORT DB_PATH`,
  one connection at a time.
  `examples/api/test.sh` (139 lines) starts the server on a free port with a temporary database,
  hits every route with `curl`, compares body **and** status, checks the final state with the
  system's `sqlite3` (`2|pay the bill|0`), and kills the server. `examples/api/Makefile`: `mc-api`,
  `api`, `test-oop`, `test-lib`, `test-api`, `test`, `clean` — no dependency beyond
  `../../build/mc1` (built by the root if missing), `curl`, and `sqlite3`. The root Makefile
  gained `check-examples` (`make -C examples/api test`) inside `make check`.
  Proofs: `build/api` at 55616 bytes, `codesign --verify` OK and `flags=0x2(adhoc)`, `otool -L`
  showing both libSystem **and** libsqlite3, `nm -m` with 13 `_sqlite3_*` symbols
  `(from libsqlite3)`; the default compiler refuses the same source
  (`examples/api/main.mc:27: expected type in the parameter` — `str`).
  Operational detail that cost a build: overwriting a signed executable at the same inode makes
  the kernel kill the next run with `Killed: 9`, so the `Makefile` and `test.sh` `rm -f` the
  target before every build. Docs: `examples/api/README.md` (new) and `docs/surface.md` § Tier 3
  gained "The real example: `examples/api`".
  — `stage0/` untouched, 2846/3000; `make check` green end to end: `test` 32/32, `check-lex`
  61/61, `check-ast` 61/61, `check-asm` 61/61, `check-obj` 32/32, `check-surface` 32/32,
  `test-exe` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`) and golden **unchanged**
  (`905f52c1…fbbc4` matches `tests/golden/mc2.sha256`), `check-examples` green.
- M13 is the next milestone (`docs/specs/M13.md`: sizing a program's memory at compile time — the
  fixed 4 MiB arena in `examples/api/lib/rt.mc` is one more motivating case).
  Update this section when each milestone closes.
