# mc — a self-hosting mini compiler, teachable through its surface

Read `docs/plan.md` before any work: it fixes the language, the teaching surface,
the architecture, the budget, and the milestones. This file only summarizes the operating rules.

## Roles
The user is the owner; the main session is the **architect** and **delegates all creation** to
agents (`.claude/agents/`): `stage0-dev` (C23), `mc-dev` (`.mc` code), `reviewer`, `verifier`,
`docs-writer`, `designer` (site identity/layout/icon), `ts-dev` (VS Code extension). Agents report facts (commands run + output), never assumptions.

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
- `make bundle` regenerates `src/bundle_data.mc` (generated source) from `tools/bundle.list`;
  run it whenever `lib/*.mc` or a core module changes, BEFORE `make bootstrap`. `make check`
  runs `check-bundle` first and fails loudly if the checked-in bundle is stale.
- `scripts/link.sh OUT IN.o` links with `ld -lSystem` (`ld` is allowed; gcc/cc/clang only for stage0).
  Since M11 it's optional: `build/mc1 --exe prog.mc -o prog` writes the signed executable directly.
- `make check-docs` runs `scripts/check-docs.sh`: no undocumented public symbol/flag/TOML key/
  directive, every fenced ` ```mc ` sample in `docs/` compiled (and run when it declares an
  expectation), every relative link resolving.
- `make site` → `build/mc1 build site` (compiles `site/gen/*.mc` into `build/mcsite`) then
  `build/mcsite site`, which renders `docs/` into `site/public`. `make check-site` adds
  `build/mcsite site --check` (internal links in mc, then `site/tools/checkhtml.py` and
  `contrast.py` when `python3` is there). Both are in `make check`, last.
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
  now rejected (`cannot redefine core keyword`), and an overflowed `MAXRULES` now uses `err_at`
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
  `syntax_stmt("return",…)`: `cannot redefine core keyword`).
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
  the default compiler **refuses** the same source (`type expected at top level`).
  — `make check` green: `budget` 2846/3000, `test` 32/32, `check-lex` 61/61, `check-ast` 61/61,
  `check-asm` 61/61, `check-obj` 32/32, `check-surface` 32/32 + Tier 3, `test-exe` 32/32,
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, 235960 bytes; `--dump-asm` diff between `mc1` and
  `mc2` empty) and golden re-recorded once in `tests/golden/mc2.sha256`
  (`f42cda85…39c28` → `905f52c1…fbbc4`). Self-hosting without `ld` still holds:
  `build/mc1 --exe src/mc.mc -o build/mc-exe` and `build/mc-exe src/mc.mc` identical to `build/mc2.o`.
- M12 done (section B of `docs/specs/M12.md`): **`examples/api`** — a to-do-list HTTP API with SQLite
  persistence, written using `class`, `interface`, `bool`, and `str` — four things the language
  doesn't have. `src/` and `stage0/` **untouched** by this section: the whole surface comes from
  `examples/api/oop.mc` (482 lines, running inside the compiler through the parser's public API)
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
  system's `sqlite3` (`2|pay bill|0`), and kills the server. `examples/api/Makefile`: `mc-api`,
  `api`, `test-oop`, `test-lib`, `test-api`, `test`, `clean` — no dependency beyond
  `../../build/mc1` (built by the root if missing), `curl`, and `sqlite3`. The root Makefile
  gained `check-examples` (`make -C examples/api test`) inside `make check`.
  Proofs: `build/api` at 55616 bytes, `codesign --verify` OK and `flags=0x2(adhoc)`, `otool -L`
  showing both libSystem **and** libsqlite3, `nm -m` with 13 `_sqlite3_*` symbols
  `(from libsqlite3)`; the default compiler refuses the same source
  (`examples/api/main.mc:27: type expected in parameter` — `str`).
  Operational detail that cost a build: overwriting a signed executable at the same inode makes
  the kernel kill the next run with `Killed: 9`, so the `Makefile` and `test.sh` `rm -f` the
  target before every build. Docs: `examples/api/README.md` (new) and `docs/surface.md` § Tier 3
  gained "The real example: `examples/api`".
  — `stage0/` untouched, 2846/3000; `make check` green end to end: `test` 32/32, `check-lex`
  61/61, `check-ast` 61/61, `check-asm` 61/61, `check-obj` 32/32, `check-surface` 32/32,
  `test-exe` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`) and golden **unchanged**
  (`905f52c1…fbbc4` matches `tests/golden/mc2.sha256`), `check-examples` green.
- M14 done (`docs/specs/M14.md`, `docs/build.md`): **project driver and `mc.toml`**.
  `mc build [DIR] [--config FILE]` reads a TOML file and drives the whole build; the single-file
  CLI (`mc in.mc -o out.o`, `--exe`, `--backend=`, `--dump-*`) is unchanged, and `stage0/` was not
  touched (2846/3000).
  New files: `src/toml.mc` (475 lines — the TOML subset: `[table]`, `[[array of tables]]`, bare/
  quoted/dotted keys, basic strings with `\" \\ \n \t \r`, integers with `+ - _`, booleans,
  multi-line arrays with a trailing comma; every error is `file:line:col: message` and exit 1).
  The result is deliberately a **flat (path, value, type, index) table in source order**, not a
  tree — the same shape as every other table here (`docs/determinism.md` rule 1): array elements
  share a path and carry an index (`include.paths[0]`), `[[x]]` puts the occurrence in the path
  (`server.0.host`), and values are always text. API: `toml_get`, `toml_get_array`, `toml_count`,
  `toml_int`, plus `toml_entries`/`toml_path_at`/`toml_val_at` — that last trio is what makes
  `[libs]`/`[externs]` work, since the driver needs the KEYS of a table.
  `src/tomldump.mc` (66) prints the table — the pretty-printer lives in the DRIVER, not in
  `toml.mc`, because the compiler carries `toml.mc` in every binary and a dump nobody calls is a
  dozen string literals against the seed's `MAXSTRS`; `scripts/check-toml.sh` (66) compares it against
  `tests/toml/*.expect` — 5 well-formed files and 5 malformed ones (`bad-string`, `bad-equals`,
  `bad-header`, `bad-escape`, `bad-value`) whose `.expect` holds the exact `file:line:col`.
  `src/driver.mc` (421) implements `[project] name/entry/out/kind`, `[target] os/arch`
  (macos/aarch64 only — anything else is an error pointing at the offending value),
  `[compiler] core/modules/out`, `[linker] cmd/args`, `[libs]`, `[externs]`, `[include].paths`.
  Every path is relative to the CONFIG's directory. Two shapes: with no `[compiler]` the entry is
  compiled in-process; with it, the driver writes `<compiler.out>.mc` (`#include` of the core plus
  each module, `../`-adjusted because the generated file lives next to the compiler), compiles it
  with `macho-exe`, and **spawns** the result as `<compiler> build DIR --config FILE --entry-only`
  — the compiler's tables are globals built once per process, so two compilations never fit in one
  run; `--entry-only` is the second half and re-reads the same TOML, which is why
  `[include]/[libs]/[externs]` apply either way. `[linker]` substitutes `{out} {obj} {sdk}` inside
  each argument and expands `{libs}` (a whole argument) into one argument per `[libs]` entry, each
  also substituted; `{sdk}` runs `xcrun --show-sdk-path` lazily, capturing stdout with a
  `posix_spawn_file_actions_addopen` on fd 1 into `<out>.sdk`, read back and unlinked. Tools are
  spawned with `posix_spawnp` + `waitpid` (inherited stderr, so their diagnostics pass through;
  non-zero exit -> exit 1). Outputs get their parent directories created and are `unlink`ed before
  writing (the cached-signature `SIGKILL`).
  Support changes (`git diff --numstat`): `src/lex.mc` +38/-1 (`lex_add_include_path`/
  `lex_readable`, extra `#include` roots tried only after the includer's own directory fails; with
  none registered, not even an extra `open` happens), `src/parse.mc` +41/-1
  (`extern_lib_pattern_add`/`extern_pat_match`, `MAXEXTPAT 32`; `extern_lib_find` consults the
  exact `#dylib` table FIRST, so `#dylib` in the source still wins),
  `src/main.mc` +6 (dispatch on `argv[1] == "build"`, after the backends are registered),
  `src/core.mc` +4, `lib/sys.mc` +19 (`posix_spawnp`/`waitpid`/`_NSGetEnviron` for programs;
  documented as having **no** `lib/sys_svc.mc` equivalent — `posix_spawn` is not a syscall, it is
  a libSystem routine marshalling a struct this language cannot lay out).
  Two limits in `src/gen_arm64.mc` (+12/-2) deliberately diverge from the C seed for the first time:
  `MAXSTRS 512 -> 2048` and `MAXGLOBALS 256 -> 512`. Reason (same as MAXFUNCS at M11): stage0 only
  has to compile ONE program, `src/mc.mc` (493 strings, 169 globals — under the C limits, which
  `make bootstrap` keeps proving), while `src/core.mc` + a taught compiler on top of it
  (`examples/api/mc-api.mc` = core + oop) went past 512 strings once `toml.mc`/`driver.mc` joined
  the core. Raising a ceiling only changes behaviour above the old one, so the whole
  check-lex/ast/asm corpus still comes out identical under `mc0` and `mc1`.
  Proofs: `examples/api/mc.toml` (40 lines) — `build/mc1 build examples/api` prints
  `compiler build/mc-api.mc -> build/mc-api` / `compile main.mc -> build/api` and produces both
  binaries (253475 and 55632 bytes, `codesign --verify` OK, `otool -L` with libSystem **and**
  libsqlite3 bound by ordinal from `[libs]`/`[externs]`); `examples/api/test.sh` now compiles with
  `mc build` and all 11 route checks pass; the Makefile keeps working as the by-hand path.
  `tests/proj/` (one program, three configs) + `scripts/check-build.sh` (160) cover
  `[include].paths` (the `#include` only resolves through it), `[libs]`/`[externs]` with **no**
  `#dylib` anywhere, `[linker]` with all four placeholders through real `ld`, `kind = "obj"`, and
  four diagnostics. New `make` targets `check-toml` and `check-build`, both inside `make check`.
  Docs: `docs/build.md` (381, new), `docs/surface.md` § "M14 — the same three things said from
  outside the source", `examples/api/README.md` § 3 and `examples/api/Makefile` header.
  — `stage0/` untouched, 2846/3000; `src/*.mc` 7731 lines; 674/1024 functions in `src/mc.mc`
  (350 of headroom), 489/512 strings and 169/256 globals under the C seed's limits -- the
  string budget is the tight one, and `MAXSTRS` in `stage0/gen_arm64.c` is the ceiling M15 will
  probably have to raise.
  `make check` green end to end: `test` 32/32, `check-lex` 64/64, `check-ast` 64/64, `check-asm`
  64/64, `check-obj` 32/32, `check-surface` 32/32 + Tier 3, `test-exe` 32/32, `check-toml` 8/8,
  `check-build` 10/10, `check-examples` green, `bootstrap` at a fixed point (`mc2.o == mc3.o`,
  267552 bytes; the `--dump-asm` diff between `mc1` and `mc2` is empty) and golden rewritten once
  in `tests/golden/mc2.sha256` (`d92fad26…cb69f` -> `20564a98…f343e`).
- M15 done (`docs/specs/M15.md`, `docs/build.md` § M15, `docs/bootstrap.md` § M15):
  **bundled standard library, `#include <name>`, `#embed`**. The binary alone is the toolchain.
  New: `src/lz.mc` (199, LZ77 both ways, zero dependencies — not even `arena.mc` — so
  `#include <lz>` is enough for a program; deterministic hash chain in bss, reset per call;
  a 3-byte match is refused while a literal run is pending, which is what makes
  `lz_bound(n) = n + n/128 + 8` a true bound), `src/bundle.mc` (229, `bundle_find`/
  `bundle_read` with lazy inflate + cache, and `bundle_emit`, the ONE definition of the
  generated file's format), `src/bundle_data.mc` (generated, 2845 lines / 323997 B),
  `tools/bundle.list` (27 entries) + `tools/bundle.mc` (186) + `tools/lz_test.mc` (151),
  `tests/mc/070-embed.mc`, `071-embed-lz.mc`, `072-include-bundle.mc` (+ 2 data files),
  `scripts/check-mc.sh` (80), `scripts/check-bundle.sh` (55), `scripts/check-standalone.sh` (140).
  Edited: `src/lex.mc` (+88: `fvirt`, `lex_push_mem`, `lex_find_path`, `lex_seen`/`lex_remember`,
  `lex_strip_mc`, `lex_include_bundled`/`lex_include_name`, `D_EMBED`, the `bopen_fn` hook),
  `src/parse.mc` (+88: `#include <name>` and `do_embed`), `src/core.mc`, `src/main.mc`,
  `src/astdump.mc`, `src/driver.mc` (default core = `<mc/core>`), `examples/api/mc-api.mc` +
  `mc.toml` (no more `core = "../../src/core.mc"`), `Makefile`, docs.
  Design notes worth keeping:
  * **The lexer does not tokenize `<name>`.** `#include <mc/core>` is `<`, the lexemes and `>`,
    reassembled in `do_directive`. So `--dump-tokens` stays byte for byte what the frozen
    `stage0/lex.c` produces and `check-lex` keeps comparing the two lexers over the whole tree.
  * **The lexer does not depend on `src/bundle.mc`** either: `main.mc` registers `bundle_open`
    through one function pointer (`lex_set_bundle`), so `src/lexdump.mc` and `src/astdump.mc`
    stay bundle-free and `check-lex`/`check-ast` keep compiling them with `mc0`.
  * **`mc/bundle_data` is regenerated on the fly** from the in-memory blob (the bundle cannot
    contain itself), which is what makes `<mc/core>` complete. Proof:
    `#include <mc/core>` + `#include <user_default>` compiles to an object **identical to
    `build/mc2.o`** (`scripts/check-standalone.sh`).
  * **Relative includes inside a bundled file** resolve by name: join + normalize + drop `.mc`,
    then fall back to the last path component (`mc/driver` → `"../lib/prelude.mc"` → `prelude`).
    `tools/bundle.mc` refuses a manifest with two entries sharing a last component.
  * **`u64` hex elements, not `u8` decimal**, in `bundle_blob`: the parser makes one AST node per
    initializer element and the frozen stage0 has a 32 MiB arena with 72-byte nodes — 134 KB of
    bytes exhausts it (measured), as `u64` it costs ~17k nodes. Hex because an element ≥ 2^63
    would need an unsigned divide to print in decimal.
  — `stage0/` untouched, 2846/3000; `src/*.mc` 11205 lines (2845 of them generated);
  **708/1024 functions** in `src/mc.mc` (316 of headroom), **500/512 strings**, 177/256 globals.
  `make check` green end to end: `test` 32/32, `check-lex` 67/67, `check-ast` 67/67,
  `check-asm` 67/67, `check-obj` 32/32, `check-bundle` (reproducible + fresh), `check-surface`
  32/32 + Tier 3, `test-exe` 32/32, `check-mc` 5/5, `check-standalone` green, `check-toml` 8/8,
  `check-build` 10/10, `check-examples` green, `bootstrap` at a fixed point (`mc2.o == mc3.o`,
  416664 bytes; the `--dump-asm` diff between `mc1` and `mc2` is empty) and golden rewritten once
  (`20564a98…f343e` -> `dea82035…4eb38`).
  Sizes: source 304346 B -> LZ 134604 B (44%), blob 134870 B; `build/mc-exe` 252316 B without
  the blob -> **384419 B** with it.
  **The string budget is now the binding constraint**: the core is at 500/512 and
  `lib/mc_syntax_demo.mc` (which `check-asm` compiles with `mc0`) at 508/512 — four literals of
  headroom for the whole repository. M16 will have to either raise `MAXSTRS` in
  `stage0/gen_arm64.c` (a seed change the owner has to authorize) or put the next milestone's
  messages on a diet.
- M16 done (`docs/specs/M16.md`, `docs/build.md` § Linux targets): **Linux arm64 — ELF64
  objects, a musl link and a system layer with no libc**. `stage0/` untouched (2846/3000): the
  ELF writer is a backend in `.mc`.
  New: `src/backend_elf.mc` (472 lines, backend `elf-obj`) — ELF64 `ET_REL`/`EM_AARCH64` on top of
  `gen_lower` + `gen_encode_all`, the same sections/symbols/relocations the Mach-O writer reads.
  Sections come out null, then the module's in creation order (`__TEXT,__text` -> `.text` AX 4,
  `__TEXT,__cstring` -> `.rodata` A 1, `__DATA,__data` -> `.data` WA 16, `__DATA,__bss` -> `.bss`
  NOBITS WA 16, `#section SEG SECT` -> `.seg.sect` with the leading underscores dropped and
  lowercased, AX when the Mach-O flags say pure-instructions and NOBITS when they say zerofill),
  then one `.rela.X` (SHF_INFO_LINK, `sh_link` = symtab, `sh_info` = X) per section with
  relocations, then `.symtab`/`.strtab`/`.shstrtab` — so a module section index is its ELF index
  minus one and `st_shndx` is `sym_sect` unchanged. Symbols: the compiler's leading `_` dropped
  (`_main` -> `main`), string labels as assembler temporaries (`l_str0` -> `.Lstr0`), STT_FUNC in a
  pure-instructions section / STT_OBJECT otherwise / STT_NOTYPE undefined, and `macho.mc`'s stable
  partition reused verbatim (locals, defined globals, undefined) because that is exactly what ELF
  requires — `sh_info` = 1 + locals. Relocations: `R_BRANCH26` -> `CALL26` (283), `R_PAGE21` ->
  `ADR_PREL_PG_HI21` (275), `R_PAGEOFF12` -> `ADD_ABS_LO12_NC` (277) on an `add` and
  `LDST{8,16,32,64}_ABS_LO12_NC` (278/284/285/286) on an ldr/str by the access width in bits 31:30
  (the same classifier `exe_fix_pageoff12` uses), `R_UNSIGNED` -> `ABS64` (257); sorted by ascending
  offset (stable insertion sort, which is one pass because the encoder already emits them in order)
  and `r_addend` always 0, since the encoder leaves the relocated immediate zeroed.
  `lib/sys_linux.mc` (123): `open`/`creat`/`read`/`write`/`close`/`fchmod`/`exit` as raw `svc #0`
  with the number in `x8` (openat 56 with `AT_FDCWD` = -100 written as `movn x0, #99`, close 57,
  read 63, write 64, fchmod 52, exit_group 94) plus `_start`, written with `#opcode`, which reads
  `argc`/`argv` off the entry stack (`x29 + 16` / `x29 + 24`: the function has no parameters and no
  locals, so the frame is empty and the prologue only moved the 16 bytes of the `stp`), calls `main`
  through `reloc(BRANCH26, "_main")` + `emit(0x94000000)` and ends in exit_group. Bundled as
  `sys_linux` (the spec wrote `<sys/linux>`; the flat name was the instruction that came with the
  task). `O_RDONLY/O_WRONLY/O_CREAT/O_TRUNC` moved out of `lib/io.mc` into each system layer,
  because they are per-system values (`O_CREAT` is 0x200 on macOS and 0x40 on Linux) and a second
  `#define` of the same name is an error.
  Driver (`src/driver.mc` +36/-7): `[target].os` takes `linux`, which swaps the object backend for
  `elf-obj` and makes `[linker]` REQUIRED (`linux requires [linker]: there is no direct executable`);
  new `{sysroot}` placeholder from `[sysroot].path`, resolved against the config's directory like
  every other path. The taught compiler is still built with `macho-exe` — it is a tool that has to
  run on the host.
  Scripts: `scripts/sysroot-linux.sh` (45) fills `build/sysroot/linux-aarch64` with
  `crt1.o crti.o crtn.o libc.a libc.so` from `apk add musl-dev` inside `alpine:3` (3.24.1), cached;
  `scripts/test-linux.sh` (123) generates a Linux `mc.toml` per test in a temp dir, builds it with
  `mc build`, links with `ld.lld` and runs it in `docker run --rm --platform linux/arm64
  -v <repo>:/w -w /w alpine:3` (the repo is the mount because `025-linecount` opens its own source
  by a relative path). `make test-linux` is inside `make check`, guarded: without `ld.lld` or with
  Docker down it prints `test-linux: SKIPPED (...)` and the build stays green.
  `tests/032-svc.mc` carries the only `// skip-linux` header (Darwin syscall numbers in x16 and
  `svc #0x80`); everything else is portable as written, `030-section` and `033-reloc` included.
  `tests/linux/070-nolibc.mc` is the no-libc case: `#include <sys_linux>` linked with
  `-nostdlib -e _start`.
  Verified field by field against `clang --target=aarch64-linux-musl -c` of equivalent C with
  `llvm-readobj`/`llvm-objdump -dr`: header, section flags, `.rela` `sh_flags`/`sh_link`/`sh_info`,
  symtab `sh_link`/`sh_info` and every relocation type agree. The one intentional difference is that
  `mc` always materializes a global address with `adrp` + `add`, so it asks for `ADD_ABS_LO12_NC`
  where clang folds the offset into the load and asks for `LDST64_ABS_LO12_NC`.
  Known limit: the compiler itself does not cross-compile yet — `src/driver.mc` needs
  `posix_spawnp`/`waitpid`/`_NSGetEnviron`, and the last one is libSystem-only.
  — `stage0/` untouched, 2846/3000; `src/*.mc` 12062 lines (3139 of them generated);
  739/2048 functions and 518/2048 strings in `src/mc.mc`. `make check` green end to end:
  `test` 32/32, `check-lex` 69/69, `check-ast` 69/69, `check-bundle` (31 files, blob 148754 B),
  `check-asm` 69/69, `check-obj` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`,
  448416 bytes; the `--dump-asm` diff between `mc1` and `mc2` is empty), `check-surface` 32/32,
  `test-exe` 32/32, `check-mc` 6/6, `check-standalone` green, `check-toml` 9/9, `check-build`
  11/11, **`test-linux` 32/32 on linux/arm64** (1 skipped), `check-examples` green; golden rewritten
  once (`2673c65e...4a3ed5` -> `f20c1332...e14aa0`).
- M21 done (`docs/specs/M21.md`, `docs/surface.md` § M21): **Tier 3 completed — expression and
  operator hooks, source record and replay, hygienic substitution**. All in `src/*.mc`;
  `stage0/` untouched. Delivered in the two gated steps the spec asks for (decision 7.5), each
  with `make check` green and the golden rewritten once.
  * **Step 1 — parser hooks.** `syntax_expr(word, &f)` (`i64 f()` -> node index) dispatched as the
    first thing in `parse_primary`, with the same "consumed no tokens" guard as
    `syntax`/`syntax_stmt` plus a second one, `syntax_expr handler produced no expression`, because
    an expression position has no empty node to fall back on. `syntax_infix(word, prec, &f)`
    (`i64 f(i64 left)`) keeps **no table of its own**: the `#infix` entry gained one column
    (`INF_FN 32`, `INF_SIZE` 32 -> 40), which is what puts a taught operator and a `#infix` one in
    one comparable precedence order; `infix_set` clears the column, so a `#infix` on the token
    drops the handler (`tests/err/066-infix-drops-handler.mc`). A second `syntax_infix` on the same
    token is refused at `user_init` time (`operator already taught: <tok>`, decision 7.3,
    `lib/user_dupop.mc`). `infix_is_taught` was added so `err_name` blames only operators that
    carry a handler, never `+`, and `word_is_taught` now covers all five registrations — its
    message became `name reserved by a syntax/type_alias registration`. `p_start()`/`p_depth()`.
    `--dump-rules` now also lists every infix/prefix operator with precedence, associativity,
    `template` and `handler` (decision 7.2) — a half that exists only in the `.mc` compiler, since
    the frozen `stage0/parse.c` has no handler column to report.
  * **Step 2 — record/replay.** `p_skip_balanced(open, close, &len)` counts depth over **real
    tokens** (so a `}` inside a string or a comment is harmless) and returns the source span,
    delimiters included, reporting an unterminated region at the **opening** token.
    A span is a slice of ONE buffer, so a region whose file ran out in the middle is refused
    (`region crosses a file boundary`) instead of returning a bogus byte range.
    `p_push_source(name, text, len)` is four lines over `lex_push_mem`, with `#include`'s exact
    semantics — which is why error attribution costs **zero** core lines: `err_at` prints
    `lex_file()`, so the module composes `slot__i64__0 instantiated from prog.mc:15` and gets it in
    front of every error inside. `p_subst_reset`/`p_subst_name`/`p_subst_int` live in `src/lex.mc`
    and are applied in `lex_next`'s **identifier branch only**, by exact lexeme: the pending
    entries sit in the slot the next frame will occupy, so the push binds them by construction and
    `lex_pop` clears the slot it vacates (`MAXSUBST 16`, nested frames independent, one slot more
    than `MAXOPEN` because the pending slot of a full stack is index `MAXOPEN`).
    `p_resplit_punct(n)` rewinds `cp` to just after the first `n` bytes of the current punctuation
    token, guarded by `cp == tok_start(cur) + tok_len(cur)` — which is exactly "a token just lexed
    from the source", never a string and never a substituted identifier. `MAXOPEN` 16 -> 32
    (`stage0` stays at 16: it has no `p_push_source` at all, the same kind of documented divergence
    as `MAXSTRS`/`MAXGLOBALS` in `gen_arm64.mc`).
  * **The demo is a toy unrelated to classes and generics**, so generality is proven and not
    asserted: `lib/user_syntax_demo.mc` (67 -> 391) keeps M12's `unless`/`enum`/`bool` and adds
    `bits u32` (a **type** in expression position), `pipe(x, f, g)` (a variable-length list there),
    `.+` (saturating add, lowering to a runtime the module itself pushes as a second source at
    `user_init`), `~>` (a **name** on the right resolved in the module's own field table, plus
    `p ~> len = 3` — which works because `=` is deliberately not in the infix table — and
    `p ~> at(i)`), and `tmpl`/`make`: the body recorded with `p_skip_balanced`, replayed once per
    argument tuple with `p_subst_name`/`p_subst_int`, memoized by the module's own mangled name,
    with `make slot<i64, sum<1, 2>>;` closing on a `>>` that `p_resplit_punct` splits. Two
    handlers (`nop`, `nil`) are broken on purpose and exist only to prove the two guards.
    `lib/syntax_demo_test.mc` (26 -> 65) uses all nine registrations plus a `#infix "<+>"` in the
    same file, and exits 42.
  * **Inert by construction** is the acceptance gate and it holds: with nothing registered every
    `tests/*.mc` object and every `--dump-ast` is byte-identical to `build/mc0`'s — the frozen C
    seed, which has none of this. `scripts/check-surface.sh` (163 -> 302) gained one case per hook,
    the four `tests/err/` cases with their exact message, the duplicate registration, the demo test
    compiled twice byte for byte, and that inertness check.
  — core cost: `src/hooks.mc` +64/-5, `src/parse.mc` +157/-8, `src/lex.mc` +77/-1 = **+298 lines,
  175 of them non-comment** against the spec's ~146/~110 estimate; the excess is `dump_ops`
  (27 lines, decision 7.2, outside the 2.x cost table), the three handler guards and the duplicate
  refusal (~20), the per-frame substitution bookkeeping (~15 over the 40 estimated) and this
  repository’s comment density (109 comments + 14 blank of the 298). New: `lib/user_dupop.mc` (18),
  `tests/err/063-tmpl-attrib.mc`, `064-expr-noadvance.mc`, `065-expr-nonode.mc`,
  `066-infix-drops-handler.mc`; `tools/bundle.list` gained `user_dupop` (30 entries).
  `stage0/` untouched, 2846/3000. `make check` green end to end: `test` 32/32, `check-lex` 68/68,
  `check-ast` 68/68, `check-asm` 68/68, `check-obj` 32/32, `check-bundle` fresh, `check-surface`
  32/32 + every M21 case, `test-exe` 32/32, `check-mc` 6/6, `check-standalone` green,
  `check-toml` 9/9, `check-build` 10/10, `check-examples` green, `bootstrap` at a fixed point
  (`mc2.o == mc3.o`, 442048 bytes; the `--dump-asm` diff between `mc1` and `mc2` is empty) and the
  golden rewritten **twice**, once per step (`e1bfc16e…6548e` then `b2579419…51be6`).
  Sizes: bundle 336730 B of source -> 149952 B of LZ (30 files); `build/mc-exe` 402211 B.
- M16 + M21 merged (2026-09-03): the two milestones were developed in parallel (M16 on a branch,
  M21 in the working tree) and brought together in one tree. They do not overlap in code: M16 is
  `src/backend_elf.mc` + `lib/sys_linux.mc` + the driver's `os = "linux"` route, M21 is
  `src/hooks.mc`/`src/parse.mc`/`src/lex.mc`. Only four files had to be reconciled by hand:
  `CLAUDE.md` § State and `docs/surface.md`'s header (both entries kept, the backend list is now
  three: `macho`, `macho-exe`, `elf-obj`), and the two generated artefacts — `src/bundle_data.mc`
  and `tests/golden/mc2.sha256` — which were discarded on both sides and regenerated
  (`tools/bundle.list` merged on its own: 32 entries, M16's `sys_linux`/`mc/backend_elf` plus
  M21's `user_dupop`). **The numbers in the two entries above are each milestone's own; the
  merged tree's are these.**
  — `stage0/` untouched, 2846/3000; `src/*.mc` 12624 lines (3417 of them generated).
  `make check` green end to end (RC 0): `test` 32/32, `check-lex` 70/70, `check-ast` 70/70,
  `check-bundle` (32 files, raw 360287 B -> LZ 161755 B, blob 162083 B), `check-asm` 70/70,
  `check-obj` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 470664 bytes; the
  `--dump-asm` diff between `mc1` and `mc2` is empty), `check-surface` 32/32 + every M21 case,
  `test-exe` 32/32, `check-mc` 6/6, `check-standalone` green, `check-toml` 9/9, `check-build`
  11/11, `test-linux` 32/32 on linux/arm64 (1 skipped: `032-svc`), `check-examples` green.
  Golden rewritten **once** for the merge, after the two gates:
  `b2579419…51be6` (M21) / `f20c1332…e14aa0` (M16) ->
  `0bfa736630cd50ce99671f95990b8b80e79cb1bb6248bdb197be11e948720788`.
  `build/mc-exe` 437011 B.
- M22 done (`docs/specs/M22.md`): **`examples/lang`** — the `lx` language (classes, interfaces,
  generics with `where` constraints, namespaces, `ref` parameters, reference counting) taught to
  `mc` by a prelude. Nothing in `src/`, `stage0/`, `lib/`, `tests/` or `docs/` was touched: the
  whole language is `examples/lang/*.mc` (9 modules, 2810 lines) registering M12/M21 hooks, plus
  `lib/rt.mc` (204, a 4 MiB arena with free lists by size class and `rc_inc`/`rc_dec`) and
  `lib/prelude.lx` (30). `mc build` assembles the taught compiler from `examples/lang/mc.toml` and
  compiles `main.lx` with it; `examples/lang/test.sh` (= `make check-lang`, inside `make check`)
  runs 12 `.lx` tests, the sample, `--dump-asm` (mangled generic instantiations and vtables),
  `--dump-rules`, a byte-for-byte re-compile, and the check that the DEFAULT compiler refuses the
  same source. Deviation on record: `[compiler].core = "lang_core.mc"` (a copy of `src/core.mc`'s
  include list without `bundle_data.mc`/`bundle.mc`/`backend_elf.mc`), because `<mc/core>` plus a
  module of this size exhausted the 32 MiB arena — M23's growable arena removes that cause, but
  the example was left as it was verified. (M21.5 removed the cost itself and DELETED both copies;
  `mc.toml` has no `core` key any more.) Open gaps reported to the architect and kept in
  `examples/lang/README.md` § Limits: `arena exhausted` carries no position, `parse_block()`
  bypasses `syntax_stmt("{")`, `syntax_stmt` cannot own `return`/`break`/`continue`, there is no
  hook for a core-declared local, and `parse_call` hard-codes `TY_I64`.
  — `make check` green with `check-lang` added; golden **not** rewritten by M22.
- M23 done (`docs/specs/M23.md`, `docs/build.md` § limits, `docs/determinism.md` § capacity):
  **dynamic limits — growable tables, one estimate, one tolerance, no ceilings**. `stage0/`
  untouched (2846/3000): the C seed keeps every `MAX*` it had, and the whole change is in `src/`.
  * **Growable tables.** Every `MAX*`-sized array in `src/` became an arena block that doubles on
    demand through one helper, `grow(id, p, n, &cap, elem)` in `src/arena.mc` (+179/-4), called at
    the append site where the `if (n == MAX) die(...)` used to be; `grow_to()` re-sizes the
    parallel arrays that share a counter (the seven `fn_*`, the three `prel_*`, `xs_*`, `xg_*`,
    `syn_*`, `alias_*`, `extlib_*`, `extpat_*`). 34 tables in all, in a fixed registry
    (`T_TOKENS`..`T_HEAP`) that also records estimate / reserve / high-water / growth events.
    Insertion order is untouched by a growth, so nothing the compiler emits can depend on it.
    `MAX*` is gone from `src/` except `MAXPARAMS` (8, the ABI), `MAXDEPTH` (64, the
    `expression too deep` bound) and `MAXBIND`/`MAXRDEPTH`/`MAXITEMS`/`MAXNAMES`, which bound ONE
    `#rule` and size the inline fields of a rule record.
  * **The arena** is the static 32 MiB `heap[]` plus, when it runs out, one `mmap` chunk per
    growth (`extern uptr mmap(...)` in `src/arena.mc`, same prototype added to `lib/sys.mc`).
    Chunks are never moved and never freed, so every pointer stays valid; `arena exhausted` now
    only happens if the kernel refuses.
  * **The estimate** (`src/limits.mc`, 586 lines, new): a byte-level pre-scan of the entry plus
    every include it can reach — relative ones from disk, `<name>` ones from the bundle (inflated
    once and cached, so the lexer pays nothing twice), following only a `#include` that OPENS a
    line (the ones inside `//` comments and inside the string literals `driver.mc` writes are not
    directives). Coefficients, calibrated against `src/mc.mc` and documented in `docs/build.md`:
    `nodes = bytes/11`, `ins = nodes*9/10`, `strings = quotes/3`, `funcs = ") {"`,
    `globals = funcs/3`, `defines = "#define"`, `symbols = funcs+globals+strings`,
    `heap = sum(count*record)*5/3 + 7*bytes`. Measured on `src/mc.mc` (690 KB, 21 files): nodes
    +2%, heap +3%, defines +4%, strings +5%, ins +7%, funcs +13%, symbols +13%, globals +29%,
    includes exact. The token table is deliberately not byte-derived (it holds distinct lexemes).
  * **Remembered usage**: `mc build` writes `build/.mc-usage.toml`, ONE SECTION PER COMPILED
    SOURCE (`[usage."main.mc"]`) — a project with a `[compiler]` compiles two sources of very
    different sizes in two processes and neither should pre-size the other. The next build takes
    the larger of its own section and the static estimate. Capacities only; the output never
    depends on it.
  * **`[limits] tolerance = 0.25`** (default), a float in `[0, 1]`. `src/toml.mc` (+69/-9) reads a
    decimal float as BASIS POINTS (`i64`, `0.25` -> 2500), at most four fraction digits;
    `TV_FLOAT` prints as `bp` in `src/tomldump.mc`. Out of range is
    `examples/api/mc.toml:46:13: tolerance must be between 0 and 1` (`toml_err_val`, no key
    appended); `tests/toml/values.toml` gained five float cases and `tests/toml/bad-float.toml`
    the fifth-digit error.
  * **`mc limits [DIR|FILE.mc]`** and **`mc build --limits`** (`src/driver.mc` +109/-31): one line
    per table with estimate, reserved, used, growth events and a verdict (`ok`, `tight` = used
    over 90% of reserved, `grew`), exit **0 / 3 / 1**. `mc limits FILE.mc` runs the real pipeline
    up to `gen_encode_all()` and writes no object. A project with a `[compiler]` prints two
    reports (compiler first, entry second — the child gets the same flag) and returns the worse
    verdict.
  * **`mc build --fix-limits`** rewrites ONLY the `[limits]` section — the smallest multiple of
    0.05 in `[0, 1]` that would have avoided `grew` and `tight` against the STATIC estimate (what
    a clean checkout has); every other byte of `mc.toml` comes out as it went in. When `1.0` is
    not enough it says so and leaves the file alone (the remembered usage, just written, is what
    covers that case). Never writes without the flag.
  * **`make check-limits`** (`scripts/check-limits.sh`, 85 lines, new, inside `make check`): the
    seed guard the architect lacked at M15 — `mc limits src/mc.mc` against the constants read
    straight out of `stage0/mc.h`/`stage0/*.c`, failing above 90%. Today: tokens 51/2048 (2%),
    defines 454/2048 (22%), funcs 788/2048 (38%), globals 231/512 (45%), strings 539/2048 (26%),
    locals 25/256 (9%) — **16/16 under 90%**.
  Proofs: a generated program with **5000 functions and 5000 string literals** (well past the
  seed's `MAXFUNCS`/`MAXSTRS` of 2048) builds with no TOML change and runs (exit 42); `mc limits`
  gives `grew` on the first build (nodes/strings/ins/heap) and `ok` on the second, whose arena
  high-water also drops from 35 MB to 20 MB. `tolerance = 0` on `examples/api` grows and exits 3;
  `--fix-limits` moves the file from `0.0` to `0.95` and `diff` shows that single line; the next
  run with the usage file deleted exits 0. `tolerance = 1.5` is refused at `mc.toml:46:13`.
  — `stage0/` untouched, 2846/3000; `src/*.mc` 12596 lines (3238 of them generated);
  `make check` green end to end: `test` 32/32, `check-lex` 68/68, `check-ast` 68/68,
  `check-asm` 68/68, `check-obj` 32/32, `check-bundle` (reproducible + fresh, 30 files),
  `check-surface` 32/32 + Tier 3, `test-exe` 32/32, `check-mc` 6/6, `check-standalone` green,
  `check-toml` 10/10, `check-build` 10/10, `check-limits` 16/16, `check-examples` green,
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, 469752 bytes; the `--dump-asm` diff between
  `mc1` and `mc2` is empty) and golden rewritten once
  (`2673c65e...94a3ed5` -> `743302fa...0e3e752ff`).
- M22 + M23 merged (2026-09-03): same situation as M16 + M21 — M22 (`examples/lang`) was in the
  working tree and M23 (dynamic limits) on a branch forked BEFORE the M16 + M21 merge, so the
  three-way apply had to reconcile five files by hand: `CLAUDE.md` § State and `docs/build.md`
  (both entries kept), the `Makefile` (`check-limits` **and** `test-linux`/`check-lang` in
  `check:` and `.PHONY`), `src/driver.mc` (M16's `drv_obj_backend()` with M23's extra `entry`
  argument to `drv_compile`) and `src/lex.mc` — the only semantic one: M23 deleted `MAXOPEN`, and
  M21's four substitution arrays were sized `(MAXOPEN + 1) * MAXSUBST`. They are parallel to the
  frame stack, so they now follow it: `lex_push_mem` re-sizes them with `grow_to` whenever
  `fstack` grows, copying `nopen + 1` slots so the PENDING slot survives the growth. `MAXSUBST`
  stays — it bounds one frame, like `MAXDEPTH`. `src/bundle_data.mc` and `tests/golden/mc2.sha256`
  were kept out of the patch and regenerated. Two tables M23 could not see, because they arrived
  with M16 and M21, were brought under the same rule instead of keeping a ceiling: the ELF section
  table (`src/backend_elf.mc`, `MAXELFSEC 128` gone) is allocated at exactly `2 * nsections + 4`
  slots, and `src/limits.mc` reaches the bundle through the lexer's `bopen_fn` pointer rather than
  calling `bundle_open`, so a taught compiler assembled without `src/bundle.mc` still links —
  which is what `examples/lang/lang_core.mc` was (it gained `#include "../../src/limits.mc"`, its
  only edit; the file is gone since M21.5). **The numbers in the two entries above are each milestone's own; the merged tree's
  are these.**
  — `stage0/` untouched, 2846/3000; `src/*.mc` 13965 lines (3779 of them generated);
  836/2048 functions, 571/2048 strings and 259/512 globals in `src/mc.mc` against the C seed.
  `make check` green end to end (RC 0): `test` 32/32, `check-lex` 71/71, `check-ast` 71/71,
  `check-bundle` (33 files, raw 396273 B -> LZ 179062 B, blob 179400 B), `check-asm` 71/71,
  `check-obj` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 523120 bytes; the
  `--dump-asm` diff between `mc1` and `mc2` is empty), `check-surface` 32/32 + every M21 case,
  `test-exe` 32/32, `check-mc` 6/6, `check-standalone` green, `check-toml` 10/10,
  `check-build` 11/11, `check-limits` 16/16 under 90%, `test-linux` 32/32 on linux/arm64
  (1 skipped: `032-svc`), `check-examples` green, `check-lang` green (12 tests + main.lx).
  Golden: the tree goes from `0bfa7366…20788` (the M22 working tree) and `743302fa…e752ff` (the
  M23 branch) to a single new value,
  `94db4b12b772d418ae44399b4ecd984d790c92c2bfb12798a568a70112f11918` — written twice during the
  merge (once for the regenerated bundle, once after the last `src/limits.mc` edit), each time
  only after `diff <(build/mc1 --dump-asm src/mc.mc) <(build/mc2 --dump-asm src/mc.mc)` came out
  empty and `cmp build/mc2.o build/mc3.o` matched.
  `build/mc-exe` 474355 B. M23's own acceptance re-run on the merged tree: a generated program
  with 5000 functions and 5000 string literals builds with no TOML change (`grew`, exit 3, then
  `ok`, exit 0) and exits 42; `mc limits examples/api` is exit 3 cold and exit 0 remembered;
  `tolerance = 1.5` is refused at `examples/api/mc.toml:46:13`.
- M21.5 done (`docs/specs/M21.5.md`, `docs/surface.md` § Tier 3 + `#embed`, `docs/build.md` §
  `[compiler]` / `mc/bundle_data` / limits): **the six follow-ups `examples/lang` exposed.**
  1. **`#embed` costs one AST node.** The payload was one `N_INT` per byte; it is now a single
     `N_BLOB` node (`src/ast.mc`, kind 25) whose `name` is the address and `val` the length, and
     `glob_place` copies the bytes straight into the section (`src/gen_arm64.mc`, +2 lines). The
     objects are byte for byte what they were (`tests/mc/070/071/073` compared against the
     pre-change `build/mc-exe`). That is what makes the bundle embeddable: `bundle_emit` gained a
     `mode` (`src/bundle.mc`) and the copy the BINARY regenerates, `mc/bundle_data`, is now
     `#embed bundle_blob "bundle.bin"` + the index — **40 lines / 989 bytes** instead of 3910
     lines / 445 898 bytes. `mc/bundle.bin` is a second synthetic index (`BUNDLE_BIN`) that serves
     `bundle_blob` itself, with no inflate and no copy; `bundle_bin_size()` rounds it up to a
     multiple of 8 so the `#embed` global has exactly the size `u64 bundle_blob[]` had, and the
     two forms produce the SAME object (`check-standalone`: `<mc/core> + <user_default> ==
     src/mc.mc, byte for byte`).
     **Deviation, on record:** `src/bundle_data.mc` ON DISK keeps the `u64 ... = { ... }` form.
     `dir_names[]` in the frozen `stage0/lex.c` has no `embed` (`build/mc0` on a file with
     `#embed` answers `unknown directive`, exit 1) and `build/mc0 src/mc.mc` is the seed step of
     `make mc1`, so the file stage0 parses cannot use the directive. For the same reason there is
     no `src/bundle.bin` on disk: nothing would read it. `check-bundle` gained the shape guard —
     `<mc/bundle_data>` has to be exactly one `BLOB` node plus the 132-value index — so a revert
     to the array form fails loudly.
  2. **`arena exhausted` names its caller.** `parse.mc`'s `next()` leaves the current token's file
     and line in `ax_file`/`ax_line` (`src/arena.mc`), and `arena_die` prints reserve, estimate,
     the request that did not fit and the position:
     `mc: arena exhausted (12 MiB reserved, 23 MiB estimated, asked 9418352 bytes) while parsing
     src/arena.mc:5 -- raise [limits].tolerance or HEAP_SIZE`. Verified by building a compiler
     with `HEAP_SIZE (12 << 20)` and `mmap` forced to fail. `cannot reserve the arena` prints the
     same line.
  3. **`mc build --compiler-only`** (`src/driver.mc`): builds the taught compiler, prints its path,
     stops. Exclusive with `--entry-only`; without `[compiler].modules` it is the same missing-key
     error. `examples/lang/test.sh` uses it, then `build/mc-lang build DIR --entry-only`.
  4. **`on_stmt(&f)`** (`src/hooks.mc`, table `T_ONSTMT`): `i64 f(i64 n)` called by `parse_stmt`
     after EVERY statement node exists — core or taught — returning the node, a replacement, or 0
     (an empty `N_BLOCK` takes its place). Order is fixed: the `syntax_stmt` handler builds the
     node first, then the hooks in registration order. `parse_stmt` is now a wrapper over
     `parse_stmt_core`, and with `nonstmt == 0` it does not even make the call.
  5. **`parse_block()` dispatches through `syntax_stmt("{")`** when one is registered, so a
     function body and a `#rule`'s `block $b` hole reach the module too; the guard against a
     handler that consumes nothing moved into `stmt_syntax()`, shared with `parse_stmt`.
  6. **Core-declared locals** are observable as the `N_VAR` node `on_stmt` receives; documented as
     the intended way, no separate hook.
  Demos: `lib/user_syntax_demo.mc` gained `sd_count` (`on_stmt`, rewrites nothing) with
  `stmtcount`/`ifcount`, and `sd_block` (`syntax_stmt("{")`, the core's loop plus two lines) with
  `blockdepth`. `scripts/check-surface.sh` gained four cases: `on_stmt-count`, `on_stmt-order` (the
  hook sees the `N_IF` the `unless` handler built), `on_stmt-blockdepth` (nesting 3, only reachable
  through `<prelude>`'s `while` rule body — 1 without the M21.5 dispatch) and the inertness proof
  (`$demo --dump-ast` from `main` on is byte for byte `$mc1 --dump-ast`).
  `examples/lang`: `lang_core.mc` and `lang_main.mc` DELETED, `[compiler].core` dropped so the core
  comes from `<mc/core>`; the scope bookkeeping moved from three hand-written call sites into
  `lg_on_stmt`; `[limits] tolerance = 1.0` so no table doubles mid-build. The taught compiler on
  `<mc/core>`: **80 312 nodes / 21.7 MiB heap (reserve past the 32 MiB static arena) before,
  58 216 nodes / 20.0 MiB inside it after** (`mc limits examples/lang`, grow 0 everywhere,
  `ins` reports `tight`). `examples/lang/test.sh` green, 14 tests + main.lx.
  — `stage0/` untouched, 2846/3000; `src/*.mc` 14291 lines (3910 of them generated).
  `make check` green end to end (RC 0): `test` 32/32, `check-lex` 71/71, `check-ast` 71/71,
  `check-bundle` (33 files, raw 409375 B -> LZ 185361 B, blob 185699 B; `<mc/bundle_data>` is one
  `#embed` node plus the 132-value index; lz round trip 57 cases), `check-asm` 71/71,
  `check-obj` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 533360 bytes; the
  `--dump-asm` diff between `mc1` and `mc2` empty), `check-surface` 32/32 + every M21 and M21.5
  case, `test-exe` 32/32, `check-mc` 6/6, `check-standalone` green, `check-toml` 10/10,
  `check-build` 11/11, `check-limits` 16/16 under 90%, `test-linux` 32/32 on linux/arm64,
  `check-examples` green, `check-lang` green. Golden rewritten ONCE, from
  `94db4b12…f11918` to `06157cbe65858ce1f6353f15446112bfe51213dde2c9a5e8c9a3f428117731d5`, only
  after the empty `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`.
- M26 done (`docs/specs/M26.md`): **the documentation set**. `docs/README.md` is the map;
  `docs/guide/00..70` is the task-oriented half (getting started, one file, `mc build` +
  `mc.toml`, teaching the compiler, emitting bytes, cross-compiling, the two examples, bootstrap
  and determinism) and `docs/reference/` the exhaustive half (`language`, `directives`, `cli`,
  `toml`, `hooks`, `objects`, `machine`, `diagnostics`, `bundle`) — 4590 lines written against
  the real compiler. `scripts/check-docs.sh` (303 lines, `make check-docs`) enforces three
  things, with every list EXTRACTED from `src/` at run time and never written down in the script:
  coverage (112 public symbols, 14 CLI flags, 16 TOML keys, 10 directives), samples (all 44
  fenced ` ```mc ` blocks compiled; 38 built with `--exe` and RUN with exit code and stdout
  compared, 6 `expect-error` blocks that must fail with the quoted text, 1 through
  `--backend=elf-obj`; a fence may name the compiler that must build it —
  `taught=lib/mc_syntax_demo.mc`, `taught=examples/api`, `taught=examples/lang ext=lx`) and links
  (110 relative links resolve). `reference/diagnostics.md` covers every message extracted from the
  `die`/`die2`/`err_at*`/`err_node`/`expect`/`toml_err*` call sites. `reference/machine.md`
  documents the M17/M24 contract and says plainly that no `machine*` function exists yet.
- M27 done (`docs/specs/M27.md`): **`mcsite`, the static site generator written in mc**.
  `site/gen/` is 3021 lines of `.mc` — `util.mc` (paths, sorted `opendir` listings, `mkdir -p`,
  escaping), `hl.mc` (fenced code; ` ```mc ` through the BUNDLED lexer, `#include <mc/lex>`, so a
  word the surface taught comes out `tok-taught`), `md.mc` (the Markdown subset), `tmpl.mc`
  (`{{name}}` in one pass + `<!--if name-->`), `site.mc` (`site.toml`, sections, nav, outline,
  pager, `search.json`, `sitemap.xml`, static copy), `check.mc` (`--check`) and `main.mc`.
  `mc build site` compiles it into `build/mcsite` (`site/mc.toml`, no `[compiler]`: mcsite
  teaches the compiler nothing, it USES it); `build/mcsite site` renders `docs/` into
  `site/public`. Deterministic: no clock anywhere (the footer year is `[site].year`), `public/`
  rebuilt from scratch, two runs byte-identical (`diff -r` empty). With M26 in the tree: **60
  pages, 5 sections, 40 fences highlighted (4 kept plain), 0 link problems**, `checkhtml.py` 60
  files 0 problems, `contrast.py` 50 pairs 0 below the minimum. `site/preview/*.html` deleted
  (generated artefact; `site/tools/preview.py` still writes it on demand);
  `.github/workflows/site.yml` runs `make mc1` → `mc1 build site` → `mcsite site --check`.
- Post-M27 batch (review): five confirmed findings fixed, four of them in `site/gen/`.
  1. **A link's scheme is checked, not its `://`.** `sg_resolve_link` (`site.mc`), the three
     inline forms in `md.mc` and `ck_link` (`check.mc`) all used `u_find(href, "://") >= 0` to
     mean "external, leave it alone" — so `[x](javascript:alert(1))` shipped as a live `<a>` and
     `javascript://%0aalert(1)//`, which contains that substring, was not even reported by
     `mcsite --check`. `u_scheme()` (`util.mc`, +45 lines) parses the RFC 3986 scheme (skipping
     the control bytes a browser strips) and answers `U_SCHEME_NONE/ABS/BAD`; only `http`,
     `https` and `mailto` are `ABS`. A refused link, image or autolink is **not a link**: its
     source goes out as escaped text with the page named on stderr, and `ck_link` reports
     `refused link scheme` for anything a template or `site.toml` writes.
  2. **`arena exhausted` no longer claims to be parsing when it is not.** `ax_file`/`ax_line`
     (M21.5) were set by `next()` and never cleared, so a failure in a pass, in `gen_lower` or in
     the object writer printed `while parsing FILE:LINE` with the EOF token's line. `parse_unit()`
     clears both on its way out (`src/parse.mc`, +2 lines plus a comment); parse-time failures are
     unchanged. Proved by raising `arena_die` from the top of `gen_lower` (message loses the
     bogus `sample.mc:10`) and from `parse_function` (message keeps `sample.mc:3`).
  3. **Nesting past `MD_MAXDEPTH` degrades instead of vanishing.** `md_quote`/`md_item` recursed
     only under the guard and wrote an empty `<blockquote>`/`<li>` past it — ten levels of `>`
     lost the text of levels 9 and 10 with nothing on stderr and nothing in `--check`. `md_too_deep`
     writes the rest escaped in a `<p>` and names the page.
  4. **An unmatched backtick run is literal in full.** `md_inline` emitted one `` ` `` and
     advanced by 1 on a failed `md_code_close`, so a stray ``` ``` ``` run was retried three times
     until its last backtick paired with an unrelated single one later in the line. It now emits
     all `k` and advances by `k`, which is what `md_plain_into`, `md_close_br` and `md_emph_close`
     already did.
  5. **`check-docs.sh` covers `on_*`.** The prefix allowlist came verbatim from the M26 spec and
     predates M21.5, so `on_stmt`'s whole reference entry could be deleted with the gate still
     printing `ok coverage: 112`. With `on_` added it fails (`FAIL undocumented public symbols:
     on_stmt`) and the real tree reports **113**. `docs/specs/M26.md` records why the list grew.
  Docs: `site/README.md` § The Markdown subset (two rules became four),
  `docs/reference/diagnostics.md` (`while parsing` appears only while parsing), `docs/specs/M26.md`.
  — `stage0/` untouched, 2846/3000. `make bundle` re-run (`src/parse.mc` is `mc/parse` in the
  bundle): 33 files, raw 409828 B -> LZ 185629 B, blob 185967 B. `make check` green end to end
  (RC 0): `test` 32/32, `check-lex` 71/71, `check-ast` 71/71, `check-bundle` (lz round trip 57
  cases), `check-asm` 71/71, `check-obj` 32/32, `bootstrap` at a fixed point (`mc2.o == mc3.o`,
  533680 bytes; the `--dump-asm` diff between `mc1` and `mc2` empty), `check-surface` 32/32,
  `test-exe` 32/32, `check-mc`, `check-standalone`, `check-toml`, `check-build`, `check-limits`,
  `test-linux` 32/32 on linux/arm64, `check-examples`, `check-lang`, `check-docs` (113 symbols,
  14 flags, 16 TOML keys, 10 directives, 44 samples, 110 links), `site` 61 pages / 5 sections /
  40 fences, `check-site` 0 link problems + `checkhtml.py` 61 files 0 problems + `contrast.py` 50
  pairs 0 below the minimum. Two consecutive renders of `site/public` are byte-identical
  (`diff -r` empty) and the real `docs/` tree raises no refused-scheme and no too-deep warning.
  Golden rewritten ONCE, from `06157cbe…7731d5` to
  `8c848b105b838d049290643a320348c14988404fe058014c8ec09851e8ee2b06`, only after the empty
  `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`.
- M31 core ✔ (`docs/specs/M31.md` § 2, the three gaps the concurrency panel found; the example
  `examples/conc` is a separate step). All three are generic and inert for an untaught program.
  1. **`decl_find` and the readers** (`src/parse.mc`, a 75-line block inside the public API section; the file grows +119 in total, the rest being the `on_jump` half):
     `decl_find(name)` walks `unit_head` linearly, in declaration order, and returns the node index
     of the `N_FUNC`/`N_PROTO`/`N_EXTERN`, -1 if none; `decl_ret`, `decl_nparams`,
     `decl_param_type` read it; `decl_valid` is the guard, so an unchecked
     `decl_ret(decl_find(f))` after a -1 gives -1 instead of reading the node table at random.
     Only what has been parsed so far is visible, which is written down rather than hidden.
     No module reads `unit_head` any more.
  2. **`on_jump(&f)`** — `i64 f(i64 n, i64 kind, i64 depth)`, table in `src/hooks.mc` (+44, shaped
     like `on_stmt`'s, arena tag `T_ONJUMP`), three call sites in `parse_stmt_core` through
     `jump_hook`, so the hook runs at node creation, **before** any `on_stmt` hook and before
     another module can rewrite the jump. `blk_depth` counts open blocks: `+1` in `parse_block`,
     and in `stmt_syntax` when the dispatch token is `K_LBRACE` (a module that owns `{` opens a
     block the core never sees) — each block exactly once; `parse_function` rebases it to 0, so
     `depth` is per function. `p_blockdepth()` reads the same counter, which is what makes the
     `depth` argument comparable to something (added beyond the spec's four lines for exactly
     that reason). 0 from a handler drops the jump and an empty `N_BLOCK` takes its place.
     What it does **not** see: a jump another module fabricates never goes through
     `parse_stmt_core`.
  3. **The ABI contract** (`docs/reference/objects.md` § 4, new; cross-referenced from
     `machine.md`): parameters in `x0..x7` untouched by the prologue, `x0` untouched by the
     epilogue, `frame == 0` for a zero-parameter zero-local function with the `stp`/`ldp` pair
     still unconditional, depths `x9..x15`, scratch `x8`/`x16`/`x17`, `x18..x28` never written,
     `callp` (pointer in `x16`, args `x0..x6`, `blr x16`, result `x0`), and the `#opcode`
     fixed-register rule. `scripts/check-surface.sh` asserts each claim against `--dump-asm`:
     six probe functions compared instruction by instruction, `lib/sys_svc.mc`'s `write` the same
     way, and over `src/mc.mc` — **837 functions**, every prologue, `ret` preceded by exactly
     `ldp x29, x30, [sp], #16`, and **0** mentions of `x18..x28` in 58 914 lines.
  Demos in `lib/user_syntax_demo.mc` (468 -> 629 lines): `widen x = f(a);` takes the local's type
  from `decl_ret` and casts each argument to `decl_param_type` (the FFI half: a C callee does not
  narrow its own arguments), and `guard EXPR { ... }` runs one statement on every exit edge —
  the fall-through and each jump inside the body. Ordering is proved by a number: `retcount`, the
  module's count of statements that still looked like an `N_RETURN` when `on_stmt` ran, does not
  move for a guarded jump. Negative cases `tests/err/067`–`070` (unknown callee, void result,
  wrong arity, `break N` out of a guard), each asserted with its exact message.
  Docs: `docs/surface.md` § Tier 3 (seven registrations now) + a new § M31,
  `docs/reference/hooks.md` (`on_jump`, the `decl_*` family, `p_blockdepth`, and `decl_name`,
  which the widened `decl_` prefix in `scripts/check-docs.sh` newly requires),
  `docs/reference/objects.md` § 4, `docs/reference/machine.md`.
  — `stage0/` untouched, 2846/3000. `make bundle` re-run: 33 files, raw 424421 B -> LZ 191969 B,
  blob 192307 B. `make check` green end to end (RC 0): `test` 32/32, `check-lex` 71/71,
  `check-ast` 71/71, `check-bundle` (lz round trip 57 cases), `check-asm` 71/71, `check-obj`
  32/32 (inert), `bootstrap` at a fixed point (`mc2.o == mc3.o`, 543128 bytes; the `--dump-asm`
  diff between `mc1` and `mc2` empty), `check-surface` 32/32 plus the new `decl_find`/`on_jump`
  cases and the nine ABI assertions, `test-exe` 32/32, `check-mc` 6/6, `check-standalone`,
  `check-toml` 10/10, `check-build` 11/11, `check-limits` 16/16 under 90%, `test-linux` 32/32 on
  linux/arm64, `check-examples`, `check-lang` (14 lx tests), `check-desktop`, `check-docs`
  (121 symbols, 14 flags, 16 TOML keys, 10 directives, 44 samples, 112 links), `site` + `check-site`
  (50 contrast pairs, 0 below the minimum). Golden rewritten ONCE, from
  `8c848b105b838d049290643a320348c14988404fe058014c8ec09851e8ee2b06` to
  `b7d47491036452c19d72faba7358b17bbefb20c7f6b4f61ae339c4a14c3c7583`, only after the empty
  `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`. The whole `--dump-asm` delta against the
  previous compiler is the 10 new functions, the `T_*` renumbering (`T_ONJUMP` inserted after
  `T_ONSTMT`), the four functions that gained the counter or the hook call, and `l_strN` index
  shifts — no other body changed.
- M17 step A ✔ (`docs/specs/M17.md` § step A, plus the two core mechanisms decided in
  `docs/specs/M33.md` § 1): **the code generator split into a resolver, a target-independent
  walker and a machine**, with the frozen C seed as the oracle — it is still one monolithic
  generator and its objects and `--dump-asm` had to come out identical.
  1. **`src/gen_resolve.mc`** (536 lines): `gen_resolve(unit)` binds every name and types every
     expression into a **side table indexed by node** (`RES_SIZE 32`: type, kind, decl, flag),
     allocated once from `nnodes` and zeroed. `ND_SIZE` stays 104, no node field was added and
     `--dump-ast` does not move — the 18 `set_nd_type` calls that used to happen as a side effect
     of AArch64 instruction selection are gone. Readers: `res_type`, `res_kind`, `res_decl`,
     `res_local_slot`, `res_bind` (M33's encoding), `res_intrin`, `res_addr_taken` (keyed by the
     DECLARING node, because a local's index is reused across sibling blocks) and
     `res_fn_addr_taken`. It also took over the signature table (`func_add`/`func_find`/`fs_*`)
     and the global table (`global_add`/`global_find`/`glb_*`), with `GLB_SYM` still filled by
     `gen_globals` at placement time — so the symbol creation order, which fixes the symbol table
     and therefore the bytes, did not move. Every name diagnostic moved with it, in the order
     `gen_lower` raised them (signatures, prototypes, globals, then each body).
  2. **`src/gen_walk.mc`** (1031) + **`src/machine_arm64.mc`** (675), from the old
     `src/gen_arm64.mc` (1623). The walker owns the `Ins` buffer, the frame in bytes
     (`slot_new`), the label counter, the loop stack, block scoping, sections, globals, strings,
     symbols and `I_LABEL` (opcode 0, reserved) — and mentions no register. It drives a
     **machine table**: `uptr m_arm64[MTASK_COUNT]`, 30 slots of `&fn` registered with
     `machine("arm64", tab)` in `src/hooks.mc` and called through `callp` (`mach(MTASK_X)`).
     The machine owns the register partition, the spill (`dslot`, `val_reg`/`dst_reg`/`dst_done`,
     `save_live`/`restore_live`), `REG_FRAME`/`fix_frame`, the encoders and the dump.
     `MAXDEPTH`, the register assignment and the spill semantics are unchanged; `frame too large`
     stays in the walker on purpose (M17 § step B asks for diagnostic parity).
     Vocabulary: `MTASK_*` (30), `MOP_*` (13), `MUN_*` (3), `MCOND_*` (6) — named `MTASK_` and not
     `MT_` because `examples/lang/lang_tab.mc` already has `MT_RET`.
     Three deliberate deviations from the spec's sketch, all documented: `m_global_addr`/
     `m_str_addr` are one task (`MTASK_SYM_ADDR`), `m_arg_move` is folded into `MTASK_CALL`/
     `MTASK_CALLP` (which is what lets `callp` put its pointer in `x16` without the walker
     knowing), and `m_prologue(frame, nparams)` is `MTASK_PROLOGUE` + `MTASK_PARAM` +
     `MTASK_FRAME_FIX` because the frame size is only known after the body.
     `gen_lower`, `gen_encode_all`, `gen_dump_asm` and every `gen_*` accessor kept their names and
     their behaviour: `lib/backend_arm64.mc`, `src/backend_exe.mc` and `src/backend_elf.mc` were
     not touched.
  3. **`target(os, arch, obj_backend, exe_backend)`** in `src/hooks.mc`, registered in
     `src/main.mc` (`macos/aarch64 -> macho + macho-exe`, `linux/aarch64 -> elf-obj + none`).
     `src/driver.mc` lost `i64 drv_linux` and both hardcoded lists; the two messages are now built
     FROM the registry (`target_os_list`, `target_arch_list`) and come out byte for byte as
     before — `only macos and linux (see docs/build.md)`, `only aarch64 (see docs/build.md)`,
     `linux requires [linker]: there is no direct executable`. Fixed ceilings (`MAXTARGETS 16`,
     `MAXMACHINES 8`) on purpose: neither table scales with the program, so M23's rule does not
     apply.
  Docs: `docs/reference/machine.md` rewritten as the versioned contract (version 1, the 30 slots
  with signatures, what each side owns, the deviations), `docs/reference/objects.md` § 1b
  (`gen_resolve` and the readers) and its file references, `docs/reference/hooks.md`
  (`machine`/`machine_find`/`machine_use`/`machine_task`/`machine_arm64_init`, `target`),
  `docs/surface.md` § Tier 2 ("the third seam"), `docs/reference/bundle.md` and `docs/build.md`
  (the three new bundle names).
  — `stage0/` untouched, 2846/3000. `make bundle` re-run (35 files, raw 455370 B -> LZ 207275 B,
  blob 207644 B). `make check` green end to end (RC 0): `test` 32/32, `check-lex` 73/73,
  `check-ast` 73/73, `check-bundle` (lz round trip 59 cases), `check-asm` 73/73, `check-obj`
  32/32 against the frozen seed, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 578696 bytes;
  the `--dump-asm` diff between `mc1` and `mc2` empty), `check-surface` 32/32 plus the nine ABI
  assertions (920 functions of `src/mc.mc`, 0 mentions of `x18..x28` in 62 323 lines),
  `test-exe` 32/32, `check-mc` 6/6, `check-standalone`, `check-toml` 10/10, `check-build` 11/11,
  `check-limits` 16/16 under 90%, `check-minimal`, `test-linux` 32/32 on linux/arm64,
  `check-examples`, `check-lang` 14, `check-conc` 21, `check-desktop`, `check-docs`
  (127 symbols, 14 flags, 16 TOML keys, 10 directives, 45 samples, 123 links), `site` +
  `check-site`. Golden rewritten to
  `b2cbbde41f36843c3ef7970a4bd66b631828736771bac0d5df047ded9516375e`, only after the empty
  `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`. Independent proof that nothing moved: a
  copy of `build/mc1` taken BEFORE the refactor and the one after produce byte-identical objects
  for all 32 `tests/*.mc`, for `src/mc.mc` itself, and — through the taught compilers each of them
  builds — for `examples/api/main.mc`, `examples/lang/main.lx`, `examples/conc/main.lx`,
  `examples/desktop/main.mc` and `examples/desktop/main.ui`.
- M17 step B ✔ (`docs/specs/M17.md` § step B): **the x86-64 machine and `linux/x86_64`**.
  `src/machine_x86_64.mc` (775 lines) fills the same task table `machine_arm64.mc` fills, and not
  one line of `src/gen_walk.mc` became architecture-specific: depths 0..3 in `r8..r11` (what is
  left once the callee-saved half and the argument registers are off the table), scratch
  `rax`/`rcx`/`rdx` (`idiv` writes `rdx`, `div` needs it zeroed, every shift counts in `cl`),
  locals at `[rbp - off]` — no frame fixup — arguments in `rdi rsi rdx rcx r8 r9` with the seventh
  and eighth pushed with `push r/m64` (no scratch spent; one extra `sub rsp, 8` when the count is
  odd, for the 16-byte alignment at the `call`), result in `rax`, `callp` with the pointer in
  `rax`, moved BEFORE any argument register because it may itself live in `r8..r11`.
  A descriptor table (`x86_desc`, six columns per opcode) drives **the same** `x86_put` that
  encodes and the dump that prints `--dump-asm`; `MTASK_INS_SIZE` runs `x86_put` over a scratch
  buffer and returns the length, so size and encoding cannot disagree by construction.
  **Machine contract: version 2** (`docs/reference/machine.md`) — one new slot,
  `MTASK_RELOC_OFF(e) -> bytes`. Version 1 assumed a relocation patches the instruction from its
  first byte, which is true of every fixed-width encoding and false of x86 (`call rel32` +1,
  `lea r,[rip+d32]` +3). AArch64 answers 0 and its objects did not move a byte.
  ELF x86-64 inside the same `src/backend_elf.mc` (`elf_em`, `R_X86_64_64/PC32/PLT32`, addend −4 on
  both pc-relative kinds because a `rel32` counts from the END of its field); backend
  `elf-obj-x86_64`; `target("linux", "x86_64", "elf-obj-x86_64", 0)` in `main.mc`. **The object
  backend is what picks the machine** (`machine_use` as its first statement), not a fifth column on
  `target()`: the format already records the architecture, and an AST-consuming backend (wasm)
  needs no machine at all. `--machine=NAME` covers the `--dump-*` modes, which never reach a
  backend. `// skip-x86_64:` on `031-opcode`, `033-reloc` and `tests/linux/070-nolibc.mc` — the
  three that write instructions by hand. `scripts/sysroot-linux.sh --arch x86_64` (alpine
  linux/amd64), `scripts/test-linux.sh --arch x86_64`, the `make test-linux-x86_64` target inside
  `make check` (self-skipping without Docker/ld.lld) and the `linux-x86_64` CI leg on
  `ubuntu-latest` (docs/plan.md § Rule for every new target).
  **The seed needed more arena**: `build/mc0 src/mc.mc` was dying with `arena exhausted` with every
  `MAX*` under 57% — what was full is `HEAP_SIZE` in `stage0/arena.c` (32 MiB, chosen in `517685f`
  when self-compiling touched 14.5 MiB; `nodes_grow` doubles and never frees, ~18.9 MB of dead
  arrays alone). Raised to 64 MiB — capacity, not behaviour: no generated byte changes.
  `scripts/check-limits.sh` gained the seventeenth row, the heap, measured as the max RSS of a real
  `build/mc0` run (`docs/build.md` § The seventeenth row).
  — `make check` green end to end (RC 0, zero FAIL): `test` 32/32, `check-lex` 74/74, `check-ast`
  74/74, `check-bundle` (lz 60 cases), `check-asm` 74/74, `check-obj` **32/32 identical to the
  frozen seed**, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 622792 bytes; the `--dump-asm`
  diff between `mc1` and `mc2` empty), `check-surface` 32/32 plus the nine ABI assertions
  (996 functions, 0 mentions of `x18..x28` in 67 051 lines), `test-exe` 32/32, `check-mc` 6/6,
  `check-standalone`, `check-toml` 10/10, `check-build` 11/11, `check-limits` **17/17** (heap
  29 Mi/64 Mi = 46%), `check-minimal`, `test-linux` 32/32 on linux/aarch64,
  **`test-linux-x86_64` 29/29 on linux/x86_64** (4 skipped), `check-examples`, `check-lang`,
  `check-conc`, `check-desktop`, `check-docs` (129 symbols, 15 flags, 16 TOML keys, 10 directives,
  45 samples, 131 links), `site` + `check-site`. Golden rewritten once to
  `9c34d8d63af895a7d382c9d24e4f7e56298f133ef6f8b15c3a3940c00774a09c`, only after the empty asm diff
  and `cmp build/mc2.o build/mc3.o`. Bundle regenerated (36 files, raw 489036 -> LZ 221119, blob
  221506 B); `tools/bundle.list` gained `mc/machine_x86_64`.
  Encoder cross-check: the **948 distinct instructions** the machine emits while compiling
  `src/mc.mc` for x86-64 re-assemble byte-identically under `llvm-mc -triple=x86_64-linux-musl`,
  and the relocations match `clang --target=x86_64-linux-musl -c` of equivalent C
  (`R_X86_64_PC32` at instruction+3, `R_X86_64_PLT32` at instruction+1, both with addend −4),
  inspected with `llvm-objdump -dr` and `llvm-readobj`.
- M37 done (`docs/specs/M37.md`, `docs/guide/90-linux-host.md`, `docs/bootstrap.md` § The Linux
  chain, `docs/build.md`, `docs/ci.md`): **`mc` hosted on Linux (aarch64 and x86_64)**.
  `stage0/` untouched (2848/3000): the C seed emits Mach-O only and stays macOS-first, so a Linux
  host does not bootstrap from clang -- it bootstraps from a published (or cross-built) `mc`.
  1. **The host layer.** `src/core.mc` is host-neutral; everything the COMPILER needs from the
     system it RUNS on is one file the entry point includes before the core --
     `src/host_macos.mc` (72), `src/host_linux.mc` (41, the OS half) plus
     `src/host_linux_aarch64.mc` / `src/host_linux_x86_64.mc` (7 each, the three architecture
     answers), with entries `src/mc_linux.mc` (15) and `src/mc_linux_x86_64.mc` (9). It answers
     `host_os/host_arch/host_machine/host_sys/host_include/host_environ/host_init/host_has_sdk`
     and declares `posix_spawnp`/`posix_spawn_file_actions_*`/`waitpid`/`mkdir`/`unlink` (same
     names in musl) plus `O_CREAT`/`O_TRUNC`, the two values that differ. `_NSGetEnviron` was the
     single blocker: musl has no equivalent, so the Linux host takes the `envp` the C runtime
     passes and `main` became `main(argc, argv, envp)`, handing it to `host_init()` first thing.
     `src/arena.mc` stayed host-neutral on purpose (so `lexdump`/`tomldump`/`tools/bundle.mc`/
     `site/gen` need no host file): its one non-portable value, the anonymous-mapping flag, is now
     `0x1022` -- `MAP_PRIVATE|MAP_ANON` on macOS and `MAP_PRIVATE|MAP_ANONYMOUS` on Linux, each
     with one ignored bit, measured on both.
     What the layer decides: `[target]` with no section = the host pair; `mc x.mc -o x.o` uses the
     host's OBJECT backend (was hardcoded `macho`); the dumps start on `host_machine()`; and
     `mc build` links the taught compiler with the host's exe backend when it has one and with
     `[linker]` when it does not. `backend_macho`/`backend_exe` now call `machine_use("arm64")`
     first, like every backend since M17 -- without it an x86_64-hosted `mc` lowered Mach-O with
     the x86 machine. New flags: `mc --host` (os/arch/sys) and `--include=DIR`.
     Bundle: `mc/host_macos`, `mc/host_linux`, `mc/host_linux_aarch64`, `mc/host_linux_x86_64`
     (40 entries) plus the synthetic **`<mc/host>`**, resolved in `src/main.mc`
     (`host_bundle_open`) to the running compiler's own host file -- which is what `mc build`
     writes above `#include <mc/core>`, so one `mc.toml` teaches a macOS compiler on macOS and a
     Linux one on Linux.
  2. **The chain.** `src/mc.linux-aarch64.toml` / `src/mc.linux-x86_64.toml` cross-build
     `build/mc-linux-arm64` (730168 B) and `build/mc-linux-x86_64` (726184 B) from macOS (ELF,
     musl, `ld.lld`); `make mc-linux` / `mc-linux-x86_64`. `scripts/bootstrap-linux.sh [SEED]`
     (232) is the Linux fixed point -- seed -> `mc1l` -> `mc2l` -> `mc3l`, `cmp`, golden
     `tests/golden/mc2-linux-<target>.sha256`, then the whole suite natively. With no argument it
     takes `build/mc-linux-<target>`, else a release asset (`gh release download` or curl of
     `mc-<VER>-linux-<arch>.tar.gz`), **unpacked only after the SHA-256 matches**; it refuses a
     seed whose `mc --host` is not `linux/<this machine>` and checks that `mc1l` and `mc2l` agree
     on `--dump-asm`. `scripts/link-linux.sh`, `scripts/link-host.sh` (uname dispatch) and
     `scripts/build-exe.sh` (`--exe` on macOS, object + linker on Linux) are what let the same
     cross-check scripts run on both hosts.
  3. **The Makefile switches on `uname -s`.** `REF`/`MC` name the two compilers a cross-check uses
     -- `mc0`/`mc1` on macOS, `mc1l`/`mc2l` on Linux. Linux `check` = `budget bootstrap-linux
     check-lex check-ast check-asm check-obj check-bundle check-mc check-toml check-limits
     check-skipped`, and `check-skipped` prints one line per macOS-only target with its reason.
     `make check-linux-host` (macOS, self-skips without Docker) cross-builds both compilers and
     runs the whole thing per architecture inside `alpine:3`, ending with the **cross proof**.
  4. **Examples.** `examples/conc`'s platform layer split into `lib/macos/thread.mc` (libdispatch
     semaphores) and `lib/linux/thread.mc` (`sem_init`/`sem_wait`/`sem_post`, all-zero pthread
     initializers, `getauxval(AT_HWCAP)` for the LSE probe), picked by `[include].paths` --
     `mc.toml` vs the new `mc.linux.toml` -- and by `--include=` for the single-file CLI.
     `examples/api/mc.linux.toml` links SQLite statically and is documented as NOT exercised
     (the musl sysroot is `apk add musl-dev`, four files, no SQLite).
  5. **CI/releases**, in the same "compile here, link there" shape the suite legs already use --
     GitHub's `macos-15` runners have **no Docker**, so the musl sysroot (four files out of
     `alpine:3`) cannot exist there and neither can a link. `ci.yml`: the macOS job cross-COMPILES
     both Linux compilers to ELF objects (`make mc-linux-obj` / `mc-linux-x86_64-obj`, the new
     `src/mc.linux-{aarch64,x86_64}-obj.toml` with `kind = "obj"` -- `drv_entry` returns before
     the `[linker]` requirement, so neither config has one) and uploads them with `build/mc2.o`;
     the two jobs `mc on linux/arm64 host` (ubuntu-24.04-arm) and `mc on linux/x86_64 host`
     (ubuntu-latest) link the object under `MC_SYSROOT=/usr/lib/<arch>-linux-musl` with
     `scripts/link-linux.sh` (which runs `ld.lld` and nothing else when the four files are there),
     then run `make check SEED=...` plus the cross proof. The object is byte-identical to the one
     the executable configs write, so `make mc-linux` stays the local road. `release.yml` has the
     same split: `build` (macOS) uploads `mc-linux-objects`, `build-linux` (a two-entry matrix on
     the two Ubuntu runners) links each object, proves it with `scripts/bootstrap-linux.sh` and
     packages it, and `publish` needs both -- three tarballs. `build-future-hosts` keeps
     `if: false` with only the Windows entries.
  — Acceptance, measured here: macOS `make check` green end to end (RC 0) -- `test` 32/32,
  `check-lex`/`check-ast`/`check-asm` 80/80, `check-obj` **32/32 identical to the frozen seed**,
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, `--dump-asm` diff empty), `check-surface` 32/32,
  `test-exe` 32/32, `check-mc` 6/6, `check-standalone` (`<mc/host> + <mc/core> + <user_default> ==
  src/mc.mc`, byte for byte), `check-toml` 10/10, `check-build` 11/11, `check-limits` 17/17 under
  90%, `check-minimal`, `test-linux` 32/32, `test-linux-x86_64` 29/29, `check-examples`,
  `check-lang`, `check-conc` 21, `check-desktop`, `check-docs` (138 symbols, 17 flags, 16 TOML
  keys, 10 directives, 46 samples, 153 links), `site` 69 pages + `check-site`. Golden rewritten
  ONCE, to `e958ceab11064dd16fc3306937744c744548bfff49b323d09bc1a7baf942adbe`, after the empty asm
  diff. `make check-linux-host` green for both architectures (RC 0): fixed point
  `mc2l.o == mc3l.o` (817280 B on aarch64, 757112 B on x86_64), goldens
  `55402bcb…cfe9e7` and `9c142589…5f8f7`, suites 32/32 and 29/29 native, `check-lex/ast/asm`
  80/80, `check-obj` 31/31 and 29/29 (the rest skipped by `// skip-` header), and the **cross
  proof**: `mc2l --backend=macho src/mc.mc` is byte for byte the macOS `build/mc2.o` on both.
  Known gaps, on record: on Linux `check-build`, `check-examples`, `check-lang`, `check-conc`,
  `check-desktop`, `check-docs`, `site` and `check-surface` are skipped with a printed reason --
  each builds `--exe` binaries or macOS dylibs -- and `check-lex`/`check-ast` there compare the
  compiler against itself rather than against the frozen C oracle.
- M19 done (`docs/specs/M19.md`, `docs/build.md` § Windows targets,
  `docs/guide/50-cross-compile.md` § Windows on ARM): **Windows on ARM — COFF objects, a kernel32
  system layer, `lld-link`**. `stage0/` untouched (2848/3000, unchanged since M17 step B raised its
  `HEAP_SIZE`): the COFF writer is a backend in `.mc`, and the machine is the same `arm64` macOS uses — this is a new file FORMAT, not a new
  instruction set.
  New: `src/backend_coff.mc` (375 lines, backend `coff-obj-arm64`) — the third writer over
  `gen_lower` + `gen_encode_all`. One COFF section per module section in creation order, so the
  1-based `SectionNumber` **is** the module's `sym_sect` and nothing is renumbered
  (`__TEXT,__text` -> `.text` `CODE|EXECUTE|READ`, `__TEXT,__cstring` -> `.rdata` `INIT|READ`,
  `__DATA,__data` -> `.data` `INIT|READ|WRITE`, `__DATA,__bss` -> `.bss` `UNINIT` with
  `SizeOfRawData` = zsize and `PointerToRawData` = 0, `#section SEG SECT` -> `.seg.sect` with the
  ELF writer's lowercasing). Alignment is not a field: it is `(log2 + 1) << 20` inside
  `Characteristics`. Symbols are 18 bytes with **no auxiliary records**, no leading underscore
  (`_main` -> `main`, like ELF), `l_strN` -> `$str.N` (STATIC), `Type 0x20` in a pure-instructions
  section, EXTERNAL for globals and undefined, and macho.mc's `sym_order` reused so the three
  writers stay comparable. Relocations are 10 bytes with **no addend field** — COFF is Mach-O's
  shape here, not ELF's — sorted by ascending offset (`elf_rel_order`, which has nothing ELF in
  it): `BRANCH26` 0x0003, `PAGEBASE_REL21` 0x0004, `PAGEOFFSET_12A` 0x0006 on an `add` /
  `PAGEOFFSET_12L` 0x0007 on an ldr/str (the same classifier `elf_pageoff12` and
  `exe_fix_pageoff12` use), `ADDR64` **0x000E**. `TimeDateStamp` is 0, never the clock, and a
  section with 65535 relocations or more is refused with a message instead of written wrong
  (65535 is the overflow SENTINEL, not a count — corrected in the post-M19 review batch below).
  Two long-name encodings, and they are NOT the same: a section name past 8 bytes is `/` plus the
  decimal offset as text, a symbol name past 8 bytes is four zero bytes plus that offset as a
  u32 — using the section form for a symbol makes `llvm-readobj` print `/17` where a name belongs
  (found and fixed during the work).
  `lib/sys_windows.mc` (190): `open`/`creat`/`read`/`write`/`close`/`exit` over seven kernel32
  `extern`s (`GetStdHandle`, `WriteFile`, `ReadFile`, `CreateFileA`, `CloseHandle`,
  `ExitProcess`, `GetCommandLineA`), all non-variadic. There is **no syscall instruction anywhere**
  — Windows has no stable system-call numbers and the documented boundary is the DLL — so unlike
  `lib/sys_svc.mc`/`lib/sys_linux.mc` this layer is ordinary mc code. Descriptors 0/1/2 go through
  `GetStdHandle`; `open`/`creat` hand back the HANDLE and the others take it back unchanged (safe:
  a real handle is never 0, 1 or 2). It provides the entry point too, `mc_start`, which splits
  `GetCommandLineA()` into argc/argv (spaces and tabs separate, `"` toggles) and calls `main`
  through a raw `bl` in a two-parameter shim — x0/x1 are already right and the prologue does not
  touch them (`docs/reference/objects.md` § 4) — so the link carries no crt object at all.
  **It deliberately does not `#include "io.mc"`**, the one divergence from `sys_linux.mc`: on Linux
  the wrappers come out of `libc.a`, an archive the linker takes members from; here they come out
  of an object linked NEXT TO the program, and a second copy of `strlen`/`puts`/`putnum` would be a
  duplicate symbol for every test that includes `lib/sys.mc`. A program that includes the layer
  directly adds `#include <io>` (`tests/windows/070-kernel32.mc` does).
  `scripts/sysroot-windows.sh` (81): writes `kernel32.def` and builds `kernel32.lib` with
  `llvm-dlltool -m arm64`. An import library is a list of names, so there is **no download, no
  mingw and no Windows SDK**; cached like the musl one, `make sysroot-windows` runs it.
  `scripts/test-windows.sh` (346): the same split shape as `test-linux.sh`. `--build-only OUTDIR`
  writes one `.obj` per test (`kind = "obj"`), the `.expect`, the `manifest`, the `skipped` list
  and the two files the other half cannot make — `winrt.obj` (the compiled layer) and
  `kernel32.lib`; `--run-only OUTDIR` needs `lld-link` and nothing else. Two link modes:
  `kernel32` (test + winrt.obj + kernel32.lib, the way musl resolves the same externs) and `self`
  (the source already includes `<sys_windows>`). The default mode is what `make test-windows` runs:
  cross-compile everything, assert every object is an arm64 COFF with TimeDateStamp 0, and link
  three of them with `lld-link`; nothing is executed here.
  Driver: `target("windows", "aarch64", "coff-obj-arm64", 0)` in `src/main.mc` and **nothing else**
  — M17's registry already made `[target].os = "windows"` require `[linker]` and already builds
  both diagnostics from the table. `src/hooks.mc` (+36/-33) only changed to make the list read as
  English with three entries: `tgt_word` became `tgt_walk`/`tgt_list`, a two-pass walk that knows
  the total before the first word, so the message is `only macos, linux and windows (see
  docs/build.md)` and not `macos and linux and windows`. `scripts/check-build.sh` gained the
  windows-without-`[linker]` case and its old "invalid os" example moved from `windows` to `haiku`
  (12/12).
  CI: `Cross-compile the suite for windows/arm64` + the `windows-arm64-objects` artifact on the
  macOS job, and the leg `Link and run the suite (windows/arm64)` on `windows-11-arm` — a tool-facts
  step that looks for a preinstalled `lld-link` first, then a cached download of the LLVM
  Windows-on-ARM release (tarball, falling back to the `woa64.exe` installer), then
  `test-windows.sh --run-only` under bash. It fails loudly rather than skipping: it is the only
  place a Windows binary is ever executed. After merge the architect adds it to the required checks
  (`docs/plan.md` § Rule for every new target).
  Deviations from the spec text, on record: `IMAGE_REL_ARM64_ADDR64` is **0x000E**, not the 0x0001
  the spec wrote (0x0001 is ADDR32) — verified against clang's own objects; `SetFilePointer` is not
  declared, because nothing in `lib/io.mc` or the suite seeks, and an unused `extern` would only be
  an undefined symbol; `os = "windows"` needs no `{sysroot}` work in the driver because M17 already
  generalised it. Not skipped, against the spec's guess: `031-opcode` and `033-reloc` are AArch64
  words and BRANCH26 and this target is AArch64, so they cross-compile and link like everything
  else — `032-svc` is the only `// skip-windows:`.
  Validation on this host: `llvm-readobj --file-headers --sections --symbols --relocs` of
  `013-putnum.obj` against `clang --target=aarch64-windows-msvc -c` of equivalent C agrees on
  Machine, SizeOfOptionalHeader, Characteristics, the four section characteristic words, storage
  classes, `ComplexType: Function`, `IMAGE_SYM_UNDEFINED` and every relocation type;
  `lld-link /machine:arm64 /subsystem:console /entry:mc_start /nodefaultlib` produces
  `001-return42.exe`, `013-putnum.exe` and `070-kernel32.exe`, each an
  `IMAGE_FILE_MACHINE_ARM64` PE with `Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI` and the seven
  kernel32 imports; a full `mc build` with `[linker] cmd = "lld-link"` produces the same thing
  through the driver.
  — `stage0/` untouched, 2848/3000; `src/*.mc` 17511 lines. `make bundle` re-run (38 files, raw
  511899 -> LZ 232981, blob 233396 B; `tools/bundle.list` gained `mc/backend_coff` and
  `sys_windows`). `make check` green end to end (RC 0): `test` 32/32, `check-lex` 76/76,
  `check-ast` 76/76, `check-bundle` (lz round trip 62 cases), `check-asm` 76/76, **`check-obj`
  32/32 identical to the frozen seed**, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 644680
  bytes; the `--dump-asm` diff between `mc1` and `mc2` is empty), `check-surface` 32/32 + inert,
  `test-exe` 32/32, `check-mc` 6/6, `check-standalone`, `check-toml` 10/10, `check-build` 12/12,
  `check-limits` 17/17 under 90%, `check-minimal`, `test-linux` 32/32 on linux/aarch64,
  `test-linux-x86_64` 29/29 on linux/x86_64, **`test-windows` 32/32 objects + 3 linked
  executables** (1 skipped), `check-examples`, `check-lang`, `check-conc`, `check-desktop`,
  `check-docs` (130 symbols, 15 flags, 16 TOML keys, 10 directives, 45 samples, 139 links),
  `site` + `check-site`. Golden rewritten once to
  `be65caca70bd805edd91ed366792591e869f3ff8d3b4def5c75ebf97ca80197e`, only after the empty asm diff
  and `cmp build/mc2.o build/mc3.o`.
- Post-M19 batch (review): three confirmed findings, two fixed in code and one recorded as a scope gap.
  1. **`win_split` handed out an out-of-bounds argv pointer once the command line filled `win_cmd`.**
     `lib/sys_windows.mc` guarded the per-character copy (`o < WIN_CMDMAX - 1`) and the terminator
     (`o < WIN_CMDMAX`) but not the pointer store, so once `o` reached `WIN_CMDMAX` (2048) every
     later argument got the SAME pointer `win_cmd + 2048` — one byte past the array, never written
     and never NUL-terminated, which is what `open(argv[1], ...)` in `tests/025-linecount.mc` would
     read. Reproduced by lifting `win_split` verbatim into a harness compiled natively
     (`3000 * 'x'` + `" y z"`): before, `nargs=3` with args 1 and 2 both at offset 2048 and both
     flagged out of bounds; after, `nargs=1` and every pointer inside the array. The fix is one
     line, `if (o >= WIN_CMDMAX) break;` next to the existing `if (n >= WIN_MAXARG) break;` — the
     command line truncates at the byte ceiling instead of one past it. Clamping `o` instead would
     leave every later argument aliased to the same trailing slot. Ordinary command lines are
     byte-identical (`prog.exe a b`, quoted regions, runs of spaces).
  2. **The `NumberOfRelocations` ceiling was off by one against the PE/COFF sentinel.**
     `src/backend_coff.mc` refused `nr > 0xffff`, but 65535 is not a count: it is the sentinel that
     says the real count is in the `VirtualAddress` of an extra leading `IMAGE_RELOCATION`, with
     `IMAGE_SCN_LNK_NRELOC_OVFL` in `Characteristics` (LLVM's own WinCOFF writer flags overflow at
     `>= 0xffff`). Reproduced with two generated programs of 65534 and 65535 `bl` calls: before,
     both compiled and `llvm-readobj` reported `RelocationCount: 65535` with the OVFL bit clear —
     the overflow form written as a plain count. Now `nr >= 0xffff` fails with `mc: 65535 or more
     relocations in one section: .text` (exit 1) and the 65534-relocation object is byte-identical
     to the one the old compiler produced.
  3. **No `.pdata`/`.xdata`** — accepted M19 gap, not fixed. `clang --target=aarch64-windows-msvc -c`
     of a non-leaf function emits both sections; `coff-obj-arm64` emits neither, for any function
     (verified with `llvm-readobj --sections` on the two objects). Windows on ARM64 has no
     frame-pointer fallback, so without a `RUNTIME_FUNCTION` record the OS unwinder treats an mc
     frame as a leaf whose return address is still in `x30`. Nothing in the language raises or
     catches and `/nodefaultlib` links no C runtime, so nothing in the suite unwinds and the
     `windows-11-arm` leg cannot see it; it matters when something else unwinds THROUGH an mc frame
     (a hardware fault, a `RaiseException` from an `extern`, a debugger's stack walk). The packed
     unwind encoding cannot describe mc's prologue when the frame is small enough that MSVC would
     fold the allocation into the `stp`, so doing it properly means the full unwind codes plus one
     `IMAGE_REL_ARM64_ADDR32NB` per function — a milestone of its own. Written down in
     `docs/reference/objects.md` § No `.pdata`/`.xdata`, `docs/build.md` § Windows targets and
     `docs/specs/M19.md` § Out of scope.
- M20 done (`docs/specs/M20.md`, `docs/build.md` § Windows targets,
  `docs/guide/50-cross-compile.md` § Windows, `docs/reference/objects.md` § 4c,
  `docs/reference/machine.md`): **Windows x64 — COFF AMD64 relocations, the Win64 ABI as a second
  x86-64 machine, and an architecture-neutral entry shim**. `stage0/` untouched (2848/3000).
  1. **`x86_64-win`, a second machine out of the same file** (`src/machine_x86_64.mc` +83/-17,
     775 -> 841). `m_x86_64_win` is a copy of `m_x86_64` with ONE slot replaced, `MTASK_PROLOGUE`;
     the other thirty entries are literally the same `&fn`, because `MTASK_INS_SIZE`,
     `MTASK_ENCODE`, `MTASK_DUMP`, `MTASK_RELOC_KIND` and `MTASK_RELOC_OFF` are pure functions of
     the `Ins` record and are ABI-blind. The convention lives in three globals — the argument table
     (`rcx rdx r8 r9`), `x86_nargreg` (6 / 4) and `x86_shadow` (0 / 32) — set by that prologue,
     which `gen_func` always runs before the first `MTASK_PARAM` and before any `MTASK_CALL`, so
     they can never be stale. `x86_param` reads argument `i >= nargreg` at
     `16 + shadow + (i - nargreg) * 8`, i.e. `[rbp+48]` for the fifth Win64 parameter;
     `x86_push_args` subtracts the shadow **last**, so it lands below the pushed arguments and the
     fifth argument is at `[rsp+32]` — which is why it must return non-zero (32) even for a call
     with no stack arguments. The alignment rule is unchanged (`8*np + 32` is 0 mod 16 iff `np` is
     even). **The register partition does not move**: `rax`, `rcx`, `rdx` and `r8..r11` are
     volatile in both ABIs, so depths stay in `r8..r11` and scratch stays `rax`/`rcx`/`rdx`;
     `rdi`/`rsi` become callee-saved and the machine simply stops naming them. Two machines and not
     a runtime flag because `--machine=x86_64-win` has to be able to DUMP the Win64 sequence.
  2. **`coff-obj-x86_64`** (`src/backend_coff.mc` +62/-10, 380 -> 432; `src/main.mc` +2):
     `i64 coff_machine`, the exact counterpart of `elf_em`, set by each entry point and deciding
     both the header value (`IMAGE_FILE_MACHINE_AMD64` 0x8664) and the relocation table.
     `R_X86_PLT32` and `R_X86_PC32` both map to `IMAGE_REL_AMD64_REL32` 0x0004, `R_UNSIGNED`
     (len 3) to `IMAGE_REL_AMD64_ADDR64` **0x0001** — not ARM64's 0x000E. **No addend anywhere and
     none needed**: `IMAGE_REL_AMD64_REL32` is defined from the byte FOLLOWING the four-byte field
     (`S + A - (P + 4)`) where ELF's `R_X86_64_PC32` computes `S + A - P` from its start, so the
     `-4` `elf_rel_addend` writes is already inside COFF's definition; `A` is the in-place content
     and the encoder leaves both fields zero. `REL32_1..5` are never needed — both relocated
     instructions put their disp32 at the very end. `backend_coff_x86` names `x86_64-win` as its
     first statement, which is how the ABI is reached without `target()` growing a fifth column
     (the M17 step B rule). `target("windows", "x86_64", "coff-obj-x86_64", 0)`.
  3. **The entry shim split** (`lib/sys_windows_start.mc`, new, 41 lines; `lib/sys_windows.mc`
     +21/-20). M19's `win_call_main` was `reloc(BRANCH26, "_main"); emit(0x94000000);` — a raw
     AArch64 `bl`, the only architecture-specific line in the layer — and it could NOT be
     re-encoded for x86-64: `emit()` writes exactly four bytes, a pending `reloc()` is pinned to
     the START of that word, `gen_word` accepts only the four Mach-O kinds, and an x86
     `call rel32` is five bytes with its field one byte in. The raw words were DELETED, not
     doubled: `mc_start` moved to its own bundled file (`<sys_windows_start>`), compiled once into
     `winstart.obj` and linked into EVERY Windows executable, where `main` is an ordinary `extern`
     reached through `MTASK_CALL`. `lib/sys_windows.mc` keeps the wrappers and `win_split` and
     gains `win_setup()`/`win_argv()`, so the file a program INCLUDES never names `main`.
     `tools/bundle.list` 42 -> 43 entries.
  4. **Scripts and tests.** `scripts/sysroot-windows.sh` unchanged (it already took
     `--arch x86_64`). `scripts/test-windows.sh` (+59/-30, 350 -> 379): `x86_64` ->
     `-machine:x64` and the `IMAGE_FILE_MACHINE_AMD64` assertion on the object AND on the linked
     `.exe`; two-level `skip_reason` copied from `test-linux.sh` (`// skip-windows:` then
     `// skip-<arch>:`, so no test needed a new header); `winstart.obj` built alongside
     `winrt.obj` and present in BOTH branches of `link_one` — the `self` mode now means "no
     `winrt.obj`", not "nothing next to it". The dash form of the lld-link options stays (MSYS
     rewrites a leading `/out:` under Git Bash). `Makefile`: `sysroot-windows-x86_64` and
     `test-windows-x86_64`, the latter in `check`, `.PHONY` and `check-skipped`.
     `tests/windows/071-nested-args.mc` (31) is `f(a, b, g(x, y), h(z))` and the same through
     `callp`: the executable proof that writing `r8`/`r9` — argument registers 3 and 4 on Win64
     AND depth registers 0 and 1 — never clobbers a source still to be read, because the table is
     written in ascending index and every depth register's own argument index is smaller than its
     position in it. `tests/windows/072-six-params.mc` (38) reads a fifth and sixth parameter at
     `[rbp+48]`/`[rbp+56]` and calls the seven-argument `CreateFileA`: the shadow space against a
     real Win64 callee that uses its home space. Both are portable and both legs run them.
  5. **CI** (`.github/workflows/ci.yml` +86): the macOS job cross-compiles for windows/x86_64 and
     uploads `windows-x86_64-objects`; `Link and run the suite (windows/x86_64)` on
     `windows-latest` links and RUNS the suite. `release.yml` untouched — no Windows-hosted `mc`
     here, that is M38. After the merge the architect adds the job to the `main` branch protection
     contexts (`docs/ci.md` § Branch protection).
  Encoder cross-check: the **967 distinct instructions** the Win64 machine emits while compiling
  `src/mc.mc` for windows/x86_64 (76533 in all) re-assemble byte-identically under
  `llvm-mc -triple=x86_64-windows-msvc`, and the 9361 pc-relative displacements it wrote were
  checked against `target - (address + length)`. Header, sections, symbols and relocation types
  match `clang --target=x86_64-windows-msvc -c` of equivalent C field for field
  (`Machine: IMAGE_FILE_MACHINE_AMD64 (0x8664)`, `main` as `Function`/`External` with no aux
  record, `IMAGE_REL_AMD64_REL32` at instruction+1 for a `call` and instruction+3 for a
  `lea r,[rip+d32]`, both with the field zero in place); the differences are mc's `TimeDateStamp`
  0 and the sections clang adds and mc does not (`.debug$S`, `.llvm_addrsig`, the section-def
  symbols). `.pdata`/`.xdata` stay the accepted M19 gap, now recorded for x64 in the same section.
  — `stage0/` untouched, 2848/3000; `src/*.mc` 18169 lines (5185 of them generated).
  `make bundle` re-run BEFORE bootstrapping: 43 files, raw 533478 -> LZ 245893, blob 246397 B.
  `make check` green end to end (RC 0, zero FAIL): `test` 32/32, `check-lex` 83/83,
  `check-ast` 83/83, `check-bundle` (lz round trip 67 cases), `check-asm` 83/83, `check-obj`
  **32/32 identical to the frozen seed**, `bootstrap` at a fixed point (`mc2.o == mc3.o`,
  663416 bytes; the `--dump-asm` diff between `mc1` and `mc2` is empty), `check-surface` 32/32,
  `test-exe` 32/32, `check-mc` 6/6, `check-standalone`, `check-toml` 10/10, `check-build` 12/12,
  `check-limits` 17/17 under 90%, `check-minimal`, `test-linux` 32/32 on linux/aarch64,
  `test-linux-x86_64` 29/29 on linux/x86_64, **`test-windows` 34/34 objects for windows/aarch64
  (1 skipped) and `test-windows-x86_64` 32/32 for windows/x86_64 (3 skipped)**, 3 executables
  linked with `lld-link` in each, `check-examples`, `check-lang`, `check-conc`, `check-desktop`,
  `check-docs` (140 symbols, 17 flags, 16 TOML keys, 10 directives, 46 samples, 163 links),
  `site` 71 pages + `check-site` (0 link problems, 71 files 0 problems, 50 contrast pairs 0 below
  the minimum). Independent inertness proof: a copy of `build/mc1` taken BEFORE the milestone and
  the one after produce a byte-identical `--dump-asm` over `src/mc.mc` for arm64 and for
  `--machine=x86_64`.
  Goldens rewritten ONCE, all three in the same commit, only after the empty `--dump-asm` diff and
  `cmp build/mc2.o build/mc3.o`: `tests/golden/mc2.sha256`
  `6674d967…591b6d40` -> `6deafb02493e63f59eaa9c12627dcd63f0d9bbda1a0e22be852fc36616ef3bad`, and
  the two Linux ones re-recorded by deleting them and running `make check-linux-host` —
  `mc2-linux-arm64.sha256` `017325eb2de7548f32fea83caad8383db0d813c9094cd23644bee3c6af826ff8`,
  `mc2-linux-x86_64.sha256` `3b93e1887585e8d38d62421a1451bd66a9f4752c7006fb2e67b6bb300852dfce`.
  `build/mc-exe` 600211 B.
- M38 done (`docs/specs/M38.md`, `docs/guide/95-windows-host.md`, `docs/bootstrap.md` § The
  Windows chain, `docs/ci.md` § M38): **`mc` hosted on Windows, arm64 and x64**. `stage0/`
  untouched (2848/3000). Four steps, one commit each.
  1. **Stack parameters 9..12, `MAXPARAMS` 8 -> 12 in `src/`** (Decision 1). `CreateProcessA`
     takes ten parameters, so the host layer could not even be declared. The arm64 machine gained
     the caller half (`a64_stack_args`: arguments 9..12 at `[sp, #0..#24]`, written BEFORE
     `x0..x7` so the stores can still read the depth registers and use `x16` for a spilled one)
     and the callee half (`a64_param` reads `[x29 + 16 + 8*(i-8)]`, since the frame record moved
     sp by 16). **Deviation from the spec's sketch, on record:** the outgoing area is NOT a
     `sub sp` around the call the way `x86_push_args` does it — every frame slot is addressed
     through the fictitious `REG_FRAME` base that `fix_frame()` only turns into `sp + (frame -
     off)` at the END of the function, so an sp that moved inside the body would make every
     spilled depth read the wrong address. It is reserved at the bottom of the FRAME instead
     (`a64_frame_fix` adds 16 or 32 bytes, `die("frame too large")` guards the 12-bit immediate)
     and the stores name `REG_SP`, which `fix_frame` leaves alone. `a64_callp` spreads its
     arguments over `x0..x7` and the stack for the same reason. `src/machine_x86_64.mc` needed
     nothing: `x86_push_args`/`x86_param` were already general (SysV 7th+, Win64 5th+ above the
     shadow space). The seed keeps 8 — `stage0` only compiles `src/mc.mc`, which has no function
     with more than eight parameters — a documented divergence like `MAXSTRS`/`MAXGLOBALS`.
     `tests/mc/080-twelve-params.mc` (sum12/pick12 direct, sum11/pick11 through `callp`, sum10
     with two CALLS in stack positions, `u8`/`u16`/`u32` on the stack path, a nested 12-argument
     call) runs on **all five targets**; `scripts/check-surface.sh` gained the callee-side and
     caller-side ABI assertions. Inertness proved: `--dump-asm` diffs EMPTY for `arm64`,
     `x86_64` and `x86_64-win` over `src/mc.mc` and the whole `tests/*.mc` + `lib/*.mc` corpus,
     and `check-obj` 32/32 identical to `mc0`.
  2. **The host layer.** `src/host_windows.mc` (58) + `host_windows_{aarch64,x86_64}.mc` +
     `mc_windows{,_x86_64}.mc`, the Linux pair's shape. `lib/sys_windows_host.mc` (244, bundled
     as `sys_windows_host`, compiled into `mcrt.obj`) is the fifteen POSIX names the compiler
     declares `extern`, over kernel32: `posix_spawnp` (MSVCRT quoting, `STARTUPINFOA` 104 B and
     `PROCESS_INFORMATION` 24 B in `u8` arrays through `st*`/`ld*`, `CreateProcessA` with
     `lpApplicationName = 0` so PATH and `.exe` are searched for us), `waitpid`
     (`WaitForSingleObject` + `GetExitCodeProcess`, `(code & 255) << 8` — Windows has no signals,
     so the shape `drv_spawn` reads is exact), `mmap` over `VirtualAlloc` (`src/arena.mc`
     untouched: `arena_map` already rounds to 64 KiB, `VirtualAlloc`'s granularity),
     `mkdir`/`unlink`/`_exit`, `chmod` returning 0, and the three
     `posix_spawn_file_actions_*` stubs. `host_exe_suffix()` joined the host interface
     (`""` / `".exe"`) and `drv_teach` uses it at every site where `[compiler].out` names a
     BINARY. `lib/sys_windows_start.mc` passes 0 as `main`'s third argument.
     `scripts/sysroot-windows.sh`'s `.def` went from seven names to thirteen. Because
     `check-ast`/`check-asm` compile every `lib/*.mc` with the seed AND with `mc1` and compare,
     `lib/sys_windows_host.mc` carries a `// seed-skip:` header with the reason and both scripts
     report it — the same argument that put `tests/mc/` in a directory of its own.
  3. **The chain.** `src/mc.windows-{aarch64,x86_64}{,-obj}.toml`, `scripts/link-windows.sh`
     (105) and `scripts/bootstrap-windows.sh` (280). The sysroot holds all three files a link
     needs and the program does not provide — `kernel32.lib`, `winstart.obj`, `mcrt.obj` — because
     a literal `[linker].args` path is resolved against the working directory and not against the
     config. The Makefile's host switch is three-way (`WINHOST` is a `findstring` over
     MINGW/MSYS/CYGWIN), `REF`/`MC` become `build/mc1w.exe`/`build/mc2w.exe`, `check` is the
     subset `budget bootstrap-windows check-lex check-ast check-asm check-obj check-bundle
     check-mc check-toml check-limits check-skipped`, and every check script that had a Linux
     branch got a Windows one. `.gitattributes` with `* -text` (Decision 11).
  4. **CI and releases.** The macOS job cross-compiles the two COFF compiler objects and the two
     sysroots and uploads `mc-windows-hosts`; the jobs `mc on windows/arm64 host`
     (`windows-11-arm`) and `mc on windows/x86_64 host` (`windows-2025`) link, ask `--host`, run
     `make check SEED=…` and the cross proof against `build/mc2.o`. `core.autocrlf=false` before
     the checkout, `MSYS2_ARG_CONV_EXCL='*'`, `choco install make`. The M20 x64 suite leg moved to
     `windows-2025` (Decision 9). `release.yml`: `build-future-hosts` deleted, `build-windows`
     (a two-entry matrix) in its place, `publish` needs all three producers — **five** assets,
     `mc.exe` inside the two Windows tarballs (`scripts/release-assets.sh`).
  — `stage0/` untouched, 2848/3000; bundle 47 files (raw 552780 -> LZ 257678, blob 258262 B).
  `make check` green end to end on macOS; `make check-linux-host` green on both architectures
  (RC 0), 33/33 on linux/aarch64 and 30/30 on linux/x86_64 with `080-twelve-params` included;
  `make test-windows` 35/35 and `make test-windows-x86_64` 33/33 objects cross-compiled and
  linked here. Cross-built and LINKED on this Mac with `lld-link`, no undefined symbols:
  `build/mc-windows-arm64.exe` 542208 B (`IMAGE_FILE_MACHINE_ARM64`) and
  `build/mc-windows-x86_64.exe` 589312 B (`IMAGE_FILE_MACHINE_AMD64`).
  **Five goldens rewritten in one commit**, each only after its own criterion: `mc2.sha256`
  `6deafb02…ef3bad` -> `28550e3912ed5012a16b7d6e5bad5ba3032a90e66364ed1a0954653bb94fd4a8`
  (empty `--dump-asm` diff between mc1 and mc2, `cmp mc2.o mc3.o`, 676560 B); the two Linux ones
  deleted and re-recorded by `make check-linux-host` —
  `mc2-linux-arm64.sha256` `113261108524194371c66e31257caa841ca01f9e396b4f53257e4a89a2fa5d78`,
  `mc2-linux-x86_64.sha256` `542893ebbd9f0da7f1ad4a77aeebb42e80884dc46f99a12d4956ce7781ea8934`;
  and the two NEW Windows ones computed on macOS as the SHA-256 of the cross-compiled object,
  which is by construction the object the Windows-hosted compiler must write —
  `mc2-windows-arm64.sha256` `b652e5d5db7177ee9b34938ba6400342c1479ffee86cdc3bbc60c1440e0d75ef`
  (689869 B), `mc2-windows-x86_64.sha256`
  `db21c424ebb68e8805ad8229f1e493377fd25e626c9b7609df762cfef467e4c6` (708729 B), and `build/mc2`
  produces both byte for byte as `build/mc1` does.
  **What only the Windows runners can prove**: that the kernel32 shims BEHAVE — a spawn, a wait,
  an exit code, a `VirtualAlloc`ed arena — and therefore the fixed point, the suite and the cross
  proof on a real Windows machine. Nothing Windows executes on this Mac.
- M39 done (`docs/specs/M39.md`, `docs/guide/97-a-new-architecture.md`): **an architecture taught
  from the surface** -- `examples/kernel`, a bare-metal RISC-V 64 micro-kernel compiled by a taught
  compiler and booted under QEMU. **`git diff --stat src/ stage0/ lib/ tests/` is empty**: that is
  the milestone. Everything is under `examples/kernel/` (2563 lines):
  `machine_riscv64.mc` (780) fills the same 31 slots `src/machine_arm64.mc` and
  `src/machine_x86_64.mc` fill -- depths 0..3 in `t3..t6`, scratch `t0`/`t1` and `t2` reserved for
  address materialisation, arguments `a0..a7` with 9..12 at `[s0 + 16 + 8*(i-8)]`, locals at
  `[s0 - off]`, an epilogue that starts with `mv sp, s0` and is therefore NEVER patched, and two
  module-private relocation kinds (32, 33) each carried by ONE fused 8-byte `Ins`
  (`auipc`+`addi`, `auipc`+`jalr`) so the walker's one-relocation-per-instruction rule is not bent
  (D4). Addressing is pc-relative because `lui t2, 0x80000` sign-extends to
  `0xFFFFFFFF80000000`, which is wrong at exactly the base a `virt` board loads at (D3).
  RV's store displacement is a SIGNED 12-bit field (2047) against the walker's 4095, so the
  MACHINE pays (G7): above 2047 the offset goes through `t2`, which is what makes `V_ADDI`, the
  eight memory forms and the frame reserve variable-length and what makes running the real encoder
  for `MTASK_INS_SIZE` mandatory. `image.mc` (246) is `backend("rv-image", ...)`: sections placed
  from `IMG_BASE 0x80000000` in creation order, bss past the file, every symbol rebased, the three
  relocation kinds resolved in place, six symbols synthesized (`_bss_start`/`_bss_end`/
  `_data_start`/`_data_end`/`_data_lma`/`_stack_top`) and raw bytes out -- no header, no
  signature. `kernel_syntax.mc` (117) teaches `mmio` / `csrw` / `csrr(...)` / `yield`.
  `lib/sys_bare.mc` (148), `lib/trap.mc` (95), `lib/sched.mc` (90), `main.mc` (90),
  `tests/sweep.mc` (177), `mc-kernel.mc` (30), `mc.toml` (62), `test.sh` (502), `README.md` (226).
  **Two deviations from the spec's sketch, both on record.** (1) The reset stub is
  `li sp, _stack_top` + `j _start`, padded to a fixed 32 bytes, not `jal x0, _start` alone: a
  RISC-V hart comes out of reset with every register zero and the compiler's frame record is
  unconditional, so `_start`'s own `sd ra, 8(sp)` would fault on the kernel's first instruction.
  (2) **The context switch is TWO instructions, not the ~25 the spec priced** -- `sd s0, 0(a0)` +
  `ld s0, 0(a1)` -- because `s1..s11` are never written, `ra`/`s0` are already on the suspended
  task's stack (the unconditional record), and `sp` is derived from `s0` by the epilogue. It was
  written and QEMU-tested FIRST, by hand in assembler, before the machine existed (risk 4).
  Proof: `boot / trap / t0 t1 x5 / ok`, **exit 0**, and the same kernel with `halt(42)` **exit 42**
  (QEMU 11.0.1 here, 8.2.2 on `ubuntu-latest`); two builds `cmp`-identical; the default compiler
  refuses both halves (`unknown backend: rv-image`, `type expected at top level`); seven ABI
  assertions over `--dump-asm --machine=riscv64` (25 functions, 0 mentions of `s1..s11`/`gp`/`tp`
  in 751 lines); the llvm-mc sweep -- **234 + 262 + 1057 distinct instructions re-assembled byte
  for byte, 0 mismatches**, and 58 + 34 + 34 pc-relative pairs plus 51 + 53 + 3253 branches checked
  against a placement recomputed independently from `--dump-syms`, 0 wrong. `make check-kernel` is
  inside `make check` and self-skips without QEMU; the `baremetal-riscv64` CI leg on
  `ubuntu-latest` boots the image the macOS job uploads.
  Gaps priced and NOT taken: G1 (`mc build` cannot drive a bare target -- `[target]` is resolved
  before `user_init()`; deferred to M39.5), G2 (`reloc()`'s four hard-coded kinds), G3 (a second
  relocation per instruction, which `linux/riscv64` ELF would need), G7 (kept in the machine on
  purpose). G9 taken as documentation only (D7): `docs/reference/hooks.md`'s recipe told a module
  to call `machine_task`, which writes `m_arm64` BY NAME -- corrected, along with "Four are
  registered" -> five.
  Post-M39 review, two confirmed findings, both fixed inside `examples/kernel/` (`src/`, `lib/`,
  `tests/` and `stage0/` still untouched -- acceptance 11 holds).
  1. **A jump the machine could not encode was truncated, not refused.** `rv_put_j` masks its
     argument into `jal`'s SIGNED 21-bit field, and `V_J` plus the `jal` half of the `V_JZ`/`V_JNZ`
     pair handed it `target - pc` unchecked -- so a jump past 1 MiB came out silently wrong, the
     one class `src/machine_arm64.mc` spends `br_off` (`branch too far`) on and the one class no
     later gate catches. `rv_jal_off(target, pc, real)` (+13 lines in
     `examples/kernel/machine_riscv64.mc`) dies with `riscv jal out of range`; `real` is
     `lab != 0`, so only the ENCODE pass checks -- `MTASK_INS_SIZE` measures with no label vector
     and both forms are fixed width. Reproduced first: one `if` over 40 000 statements (1.4 MiB of
     code) built a 1442680-byte image whose jump disassembles as `j -657148` where the target is
     +1440004, and QEMU stopped it with `unexpected trap, mcause=2`, exit 2; with the guard the
     same source is `mc: riscv jal out of range`, exit 1. `build/kernel.bin` is byte-identical
     before and after (`cmp`), and still boots to `ok`, exit 0. `test.sh` step 6b asserts it (the
     source generated with `awk`, 0.7 s), and fails with the pre-fix compiler.
  2. **`test.sh`'s `mc limits` step accepted exit 3 as a pass.** Exit 3 is M23's code for "a table
     grew OR is tight", so the one automated check of acceptance 9 could not fail. It is now two
     phases, the shape M23 recorded for `examples/api`: **cold**, where the COMPILER half must show
     no `grew` line (that is what `[limits] tolerance = 1.0` buys) and the exit code must be 0 or
     3; then `mc build` to record the usage, and **remembered**, where both halves must be exit 0
     with `grow 0` in every table. Verified to fail on both paths by setting `tolerance = 0.0`.
     On record, because acceptance 9's literal "grow 0" holds only in the remembered form: the
     ENTRY half's static estimate is a function of source BYTES, and `main.mc` is 90 lines whose
     taught words and `#rule` prelude expand into about five times the nodes those bytes predict
     (nodes 401 estimated, 1914 used) -- a factor no tolerance in `[0, 1]` covers.
     `examples/kernel/mc.toml`, `examples/kernel/README.md` § Limits and `docs/build.md` § M39 all
     say so now instead of "at 1.0 nothing grows".
  -- `stage0/` untouched, 2846/3000; goldens NOT rewritten (`src/` untouched, so nothing can
  move); `make bundle` not needed (`lib/` untouched). Docs: `docs/guide/97-a-new-architecture.md`
  (new), `docs/reference/machine.md` (the riscv64 column, the third division answer, the G7
  obligation, and -- from the review -- the jump-range row and the rule that a machine whose field
  is too small says so with a diagnostic), `docs/reference/hooks.md` (the two corrections),
  `docs/build.md` § M39, `docs/surface.md`, `docs/README.md`, `docs/ci.md`,
  `examples/kernel/README.md`.
- M39.5 done (`docs/specs/M39.md` § Gaps G1, decision D2): **`mc build` with a module-registered
  `[target]`** -- the deferral form and nothing else. `drv_run` keeps `[target].os`/`.arch` as the
  strings the file wrote (`drv_os`/`drv_arch`) and no longer consults the registry; `drv_entry`
  passes a ROLE (`DRV_ROLE_OBJ` / `DRV_ROLE_EXE`) where it used to pass
  `drv_obj_backend()`/`drv_exe_backend()`; and `drv_backend_for(role)` resolves the pair inside
  `drv_parse`, **after `user_init()`** (so a target a module registered counts) and **before
  `parse_unit()`** (so an unknown pair is still reported ahead of anything wrong in the source).
  The two diagnostics stay built from the registry and the
  `<os> requires [linker]: there is no direct executable` check moved with them, all three
  byte-identical; `drv_teach`'s independent lookup of the HOST pair is untouched; there is no
  second user entry point (`mc` has no weak definitions -- a `user_targets()` would break every
  taught compiler until it grew an empty body).
  Cost in `src/`: **18 added / 15 removed code lines** in `src/driver.mc` (41/15 with comments) --
  the spec priced ~25.
  One behavioural consequence, on record in `docs/reference/diagnostics.md`: an unknown `[target]`
  is now reported after the entry has been opened and lexed, so the `compile x -> y` step line
  comes first. `scripts/check-build.sh` already asserted the LAST line of output, so the three
  `[target]` messages did not move; what had to change is where those three diag configs live
  (`tests/proj/build/d.toml`, `entry = "../app.mc"`) so the entry exists -- with an unopenable
  entry the first error would now be `cannot open`. 16/16 checks, messages unchanged.
  `examples/kernel` is the consumer, and G1 was the only thing standing between it and `mc build`:
  `mc.toml` gained `[target] os = "none" / arch = "riscv64"` with `entry = "main.mc"`,
  `out = "build/kernel.bin"`, `kind = "exe"`; `mc-kernel.mc`'s `user_init` gained
  `target("none", "riscv64", "rv-image", "rv-image")` -- `rv-image` in **both** roles because a
  bare board has no separable object step, and in the EXE slot so `kind = "exe"` needs no
  `[linker]`. `mc build examples/kernel` is now the whole build (compiler, then the spawned child
  with `--entry-only`), and the image it writes is **byte for byte** the one the single-file CLI
  wrote before the change (3304 bytes, `cmp` against a copy taken from the pre-M39.5 tree);
  `test.sh` asserts that equality on every run and gained a fourth refusal case
  (`mc1 build examples/kernel --entry-only` -> `only macos, linux and windows (see
  docs/build.md): target.os`). `.github/workflows/ci.yml`'s "Build the bare-metal RISC-V images"
  step is `build/mc1 build examples/kernel`; the halt(42) variant keeps the single-file CLI,
  since it is not `[project].entry`.
  Inertness (the M17-step-A protocol): a copy of `build/mc1` taken BEFORE the change writes
  byte-identical objects for all 32 `tests/*.mc` **and for `src/mc.mc` itself**, and -- through
  the taught compilers each of them builds -- byte-identical artefacts for `examples/api`
  (55632 B), `examples/lang` (35350 B), `examples/conc` (54342 B) and `examples/desktop`
  (37444 B). Nothing the compiler emits moved; the goldens moved only because `src/driver.mc` and
  the bundle did.
  -- `stage0/` untouched, 2848/3000; `make bundle` re-run before bootstrapping (`src/driver.mc` is
  bundled as `mc/driver`). `make check` green end to end (RC 0): `test` 32/32, `check-lex`/
  `check-ast`/`check-asm` (92/92, 91/91, 91/91 files), `check-obj` **32/32** against the frozen
  seed, `check-bundle`, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 749344 bytes; the
  `--dump-asm` diff between `mc1` and `mc2` is **empty**), `check-surface` 32/32, `test-exe`
  32/32, `check-mc` 7/7, `check-standalone`, `check-toml` 10/10, `check-build` **16/16**,
  `check-stubs` 9/9, `check-limits` 17/17 under 90%, `test-linux` 33/33, `test-linux-x86_64`
  30/30, `test-windows` 35/35 + 33/33 cross-compiled, `check-examples`, `check-lang`,
  `check-conc`, `check-desktop`, **`check-kernel` OK (0 skipped)** -- QEMU 11.0.1 prints the exact
  transcript and exit 0, `halt(42)` gives exit 42 -- `check-docs` (144 symbols, 18 flags, 17 TOML
  keys, 10 directives, 47 samples, 220 links), `site` + `check-site`.
  The five goldens rewritten **once**, in the same commit, only after the empty `--dump-asm` diff
  and `cmp build/mc2.o build/mc3.o`: `mc2.sha256`
  `92b04f72...82f903` -> `5836c1fd132a57fad34e9883b1749c47256ef01f33e75c5d4ffb4e66c61c0344`, the
  Linux pair re-recorded by `make check-linux-host` (Docker, both arches, each after its own fixed
  point) and the Windows pair cross-computed per `tests/golden/README.md`.
  Docs: `docs/build.md` § M39 / M39.5 (rewritten), `docs/reference/toml.md` § `[target]`
  ("a pair the compiler or one of its modules registered"), `docs/reference/diagnostics.md`,
  `docs/guide/97-a-new-architecture.md` (four registrations now, and the gap removed from "what
  this does not buy yet"), `examples/kernel/README.md` + `mc.toml`, `docs/specs/M39.md` (G1 marked
  taken, with the real line count).
- Post-M39.5 batch (review): the two findings the PR review raised, both confirmed by reading and
  both about a backend slot a module can leave at 0. Only `src/driver.mc` changed (+35/-6, 12 of
  them code).
  1. **`drv_backend_for(DRV_ROLE_OBJ)` handed a null to `backend_find`.** `target(os, arch, 0,
     exe)` is a legitimate registration -- it is what a board whose flat image IS the artefact
     writes -- and asking such a target for an object (`kind = "obj"`, or `kind = "exe"` with a
     `[linker]`, which goes through the object step) returned `tgt_obj_at() == 0` unchecked;
     `backend_find` compares that against every registered name with `str_eq` and dereferenced it.
     Reproduced on the pre-fix compiler: the spawned child died of **SIGSEGV (exit 139)** with the
     `compile app.mc -> build/app-toy.o` step line as its last word, and `mc build` reported
     nothing but exit 1. Now `toy/toy has no object backend: use kind = "exe"` through
     `toml_err_key("target.os", ...)`, at the value's own position and exit 1 -- the mirror of the
     `<os> requires [linker]: there is no direct executable` message the empty EXE slot has always
     had.
  2. **`mc sysroot stub` never resolved `[target]`.** That path reaches `drv_parse` directly
     (`src/sysroot.mc`), not through `drv_compile`, so `drv_bname` was never one of the M39.5 role
     markers and the resolution inside `drv_parse` was skipped: a foreign `[target].os` came out
     of the stub writer as `mc: no stub writer for: haiku: a static libc is code, not a name list`
     and an unregistered arch was not diagnosed at all. A third marker, **`DRV_ROLE_NONE`**, is
     set on that path: `drv_backend_for` runs the two registry checks and returns 0 without
     touching a slot -- deliberately not `DRV_ROLE_OBJ`, since a `.tbd`/`.def` needs the os and
     the arch and never a backend, so a target with no object backend still stubs. `mc sysroot
     stub` and `mc build` now print the same message, same `file:line:col`, same exit 1, checked
     side by side.
  Proofs, all in `scripts/check-build.sh` (16/16 -> **21/21**): `tests/proj/noobj.mc` is the whole
  taught compiler (`target("toy", "toy", 0, "macho-exe")`, the only way to get a 0 into a slot,
  since every target `src/main.mc` registers has an object backend), `noobj.toml` asserts the new
  message as the exact last line (`tests/proj/noobj.toml:19:8: toy/toy has no object backend: use
  kind = "exe": target.os`), `toy.toml` is the same project with the fix the message names --
  `kind = "exe"`, built through the taught target and RUN, so the advice is proved and not
  asserted -- plus a `[target].arch` diagnostic in build mode and the two `sysroot stub` ones. The
  `diag` helper gained one variable (`diag_cmd`) so both subcommands go through the same
  assertion. `check-stubs` stays 9/9: the `no stub writer for: linux` case is a REGISTERED target
  and reaches the writer exactly as before.
  Docs: `docs/reference/diagnostics.md` (the new row, plus the note that `mc sysroot stub` runs
  the same resolution -- and the § 10 table, split in two by M39.5's paragraph, put back together),
  `docs/reference/hooks.md` § `target()` (what a 0 in EITHER slot means; the stale "`mc build`
  will not reach it yet" paragraph, which M39.5 had already made false, rewritten),
  `docs/reference/toml.md` § `[target]`, `docs/reference/sysroot.md` § 7, `docs/build.md`
  § M39 / M39.5, `docs/specs/M39.md` § G1.
  -- `stage0/` untouched, 2848/3000; `make bundle` re-run (`src/driver.mc` is bundled as
  `mc/driver`): 50 files, raw 616002 -> LZ 286592, blob 287208 B. `make check` green end to end
  (RC 0, zero FAIL, 3m54s): `test` 32/32, `check-lex` 92/92, `check-ast` 91/91, `check-asm` 91/91,
  `check-obj` 32/32 against the frozen seed, `check-bundle` (reproducible + fresh), `bootstrap` at
  a fixed point (`mc2.o == mc3.o`, 750704 bytes; the `--dump-asm` diff between `mc1` and `mc2` is
  **empty**), `check-surface` 32/32 + inert, `test-exe` 32/32, `check-mc` 7/7, `check-standalone`,
  `check-toml` 10/10, **`check-build` 21/21**, `check-stubs` 9/9, `check-sysroots` (13 rows),
  `check-limits` **17/17 under 90%** (the tightest is `globals` 330/512 = 64%),
  `check-minimal`, `test-linux` 33/33, `test-linux-x86_64` 30/30, `test-windows` 35/35 +
  33/33 cross-compiled,
  `check-examples`, `check-lang` 14, `check-conc` 21, `check-desktop`, `check-kernel`
  (`mc build examples/kernel` -> 3304 B, QEMU 11.0.1 transcript and exit 0),
  `check-docs` (144 symbols, 18 flags, 17 TOML keys, 10 directives, 47 samples, 224 links),
  `site` + `check-site` (77 files, 0 problems; 50 contrast pairs, 0 below the minimum).
  The five goldens rewritten **once more**, superseding the values in the entry above, only after
  the empty `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`: `mc2.sha256`
  `5836c1fd...c0344` -> `d73a2861da0233e9c99b17ab3ace4104a97d21f0113f08251be024d4e849b79b`, the
  Linux pair re-recorded by `make check-linux-host` (Docker, both arches, each after its own fixed
  point) and the Windows pair cross-computed per `tests/golden/README.md`.
- M43 step B ✔ (`docs/specs/M43.md` § Implementation notes -- step B, ten numbered kernel
  corrections): **the box and the supervisor, without seccomp/Landlock (step C).**
  `src/sandbox_box.mc` (440) and `src/sandbox.mc` (1280); `scripts/test-sandbox.sh`;
  `tests/sandbox/*.mc` (clean, forever, sleeper, eightgib, shadow, connect, forkbomb, rocwd).
  What the kernel decided: **four processes, not three** -- P (supervisor), I (unshares the six
  namespaces, builds the tree, `pivot_root`s), **J** (pid 1 of the pid namespace, runs one C per
  step: an init that exits accepts no new process, and a second `unshare(CLONE_NEWPID)` is EINVAL),
  C (the step). Maps: `0 <uid> 1` unprivileged and **`0 0 65536`** for root, no `setuid` -- `0 65534
  1` alone left the caller unmapped (`mkdirat` EOVERFLOW) and `+ 1 0 1` broke overlay copy-up on a
  root-owned lower (the inode owner must be mapped; `CAP_DAC_OVERRIDE` does not help); the cost is
  that `RLIMIT_NPROC` does not bind for root (`copy_process` exempts `INIT_USER`), documented with
  "run it unprivileged" as the answer. Overlay needs `userxattr` inside a user namespace, and it
  mounts on virtiofs (Lima) and ext4 (VPS), root and unprivileged -- the priced ro-`/src` + `/out`
  fallback is implemented and no cell reached it. `RLIMIT_AS`/`NPROC`/`STACK` are set by C right
  before `execve` (in I they would cap the box's own arena and refuse its own fork); the compile
  step gets `NPROC 16` because `mc build` spawns the compiler it taught. Soft = hard `RLIMIT_CPU`
  is SIGKILL, not SIGXCPU, and rusage lands a shade under the cap (1.997 s for 2), so J's cpu
  verdict carries 100 ms of slack; the wall-clock line is P's because killing J kills the reporter.
  Two options the corpus forced: `--root DIR` (with `/src` at the source's own directory,
  `#include "../lib/sys.mc"` resolved to `/lib/sys.mc` -- nine tests) and `--config NAME`
  (`examples/lang` needs `mc.linux.toml`/`mc.linux-gnu.toml` without `[target]`); `--report FILE`
  writes the file AND stderr. **Globals: 422/512** -- one global (`sb_state`, an arena record with
  `SB_*` accessors) for the whole milestone; step A's sixteen became the record.
  Measured (Ubuntu 26.04, 7.0.0-30, Lima aarch64 + VPS x86_64, root and unprivileged; plus
  `alpine:3 --privileged` on 6.12): isolation cases 8/8 in every cell, the suite 31/31 and 29/29
  through `mc sandbox run` with identical exit/stdout, `mc sandbox exec` on static AND dynamic
  M42 binaries with only `/lib` bound, `examples/lang` taught and run inside (`13 25 12 box`),
  host tree untouched; `clean.mc` byte-identical to the unsandboxed run; `forever.mc` `killed: cpu
  limit (2 s)` exit 124 at 2.006 s; `sleeper.mc` `killed: wall clock (5 s)` exit 124 at 5.01 s;
  `eightgib.mc`'s `malloc(8 GiB)` returns 0 under `RLIMIT_AS`; `shadow.mc` gets ENOENT (`/etc` does
  not exist -- the NAMED `refused: open` is step C's); `connect.mc` ENETUNREACH from the empty
  netns; `forkbomb.mc` `forked 0` unprivileged (EAGAIN on the first clone) and 200 as root;
  unprivileged with the stock sysctl: `sandbox: cannot mount /: EACCES (apparmor restricts
  unprivileged user namespaces: ...)`, exit 126. **Overhead per box: 1.37/1.43 ms aarch64,
  4.12/4.98 ms x86_64** (root/unprivileged). Reports deterministic (`cmp` equal, no digit run >= 4),
  no `/tmp/.mc-box*` left, `find -newer` empty outside `build/`.
  -- `stage0/`, `lib/`, `tests/*.mc` untouched; bundle 84 files (blob 454822 B); `make check` RC 0
  with `test-sandbox` 49 ok / 1 skipped inside it (delegating to Lima from macOS); `check-obj`
  32/32; fixed point 1050240 B; `check-limits` 17/17; four Linux cells RC 0; `check-inert`
  identical everywhere. Goldens rewritten once: `mc2.sha256`
  `675d62a48b1ca5d1f04649a2b88aa151da8fec53654dcd5ea3e0790ffe1ef0fd`, Linux `bee69954…46dea4` /
  `97c888a8…7251ca`, Windows `edd2d619…e0776` / `08a6d675…6e0a`. Not yet: the CI job (acceptance
  10), exit 125 and every `refused:` line (step C).
- M43 step C ✔ (`docs/specs/M43.md` § Implementation notes -- step C, fourteen kernel/libc facts):
  **the two walls and the explain channel.** `src/seccomp.mc` (600): the BPF builder
  (`ld[arch]`/`jeq host_audit_arch()` -- a new host-layer answer, not a constant -- `/ld[nr]/jge
  0x40000000 -> KILL (x32)/one JEQ per profile entry/the clone flag block/ret USER_NOTIF`),
  Landlock with the ABI probed at runtime (**abi 8** measured, floor 4; masks per level, 12-byte
  packed `path_beneath`, O_PATH fds; a rule on a FILE may not carry `READ_DIR`, EINVAL), installed
  by C in the marked spot: Landlock, the per-step rlimits, then seccomp with `NEW_LISTENER`.
  **The listener road, decided by measurement**: two `pidfd_getfd` hops (C -> J -> P), because C's
  pid is a number in the box's namespace that P only learns from the first notification; Yama
  `ptrace_scope` = 1 on both hosts and both hops are parent -> descendant, same uid. The explain
  channel in P (`src/sandbox.mc` +180): `ppoll` over status pipe + listener, `NOTIF_RECV`/`SEND`/
  `ID_VALID`, `process_vm_readv` page by page; the § 4 table plus `fork`/`vfork` in the
  process-creating set; `sn_names[]` in `src/sysno.mc` indexed by the same `SN_*` as the number
  table (one table, two columns). **A refused call is killed and NOT answered** (deviation from
  § 4): answering woke the step and `shadow errno=13`/`socket refused` appeared on some runs only.
  **Profiles measured, not written**: `scripts/sandbox-trace.sh` (386) with `strace -fc` OUTSIDE the
  box (tracing the box records `unshare`/`mount`/`pivot_root`, and once a filter exists the
  measurement is circular), `tools/sandbox/*.list` (12), `src/sandbox_profiles.mc` (198, generated,
  in `SN_*` terms): compile musl 18/19, glibc +8/+7; program musl 16/17, glibc +9/+9; threads
  delta 5 (aarch64/x86_64). `--check` green on four cells both ways and exit 1 on a deliberate extra
  entry. `strace -c` DROPS `exit_group` -- a profile without it refuses every program at its last
  instruction. musl on x86_64 forks with `fork` (57). glibc's loader needs `/etc/ld.so.cache`
  bound AND granted by Landlock, else its fallback path hits `madvise` (aarch64, 1 run in 12) or
  `newfstatat` (x86_64, every dynamic program, probing `glibc-hwcaps/x86-64-v4/`). The process cap
  needs `RLIMIT_NPROC` (128) looser than P's counter (64) or the kernel's EAGAIN wins. Unprivileged
  copy-up needs owner AND group mapped.
  Acceptance 2, every line, per cell (Lima aarch64 root+unprivileged, VPS x86_64 root+unprivileged,
  x86_64 glibc by hand): `refused: open /etc/shadow` -- **before the kernel answers ENOENT**, the
  notification fires on `openat` entry (the step-B compiler prints `shadow errno=2` on the same
  source); `refused: syscall 198 (socket)` / `41`; `refused: syscall 220 (clone)` / `57 (fork)`
  musl / `56 (clone)` glibc; `refused: process limit (64)` with `--allow=threads`; `refused: mmap
  8589934592 bytes over the cap (268435456)`; all exit 125; `killed:` lines unchanged (124);
  `clean.mc` byte-identical with the program profile installed. Host process count and available
  memory unchanged, asserted by the script. Suites 31/31 and 29/29 through the box, `exec` 2/2
  incl. a `PT_INTERP` binary, `examples/lang` inside with **`compile: execve 2`** (`mc build` execs
  the compiler it wrote, which compiles the entry in-process; 3 kept as the ceiling). Five cells
  **52/52/50/50/50 ok, 0 failed**. Overhead with the filter: 1916 us vs 1619 us per box on aarch64
  (**+297 us, +21%**); on the VPS inside the noise.
  -- `stage0/`, `lib/`, `tests/*.mc` untouched; bundle 86 files (blob 478358 B); `make check` RC 0
  (`check-lex`/`ast`/`asm` 134/134, `check-obj` 32/32, fixed point 1099928 B, `check-limits` 17/17
  with **globals 432/512**, `test-sandbox` 52 ok / 1 skipped); four Linux cells RC 0; `check-inert`
  identical everywhere. Goldens rewritten once: `mc2.sha256`
  `bb48b0b27df913fcaa54b60a59da3a0e9c3cf219d0f474f731adb7b9b7bf6075`, Linux `394ce144…34579` /
  `8c9c7fab…167c17`, Windows `f2d9b228…ad4ff6` / `3596c00b…15e98e`. Not yet: the CI job
  (acceptance 10) and `docs/guide/99-sandbox.md` (step D).
- M43 step D ✔ (`docs/specs/M43.md` § Implementation notes -- step D): **the CI job, the guide,
  the last acceptance items.** Two jobs in `.github/workflows/ci.yml`, `The sandbox (linux/arm64)`
  (`ubuntu-24.04-arm`) and `The sandbox (linux/x86_64)` (`ubuntu-latest`), `needs: check`: the
  macOS job cross-compiles FOUR executables (`mc-linux{,-x86_64}{,-gnu}`, `mc build` writes the
  dynamic ELF itself since M42) into `mc-linux-sandbox`; each job flips
  `kernel.apparmor_restrict_unprivileged_userns` both ways and asserts `mc sandbox check` in each
  state, runs the unprivileged cell and the root cell (`scripts/ci-sandbox-cell.sh`, 70 lines: a
  skip on a runner is a failure unless it is a test's own `// skip-linux:` header, and `0 failed`
  is required), `scripts/sandbox-trace.sh --check` with `strace`, and `docker run` WITHOUT
  `--privileged` (`userns: EPERM`, `run` -> `cannot unshare: EPERM`, exit 126). Both contexts go
  into the required checks after the merge (`docs/ci.md` § Branch protection).
  **The runners' answers** (kernel `6.17.0-1022-azure`, glibc 2.39, Landlock **abi 7**): sysctl = 1
  -> `userns: restricted (apparmor)` exit 1; sysctl = 0 -> `userns: ok` **exit 0** -- the cell no
  local oracle could measure. Suites 52/50 ok, 0 failed, per cell; box cost ~2.1-2.2 ms.
  **Two defects only CI could find**, both fixed here: (1) a profile is a UNION over glibc versions
  (2.39 needs `rt_sigaction` and `clone`) -- `sandbox-trace.sh` gained `--union`/`--strict`, and
  `--check` fails only on "the trace has a call the table lacks", reporting the reverse as `note`;
  (2) **`lex_readable` (`src/lex.mc`) was the one `open` in `src/` without `c_int()`** (an M45 D8
  miss): on a glibc host a failing `open` returns `0x00000000ffffffff`, so every missing file was
  "readable" and `mc build` on a fresh tree died with `cannot open: build/.mc-usage.toml`; it also
  affected `[include].paths`. One line.
  `docs/guide/99-sandbox.md` (205 lines, 2 samples compiled and not run, with the reason on the
  page); `docs/reference/sandbox.md` complete (the four CI cells in § Hosts, the union rule, the
  Docker-Desktop `fakeowner` finding); `check-parts` gained acceptance 9's second half (a compiler
  without `<mc/core_sandbox>` prints no `sandbox` usage line and refuses `mc sandbox` as
  `cannot open: sandbox`). Oracles cleaned (VPS `/root/m43`, `mcbox` user, Lima `/tmp`; sysctl
  back to 1 on both).
  -- `stage0/`, `lib/`, `tests/*.mc` untouched; bundle 86 files (blob 478867 B); `make check` RC 0
  (`check-lex`/`ast`/`asm` 134/134, `check-obj` 32/32, fixed point 1100464 B, empty `--dump-asm`
  diff, `check-limits` 17/17, `test-sandbox` 52 ok / 1 skipped, `check-docs` 192 symbols / 33 flags
  / 50 samples / 318 links, site 87 pages); four Linux cells RC 0; `check-inert` against a `mc1`
  from 3966268 identical everywhere. Goldens rewritten (twice in this step: the union, then the
  `lex.mc` line), final: `mc2.sha256`
  `f8b05c08c9f06a14ba17ae3f329f240396ff5dc2473c07c445a4013feba173e1`, Linux `d8bdbeeb…da6b59` /
  `ed7c7f61…fd08dd`, Windows `4de1c3c9…d48cf3` / `7da0aa71…1c0d01`. Draft PR #23: three CI
  rounds, the last two **14/14 green**.
- M43 review batch ✔ (`docs/specs/M43.md` § Implementation notes -- the review): the security
  review's HIGH finding, **reproduced before it was fixed**. The COMPILE profile listed `clone`
  (and `clone3` in the glibc variant) as a plain ALLOW -- the arg-checked clone block was emitted
  only under `--allow=threads` -- so a program reachable from an untrusted tree (`mc build` runs
  `[linker].cmd` from the source's own `mc.toml`: `/src/bomb`, `PATH=/`, `/src` writable and
  executable) forked freely with no `refused:` line: `forked 12` unprivileged, `forked 200` as
  root, and `nsclone.mc` created a USER NAMESPACE inside the box (`cloned 4`). Rule now: **a
  process-creating call is never a plain ALLOW in any profile** -- `clone`/`clone3`/`fork`/`vfork`
  always reach P (`sb_notified`), any `CLONE_NEW*` bit is `refused: clone with namespace flags`
  (for `clone3` the first u64 of `clone_args` read with `process_vm_readv`; unreadable ->
  `refused: clone3 with unreadable arguments`), the rest counted per step -- compile **16**, run
  0, `--allow=threads` 64 -- as `refused: process limit (N)`; `RLIMIT_NPROC` stays the second
  wall (compile 32, so the named one wins). The generated profiles say
  `// SN_CLONE  notified, never allowed`. New cases `tests/sandbox/linkbomb/` (the hostile
  `mc.toml`), `nsclone.mc`, `nsclone3.mc`; `forkbomb.mc`'s three per-libc headers collapsed into
  one line. LOW: `sb_num` stops at 10^12 with maxima 86400 s / 1048576 MiB / 65536 MiB and minimum
  1 (`--mem 0` used to SIGSEGV the compile step). INFO: `landlock: abi N (no scoped signals below
  6)`. The docs' "compile-step forks" residual paragraph is gone because it is no longer true.
  Measured: Lima aarch64 glibc root+unprivileged 55/55, VPS x86_64 musl root+unprivileged 53/53,
  x86_64 glibc by hand, CI four cells 55/55 x2 + 53/53 x2; host process count 134 -> 134 in every
  case; `sandbox-trace.sh --check` green everywhere. `make check` RC 0, `check-obj` 32/32,
  `check-inert` identical, four Linux cells RC 0; goldens rewritten once: `mc2.sha256`
  `9e7b803f127cb6f1e059c1e6572a629bfa909cfbecbfae18b01abd1fd7a2d431`, Linux `182a4c6d…036679` /
  `e63d09bc…d99ffa`, Windows `dcaac914…4256c3` / `dfaf002c…a97b861`. PR #23 CI 14/14.
- M44 step 2 ✔ (`docs/specs/M44.md` § Implementation notes -- step 2; Amendment § A1-A3, A5, A6,
  D1'/D2'/D10'/D24): **angle brackets are libraries, quotes are my files.** `tok_add(".", 1)`
  appended LAST in `tok_init` (no id moves; `examples/lang`'s own `tok_add(".")` lands on the same
  id); `lex_include_name` is three steps through two pointers -- the lock road (`lopen_fn`,
  `lex_set_libs` from `mc_build_init()`), the bundle (`bopen_fn`, unchanged), the installed `mc`
  package (`<libs>/mc/v<mc_version()>/` + the `bundle.list` map) -- a trailing `.mc` stripped from
  every `<...>` name, `<pack>` alone = the lock row's `lib`, the once-only key for a disk-served
  name its NORMALISED path (no `getcwd` here), never the working directory, never an unlocked
  directory; `lex_root_of` + the edge list + the closure test for `#include` and `#embed`.
  `src/deps.mc` (662): the name rule and the reserved set (`mc`, `mc/...`, `deps`, `build`),
  `[deps]`/`[replace]`/`[registry]`, the lock READER, the tree hash, `libs_open` (vendored
  `deps/<pack>/` wins, then `<libs>/<pack>/v<version>/`), semver, the refusals (`mc.lock is stale`
  with the M25 `run:` block, `<pack> <ver>: <file> does not match mc.lock`, `is not fetched`,
  and -- vendored trees have no manifest for per-file attribution -- `the tree does not match
  mc.lock`). `src/toml.mc` re-entrant (`toml_push`/`toml_pop`, `toml_occurrences`);
  `src/driver.mc` `--libs-dir` (default `host_home()/.mc/libs`), `drv_apply_deps` for both halves,
  `<...>` modules verbatim. Cost **999 added lines in `src/`, 677 code** (spec ~543); globals
  432 -> **439/512**. **What did not survive**: `check-lex` cannot stay 100% -- `--dump-tokens`
  processes no directive, so `lib/syntax_demo_test.mc`'s taught `.+` operator now lexes `.` `+` where the
  seed says `unexpected character` (M44 risk 17, measured); a new `// lex-skip:` header (NOT
  `seed-skip:`, which `check-asm`/`check-ast` also honour and which would have dropped the file from
  two gates that still compare it byte for byte) -- 135/135 identical, 3 skipped. Two silent path
  bugs only a fixture found: `path_norm` drops a trailing slash and macOS `TMPDIR` ends in `/`, so
  every package root was a prefix of nothing and the closure rule never fired -- `dp_set_dir`
  normalises once. Fixtures `tests/pkg/` (mathx 1.0.0, geo 1.2.0, teach, bad, float 1.3.0, app,
  app-float, `nobundle.mc` = every part but `<mc/core_bundle>`, which is what `mc-slim` will be);
  `scripts/check-pkg.sh` **31/31** inside `make check`, under a `curl`/`wget`/`tar` shim that exits
  97 if invoked: acceptance 5-11, 18, 19 measured as the spec spells them, and step 3 of A3 --
  `<mc/host>` + `<mc/core>` + `<user_default>` served from a hand-laid `<libs>/mc/v0.0.0-dev/`
  compiles to an object `cmp`-identical to `build/mc1 src/mc.mc`. `make check` RC 0 (`check-obj`
  32/32, `check-ast`/`asm` 137/137, fixed point 1154264 B, `check-docs` 196 symbols / 35 flags /
  24 TOML keys / 349 links), four Linux cells RC 0, `check-inert` identical everywhere (D24: no
  `[deps]`, no change). Goldens rewritten once (after the rebase onto 167d540 re-recorded step 1's):
  `mc2.sha256` `9e00398d7338ad9b53654c7f07e0d16ff21319e79c915b2ac473d20e1411420a`, Linux
  `67f062a4…7a02fd` / `3c93e81f…debe70`, Windows `2858b236…3f5959` / `c75e23fd…b909322`.
- M44 step 3 ✔ (`docs/specs/M44.md` § Implementation notes -- step 3; draft § 4-§ 8, D21): **the
  write and network side.** `src/fetch.mc` (169): `fetch_get` (an `https://` source spawns the
  host downloader with M25's flags, anything else is a LOCAL PATH copied -- what makes the suite
  need no network and prices a private registry at zero), `fetch_extract`, `fetch_sha256_line`;
  `src/sysroot.mc` lost 122 lines and delegates (`check-sysroots`/`check-stubs` unchanged).
  `hex64` could NOT live in `fetch.mc` (`deps.mc` prints a hash before `driver.mc`, which
  `fetch.mc` needs): `hex64`/`sha256_file` moved to `src/sha256.mc`, one spelling of a digest
  instead of three. `src/pkg.mc` (1387) in the new part `<mc/core_pkg>` (`src/core_pkg.mc`):
  the index reader (`<registry>/index/<name>.toml`, `--registry URL|DIR`, `[registry].url`,
  default `https://minicompiler.dev/registry` -- **the owner decided the same day that a package
  SERVER at minicompiler.dev, in the private `schivei/mc-registry`, PRODUCES this exact layout
  from public git URLs validated in the sandbox; the compiler gains no client code**), MVS with
  the two-majors refusal and yanked rows skipped, the lock WRITER (sorted, `lib`/`deps` from the
  archive's own `mc.toml`, `sha256` the tree hash), the archive fetch in M25's order (download,
  extract, HASH AND COMPARE, manifest last, unlink on refusal), `vendor`, `add` (one `[deps]` line
  by `lim_fix_write`'s method), `list`, `verify`, `hash`, `check`, and top-level `mc update`
  (D21: inside its major -- `go get -u` does not cross one; `mc pkg add NAME` with no `@` takes
  the newest non-yanked of any major). `dep_hash_tree(dir, pk)` is the ONE definition of D5's
  hash for `mc build`, `mc pkg hash|sync|vendor|check`. `sync` with nothing to download
  completes without `--yes`; `check` compares against the registry's published copy for
  immutability. Cost **1673 added lines in `src/`, 1268 code** (spec ~880; the cache-manifest
  writer, `check`'s immutability half, `vendor`, the plan table); **globals 440/512**.
  `scripts/check-pkg.sh` 31 -> **63/63**, all offline: a DIRECTORY registry the script builds
  (tarballs from `tests/pkg/src`, `url` = local file, `sha256` from `scripts/pkg-hash.sh` -- so the
  two hash implementations cross-check), fixtures `mathx-1.1.0/2.0.0/2.0.1 (yanked)`, `plot`,
  `heavy` (the other major), `sync/`, `major/`, `add/`; goldens `tests/golden/pkg-list.txt`,
  `tests/pkg/sync/mc.lock.expect`; `check-parts` covers `<mc/core_pkg>`. Rebased onto 8c31a0e
  (#26): no code overlap. `make check` RC 0 (`check-obj` 32/32, fixed point 1228304 B, empty
  `--dump-asm` diff, `check-docs` 197 symbols / 36 flags / 27 TOML keys / 358 links, site 89
  pages), four Linux cells RC 0, `check-inert` identical. Goldens rewritten once: `mc2.sha256`
  `cede0b38…07284`, Linux `e4c876dd…dbc02` / `3f036b4d…d2012`, Windows `70a2259d…68309` /
  `98cf8605…4fde5`. Steps 4-5 (the slim binary, `mc install`, `mc upgrade`) follow the site, per
  the owner's sequencing of 2026-09-05.
- M44 review batch ✔ (`docs/specs/M44.md` § Implementation notes -- the supply-chain review): the
  reviewer's CRITICAL, **reproduced before it was fixed**: `[package].files` of a dependency went
  to `path_join`/`path_norm` uncontained (`path_join` DISCARDS its base on an absolute `rel`;
  `path_norm` resolves `..` with no floor) -- arbitrary READ on every `mc build` (`files =
  ["../../../payload.txt"]` hashed, rc 0), arbitrary WRITE by `mc pkg vendor` (a payload landed
  outside the project), arbitrary DELETE on a hash MISMATCH (`pkg_unbless` re-read the just-refused
  tree and unlinked what it listed: a registry row with a wrong `sha256` deleted a canary two
  directories up -- the attacker never needs a hash that passes). Rule now: ONE reader of
  `package.files`, `dep_read_files()`, behind `dep_rel_ok` (no empty/absolute, no `.`/`..`/empty
  component, no backslash, no byte < 0x20) + `dep_under` (normalised-join prefix) ->
  `<pack> <ver>: files entry escapes the package: <entry>`, exit 2; `pkg_unbless` deletes what the
  EXTRACTION wrote (the member table) and never reads that list again. HIGH: `fetch_extract`
  trusted `tar` (a symlink member to `/etc/hosts` was vendored into `deps/`): `fetch_check_members`
  lists twice (names, then the type column) and refuses links, absolute or `..` members and anything
  leaving `dest` after `--strip-components` (`member escapes the archive` / `archive member is a
  link`, exit 2, archive unlinked), every listed regular file checked afterwards; NOT done, on
  record: the extraction still names no members (a member with a space cannot travel on argv).
  MEDIUM: the hash line is now injective (`<hex> <len>:<path>\n`; control bytes refused; a forgery
  was not constructible anyway because line 1 digests `mc.toml`, where the list lives -- measured);
  `pkg_check_immutable` no longer skips without `--yes` on a URL registry and distinguishes a 404
  (`curl -f` 22 / `wget` 8 = new) from any other failure (`cannot read the published index`).
  LOW: the missing-file failure now unblesses first ("collect the error", `dep_hash_soft`);
  size caps 64 MiB archive / 1 MiB index (`larger than the cap`). Copilot's review of #27 added
  the characters Windows reserves in a name to `dep_rel_ok` (`:` `<` `>` `"` `|` `?` `*` -- `C:/x`
  is absolute to a Windows extractor; one rule for the three hosts). `check-pkg` 63 -> **80/80**
  (four escaping shapes each with a canary asserted untouched, the cross-directory vendor case,
  the wrong-hash unbless, three crafted archives, the `check` refusals, a 68 MB archive, the line
  shape). Cost: `deps.mc` +106 code, `fetch.mc` +197, `pkg.mc` +46. `make check` RC 0 (`check-obj`
  32/32, empty `--dump-asm` diff, `check-lex` 143/143 (3 skipped), `check-docs` 197 symbols),
  four Linux cells RC 0, `check-inert` identical. Goldens rewritten (final, after the Copilot
  fix and the lex-skip wording): `mc2.sha256` `5d2db5f9e94d33422d6d812d1143dc1cdd9f3bc2a1e8727a6ea113060e67ae55`, Linux
  `9161fb1b…e17f8d` / `1ea7dc83…90d1cb`, Windows `831a422a…64b068` / `6224c4a9…9b570b` -- all
  five in the scripts' `hash  file` format.
- Next: M18 or M24 (`docs/plan.md`); M40 (the word-size sweep AVR/PIC need) is
  named in `docs/plan.md`; M13 stays in the backlog (`docs/specs/M13.md`:
- M24 step A ✔ (`docs/specs/M24.md` § M1-M6, M8 and decision D5): **Tier 4 -- the inert half.
  A primitive the core has never heard of.** All in `src/`; `stage0/` untouched (2848/3000).
  A primitive the core has never heard of.** All in `src/`; `stage0/` untouched (2848/3000, byte for byte what main has).
  The rule the whole milestone rests on is a number: **a type id below `TY_MAX` (7) is a core type
  and behaves exactly as it always has, byte for byte; an id at or above it was registered by a
  module, and every core decision about it is delegated.**
  * **M1, the type registry** (`src/ast.mc`, `src/hooks.mc`): `type_new(name, width, align, kind)
    -> ty`, with `type_count`/`type_width`/`type_align`/`type_kind`/`type_name` falling through to
    it above `TY_MAX` and unchanged below. `TK_INT/TK_FLOAT/TK_WIDE/TK_OPAQUE` is what a MACHINE
    dispatches on; the core reads only width and align. A growable arena block (`T_TYPES`) holding
    only the registered types, so the core ladder is untouched. The word is reserved through the
    same `word_add` and entered in the same table `type_alias` writes, so `type_of_token` needed
    NO line and the name is valid in all seven type positions at once; `type_alias`'s guard
    widened from `TY_MAX` to `type_count()`. No keyword and no directive: `tok_init` is untouched,
    `K_U8..K_EXTERN` do not shift, `check-lex` keeps comparing the two lexers.
  * **M2, the literal's type survives resolve** (`src/gen_resolve.mc`): `res_expr`'s `N_INT` arm
    answered `TY_I64` unconditionally and threw a taught literal's type away before the walker or
    any machine could see it.
  * **M3, the three fold guards** (`src/parse.mc`): `fold_unary`, `fold_binary` and `fold_cast`
    return early on a type at or above `TY_MAX`. Without them `1.5 + 2.5` would fold to an INTEGER
    add of two bit patterns and produce an infinity at compile time, silently.
  * **M4, the depth type** (`src/gen_walk.mc`): `walk_depth_type(d)` and `walk_ret_type()`, a
    `MAXDEPTH` array reset per function. **Not a task slot** -- no signature moves, and a machine
    that never reads it emits byte for byte what it emitted before. The five re-announcement sites
    the spec lists are covered in ONE place instead: `gen_expr` became a wrapper that writes
    `res_type(n)` into the depth before the dispatch and again after, and saves/restores
    `walk_ret` around each child, so a comparison, `gen_logic`'s shortcut, `MUN_LNOT`, a cast, an
    intrinsic load and a call are all handled by the same two lines.
  * **M5, the frame slot is the type's width** (`src/gen_walk.mc`, 2 lines): `slot_new(8)` ->
    `slot_new(type_width(ty))` for a scalar local and for a parameter. Provably byte-identical for
    the seven core types, since `slot_new` rounds `(size + 7) & ~7`.
  * **M6, `syntax_lit(&f)`** (`src/hooks.mc`, `src/parse.mc`): the one grammar position Tier 3
    cannot reach, short-circuited by `nonlit == 0`. The handler returns a node or 0 ("the core
    handles this one"). The decimal-to-binary conversion lives in the MODULE, so `lex_number` and
    therefore `--dump-tokens` are exactly what the frozen `stage0/lex.c` produces. **Deviation,
    +8 lines over the spec's M6:** the handler also needs to say where its literal ended, so
    `p_take_lit(q)` and `p_src_end()` were added beside `p_resplit_punct`, under the same "a token
    just lexed from the source being read" guard.
  * **M8, deriving a machine** (`src/gen_walk.mc` for `machine_slot`, `src/hooks.mc` for
    `machine_tab`): `machine_task` writes the GLOBAL `m_arm64` by name, so the recipe
    `docs/reference/hooks.md` published corrupted arm64's own table. Both are built and the doc is
    corrected with them, including the one trap: delegate through a PRISTINE second copy, never
    through the table you patched. `machine_slot` lives in `gen_walk.mc` beside the `MTASK_*` list
    it bounds-checks, and because `src/astdump.mc` includes `hooks.mc` without `gen_walk.mc`.
  * **D5**: a `machine()` registration that shadows an existing name reuses that name's slot.
  Proofs, all in `scripts/check-surface.sh`: a taught `fix` (16.16 fixed point) and `pair`
  (16 bytes) in `lib/user_syntax_demo.mc` with a `syntax_lit` handler reading `1.5` out of the raw
  source -- a parameter, a cast and the literal in one program (exit 42); two `pair` locals
  reserving 32 bytes of frame where two `i64` reserve 16; the fold guards through `+`, `-`, `~`,
  `!` and a cast measured on `--dump-asm` (`fold()` runs after `--dump-ast`), with the control that
  core literals still fold; `type_new("if", ...)` refused with `cannot redefine core keyword: if`
  (`lib/user_dupty.mc`); `lib/user_lit_nop.mc` -- a module whose only registration is `syntax_lit`
  and whose handler answers 0 -- producing byte-identical `--dump-ast` AND objects over the whole
  `tests/` corpus; and `lib/machine_probe.mc`, a machine derived from `arm64` that changes no
  instruction and asserts the depth-type contract on every task over the whole of `src/mc.mc`:
  **32137 tasks, 40238 depths, object byte-identical to the bundled machine's**.
  `scripts/check-lex.sh` gained the `seed-skip` escape `check-asm.sh`/`check-ast.sh` already had
  (risk 6 / D6), unused today. New `scripts/check-inert.sh`: the M17-step-A proof as a script.
  — core cost, measured (`git diff --numstat`, added lines / added lines that are neither a
  comment nor blank): `ast.mc` +58/37, `hooks.mc` +117/45, `parse.mc` +41/15, `gen_resolve.mc`
  +11/5, `gen_walk.mc` +73/34 = **300 added lines, 136 of code**, against the spec's 132 for this
  half. The 164 lines of comment are this repository's density, not extra mechanism.
  `stage0/` untouched, 2848/3000 -- `git diff` against the base commit is empty.
  **The gate is that nothing moves, and it held.** `make check` green end to end (RC 0):
  `test` 32/32, `check-lex` 93/93 (1 skipped), `check-ast` 93/93, `check-asm` 93/93, `check-obj`
  **32/32 identical to the frozen seed**, `check-bundle` (52 files), `bootstrap` at a fixed point
  (`mc2.o == mc3.o`, `--dump-asm` diff between `mc1` and `mc2` empty), `check-surface` 32/32 plus
  every M24 case, `test-exe` 32/32, `check-mc` 7/7, `check-standalone`, `check-toml`,
  `check-build`, `check-limits` **17/17 under 90%**, `check-minimal`, `test-linux` 33/33,
  `test-linux-x86_64` 30/30, `test-windows`, `test-windows-x86_64`, `check-examples`,
  `check-lang`, `check-conc`, `check-desktop`, `check-docs` (155 symbols, 17 flags, 16 TOML keys,
  10 directives, 47 samples, 196 links), `site` 75 pages, `check-site` 0 link problems.
  Plus `scripts/check-inert.sh`: the compiler from before the step and the one after produce
  **byte-identical objects for all 32 `tests/*.mc`, for `src/mc.mc`, and -- through the taught
  compiler each of them builds -- for `examples/api`, `examples/lang`, `examples/conc` and
  `examples/desktop`**. All five goldens rewritten once.
  Docs: `docs/reference/machine.md` (contract **version 3**, § 3 and § 4 rewritten -- the old
  thirteen `mf_*` float slots and `#machine` are DROPPED, with the three reasons recorded),
  `docs/reference/hooks.md` (§ 3 is now six word registrations and three node hooks; the
  derivation recipe corrected), `docs/reference/language.md` § 2 and § 11,
  `docs/reference/diagnostics.md`, `docs/reference/bundle.md`, `docs/build.md`, and the new
  `docs/guide/96-a-new-primitive.md`.
- M24 step B ✔ (`docs/specs/M24.md` § M7, M9 and decisions D1-D3): **`intrinsic` and
  `--dump-machine`.** Still all in `src/`; `stage0/` untouched (2848/3000, byte for byte what main has), and still inert -- no
  test in the corpus registers anything, so `check-obj` stays 32/32 against the frozen seed and the
  pre/post compilers produce byte-identical objects everywhere.
  * **M7, `intrinsic(name, nargs, ty, &f)`** (`src/gen_resolve.mc` +74/45 code, `src/gen_walk.mc`
    +32/22, `src/arena.mc` +7): a NAMED HARDWARE INSTRUCTION applied to values the allocator
    placed. One row inserted between `opc_find` and `func_find` in the dispatch `res_call` and
    `gen_call` already run in that order, so a core intrinsic can never be shadowed
    (`cannot shadow a core intrinsic: ld64`, refused at registration) and every existing
    diagnostic keeps its order; an ordinary function of the same name IS shadowed, which is
    written down. The handler gets `(d, nargs)` with the arguments already lowered to depths
    `d..d+nargs-1` and `walk_depth_type` filled in. The registry lives in `src/gen_resolve.mc`
    beside `intrin_id` and the `IN_*` list it must refuse to shadow -- the same reason
    `machine_slot` lives in `gen_walk.mc`, and because `src/astdump.mc` includes `hooks.mc`
    without either.
    **D2**: `val_reg(d, scratch)`, `dst_reg(d)` and `dst_done(d, reg)` are published as contract
    **version 3** and are the only three names of a machine's internals that are; delegation to a
    built-in task goes through the copied table pointer, so no `a64_*` name is frozen.
  * **M9, `--dump-machine`** (`src/main.mc` +59/43, `src/hooks.mc` +28/15): per registered
    machine, one line per task with the ORIGIN of the slot -- `bundled <machine>` or `taught`, and
    `(current)` on the one the walker would drive. There is no runtime symbol table, so the origin
    is read from a SNAPSHOT (`machine_freeze()`, taken by `main()` before `user_init`) and not
    from a symbol name; a snapshot and not just a count, because a module that re-registers
    `arm64` reuses that name's registry slot (D5) and the registry no longer remembers what was
    there. It stops right after `user_init()`: a machine table is not a function of the source.
  * **D3/`#machine` stays dropped**, with the three reasons in `docs/reference/machine.md` § 4.
  Proofs (`scripts/check-surface.sh`): `rbit(x)` -- AArch64 bit reversal registered as an
  intrinsic in `lib/user_syntax_demo.mc` -- on an arbitrary expression AND at a spilled depth
  (two programs, exit 42 each); `intrinsic("ld64", ...)` refused (`lib/user_dupintrin.mc`); and the
  observable-override proof the old § 4 asked of `#machine`, delivered without the directive:
  `lib/user_badmach.mc` replaces ONE slot so that `+` lowers as a subtraction, `v(50) + v(8)`
  answers **42 instead of 58**, and `--dump-machine` reports exactly one `taught` slot, on the
  `arm64` row, across three machines -- while the stock compiler reports none.
  — core cost: **200 added lines, 130 of code** (`gen_resolve.mc` +74/45, `main.mc` +59/43,
  `gen_walk.mc` +32/22, `hooks.mc` +28/15, `arena.mc` +7/5), against the spec's 55 + 40 = 95.
  The excess is the `--dump-machine` snapshot (D5 made a counter insufficient), the four
  registration guards, and the `mtask_names[]` table the dump prints from.
  `make check` green end to end (RC 0), same numbers as step A plus `check-docs` at 162 symbols
  and 18 CLI flags; `scripts/check-inert.sh` identical everywhere; all five goldens rewritten once.
  Docs: `docs/reference/hooks.md` (`intrinsic` and the lookup family, `machine_freeze`),
  `docs/reference/cli.md` (§ "the six dumps", with the `--dump-machine` example),
  `docs/reference/machine.md` § 3 and § 4, `docs/reference/diagnostics.md`,
  `docs/reference/bundle.md`, `docs/guide/96-a-new-primitive.md`.
- M24 step 1 ✔ (`docs/specs/M24.md` § "Step 1 -- `<float>`, the first library"):
  **`f32` and `f64`, taught to `mc` from outside the compiler.** `git diff src/` for this step is
  **empty** apart from the generated `src/bundle_data.mc`; `stage0/` untouched, 2848/3000 -- `git diff` against the base commit is empty.
  * `lib/float.mc` (432): `type_new` for `f64` (8, 8, TK_FLOAT), `f32` (4, 4) and `f64raw` (8, 8,
    TK_INT -- the same bytes as an integer, so `(f64raw) x` is one `fmov`/`movq` and a NaN can be
    written down in a language with no NaN literal); the `syntax_lit` handler; and eight
    `intrinsic` registrations (`ldf32 ldf64 stf32 stf64 sqrt_f64 fabs fmin fmax`).
    **The decimal-to-binary conversion is correctly rounded and written in integers**, because the
    compiler that runs it has no floats: the literal is the exact rational `U/V`, and a 2048-bit
    big integer in fixed arrays takes the quotient with one guard bit and lets the remainder decide
    the tie. `f32` is produced by running the same routine with a 24-bit significand, never by
    narrowing an `f64`, so there is no double rounding. Verified bit for bit on `0.1 + 0.2`
    (...334, not ...333), pi to fifteen digits, `1e308`, the smallest **subnormal** `5e-324`,
    `1e20` and an exact value.
  * `lib/machine_arm64_float.mc` (669) and `lib/machine_x86_64_float.mc` (775): two derived
    machines, 21 slots each, everything else delegating through a pristine copy. Float depths in
    `v16..v23` (never the callee-saved `v8..v15`) / `xmm8..xmm13` on SysV / `xmm0..xmm5` on Win64,
    where `xmm6..xmm15` are callee-saved. The **whole ABI comes out of `walk_depth_type`**: two
    counters on AAPCS64 and SysV, one shared position on Win64, and the overflow in argument order.
    `walk_ret_type()` is what tells `MTASK_CALL` what the call returns, since by then depth `d`
    holds argument 0.
    Two things worth keeping: the AArch64 float conditions are `mi/ls/gt/ge/eq`, never `lt/le`, so
    a NaN makes all six ordered predicates false; on x86-64 `<` and `<=` SWAP their operands and
    use `a`/`ae` for the same reason, and only `==`/`!=` need the parity mask.
  * `lib/user_float.mc` (17) is the `[compiler] modules` entry, `lib/mc_float.mc` (12) the
    standalone one, and `lib/float_rt.mc` (71) the RUN-TIME half a program includes -- `putf64`
    (fixed precision, half-up, `nan`/`inf` by bit pattern, a hex fallback past 2^63),
    `fmt_f64` and `puthexf`. It is a separate include and NOT a source the module pushes:
    pushing it would put a call to `write` into every program the taught compiler compiles,
    including `lib/sys_windows_start.mc`, which has no system layer at all. It is the first user of
    the `seed-skip` escape step A added to `scripts/check-lex.sh` -- it spells float literals, so
    the frozen seed cannot lex it, and it says so in its own header.
  * `tests/float/` (12 files) and `scripts/check-float.sh` (369), inside `make check`. Every test
    is **bit-exact**: it stores with `stf64`, reads back with `ld64` and prints sixteen hex digits
    against a value recorded in its header (produced once by `python3`, so the suite has no python3
    dependency).
  Results, the same twelve sources on every leg: **macos/aarch64 12/12, linux/aarch64 12/12,
  linux/x86_64 12/12** (run for real in Docker), **windows/aarch64 11/11 and windows/x86_64 11/11
  objects linked** with `lld-link` (1 skipped: `extern f64 sqrt` -- there is no C runtime on that
  target). `.github/workflows/ci.yml` puts the float objects into the SAME four artifacts the
  suites use, so the two Windows jobs and the two Linux jobs RUN them.
  **The llvm-mc sweep**, mandatory for a machine that lands in `lib/`: every distinct float
  instruction the two machines emit over the whole corpus, fed back through the assembler --
  **37 (mach-o arm64), 37 (elf aarch64), 181 (elf x86_64), 166 (coff x86_64), 0 mismatches**.
  `sqrt(2.0)` through `extern f64 sqrt(f64)` -- the case that is flatly unreachable without M24,
  because `MTASK_CALL` could not be told an argument was a double -- comes back
  `0x3ff6a09e667f3bcd`, bit for bit what the `sqrt_f64` intrinsic produces and what libm produces.
  `make check` green end to end (RC 0), with `check-float` added: `test` 32/32, `check-lex`
  101/101 (2 skipped), `check-ast` 101/101, `check-asm` 101/101, `check-obj` **32/32 identical to
  the frozen seed**, `check-bundle` (61 files), `bootstrap` at a fixed point, `check-surface`
  32/32, `test-exe` 32/32, `check-limits` 17/17 under 90%, `test-linux` 33/33,
  `test-linux-x86_64` 30/30, `check-float` ok, `check-examples`, `check-lang`, `check-conc`,
  `check-desktop`, `check-docs`, `site` + `check-site`. `scripts/check-inert.sh` between the
  step-B compiler and this one: identical everywhere. All five goldens rewritten once.
  Docs: `docs/guide/96-a-new-primitive.md` § 5 (`<float>`, worked), `docs/build.md`,
  `docs/reference/bundle.md` § `<float>`, `docs/reference/language.md`, `docs/ci.md`.
- M24 step 2 ✔ (`docs/specs/M24.md` § Generality, and the architect's addition (a)):
  **the three modules that prove the principle.** For all three, `git diff src/` is **empty**
  apart from the generated `src/bundle_data.mc`; `stage0/` untouched, 2848/3000 -- `git diff` against the base commit is empty. The gate is
  `make check-wide` (`scripts/check-wide.sh`, 170 lines), inside `make check`.
  * **`lib/i128.mc` (438)** -- a 128-bit integer. `type_new("i128", 16, 16, TK_WIDE)`, and the
    value lives in **ONE depth backed by a 16-byte slot**: a value spanning two depths would
    collide with `gen_binary`'s `depth + 1` and `gen_call`'s `depth + i`, which is the walker's own
    arithmetic and what `MTASK_DEPTH_SPAN` would be for. Carry survives memory residency because
    neither `ldr` nor `str` touches NZCV: `adds`/`adc`, `subs`/`sbc`, `mul`/`umulh`. The compare is
    the one place a 128-bit operation is not "the 64-bit one twice" -- `subs`/`sbcs` leave N and V
    right but Z reflects only the high half, so equality is computed separately and
    `gt = ge && !eq`, `le = lt || eq`. The literal `123i` goes through a **module-private global
    with an `N_BLOB` initializer** (`MTASK_CONST` and `N_INT`'s val are one `i64` each) whose name
    carries `$`, so it cannot collide with anything a program wrote. A 16-byte argument arrives in
    an AAPCS64 **even register pair**. AArch64 only, and it says so.
  * **`lib/f16.mc` (240)** -- half precision as a STORAGE type, on top of `<float>`'s machine:
    four slots (`ldr h`/`str h` and the two `fcvt`s), two intrinsics and two accessors, and
    nothing else. That is only possible because `<float>`'s `fa_is_float` was generalised in the
    same commit from `t == ty_f64 || t == ty_f32` to **`type_kind(t) == TK_FLOAT`** -- which is
    what `kind` is for, and what lets one float machine carry f64, f32 and somebody else's half
    with the same register file, spill, ABI and return position. `f32` became `type_width(t) == 4`
    for the same reason, and `fa_need_ds` refuses arithmetic on a width this machine has no
    instructions for instead of doing it quietly.
    The acceptance case is round-to-nearest-**ties-to-even**: 1 + 2^-11 is exactly halfway between
    the halves `0x3c00` and `0x3c01` and goes to the even one; a round-half-up conversion would
    answer `0x3c01`. `f16 tbl[8]` is **16 bytes of `__bss`**, checked in the object.
    Deviation on record: the spec asks for the software fallback to be exercised "by building
    x86-64 without F16C". `mc`'s x86-64 machine never had F16C -- VEX encoding is `examples/avx`'s
    subject -- so what is delivered is the ARM64 hardware path, with the module stating that on a
    machine without the instruction the identically-named ordinary functions are called instead
    (an intrinsic shadows a function of the same name and nothing else does).
  * **`examples/avx/` (avx.mc 300, main.mc 45, README.md)** -- ONE AVX instruction named by its
    encoding. `type_new("v8f32", 32, 32, TK_OPAQUE)`, `intrinsic("vaddps", 2, ...)` whose two
    operands arrive at depths the core chose, `val_reg`/`dst_reg`/`dst_done` to find them, and the
    module's own **VEX bytes** -- two-byte `C5` when nothing outside the low eight registers is
    named and three-byte `C4` otherwise, which is the rule `llvm-mc` follows and what makes the
    re-assembly an equality: **11 distinct VEX instructions, byte for byte**. Depths 0..5 in
    `ymm0..ymm5`, spilled from 6 into 32-byte slots with `vmovups`, because the frame is 16-byte
    aligned and a 32-byte aligned spill is unreachable. It is NOT executed here: this host has no
    AVX machine and no emulator guaranteed to have it; the README says which VEX forms are
    reachable and which are not, and that is the open problem only a real x86-64 CI leg can close.
  `check-wide` output: i128 and f16 both run and exit 0 with their expected stdout, the default
  compiler refuses both sources, 5 literal globals each an `N_BLOB` of 16 bytes and 16 bytes apart
  in the object, the `adds`/`adc` pair in `--dump-asm`, the even register pair, the 16-byte array,
  `fcvt h16, s16`, the AVX object, and the sweep.
  `make check` green end to end (RC 0) with `check-wide` added; `check-float` still ok on all five
  legs after the kind-based generalisation (12/12, 12/12, 12/12, 11/11, 11/11 and the four sweeps).
  All five goldens rewritten once. Docs: `docs/guide/96-a-new-primitive.md` § 5,
  `docs/reference/bundle.md` § "The generality proofs", `examples/avx/README.md` (new).
- M41 done (`docs/specs/M41.md` + its § Implementation notes, `docs/guide/98-recreating-the-compiler.md`,
  `docs/reference/bundle.md` § The parts of the core, `docs/reference/hooks.md` § 7,
  `docs/reference/machine.md` § 6): **`<mc/core>` becomes composable, and a recreated compiler is
  smaller than `mc` by exactly what it omits.** `stage0/` untouched (2848/3000); everything is in
  `src/`, `lib/`, `scripts/`, `site/gen/` and `docs/`. Four gated commits, `make check` green after
  each one.
  * **Two splits, byte-neutral by construction** (commit 1). `src/macho.mc` became
    `src/objmodel.mc` (321 lines: the three record layouts, `R_*`/`S_*`/`TEXT_FLAGS`, `sec_new`,
    `sym_new`, `sym_set_value`, `reloc_add`, `sym_class`, `sym_order`, `out_name16`, `dump_syms`)
    plus `src/macho.mc` (172: the `MH_*`/`LC_*`/`N_*`/`CPU_*` defines and `macho_write`), and
    `src/main.mc` became `src/cli.mc` + a `main()`. Both are single cuts, so the function
    DEFINITION ORDER of the whole program did not move: with the bundle held at its pre-split
    content, `build/mc1 src/mc.mc` produced `build/mc2.o` byte for byte
    (`c1249acab30099cb52fe4ebdc1c547a0b2fc2e2cbdc2032390c88bf6bdf563a2`). `src/astdump.mc` now
    includes `objmodel.mc` alone -- it never needed a writer.
  * **Five parts, and `src/core.mc` is their sum** (commit 2): `src/core_min.mc` (arena lz objmodel
    lex ast parse gen_resolve gen_walk hooks cli), `core_machines.mc`, `core_writers.mc`,
    `core_build.mc`, `core_bundle.mc`, then `main.mc` -- six `#include` lines, so the full assembly
    IS the parts. `main.mc` (36 lines) calls `host_init`, `mc_machines_init()`,
    `mc_writers_init()`, `mc_bundle_init()`, `mc_build_init()` and hands over to
    `i64 mc_main(i64 argc, uptr argv, uptr envp)`, which is `src/cli.mc`'s and therefore
    `<mc/core_min>`'s. Four `if`s in that file became registrations (`src/hooks.mc` +119):
    `machine_use_if` (the host's machine, when it exists), `backend_default` (the default object
    backend when there is no target registry), `subcommand(name, fn, usage)` (the eighth registry;
    `build`/`limits`/`sysroot` are `<mc/core_build>`'s, each carrying its own usage line, and
    `drv_usage()` is now `subcommand_usage()`), and `on_plan` (M23's `lim_plan`). Plus the
    architect's addition (b): `no machine registered` before `gen_lower`. `src/driver.mc`: a
    `[compiler].core` starting with `<` is emitted verbatim, which is how a project asks for a part.
  * **Removal and one override** (commit 3), all inert with nothing declared: `type_disable(ty)`
    (a bitmask in `src/ast.mc`, one test at the head of `type_of_token` --
    `u32: removed by this compiler`, at the token; it removes the WORD from the surface, not the
    type from the model), `intrinsic_disable(name)` (a fixed 32-entry table, one test at the head
    of `res_call`, so core and taught intrinsics are refused the same way), and
    `type_set_width(ty, w)`, which accepts `TY_UPTR` alone. M40 § 1b C1/C3/C4/C5:
    `type_width(TY_UPTR)` reads `ty_uptr_w`, `slot_new`'s granule is `walk_word()`, the three
    roundings to 16 are `align_up(v, walk_align())` and a string in a `uptr[]` initializer writes
    `w` zero bytes with an `R_UNSIGNED` of length log2(w).
  * **The gate** (commit 4): `scripts/check-parts.sh` (`make check-parts`, inside `make check`)
    proves five things -- the two spellings `cmp` equal (849856 bytes); each part compiles on
    `<mc/core_min>` ALONE; the measured table; the two refusals; the width. That per-part case is
    not in the spec's acceptance list and it earned its keep at once: **four names had to move**
    for the parts to be parts -- `tm_cat` and `tm_num_str` (`toml.mc` -> `arena.mc`), `MODE_755`
    (`backend_exe.mc` -> `arena.mc`) and `R_X86_PC32`/`R_X86_PLT32` (`machine_x86_64.mc` ->
    `objmodel.mc`). `site/gen/util.mc` lost its own `MODE_755` for the same reason.
  **Measured** (`sh scripts/check-parts.sh`, and the cumulative spellings behind
  `docs/guide/98-recreating-the-compiler.md` § 3):

  | spelling | `__text` | `__cstring` | `__data` | on disk |
  |---|---|---|---|---|
  | `<mc/core_min>` + probe machine + null writer | 147 224 | 7 034 | 2 496 | **219 417** |
  | + `<mc/core_machines>` | 183 664 | 7 795 | 6 224 | 260 543 |
  | + `<mc/core_writers>` | 232 712 | 8 683 | 6 640 | 315 934 |
  | + `<mc/core_build>` | 289 484 | 15 093 | 6 936 | 395 820 |
  | + `<mc/core_bundle>` | 293 180 | 15 454 | 374 800 | 760 013 |
  | `mc` itself | 292 968 | 15 443 | 374 800 | **759 875** |

  A compiler with one machine and one writer of its own is **29% of `mc`** -- of the 540 KB it does
  not pay, 364 KB is the bundle blob and 146 KB is code.
  Probes: `lib/user_core_min.mc` (a two-slot probe machine and a null writer), `user_nold64.mc`,
  `user_nou32.mc`, `user_uptr2.mc`, `user_badwidth.mc` -- files in `lib/`, deliberately NOT
  bundled (they are fixtures; bundling them would move the blob and the five goldens for something
  no compiler includes).
  **Inertness**, in M17 step A's protocol: `scripts/check-inert.sh` between the compiler before
  each step and the one after -- 33 objects identical (`tests/*.mc` and `src/mc.mc`) and the five
  taught examples (`api`, `lang`, `conc`, `desktop`, `kernel`) identical through the compiler each
  side builds. `examples/kernel` was the one Acceptance 3 named and the script did not run: it is
  untouched and still includes `<mc/core>`, and it is now asserted like the other four -- the
  widest of the five, since its module registers a machine, a backend and an `os`/`arch` pair the
  running compiler does not have, and its artefact is a flat image where one byte shows.
  — `make check` green end to end (RC 0, 0 FAIL): `test` 32/32, `check-lex` 120/120 (2 skipped),
  `check-ast` 120/120, `check-bundle` (75 files, raw 776601 -> lz 364543, blob 365449 B),
  `check-asm` 120/120, `check-obj` 32/32 against the frozen seed, `bootstrap` at a fixed point
  (`cmp mc2.o mc3.o`; the `--dump-asm` diff between `mc1` and `mc2` empty), `check-surface` 32/32,
  `test-exe` 32/32, `check-mc` 7/7, `check-standalone`, **`check-parts`**, `check-toml` 10/10,
  `check-build` 21/21, `check-sysroots`, `check-stubs` 9/9, `check-limits` 17/17 under 90%,
  `check-minimal`, `test-linux` 33/33, `test-linux-x86_64` 30/30, `test-windows`,
  `test-windows-x86_64`, `check-examples`, `check-lang`, `check-conc`, `check-desktop`,
  `check-float`, `check-wide`, `check-kernel`, `check-docs` (178 symbols, 19 flags, 17 TOML keys,
  10 directives, 47 samples, 243 links), `site` (80 pages) + `check-site`. `make check-linux-host`
  green on both architectures. The five goldens were rewritten once **per commit** (four times, not
  once): every commit that touches `src/` regenerates `src/bundle_data.mc`, which is part of
  `src/mc.mc`, so `build/mc2.o` moves in each of them -- recorded in `docs/specs/M41.md`
  § Implementation notes 9, each rewrite after an empty `--dump-asm` diff and a passing
  `cmp build/mc2.o build/mc3.o`.
- M41.5 done (`docs/specs/M41.5.md`, `docs/surface.md` § M41.5, `docs/reference/hooks.md` § 3):
  **a module can participate in a function's parameter list.** `stage0/` untouched (2848/3000;
  `git diff main -- stage0/` is empty). `parse_params` was the one position on the parse path with
  no hook at all -- `syntax` fires on a declaration's FIRST token and `word_add` refuses the core
  type words, so nothing keyed by a word can ever be reached from `i64`. The consumer (the `ngen`
  port of teko, written against `docs/`) is blocked on two things that are parameters and nothing
  else: `i64 f(i64 x, i64 y = 10)` and `i64 g(params i64 xs)`. The owner chose the HOOK over the
  features: neither default parameters nor variadics are in the language.
  * **`syntax_param(&f)`** (`src/hooks.mc` +52/-0, 19 code lines): `i64 f()` -> the index of an
    `N_PARAM`, or **0 = "the core handles this one"**. Growable table (`grow`), arena tag
    `T_SYNPARAM` inserted after `T_ONJUMP` (`src/arena.mc` +16/-13 -- one new `#define`, one name,
    one seed, and the twelve renumbered tags; `T_COUNT` 38 -> 39, and `mc limits` gains a
    `syntax_param` row). Handlers run in registration order, the first non-zero answer wins, and
    `nsynp == 0` short-circuits the whole branch the way `nonstmt`/`nonjump`/`nonlit` do.
    Consulted at the HEAD of `parse_params`'s loop, right after the `K_RPAR` test and **before
    `type_of_token`** -- which is the entire point: a parameter opening with a taught word has to
    get there before the core demands a type, and a parameter with a trailer has to be read WHOLE
    (`p_type()`, `p_ident()`, then `p_accept(K_ASSIGN)` + `parse_expr(0)`) by whoever records the
    trailer. Named `syntax_param` and not `on_param`: the `on_*` family runs after a node exists
    and cannot consume tokens.
    Two guards, both at the parameter's own position: `syntax_param handler consumed no tokens:
    <word>` (the `stmt_syntax` precedent, cursor AND token start compared) and `syntax_param
    handler did not return a parameter` (index out of range included) -- that node goes straight
    into a list `gen_lower` walks by `nd_type`/`nd_name`, so anything else is a wrong frame layout
    later rather than a diagnostic here. `MAXPARAMS` and `at most 12 parameters` still apply to
    what the handler returns.
  * **`p_decl_name()`** (`src/parse.mc` +64/-11, 33 code lines, with `param_syntax`): the name of
    the top-level declaration being parsed, 0 outside one. Set by `parse_top` **and by
    `parse_extern`** (a deviation from the design's literal text, on record in the spec § 6: an
    `extern` is a top-level declaration and it calls `parse_params`) the moment the name is read,
    cleared by `top_add`. The storage is called `cur_decl` because `decl_name(uptr msg)` is already
    a function in `parse.mc`.
  * Proofs, all in `lib/user_syntax_demo.mc` (707 -> 850) and `scripts/check-surface.sh`:
    (a) `i64 f(i64 x, i64 y = 10)` with the module recording the default and completing `f(1)`
    from a `pass()` with `decl_find`/`decl_nparams` -- exit 42; (b) `i64 sum2(params i64 xs)`,
    the taught word lowering to `PARAM type=uptr name=xs`, exit 42, and the default compiler
    refusing both sources (`expected ) in the parameter list`, `type expected in parameter`);
    (c) `p_decl_name()` with teeth -- `f` and `g` differ ONLY in the default at the same parameter
    index, and the tree shows `INT val=10` in one call and `INT val=30` in the other, which a
    module ignoring `p_decl_name()` could not produce; (d) `tests/err/071-param-noadvance.mc` and
    `072-param-nonparam.mc` with their exact messages and the two fixture handlers `sd_pnop`/
    `sd_pbad` (the `sd_nop`/`sd_nil` shape); (e) inertness -- `lib/user_param_nop.mc` +
    `lib/mc_param_nop.mc`, a module whose ONLY registration is `syntax_param` and whose handler
    answers 0 for every parameter of every function: `--dump-ast` and objects byte-identical over
    the whole `tests/` corpus.
  * `examples/lang/README.md` said "At most 8 parameters"; `MAXPARAMS` has been 12 since M38 and
    the example has no ceiling of its own (`lang_expr.mc`, `lang_stmt.mc` test against
    `MAXPARAMS`). Corrected to 12 slots / at most 10 arguments besides `self`.
  -- core cost: **132 added lines, 66 of them neither comment nor blank** (`parse.mc` +64/33,
  `hooks.mc` +52/19, `arena.mc` +16/14, twelve of those last being the renumbered tags).
  `make bundle` re-run BEFORE bootstrapping (`tools/bundle.list` gained `mc_param_nop` and
  `user_param_nop`): **77 files, raw 789698 -> LZ 369888, blob 370822 B**, `<mc/bundle_data>` one
  `#embed` node plus a 308-value index. `make check` green end to end (RC 0, zero FAIL):
  `budget` 2848/3000, `test` 32/32, `check-lex` 122/122 (2 skipped), `check-ast` 122/122,
  `check-asm` 122/122, `check-obj` **32/32 identical to the frozen seed**, `check-bundle`
  (reproducible + fresh, lz round trip 101 cases), `bootstrap` at a fixed point (`mc2.o == mc3.o`,
  857240 bytes; the `--dump-asm` diff between `mc1` and `mc2` is **empty**), `check-surface` 32/32
  + every M41.5 case, `test-exe` 32/32, `check-mc` 7/7, `check-standalone`, `check-parts`,
  `check-toml` 10/10, `check-build` 21/21, `check-stubs` 9/9, `check-limits` 17/17 under 90%,
  `check-minimal`, `test-linux` 33/33, `test-linux-x86_64` 30/30, `test-windows` 35/35 +
  `test-windows-x86_64` 33/33 cross-compiled, `check-examples`, `check-lang` 14, `check-conc` 21,
  `check-desktop`, `check-float`, `check-wide`, `check-kernel` (QEMU 11.0.1, exit 0),
  `check-docs` (**180 symbols**, 19 flags, 17 TOML keys, 10 directives, 47 samples, 243 links),
  `site` 81 pages + `check-site` (0 link problems).
  `scripts/check-inert.sh build/mc1.pre build/mc1` (pre = a `mc1` built from 752d385): **33
  objects identical** (`tests/*.mc` and `src/mc.mc`) plus byte-identical artefacts for
  `examples/api`, `examples/lang`, `examples/conc`, `examples/desktop` and `examples/kernel`
  through the taught compiler each of them builds.
  The five goldens rewritten **once**, only after the empty `--dump-asm` diff and
  `cmp build/mc2.o build/mc3.o`: `mc2.sha256` `779f272d...31f9e` ->
  `17adb08037b7afb30e31c81ed252a6bb6555ffc46831df54c7d5c0969f4d24ce`; the Linux pair deleted and
  re-recorded by `make check-linux-host` (Docker, both arches, each after its own fixed point
  `mc2l.o == mc3l.o` and with the cross proof green) --
  `mc2-linux-arm64.sha256` `7fefed77dafb84ad04bdeee737cdfa5bc1df70112a685a1e1e52eac265b5bdff`,
  `mc2-linux-x86_64.sha256` `912613369fedc29bd8c58c42ad973b1da08c0e9c06a828e4a6bed7d76689c05d`;
  the Windows pair cross-computed per `tests/golden/README.md` --
  `mc2-windows-arm64.sha256` `2aed564c9a9f37c891adb124b01c49d5a5f28abf02d3c69a937faae4142d32ce`
  (872667 B), `mc2-windows-x86_64.sha256`
  `a41a3c727bf13094f3a1907ce7592704e032aa12244339b964afccba4dec4784` (891291 B).
- M41.5, second follow-up (`docs/specs/M41.5.md` §§ 8-11, `docs/reference/hooks.md` §
  `syntax_infix`, `docs/surface.md` § "M41.5 -- and a core operator"): **a module may teach a CORE
  operator.** `stage0/` untouched (2848/3000). The defect the same `ngen` consumer exposed:
  `syntax_infix("+", 9, &h)` was ACCEPTED -- `word_add` refuses only `K_U8..K_EXTERN`, and `+` is
  `K_ADD`, punctuation outside that range -- and then silently UNDONE, because `parse_unit()` ran
  `ops_init()` as its first statement, after `user_init()`, and `infix_set`'s last line is
  `set_ie_fn(e, 0)` (M21's rule that a `#infix` drops the handler). Reproduced with a handler whose
  body is an unconditional `die()`: before, the compiler built fine and `i64 main() { return 1 + 2; }`
  compiled and exited **3**; after, `mc: probe: the + handler fired`, exit 1.
  * **The owner's decision was permit, not refuse**, consistent with M24 already letting a module
    replace the machine slot that lowers `+` (`lib/user_badmach.mc`).
  * **The fix is five code lines**: `i64 ops_ready = 0;` plus a two-line guard at the top of
    `ops_init()` (`src/parse.mc`) and one `ops_init();` call at the head of `syntax_infix`
    (`src/hooks.mc`) -- 30 added lines in `src/`, **4 of them neither comment nor blank**.
    Placement: NOT `src/cli.mc` (another branch is editing it heavily, and "before `user_init()`"
    is three call sites, not one -- `cli.mc`, `driver.mc`, `limits.mc`, with `astdump.mc` parsing
    without one at all); the table is an initialisation, not a phase, so it is built ON FIRST USE
    and the first consumer triggers it. The guard also removes a latent bug: `ops_init` used to
    re-fill the table on every `parse_unit`, which would have undone a `#infix` and every
    `syntax_infix` if any process ever parsed two units.
  * **The precedence question, decided and tested: the module's `prec` wins.** `syntax_infix`
    re-declares the entry exactly as `#infix` does, so a module that wants the core's grouping
    repeats the core's number (`docs/reference/language.md` § 3). M21's rule is untouched (a
    `#infix "+"` in the SOURCE still drops the handler) and the duplicate refusal stays -- the
    FIRST registration on a core operator is allowed, because a core operator carries no handler
    to override.
  * Proofs, `lib/user_coreop.mc` + `lib/mc_coreop.mc` (the `user_badmach`/`mc_badmach` shape) and
    `scripts/check-surface.sh` (+121/-20): the taught `+` lowers `a + b` to a call `plus(a, b)`
    the PROGRAM provides -- `v(50) + v(8)` is **58** with `build/mc1` and **42** with
    `build/mc-coreop`, and `--dump-ast` holds `CALL type=i64 name=plus` with no `op=+`; `*` taught
    at **3** instead of the core's 10 makes `55 - 6 * 7` parse as `star(55 - 6, 7)` = **42**
    against **13** for the stock compiler; `--dump-rules` prints `infix + prec 9 left handler`,
    `infix * prec 3 left handler`, `infix - prec 9 left`; a `#infix "+" 9 left $1 - $2` in a source
    that defines no `plus` compiles and exits 42 (the handler would have died with
    `unknown function: plus`); and `lib/user_dupcoreop.mc` gives `mc: operator already taught: +`
    at `user_init` time -- the old dupop block became a `dup_case` helper run for `.+` and for `+`.
    No `tests/err/` case was added: the change introduces no new message, and
    `066-infix-drops-handler.mc` passes unchanged with its exact text. The three new `lib/` files
    are NOT in `tools/bundle.list`, following the M41 precedent for check-script-only modules
    (`user_badwidth`, `user_uptr2`, `user_nou32`, `user_nold64`, `user_core_min`).
  -- inertness: `scripts/check-inert.sh build/mc1.pre build/mc1` (pre = a `mc1` built from the
  branch's HEAD before the edit) -- **33 objects identical** (`tests/*.mc` and `src/mc.mc`) plus
  byte-identical artefacts for `examples/api`, `examples/lang`, `examples/conc`,
  `examples/desktop` and `examples/kernel`. `make bundle` re-run BEFORE bootstrapping (77 files,
  raw 791608 -> LZ 370822, blob 371756 B). `make check` green end to end (**RC 0, zero FAIL**):
  `test` 32/32, `check-lex` 125/125 (2 skipped), `check-ast` 125/125, `check-asm` 125/125,
  `check-obj` **32/32 identical to the frozen seed**, `check-bundle` (lz round trip 101 cases),
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, 858304 bytes; the `--dump-asm` diff between
  `mc1` and `mc2` is **empty**), `check-surface` 32/32 + the five new core-operator cases + inert,
  `test-exe` 32/32, `check-mc` 7/7, `check-standalone`, `check-parts`, `check-toml` 10/10,
  `check-build` 21/21, `check-stubs` 9/9, `check-limits` 17/17 under 90%, `check-minimal`,
  `test-linux` 33/33, `test-linux-x86_64` 30/30, `test-windows` 35/35 + `test-windows-x86_64`
  33/33 cross-compiled, `check-examples`, `check-lang` 14, `check-conc` 21, `check-desktop`,
  `check-float`, `check-wide`, `check-kernel` (QEMU 11.0.1, exit 0), `check-docs` (180 symbols,
  19 flags, 17 TOML keys, 10 directives, 47 samples, 244 links), `site` 81 pages + `check-site`
  (0 link problems). The five goldens rewritten once, only after the empty `--dump-asm` diff and
  `cmp build/mc2.o build/mc3.o`: `mc2.sha256` `17adb080...4d24ce` ->
  `0883ef0cedc2f388fa6937452e62d9c0deecbfa81e52b91b64d16526b930bae1`; the Linux pair deleted and
  re-recorded by `make check-linux-host` -- `mc2-linux-arm64.sha256`
  `58fef265ba539e386c114f427cc60fffb355b8fa390d38e1a89f85e73609ff2b`,
  `mc2-linux-x86_64.sha256`
  `6361d20d6e08e9b57e142dbadfed08e608a43147de324c563c45c2b944132eff` (each after its own
  `mc2l.o == mc3l.o` and with the cross proof against the macOS `build/mc2.o` green); the Windows pair cross-computed per
  `tests/golden/README.md` -- `mc2-windows-arm64.sha256`
  `2ccfc7b850fcd7c17e88ec1b152aaaa399cc12ddc4c53445caf057fd9ef88ebe` (873735 B),
  `mc2-windows-x86_64.sha256`
  `bfe9e7540023050a1af5684f787f430f5e5faba36ce374a74f74f9b935d45477` (892351 B).
- Post-M41.5 batch (review, `docs/specs/M41.5.md` § 12): the three findings the PR review raised.
  The whole code change is `src/parse.mc` **+45/-2, 19 of the added lines neither comment nor
  blank**; `stage0/` untouched (2848/3000, `git diff origin/main -- stage0/` empty). Rebased onto
  `origin/main` 611671a first (PR #15 + #14): the only conflicts were generated or aggregated
  files -- `src/bundle_data.mc` and the five goldens (regenerated/re-recorded below),
  `examples/lang/README.md`, where main had made the same "8 parameters -> 12" correction, so this
  branch's commit `f40fbab` became empty and was dropped. `CLAUDE.md`, `docs/surface.md`,
  `docs/reference/hooks.md` and `docs/reference/diagnostics.md` auto-merged with both sides' text
  (main added no § State entry of its own in those two PRs).
  1. **A `syntax_param` handler that consumed tokens and then returned 0 was believed** (HIGH).
     `param_syntax()` ran the "consumed no tokens" guard only on the non-zero answer, so 0 --
     "the core handles this one" -- was taken at face value with the cursor already moved.
     Reproduced with a handler that reads `peat i64 x` and the comma after it and answers 0:
     `i64 f(peat i64 x, i64 y, i64 z)` came out of `--dump-ast` as a **two-parameter** `f(y, z)`,
     compiled clean, linked, and returned 42 for `f(4, 2)` -- a three-parameter declaration
     running with the wrong arity, no diagnostic anywhere. The guard now compares the cursor AND
     the token start on **both** answers: `syntax_param handler consumed tokens and returned 0:
     <word>`, at the parameter's own position, with the word copied from the token the handler was
     GIVEN (`xstrdup(t0, l0)`) rather than from `cur_name()`, which by then names something else.
     **`syntax_lit` had the same latent shape** (M24) and is fixed in the same commit: a handler
     that moved the cursor with `p_take_lit` and then declined left `parse_primary` building its
     `N_INT` out of a token whose span no longer covers what was read -- `return 7q;` compiled
     clean and exited **7**, the `q` swallowed. Now `syntax_lit handler consumed tokens and
     returned 0: <literal>`. Both checks are at the END of the handler chain, not per handler:
     `run_syntax_param`/`run_syntax_lit` live in `src/hooks.mc`, which is included before
     `src/parse.mc` and cannot see `cp` or `cur` -- so the two broken fixtures are registered LAST
     in `lib/user_syntax_demo.mc` (`sd_peat`, `sd_leat`), and their headers say why.
  2. **`p_decl_name()` was blind inside a handler that owns the declaration** (MEDIUM).
     `cur_decl` was set only by `parse_top`/`parse_extern` -- the two places the CORE reads a
     name -- so a `syntax` handler that parses a container and declares each member with the
     public `parse_params()` + `parse_function()` got the enclosing declaration's name, or 0, for
     every member, while `docs/reference/hooks.md` recommends keying `syntax_param` bookkeeping by
     exactly that value. Two changes: `parse_function(ty, name, params)` sets `cur_decl = name`
     for the duration of the body and **restores** the previous value (a module may nest a
     declaration through `p_push_source`), and `void p_set_decl_name(uptr name)` joins the public
     API for a handler that reads the member's name itself. Proof in the demo:
     `capsule Name { ... }` (named `capsule` and not `box` because `lib/syntax_demo_test.mc`
     already declares a global `box`, and a `syntax` registration reserves its word program-wide)
     declares two members carrying a default at the **same** parameter index with different
     values; `--dump-ast` shows `INT val=10` in one call and `INT val=30` in the other and the
     program exits 42. With the `p_set_decl_name` line commented out, the same source dies with
     the module's own `a default parameter needs a named declaration`.
  3. **The documented message text was missing its detail** (LOW). All four
     `consumed no tokens` messages are `err_at2` calls and print `: <word>`;
     `docs/reference/diagnostics.md` wrote all four without it. The four rows -- plus
     `syntax_expr handler produced no expression` and `syntax_infix handler produced no
     expression`, `err_at2` too -- now carry the suffix, so the table matches the runtime.
  New: `tests/err/073-param-consumed-zero.mc` (the arity repro itself: the source that used to
  compile clean and exit 42) and `tests/err/074-lit-consumed-zero.mc`, each asserted with its
  exact message in `scripts/check-surface.sh`, which also gained the `capsule` case and its two
  `--dump-ast` assertions and now refuses all three `syntax_param` sources with the default
  compiler. `lib/user_syntax_demo.mc` +79/-2: `sd_peat`, `sd_leat`, `sd_capsule`.
  -- `make bundle` re-run BEFORE bootstrapping (77 files, raw 802395 -> LZ 375334, blob 376268 B).
  `make check` green end to end (RC 0, zero FAIL): `budget` 2848/3000, `test` 32/32, `check-lex`
  125/125 (2 skipped), `check-ast` 125/125, `check-bundle` (reproducible + fresh, lz round trip
  101 cases), `check-asm` 125/125, `check-obj` **32/32 identical to the frozen seed**, `bootstrap`
  at a fixed point (`mc2.o == mc3.o`, 864584 bytes; the `--dump-asm` diff between `mc1` and `mc2`
  is **empty**), `check-surface` 32/32 + 109 ok lines (every M21/M24/M31/M41.5 case plus the four
  new ones) + inert, `test-exe` 32/32, `check-mc` 7/7, `check-standalone`, `check-toml` 10/10,
  `check-build` 29/29, `check-stubs` 9/9, `check-limits` 17/17 under 90%, `check-minimal`,
  `test-linux` 33/33, `test-linux-x86_64` 30/30, `test-windows` 35/35 + `test-windows-x86_64`
  33/33 objects cross-compiled, `check-examples`, `check-lang`, `check-conc`, `check-desktop`,
  `check-float`, `check-wide`, `check-kernel` (QEMU 11.0.1, `build/kernel.bin` 3304 B),
  `check-docs` (181 symbols, 19 flags, 17 TOML keys, 10 directives, 47 samples, 247 links),
  `site` 81 pages + `check-site` (0 link problems). `scripts/check-inert.sh` between a `build/mc1`
  built from the rebased HEAD before the edit and the one after: **33 objects identical**
  (`tests/*.mc` + `src/mc.mc`) and the five taught examples identical too
  (`examples/api`, `lang`, `conc`, `desktop`, `kernel`).
  `make check-linux-host` green for both architectures (RC 0), each after its own
  `mc2l.o == mc3l.o` and with the cross proof (`mc2l --backend=macho src/mc.mc` byte for byte the
  macOS `build/mc2.o`) green on both.
  The five goldens rewritten **once**, each only after its own criterion: `mc2.sha256`
  `0883ef0c...30bae1` -> `6766ee56750f9a8f5337f8d901d4196e114477c0552812cc1d34694ab574a5a4`
  (after the empty `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`); the Linux pair deleted
  and re-recorded by `make check-linux-host` -- `mc2-linux-arm64.sha256`
  `eda566cd2559486324a5199e80e80f9770002ba556e4e657f11ab2ece07e5af9`,
  `mc2-linux-x86_64.sha256`
  `a95ec2516cffe9059456a3a1d0863ba91b5dda6efa435bd06016804b4023ea59`; the Windows pair
  cross-computed per `tests/golden/README.md` -- `mc2-windows-arm64.sha256`
  `96841b9071b542a8f7b5bd83106b8f7209a18dfc3fccbbf56718c23a665cf2d9` (880099 B),
  `mc2-windows-x86_64.sha256`
  `0163654105ea20cf13faf88203a7fecefa7ff41664f20ed5f0d5b8737fdd5e73` (898911 B), both also
  produced byte for byte by `build/mc2`.
- M42 done (`docs/specs/M42.md`, incl. its new § Implementation notes): **`elf-exe` and
  `elf-exe-x86_64` -- a dynamic ELF64 `ET_EXEC` writer, so `--exe` works on Linux and a Linux
  `mc build` needs no `[linker]` and no sysroot.** `stage0/` untouched (2848/3000).
  `src/backend_elf_exe.mc` (956 lines, ~500 of them code) is to `src/backend_elf.mc` what
  `src/backend_exe.mc` is to `src/macho.mc`: the same `gen_lower` + `gen_encode_all` in front,
  the same sections/symbols/relocations behind, and then instead of handing the relocations to
  `ld.lld` it lays out the segments, resolves everything in place and writes the loader's tables.
  `ET_EXEC` at `0x400000` (not PIE: no `R_*_RELATIVE`, and no ASLR -- documented, priced as a
  follow-up); `DT_BIND_NOW` + `DF_1_NOW` (no lazy binding, no PLT0, no resolver); `PT_PHDR`,
  `PT_INTERP`, one `PT_LOAD` per Mach-O segment name (the grouping `backend_exe.mc` already uses,
  so a `#section` with its own segment gets its own load), `PT_DYNAMIC`, `PT_GNU_STACK` **RW and
  never X**; `p_align` 64 KiB on aarch64 and 4 KiB on x86-64 (§ Risks 3). One PLT stub
  (`adrp x16 / ldr x17 / br x17 / nop`, or `jmp qword ptr [rip+got] / int3 / int3`) and exactly
  one 8-byte GOT slot per import; a real SysV `DT_HASH` (`nbucket = nchain = 1 + imports`).
  **`JUMP_SLOT` is the only dynamic relocation kind in the file**: a reference to an import -- a
  call, and equally `&write` in an expression (the global-initializer form the spec first cited,
  `uptr p[] = { &write }`, is not syntax this language has: it is `initializer must be constant`)
  -- resolves in place to its stub, which is the canonical address a
  linker gives an imported function in a non-PIE executable, so no `GLOB_DAT` is needed (mc
  imports functions, never data). Relocations are patched with `backend_exe.mc`'s four patchers:
  they encode instructions, and an instruction has no file format.
  **The static case is the degenerate case, decided by COUNTING imports and never by a flag**:
  with none there is no `PT_INTERP`, no `PT_DYNAMIC`, no `.dynsym`/`.dynstr`/`.hash`/`.rela.plt`,
  no PLT and no GOT.
  Deviations, all in § Implementation notes: **section headers ARE written** (plus a full
  `.symtab`/`.strtab` with final addresses -- no loader reads them, but `llvm-readelf`, `llvm-nm`,
  `llvm-objdump -d` and a debugger do); the **entry point** is the program's own `_start` when it
  has one (`<sys_linux>`) and otherwise a synthesized `.text.mcstart` -- 7 AArch64 instructions
  (28 B) or 34 x86-64 bytes -- that reads argc/argv/envp off the entry stack, calls `main` and
  exits by **raw `exit_group` syscall**, so it costs no import; both segments are page-padded in
  the file so `p_offset == p_vaddr (mod p_align)` holds by construction; `DT_NEEDED` is emitted
  for the default library even when every import is claimed by a `#dylib`, as `macho-exe` always
  emits `LC_LOAD_DYLIB` for libSystem.
  **Two TOML keys, not one** (decision 6 asked for the interpreter path; glibc needs a second
  name): `[target].interp` and `[target].libc`, musl by default
  (`/lib/ld-musl-<arch>.so.1`, `libc.so`), glibc one config line away
  (`/lib/ld-linux-aarch64.so.1` or `/lib64/ld-linux-x86-64.so.2`, `libc.so.6`). `src/driver.mc`
  reads them into two globals declared in `src/objmodel.mc` and NOT in the writer, because
  `<mc/core_build>` may be assembled without `<mc/core_writers>` and must still compile
  (`scripts/check-parts.sh` § 1b).
  One more core edit, forced: `lim_seeds[T_BACKENDS]` 8 -> 16 in `src/arena.mc`, because that
  table is full before the pre-scan can size it (every built-in is registered from `main()`) and
  `<mc/core_writers>` now registers eight, so `examples/kernel` reported `grew`. Capacity only.
  `mc limits src/mc.mc` says `backends 0 16 8 0 ok`.
  **`--exe` is NOT this milestone's edit any more**: the post-M41 review batch (#15) already made
  `src/cli.mc` resolve the host pair through the `target()` registry, after `user_init()`, and
  refuse a 0 slot; M42's own first draft resolved it during argv parsing (before `user_init()`,
  so a module's registration was silently ignored) and was dropped in the rebase. What M42 changes
  is only which slots are non-zero -- the two Linux ones -- and `tests/proj/noexe.mc`, which
  re-registers the host pair with 0 in the exe slot, still passes.
  Gates: `scripts/test-linux.sh` gained an **`--exe` mode** beside the object+link mode -- same
  corpus, same Docker oracle, both architectures, both split halves (`--build-only` writes
  executables, `--run-only` just runs them) -- which **moves `~/.mc/sysroots/linux-*` and
  `build/sysroot/linux-*` aside for the duration and puts them back**, so the no-sysroot claim is
  proved by the script and not by the report. It adds four assertions the object mode cannot make:
  `013-putnum` shows `PT_INTERP` + `DT_NEEDED` + a `JUMP_SLOT` and `001-return42` shows none of
  the three, `GNU_STACK` is RW and never E on every binary, and two builds are `cmp`-identical.
  `tests/linux/071-errno-malloc.mc` goes past the § 0 probe: a failing libc call whose `errno` it
  reads (TLS) plus `malloc` and stdio, run under **musl (`alpine:3` 3.24.1) AND glibc
  (`ubuntu:latest` = Ubuntu 26.04 LTS, glibc 2.43) on both architectures -- `errno=2 malloc ok`,
  exit 0, four for four**. It uses `fopen` and not `open`, but NOT for the reason first written
  here: the claim that glibc's failing `open` hands back `0x00000000ffffffff` was **re-measured on
  all four cells and does not reproduce** -- every one of them returns `0xffffffffffffffff` and
  `fd >= 0` is false. What survives is that both ABIs leave the bits above a 32-bit return value
  unspecified and mc has no narrow return types, so the hazard is latent; `fopen` is kept because
  it returns a full pointer and drags stdio in, which is more start-up state to prove.
  `scripts/test-exe.sh` is host-aware (`codesign` only on macOS, `// skip-<host>` honoured), so
  **`make check` on a Linux host runs `test-exe`** -- the whole suite through `mc --exe`, natively.
  `scripts/check-build.sh` lost the `linux requires [linker]` diagnostic (it is gone for Linux and
  still there for Windows) and gained `tests/proj/linux-exe.toml` / `linux-exe-x86.toml`: both
  architectures asserted down to `e_type`/`e_machine` with `od`, plus determinism -- **31/31**
  with the post-M41 cases.
  `Makefile`: `test-linux-exe` and `test-linux-x86_64-exe` inside `make check`, guarded on Docker
  alone. `.github/workflows/ci.yml`: the macOS job cross-compiles both `--exe` suites into the new
  `linux-arm64-exes` / `linux-x86_64-exes` artifacts and each Linux leg runs them with nothing
  linked.
  **Both libcs, everywhere** (post-merge review): `scripts/test-linux.sh` gained `--libc musl`
  (default, `alpine:3`) and `--libc glibc` (`ubuntu:latest`), which writes `[target].interp` /
  `[target].libc` into the generated config and picks the container; `native` now also asks
  whether the host HAS that loader, so a glibc runner falls back to Docker for the musl set
  instead of failing on `no such file or directory`. Without this the new CI legs -- which run
  `--exe --run-only` NATIVELY on the Ubuntu runners -- would have failed on every binary:
  reproduced under `ubuntu:latest`, `exec ...: no such file or directory`, exit 255. Both
  Makefile targets run both libcs and the CI legs run the glibc set natively and the musl set in
  `alpine:3`.
  **`mc --exe` still writes musl** and cannot be told otherwise: the two names are TOML keys and
  the writer's default is a constant, because a probe of the machine would make one source produce
  different bytes on two hosts (`docs/determinism.md`). That is written down in
  `docs/specs/M42.md` § Implementation notes 12, in `docs/reference/cli.md` and in
  `docs/guide/90-linux-host.md` § 3, and the three scripts that need a runnable binary on the host
  --  `scripts/test-exe.sh`, `scripts/build-exe.sh` and `scripts/bootstrap-linux.sh` -- take the
  `mc build` road when the loader on the disk says the host is glibc, and say which road they
  took. Measured: `test-exe.sh` is **31/31 via `mc build`** inside `ubuntu:latest` and **31/31 via
  `--exe`** inside `alpine:3`, with the same glibc- and musl-hosted compilers.
  **The self-hosting proof**: `src/mc.linux-aarch64.toml` and `src/mc.linux-x86_64.toml` DROPPED
  their `[linker]` and `[sysroot]`, and `make mc-linux` / `mc-linux-x86_64` no longer depend on
  `sysroot-linux` -- cross-building `mc` for a Linux host from macOS now needs nothing installed.
  `make check-linux-host` now runs **two cells per architecture, one per libc**, and is green for
  all four (RC 0). The musl cell is what it was -- `make check SEED=...` inside `alpine:3` plus
  the cross proof. The glibc cell is new (post-merge review, the owner's "dynamic support even if
  only in tests" applied to the COMPILER): `src/mc.linux-{aarch64,x86_64}-gnu.toml` cross-build
  `mc` for a glibc host from macOS -- the musl config plus `interp` and `libc`, nothing else --
  and inside `ubuntu:latest` **with nothing installed in the container** (no `make`, no `lld`, no
  `musl-dev`) `scripts/bootstrap-linux.sh --libc glibc` takes it to its own fixed point, runs the
  whole suite through `mc --exe`, and does the same cross proof.
  `scripts/bootstrap-linux.sh` gained `--exe` and `--libc` for that: with them every stage is
  written by the previous compiler through `mc build` and there is no linker in the chain at all.
  Its default is unchanged -- `ld.lld` plus the musl sysroot -- because the SEED may be a
  published release older than M42.
  **The golden is the same file on both roads**: an ELF `ET_REL` records no interpreter, so the
  musl chain and the glibc chain must write the same `mc2l.o`, and they do.
  Windows is untouched and still refuses `--exe`; this milestone filled two of the four zero slots.
  -- `stage0/` untouched, 2848/3000 (`git diff origin/main -- stage0/` is empty); `make bundle`
  re-run before bootstrapping (78 files, raw 840956 -> LZ 391459, blob 392412 B;
  `tools/bundle.list` gained `mc/backend_elf_exe`).
  `make check` RC 0, zero FAIL: `test` 32/32, `check-lex`/`check-ast`/`check-asm` 126/126
  (2 skipped), `check-obj` **32/32 identical to the frozen seed**, `bootstrap` at a fixed point
  (`mc2.o == mc3.o`, 917008 B; the `--dump-asm` diff between `mc1` and `mc2` is **empty**),
  `check-surface` 32/32 + inert, `test-exe` 32/32 via `--exe`, `check-mc` 7/7,
  `check-standalone`, `check-parts`, `check-toml` 10/10, `check-build` **31/31**, `check-stubs`
  9/9, `check-sysroots`, `check-limits` 17/17 under 90%, `check-minimal`,
  `test-linux` 34/34 + **`test-linux-exe` 37/37 musl and 37/37 glibc**,
  `test-linux-x86_64` 31/31 + **`test-linux-x86_64-exe` 34/34 musl and 34/34 glibc**,
  `test-windows` 35/35, `test-windows-x86_64` 33/33, `check-examples`, `check-lang`, `check-conc`,
  `check-desktop`, `check-float`, `check-wide`, `check-kernel` (QEMU 11.0.1), `check-docs`
  (183 symbols, 19 flags, 19 TOML keys, 10 directives, 47 samples, 261 links), `site` 82 pages +
  `check-site` 0 link problems. `scripts/check-inert.sh` between a `build/mc1` built from
  `origin/main` and this one: **identical everywhere** (33 objects including `src/mc.mc`, and the
  five taught examples -- api, lang, conc, desktop, kernel).
  `make check-linux-host` RC 0 over all four cells: fixed point `mc2l.o == mc3l.o`
  (1161024 B on aarch64, 1076360 B on x86_64), the musl cells' `make check` with
  `test-exe` 31/31 and 29/29 and `check-obj` 31/31 and 29/29, the glibc cells' suites 35/35 and
  32/32 natively through `mc --exe`, and the cross proof on all four.
  All five goldens rewritten, each only after its own criterion: `mc2.sha256`
  `d73a2861...e849b79b` -> `7baa684a571a2cb4ed95c025a00ae813314b1cbd055623961b2015e69bc9b2c5`
  (after the empty `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`);
  the Linux pair deleted and re-recorded by `make check-linux-host` --
  `mc2-linux-arm64.sha256` `af2bbca7118274b64b1abb497999586a9c68dec118d84377d153bc6f09de000d`,
  `mc2-linux-x86_64.sha256` `978be8d6fa896601fd495bdec58b3f6941d135867613de05cde6db9ccb1a9724`,
  each verified a second time by the glibc cell of its architecture;
  the Windows pair cross-computed per `tests/golden/README.md` --
  `mc2-windows-arm64.sha256` `dc900682e98b6af721692ba95f10a5590d8f5007bca7a68db63c4c13dfa420b4`
  (934590 B), `mc2-windows-x86_64.sha256`
  `20f22777b8e907407b6b7a4938e3bf0a37555af364fbff6a1295beeb41248788` (953722 B), both also
  produced byte for byte by `build/mc2`.
  Docs: `docs/reference/objects.md` § 8b (new, the layout field by field with the `llvm-readelf`
  cross-check), `docs/reference/toml.md` § `[target]`, `docs/reference/cli.md`,
  `docs/reference/bundle.md`, `docs/build.md` § Linux targets (rewritten),
  `docs/guide/50-cross-compile.md`, `docs/guide/90-linux-host.md` § 3 (rewritten),
  `docs/bootstrap.md` (the standalone claim now says on which hosts it holds -- and, since the
  post-merge review, that `ld-musl-<arch>.so.1` exists only on musl distributions and the default
  is a CHOICE), `docs/ci.md`.
  Post-merge review, all of it recorded in `docs/specs/M42.md`: the `--exe` draft dropped for
  `main`'s (a), `lim_seeds[T_BACKENDS]` reconciled BY NAME after M41.5 inserted `T_SYNPARAM`
  before it -- index 31, not 30, and a textual merge would have put the 16 on `syntax_param` with
  no conflict to show for it (b), the two libcs everywhere (d), `ubuntu:latest` (26.04, glibc
  2.43) as the glibc oracle in place of `debian:bookworm-slim` and the four-cell run redone on it
  (e), the compiler itself built dynamically against glibc and taken to its own fixed point (f),
  note 5's unreachable `uptr p[] = { &write }` corrected (g), and note 10's `open` claim
  re-measured and **not reproduced** (h).
- Post-M42 patch (owner's two decisions, 2026-09-04; `docs/specs/M42.md` note 12 CLOSED,
  `docs/build.md` § Linux targets): **the target belongs to the developer -- one vocabulary for
  the Linux matrix, and `mc --exe` can say it.** `stage0/` untouched (2848/3000, `git diff main --
  stage0/` empty).
  1. **`[target].libc` stopped being a soname and became a FAMILY**: `gnu` or `musl`, and the
     family names the `PT_INTERP` path and the `DT_NEEDED` soname TOGETHER (`gnu` ->
     `/lib/ld-linux-aarch64.so.1` or `/lib64/ld-linux-x86-64.so.2` + `libc.so.6`; `musl`, the
     default -> `/lib/ld-musl-<arch>.so.1` + `libc.so`). They always travel together and a file
     that names them one at a time is a file that can name half a libc. The M42 spelling is
     refused WITH the migration in the message -- `libc must be gnu or musl (a soname is not a
     value: gnu is libc.so.6, musl is libc.so)` -- and the two configs that used it,
     `src/mc.linux-<arch>-gnu.toml`, each lost a key. `[target].interp` stays as the explicit
     loader-path override.
  2. **`[target].link = "dynamic" | "static"`** is new. `static` does NOT select the static image
     -- the import count still does, exactly as M42 wrote it -- it **asserts** it: a program that
     imports a libc symbol is refused with `static link with a libc needs [linker]: see
     docs/build.md -- static linking (M46)` instead of being handed a dynamic binary it did not
     ask for. With a `[linker]` present the driver takes the object+linker road as before and the
     key never reaches the writer.
     The refusal is raised by the WRITER (only the import set answers it) and reported at the
     KEY's `file:line:col` -- `dyn_die(key, msg)` in `src/objmodel.mc` calls a reporter the
     driver installs (`dyn_err_fn = &toml_err_key`) and falls back to `die()` on the CLI road.
     A writer must not know what TOML is and a `mc.toml` diagnostic must not lose its position;
     this is the one line that satisfies both.
  3. **Three CLI flags mirror the three keys**: `--libc=gnu|musl`, `--link=dynamic|static`,
     `--interp=PATH` (`src/cli.mc`), last one wins. **No probe of the host, ever** -- the default
     stays the constant musl, because one source must give one answer on every machine
     (`docs/determinism.md`); the probing belongs to the SCRIPTS. Off Linux, with no `--backend=`
     naming a writer, each is refused (`mc: --libc applies to a linux target`) rather than
     ignored. The TOML refusal uses the same condition, `[target].os != linux && host != linux`
     -- not `[target]` alone -- because a taught compiler is a binary for the HOST, so on a Linux
     host the keys still describe the compiler `mc build` writes.
  4. **One vocabulary everywhere.** `scripts/test-linux.sh`, `scripts/bootstrap-linux.sh` and
     `scripts/check-linux-host.sh` take `--libc musl|gnu`; the value `glibc` is refused with the
     rename spelled out. `scripts/test-exe.sh` and `scripts/build-exe.sh` LOST their `mc build`
     detour entirely (-46 lines between them): they are `mc --exe --libc=$(probe)` now, which is
     what decision (1) was for. The Makefile and `.github/workflows/ci.yml` pass `--libc gnu`.
  -- core cost: `src/objmodel.mc` +48/-11 (24 code), `src/driver.mc` +40/-10 (19 code),
  `src/cli.mc` +33/-2 (20 code), `src/backend_elf_exe.mc` +26/-8 (9 code).
  New: `tests/proj/lin-libc.mc` and four configs (`linux-musl`, `linux-gnu`, `linux-static`,
  `linux-static-linker`); `scripts/check-build.sh` +217 lines -- **the whole matrix, both roads,
  with no Docker**: musl/dynamic and gnu/dynamic built and read with `llvm-readelf` (`PT_INTERP`
  + `DT_NEEDED`), none/static with neither program header, gnu|musl/static through `[linker]`
  (object + spawn, `echo` standing in for `ld.lld`), the four CLI cases (`--libc=gnu`,
  `--libc=musl`, `--interp=` overriding, the last flag winning) and seven refusals verbatim.
  `make check-build` 21/21 -> **47/47**.
  -- `make bundle` re-run before bootstrapping (78 files, raw 848230 -> LZ 395264, blob 396217 B).
  `make check` green end to end (RC 0, zero FAIL): `test` 32/32, `check-lex` 126/126 (2 skipped),
  `check-ast`/`check-asm` 126/126, `check-obj` **32/32 identical to the frozen seed**,
  `check-bundle`, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 925176 B; the `--dump-asm` diff
  between `mc1` and `mc2` is **empty**), `check-surface` 32/32, `test-exe` **32/32 via `--exe`**,
  `check-mc`, `check-standalone`, `check-toml`, **`check-build` 47/47**, `check-stubs`,
  `check-limits` 17/17 under 90%, `test-linux` 34/34 and `test-linux-x86_64` 31/31, the four
  `--exe` cells **37/37 (aarch64 musl, alpine:3), 37/37 (aarch64 gnu, ubuntu:latest), 34/34
  (x86_64 musl) and 34/34 (x86_64 gnu)**, `test-windows` / `test-windows-x86_64`, `check-float`,
  `check-wide`,
  `check-examples`, `check-lang`, `check-conc`, `check-desktop`, `check-kernel`, `check-avr`,
  `check-docs` (183 symbols, 22 flags, 20 TOML keys, 10 directives, 47 samples, 277 links),
  `site` 84 pages + `check-site` (0 link problems, 84 files 0 problems, 50 contrast pairs 0 below
  the minimum). `scripts/check-inert.sh` against a `build/mc1` built from `main`: **33 objects and
  all five taught examples byte-identical** -- the keys and the flags are inert when nobody writes
  them. `make check-linux-host` RC 0, all four cells: fixed point `mc2l.o == mc3l.o` on both
  architectures under musl AND under gnu, the suite native through `mc --exe` (35/35 aarch64,
  32/32 x86_64 on the gnu cells) and the cross proof against the macOS `build/mc2.o` in each.
  The five goldens rewritten once, each only after its own criterion: `mc2.sha256`
  `7baa684a...b2c5` -> `2b919a15f9509a10c6a26e795a9107b8cff8c064077895132de27c75f9913601`, the
  Linux pair deleted and re-recorded by `make check-linux-host`
  (`d899ec57...8117`, `d1fa7e6c...deb9`) and the Windows pair cross-computed per
  `tests/golden/README.md` (`0ea0599b...d97c`, `c5364e3a...74d3`).
- Post-M42 review (2026-09-05, two findings from the PR review, one gated commit;
  `docs/specs/M42.md` note 12 § Reviewed again): **a flag that is read by nobody is refused, and
  the "Linux has no direct executable" row is retired.** `stage0/` untouched (2848/3000,
  `git diff origin/main -- stage0/` empty).
  1. **The three flags were accepted on the OBJECT road and did nothing.** The patch's gate was
     `linkflag && bname == 0 && host != linux`, so a Linux host took `mc x.mc -o x.o --libc=gnu`
     and every host took `--backend=elf-obj --libc=gnu`. Reproduced before the fix with `cmp`:
     the object built with the flag and the object built without it are **byte for byte
     identical** (`--libc=gnu`, `--interp=`, `--link=static`, all three). Only
     `src/backend_elf_exe.mc` reads `dyn_libc`/`dyn_interp`/`dyn_static` -- `PT_INTERP` and
     `DT_NEEDED` are program-header fields and an object has neither.
     The gate is now three questions in `src/cli.mc`, moved to just after `user_init()`:
     `applies to an executable: a --dump-* mode writes none` (a dump returns before any backend,
     with or without `--exe`), `applies to an executable: use --exe` (the object road), and the
     original `applies to a linux target` (`--exe` off Linux). What counts as an executable writer
     is asked of the TARGET REGISTRY, never of the name: **`backend_is_exe(name)`**
     (`src/hooks.mc`) is 1 when some `target()` names it in its exe slot, so a target a
     module registered from `user_init()` answers for its own writer -- which is why the gate had
     to move after `user_init()`, and the price of the move is that an unreadable entry reports
     `cannot open` first (the same trade M39.5 accepted for `[target]`).
     `src/cli.mc` +33/-9 (8 code) and `src/hooks.mc` +23/-0 (10 code).
     `scripts/check-build.sh` +59/-10, **47/47 -> 53/53**: six refusals
     verbatim (the three flags on `--backend=elf-obj`, the default road with neither `--exe` nor
     `--backend=`, and a dump mode with and without `--exe`), plus, on a Linux host only, the two
     positives `--exe --libc=gnu` -> `libc.so.6` and `--exe --libc=musl` -> `libc.so`. The
     `--backend=elf-exe --libc=…` cases are unchanged and still pass.
     Verified on a real Linux host (`alpine:3`, linux/arm64, `build/mc-linux-arm64`): the object
     road is `mc: --libc applies to an executable: use --exe` (exit 1), the dump road is
     `mc: --libc applies to an executable: a --dump-* mode writes none` (exit 1), and
     `--exe --libc=gnu` writes `/lib/ld-linux-aarch64.so.1` + `libc.so.6` while `--exe
     --libc=musl` writes `/lib/ld-musl-aarch64.so.1` + `libc.so` and RUNS (`hi`, exit 0).
     On record: `--backend=macho-exe --libc=gnu` is still accepted and ignored -- an exe slot
     answers yes, and a Mach-O executable has no interpreter to name. That is the boundary the
     accept condition draws, and it is documented.
  2. **`linux requires [linker]: there is no direct executable` retired as a Linux fact.** Since
     M42 filled the two Linux exe slots the message belongs to any target whose exe slot is 0 --
     `windows/aarch64` and `windows/x86_64` today, or `target(os, arch, obj, 0)` from a module.
     `docs/reference/diagnostics.md` § 10's row rewritten as `<os> requires [linker]: …`, § 9's
     sibling row corrected (`linux` was on that list), and three more stale places found by the
     same grep: `docs/reference/hooks.md` § `target()` still showed
     `target("linux", "aarch64", "elf-obj", 0)` in its code sample and called `exe = 0` "what
     `os = "linux"` and `os = "windows"` do", and `docs/guide/90-linux-host.md` still told the
     reader to run `scripts/bootstrap-linux.sh --libc glibc` and `test-linux.sh --exe --libc
     glibc` -- a value those scripts REFUSE since the patch commit -- and still said `mc --exe`'s
     interpreter "cannot be told otherwise from a command line". Also documented: the new
     refusals in `docs/reference/cli.md` (a three-row table), `docs/build.md` § the matrix,
     `docs/guide/50-cross-compile.md` § the object road, and `backend_is_exe` in
     `docs/reference/hooks.md`.
  -- `make bundle` re-run before bootstrapping (78 files, raw 850657 -> LZ 396299, blob 397252 B).
  `make check` green end to end (**RC 0, zero FAIL**, 5m08s): `test` 32/32, `check-lex` 126/126
  (2 skipped), `check-ast`/`check-asm` 126/126, `check-obj` **32/32 identical to the frozen
  seed**, `check-bundle`, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 926848 B; the
  `--dump-asm` diff between `mc1` and `mc2` **empty**), `check-surface` 32/32, `test-exe` 32/32
  via `--exe`, `check-mc` 7/7, `check-standalone`, `check-toml` 10/10, **`check-build` 53/53**,
  `check-stubs` 9/9, `check-limits` 17/17 under 90%, `test-linux` 34/34 and `test-linux-x86_64`
  31/31, `test-windows` 35/35 and `test-windows-x86_64` 33/33 objects, `check-float`,
  `check-wide`, `check-examples`, `check-lang` 18, `check-conc` 21, `check-desktop`,
  `check-kernel`, `check-avr`, `check-docs` (**184** symbols, 22 flags, 20 TOML keys, 10
  directives, 47 samples, 281 links), `site` 85 pages + `check-site` (0 link problems).
  `scripts/check-inert.sh` against a `build/mc1` built from `origin/main`: **33 objects and all
  five taught examples byte-identical** -- the new gate refuses only what the old one accepted and
  ignored. `make check-linux-host` RC 0, all four cells (musl and gnu x aarch64 and x86_64):
  fixed point `mc2l.o == mc3l.o` in each, the suite native through `mc --exe` and the cross proof
  against the macOS `build/mc2.o`.
  The five goldens rewritten once, each after its own criterion: `mc2.sha256`
  `2b919a15…3601` -> `61404319507a811f17d464062670096152ff5c2c08e3607bf2dc14d66a6653f2` (after
  the empty `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`), the Linux pair deleted and
  re-recorded by `make check-linux-host`
  (`54a31181bff8483b493415643de1ce3371c3157aea553ec406204e7b6e8334b6` and
  `d1cdca0320413cb4abd74750e6efc1b54154dfe8dabaca01178b2af68a1e9dfe`, each inside its own
  container and only after its own fixed point) and the Windows pair cross-computed per
  `tests/golden/README.md`
  (`fdaa573611f5c90677d799346173114ff50a4fb3435ba0d1ef65a75e98dbc75e` and
  `63962f990b853564a4926d1216a25e017faa47477477af5e84c7c506e18ef32b`, and `build/mc2` writes both
  byte for byte as `build/mc1` does).
- M45 step 1 (the mechanism) ✔ (`docs/specs/M45.md` § Amendment + § Implementation notes):
  **`i32`, and a call returns what it declares** -- the mechanism half, INERT. `stage0/` untouched
  (`git diff stage0/` empty).
  * **`i32` is registered by the core, not a keyword.** `core_types_init()` (`src/hooks.mc`) calls
    `type_new("i32", 4, 4, TK_SINT)` before `user_init()`, so the word arrives through exactly the
    M24 mechanism a module uses -- the alias table, `word_add`, `type_of_token`'s last arm --
    `TY_MAX` stays 7, `tok_init` is untouched and `src/lexdump.mc` still lexes `i32` as identifier
    1, byte for byte what the frozen `stage0/lex.c` does. **Three call sites, not the one the spec
    named**: `mc build` (`src/driver.mc`) and `mc limits` (`src/limits.mc`) run their own
    tok_init/lex_init/user_init and would otherwise leave `ty_i32` at 0 -- found by
    `type_disable(ty_i32)` in `examples/avr` disabling `TY_VOID`.
  * **`TK_SINT`, a fifth kind**, appended so `TK_INT..TK_OPAQUE` keep 0..3, and
    `type_signed(t) = t == TY_I64 || type_kind(t) == TK_SINT` (`src/ast.mc`) as the ONE place
    signedness is written down. The core now reads `kind` in exactly three places -- `type_signed`,
    `fold_taught` and `walk_narrow` -- and nothing tests an id. What that buys is measured, not
    asserted: `type_new("i16", 2, 2, TK_SINT)` in `lib/user_syntax_demo.mc` is **one line** and
    gets `ldrsh`, `sxth`, signed `/ % >>`, a signed comparison and a narrowed call result.
  * **The fold guards key on kind (D17).** `fold_taught` is `k != TK_INT && k != TK_SINT`, and
    `fold_cast`'s three masks became a width-and-kind rule (byte-identical for `u8`/`u16`/`u32`).
    So `fix` -- `lib/user_syntax_demo.mc`'s `TK_INT` -- now folds like a core literal, which is
    what `check-surface`'s M24 fold case asserts; the non-folding half moved onto `<float>`'s
    `f64` (`fadd`/`fneg`/`fcmp` all survive) in the same case.
  * **The walker narrows through the existing `MTASK_CAST`, no new slot** (D4/D5/D7'):
    `walk_narrow(t)` admits a `TK_INT`/`TK_SINT` of width < 8 except `uptr`, and `gen_call` issues
    `set_walk_depth_type(depth, rt)` + `MTASK_CAST(rt, depth)` after `MTASK_CALL`, `N_RETURN`
    issues one before `MTASK_RET` from `walk_fn_ret`. The `set_walk_depth_type` line is
    load-bearing and was proved so: without it `extern i32 ilogb(f64 x)` lowers as
    `fcvtzu x9, d16` -- a float register that never held the value -- and with it as `sxtw x9, w9`
    (`tests/float/022-int-return.mc`). **Deviation:** the RETURN side does NOT rewrite the depth
    type before its cast, only after; there `dtype[0]` already describes the value `gen_value`
    produced, which is the SOURCE a derived machine needs.
  * **Contract version 4** (`docs/reference/machine.md`): no slot, no signature change. The bump
    is the obligation -- every `ty`-carrying slot dispatches on `type_width` and `type_kind`,
    never on the id; zero-fill for `TK_INT`, sign-fill for `TK_SINT`; a machine that will not
    implement it says `type_disable(ty_i32)`. Four machines updated: `src/machine_arm64.mc`
    (`I_LDRSB/LDRSH/LDRSW`, `I_SXTB/SXTH/SXTW`), `src/machine_x86_64.mc` (`X_LDS8/16/32`,
    `X_MOVSXB/W/D`, both forms), `lib/backend_arm64.mc` (the surface encoder, same rows) and
    `examples/kernel/machine_riscv64.mc` (`lb`/`lh`/`lw`, `srai` through a new funct6 column,
    `sext.w` as `V_ADDIW`); `examples/avr/mc-avr.mc` calls `type_disable(ty_i32)` instead.
  * **Acceptance 1 was MEASURED before anything changed** and is in `docs/specs/M45.md`
    § Implementation notes 1. `open`/`close(-1)`/`waitpid(-1)` return a full 64-bit -1 on musl and
    glibc, both architectures, and on macOS -- **the spec's `open` claim did not reproduce**. The
    defect class does: `atoi("-1")` is `0x00000000ffffffff` on musl (both arches) and
    `strcmp("a","b")` is on glibc/x86_64, so `< 0` is FALSE through the pre-milestone compiler; on
    macOS an ordinary `int m45_neg(void){return -1;}` compiled by clang (`mov w0, #-0x1; ret`)
    reads back `0x00000000ffffffff` too. That measurement is why `lib/sys.mc` keeps its `i64`
    declarations (§ 5's row, decided by measurement) and why `tests/linux/072` declares three
    functions rather than one.
  — **Inertness is the gate and it held where the milestone claims it.**
  `scripts/check-inert.sh` between the `build/mc1` of `6fab014` and this one: **33 objects
  identical** (`tests/*.mc` + `src/mc.mc`) and `lang`/`conc`/`desktop` identical through the taught
  compiler each builds; `examples/kernel`'s image (3304 B) and `examples/avr`'s ELF compared by
  hand, pre compiler + pre machine against post + post -- **identical** (the script's kernel case
  cannot run across this milestone: the pre compiler's bundle has no `TK_SINT`).
  **Correction (review, 2026-09-05): `examples/api` is a `DIFF`, not an `ok`** -- the entry here
  and `docs/specs/M45.md` § Implementation notes 3 both said `ok` and were wrong. The corpus grep
  that found "no narrow-declared callee anywhere" is over SOURCE TEXT, and a Tier 3 module can
  declare a narrow function without writing one: `examples/api/oop.mc`'s `class` handler builds
  `u8 todo_done(uptr self)` out of AST nodes for the field `bool done;` (`bool` is
  `type_alias("bool", TY_U8)`). D5 then applies on both sides, which is the design. Measured:
  `--dump-asm` of `examples/api/main.mc` through the taught `mc-api` each compiler builds differs
  by **exactly two instructions**, both `and x9, x9, #255` -- one after the `ldrb w9, [x9]` that is
  `todo_done`'s body (the return side, `walk_fn_ret`), one after the `mov x9, x0` that follows
  `bl _todo_done` (the call side, `res_type`). Both are no-ops on the value -- `ldrb` already
  zero-extends -- so `build/api` is the same 55632 bytes and the eleven route checks stay green.
  Read the rule as: the return-side and call-side narrowing move bytes for EVERY narrow-returning
  function, written or synthesized, and a grep over sources cannot enumerate the synthesized ones. Sweep: 16 distinct new instructions re-assemble byte for
  byte under `llvm-mc` on each of mach-o arm64, elf aarch64, coff aarch64, elf x86-64 and coff
  x86-64; `examples/kernel`'s own sweep goes 262 -> 285 with 0 mismatches, plus a scratch run with
  `i8`/`i16` registered (62, 0 mismatches, `lb`/`lh`/`srai` present).
  New: `tests/mc/090-i32-basic.mc`, `091-i32-cast.mc`, `092-i32-div.mc` (`INT_MIN / -1` is
  2147483648 on every machine, no `#DE`), `093-i32-return.mc`, `tests/linux/072-int-return.mc`,
  `tests/windows/073-int-return.mc`, `tests/float/022-int-return.mc`;
  `scripts/test-linux.sh`/`test-windows.sh` run `tests/mc/0[89]*.mc` on every target;
  `scripts/sysroot-windows.sh` gained `GetFileAttributesA`.
  Cost in `src/`: **234 added lines, 128 of them code** (86 of the 128 in the two machines).
  `make check` green end to end (RC 0, zero FAIL, 5m09s), `make check-linux-host` green on both
  architectures with the cross proof. All five goldens rewritten once: `mc2.sha256`
  `7baa684a…9b2c5` -> `77a973a294e24c9ec4df0b95e021dead8525178288371e75a60336a02a87d1b9`,
  `mc2-linux-arm64` `167b37cb6c0b71b0a4d1046700afa5e3a9299337c11b7e22f3ff63af0df9dcdf`,
  `mc2-linux-x86_64` `067cfbc824ec1fbdabdccddee85aab1d454b6945e8dacb4dabe388a98e6087a2`,
  `mc2-windows-arm64` `f778e38a8fcfb32626a0b0f6fa786d6c122bbc8506ba95eb68534369d67e161d`,
  `mc2-windows-x86_64` `73c904a1a70fd5791f78d76b874572c571d42180de53f5878ea500ae7117fa88`.
- M45 step 2 (the declarations) ✔ (`docs/specs/M45.md` § 5 + § Implementation notes 4):
  **the truthful declarations, and the one place D8 did not survive contact with the code.**
  `stage0/` untouched.
  * **D8 as written is incompatible with `check-asm`.** § 5 asks `src/*.mc` and the seed-compiled
    libraries to declare an `int` result as `u32`. Implemented literally, `make check` came back
    **RC 2 with 23 FAILs** and `check-asm` at 103/126: that script compares `mc0 --dump-asm`
    against `mc1 --dump-asm` over `tests/ lib/ src/`, and a narrow declaration makes `mc1` emit a
    `mov w9, w9` the frozen seed has no way to emit -- **27 of them over `src/mc.mc`, and nothing
    else**. Both escapes are closed by the task's own rules (no `seed-skip` in the seed set,
    `stage0/` frozen). Resolution: **D8's own named alternative** -- `c_int()` alone in the seed
    set, `i32` everywhere else. Not weaker: `c_int(v)` is the low 32 bits sign-extended from bit
    31, so it is right whether the callee left the sign there or not, on every host and under
    every seed; what is lost is only that the declaration would have carried the information.
  * `c_int()` in `src/arena.mc` and four call sites: `c_int(open(...))` and `c_int(creat(...))` in
    `read_file`/`write_file`, `c_int(open(...))` in `src/sysroot.mc`, `c_int(creat(...))` in
    `src/backend_exe.mc`, and `c_int(waitpid(...))` at **both** sites in `src/driver.mc` -- the
    same latent defect as `open`, and the one a spawned tool's `pid_t` would hit. The host layers
    and `lib/sys_windows*.mc` keep their declarations with the reason written in a comment; the
    `& BOOL_MASK` masks stay (D9).
  * **`lib/sys.mc` stays `i64` BY MEASUREMENT** (Acceptance 1c), with the numbers in its header:
    libSystem's wrappers hand back a full 64-bit -1 for `open`, `close(-1)` and `waitpid(-1)`.
    The header also says what is not true of an ordinary C function, and
    `docs/reference/language.md` § `extern` says a program wanting the truthful declaration writes
    its own `extern i32 open(...)`.
  * **`i32` where the seed never looks**: `examples/api/lib/sqlite.mc` (11 declarations;
    `sqlite3_last_insert_rowid` stays `i64`), `examples/api/lib/http.mc` (5, and its three `< 0`
    tests are now sound), `examples/api/tests/lib_test.mc`, `examples/conc/lib/{macos,linux}/
    thread.mc` (12 each), `examples/desktop/lib/gtk.mc` + `main.mc` -- where **both `(u32)` casts
    are gone**, because the declaration now says what the cast used to.
    `examples/api/test_sqlite_lib.mc` was left alone and the reason recorded: nothing builds it and
    it does not compile (`call to unknown function` -- `sqlite3_libversion_number` is declared
    nowhere).
  — Measured: `check-inert` between the pre-milestone `build/mc1` and this one keeps **the 33 core
  objects identical** (that is what leaving the seed set alone buys) while `api`/`conc`/`desktop`
  now REFUSE to build under the old compiler, which is the fix; `bl _sqlite3_step` is followed by
  `sxtw x9, w9`; the `--dump-asm` diff over `src/mc.mc` between the two compilers is **empty**, so
  the golden moves because `c_int` is a new function and not because instruction selection did;
  and a pre-M45 compiler -- what a published release is -- produces **byte-identical objects** for
  `src/mc_windows.mc`, `src/mc_windows_x86_64.mc`, `src/mc_linux.mc` and `src/mc_linux_x86_64.mc`,
  so both foreign chains bootstrap from 0.12.0 unchanged. `mc-linux-arm64` (musl) and
  `mc-linux-arm64-gnu` (glibc) both answer `mc: cannot open`, exit 1.
  `make check` RC 0, zero FAIL, `check-asm` back at 126/126 and `check-obj` 32/32;
  `make check-linux-host` RC 0 on both architectures with the cross proof on musl and glibc.
  Goldens rewritten a second time: `mc2.sha256`
  `0c26544589966095fc795ffcf7f7cb0602495229f8bae7f72a35ed64def62fec`,
  `mc2-linux-arm64` `06165599f9de9e3413e4a05e1371fdc26ef02494615d1c1da76916b26beded44`,
  `mc2-linux-x86_64` `02eec99d84119a077c806ca14230bfa58aba63affd4591efbf06b3b54ed94893`,
  `mc2-windows-arm64` `57b2a7e174f6be3f3ca8063d503a8dffc7fd650cbce2e4b83d41ce0540879ce6`,
  `mc2-windows-x86_64` `24b994e706bc37d9533898331da538fdab4814ee1097f78fe04e8ac2e5a2bb45`.
- M45 step 3 ✔ (`docs/specs/M45.md` § Implementation notes 5): **`p_cp()` public** -- the lexer's
  cursor, for a handler that scans raw source forward. Not part of the spec; asked for alongside it
  because the ngen consumer hit it. `p_start()` is where the CURRENT TOKEN starts, and on a token
  `p_subst_name()` replaced, `subst_apply` swaps `tok_start`/`tok_len` for the REPLACEMENT string,
  which lives in the arena -- so a `syntax_lit`-style scan from `p_start()` inside a
  `p_push_source` frame reads the arena lexeme and not the source. One line in `src/parse.mc`
  beside `p_start()`/`p_src_end()`, a row and a caveat paragraph in
  `docs/reference/hooks.md` § Record and replay, and a `check-surface` case
  (`p_cp-under-substitution`) built on three new demo registrations: `srcbyte` (`ld8(p_cp())`),
  `srcbyte0` (`ld8(p_start())`) and `probe NAME;`, which pushes
  `i64 NAME() { return W  * 1000 + V; }` with `W -> srcbyte` and `V -> srcbyte0` so both run on
  SUBSTITUTED tokens. The four numbers: 59 and 115 in ordinary source (where the two positions
  agree), then **32** from `p_cp()` -- the space that really follows `W` in the pushed text -- and
  **115** from `p_start()`, the arena copy of `"srcbyte0"`, where the source holds `V` (86).
  Inert: `check-inert` between the step-2 compiler and this one is identical everywhere, all five
  taught examples included, and the `mc1`/`mc2` `--dump-asm` diff over `src/mc.mc` is empty; the
  goldens move only because `p_cp` is a new function. `make check` RC 0, zero FAIL;
  `make check-linux-host` RC 0 on both architectures. Goldens rewritten a third time:
  `mc2.sha256` `60b21acb8c61fdfea8803c3ec8bda15341ab9aef36f78f6f4425038fafc8db6c`,
  `mc2-linux-arm64` `89fab268edeccb94f86c3b9f98f1d4206464cc40bf0306f4a1a8297cafdae37d`,
  `mc2-linux-x86_64` `68b2c57d1b9ac8787abce3647ac545c70978376247010f7af6fda3637bf12659`,
  `mc2-windows-arm64` `2877458c375b72018b2b9a62d30bb30cd7ee84488a938a1bcacf05653388f3b8`,
  `mc2-windows-x86_64` `97e02abd56e1e11d595d54f2586437f56bb45596e2c0cf2b5a852a5ab2c3629f`.
- Post-M45 batch (review, `docs/specs/M45.md` § Implementation notes 6): the four findings the
  reviewer of the branch raised. One is a correction to the record, one is a documentation gap the
  gate could not see, one is a name that was wrong about the hardware, and one is a real defect a
  consumer hit. `stage0/` untouched (2848/3000). The only compiled change is
  **`src/parse.mc` +15/-2, 3 of the added lines code**.
  1. **The record was wrong about commit 1's inertness in `examples/api`** -- corrected in
     `docs/specs/M45.md` (§ 3 of the Design and § Implementation notes 3) and in the M45 step 1
     entry above, both of which said `ok taught examples/api`. Reproduced first, with `mc1.pre`
     rebuilt from `6fab014` and `mc1` from `9e27e06`: `DIFF taught examples/api -> build/api`. The
     reason is the general one and matters more than the row: **the grep that established "no
     narrow-declared callee anywhere in the corpus" is over SOURCE TEXT, and a Tier 3 module can
     declare a narrow function without writing one.** `examples/api/oop.mc`'s `class` handler
     builds a getter per field out of AST nodes (`oop_getter` -> `oop_func(ty, ...)`), so
     `bool done;` in `class Todo` -- `bool` being `type_alias("bool", TY_U8)` -- is a declaration
     of `u8 todo_done(uptr self)` that no grep over `examples/` can find. D5 then applies on both
     sides, by design. Measured: `--dump-asm` of `examples/api/main.mc` through the taught `mc-api`
     each compiler builds differs by **exactly two instructions**, both `and x9, x9, #255` -- one
     after the `ldrb w9, [x9]` that IS `todo_done`'s body (the return side, `walk_fn_ret`), one
     after the `mov x9, x0` that follows `bl _todo_done` (the call side, `res_type`). Both are
     no-ops on the value, since `ldrb` already zero-extends; `build/api` is the same 55632 bytes.
     What is identical and stays identical: the 33 objects (`tests/*.mc` + `src/mc.mc`), `lang`,
     `conc`, `desktop`, `kernel` and the AVR image. D5 is not weakened -- the cast is the design.
  2. **`c_int` was not in `docs/reference/`.** Acceptance 8 promised it documented; it existed only
     in the spec and in this file, and `scripts/check-docs.sh`'s symbol regex had no prefix that
     reached it. Documented in `docs/reference/language.md` § 6, right after the `extern` rule that
     tells a program to declare `i32` -- with the exact contract (the low 32 bits sign-extended
     from bit 31; correct whether the callee sign-extended, zero-extended or left rubbish above;
     pure arithmetic, so no machine support) and the reason `src/` uses it instead of a narrow
     declaration (the frozen seed cannot spell `i32`, and `u32` would make `mc1` emit an extension
     the seed cannot, which `check-asm` compares over exactly those files) -- and cross-referenced
     from `docs/reference/hooks.md` § The host layer, where the `open`/`creat`/`waitpid`
     declarations it exists for are described. The extraction regex gained `c_`, the same widening
     `on_` and `decl_` got (`docs/specs/M26.md`); `c_int` is the only symbol it adds. Verified in
     both directions: with the two mentions renamed, `check-docs` prints
     `FAIL undocumented public symbols`; with them, `docs ok: 187 symbols`.
  3. **`rv_if7[]` was a funct6.** RV64I's shift-immediate forms take a 6-bit shamt (bits 25:20), so
     the differentiator above it is a funct6 at bits 31:26, not the funct7 the register forms carry
     at 31:25. The one value in the column, `0x20 << 5`, lands on bit 30 -- exactly where
     `0x10 << 6` lands -- so the encoding was right and only the name and the shift were wrong; a
     second, multi-bit value would have been misplaced. Renamed to `rv_if6`/`rv_if6_at`, `0x10`,
     `<< 6` (`examples/kernel/machine_riscv64.mc` +12/-8, all comment but three lines).
     `examples/kernel/build/kernel.bin` is **`cmp`-identical before and after** (3304 bytes, same
     compiler, both machines) and `make check-kernel` is green with QEMU 11.0.1. The kernel corpus
     has no `srai` at all -- it comes only from `rv_cast`'s sign-extension pair, which needs a 1-
     or 2-byte `TK_SINT` -- so the arm was re-proved on the scratch compiler of § Implementation
     notes 3 (`mc-kernel` + `type_new("i16", 2, 2, TK_SINT)` + `i8`): **36 distinct instructions,
     0 mismatches** under `llvm-mc -triple=riscv64 -mattr=+m`, with `srai t3, t3, 48` =
     `135e0e43` and `srai t4, t4, 56` = `93de8e43`.
  4. **`p_skip_balanced` refused a region that ends flush with the end of an included file**
     (reported by the teko/ngen consumer). The frame depth was compared AFTER the lookahead
     `next()` that follows the closing delimiter, and `lex_next` pops an exhausted `#include` frame
     BEFORE it produces a token -- so a perfectly balanced region whose `}` was the include's last
     token left `nopen` one lower and came out as `region crosses a file boundary`. It is now
     sampled at the CLOSER, inside the loop (`i64 dend`), which is exactly the "both delimiters
     live in one buffer" the rule always meant; an `#include` opened and closed inside the region
     still moves `nopen` up and back down and is still fine, and a region that really does cross is
     still refused, with the same message at the same position (the OPENING token). Reproduced
     first: a `tmpl t<T, N> { ... }` alone in `tpl.mc`, `#include`d, was refused at `tpl.mc:1`;
     with the fix it compiles and the program exits 42. Two new cases in
     `scripts/check-surface.sh` -- `p_skip_balanced-include-eof` (compiled with the demo compiler
     and RUN) and `p_skip_balanced-cross` (the message asserted by suffix, since `$TMPDIR` may end
     in a slash and the compiler prints the path it opened, normalized). **The message had no test
     at all before.** Docs: `docs/reference/hooks.md` § Record and replay,
     `docs/reference/diagnostics.md` and `docs/surface.md`.
  -- `make bundle` re-run BEFORE bootstrapping (`src/parse.mc` is `mc/parse`): 78 files, raw
  861794 -> LZ 402157, blob 403110 B. `make check` green end to end (**RC 0, zero FAIL, 5m01s**):
  `budget` 2848/3000, `test` 32/32, `check-lex` 126/126 (2 skipped), `check-ast` 126/126,
  `check-asm` 126/126, `check-obj` **32/32 identical to the frozen seed**, `check-bundle`,
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, 931696 B; the `--dump-asm` diff between `mc1` and
  `mc2` is **empty**), `check-surface` 32/32 + 116 ok lines including the two new ones,
  `test-exe` 32/32, `check-mc` 11/11, `check-standalone`, `check-parts`, `check-toml` 10/10,
  `check-build` 31/31, `check-stubs` 9/9, `check-sysroots`, `check-limits` 17/17 under 90%,
  `check-minimal`, `test-linux` 39/39, `test-linux-x86_64` 36/36, `test-linux-exe` 42/42 musl +
  42/42 glibc, `test-linux-x86_64-exe` 39/39 + 39/39, `test-windows` 40/40 objects,
  `test-windows-x86_64` 38/38, `check-examples`, `check-lang`, `check-conc`, `check-desktop`,
  `check-float`, `check-wide`, `check-kernel` (QEMU 11.0.1, exit 0), `check-docs`
  (**187 symbols**, 19 flags, 19 TOML keys, 10 directives, 48 samples, 275 links), `site` 85 pages
  + `check-site` 0 link problems.
  `scripts/check-inert.sh build/mc1.pre build/mc1` (pre = the branch's HEAD compiler, before these
  edits): **33 objects identical** (`tests/*.mc` + `src/mc.mc`) and all five taught examples
  identical -- `api`, `lang`, `conc`, `desktop` and `kernel`. Item 4 is the only change to a
  compiled byte in `src/`, and it changes no byte the compiler EMITS.
  `tests/golden/mc2.sha256` rewritten once, only after the empty `--dump-asm` diff and
  `cmp build/mc2.o build/mc3.o`: `60b21acb...c8db6c` ->
  `26c9a7c8070e64471bafecfeb42917ba43dec6e2413374a5ea25b0ebc9923c06`. The four foreign goldens are
  deliberately NOT re-recorded here: they move with the same `src/parse.mc` edit and the same
  bundle, and the architect asked for one re-recording after the rebase.
- M45 rebased onto `origin/main` e4a4c40 (PR #21, `[target].libc` as a family) and the five
  goldens re-recorded once, which is the "one re-recording after the rebase" the entry above
  defers to. Six files conflicted and each was resolved by reading both sides: `CLAUDE.md`
  (main's post-M42 entry kept AND the M45 entries after it, M45 last), `docs/specs/M45.md`
  (main's corrected defect paragraph -- the one the spec PR re-measured -- plus this branch's
  § Implementation notes), `src/bundle_data.mc` and the five `tests/golden/*.sha256`
  (regenerated / re-recorded below). `src/cli.mc`, `src/driver.mc`, `src/hooks.mc`,
  `src/objmodel.mc`, `scripts/test-linux.sh`, `docs/reference/{diagnostics,hooks,objects}.md`
  auto-merged and were read to confirm BOTH sides survived: `core_types_init()` at its three call
  sites (`cli.mc:254`, `driver.mc:339`, `limits.mc:586`, each before `user_init()`) next to
  main's `linkflag` gating through `backend_is_exe` and its `dyn_interp`/`dyn_libc` globals; the
  `c_` prefix still in `scripts/check-docs.sh`'s symbol regex; `test-linux.sh` carrying main's
  `--libc musl|gnu` vocabulary with M45's `tests/mc/0[89]*.mc` loop and `072-int-return` written
  in it. `src/arena.mc`'s tag list was checked BY NAME rather than by position (the M42 lesson):
  `T_SYNPARAM 30`, `T_BACKENDS 31`, `T_COUNT 39`, and `lim_seeds[31] = 16` is still on
  `backends` -- only this branch touched the file, so nothing moved.
  -- `make bundle` re-run FIRST (78 files, raw 871568 -> LZ 407042, blob 407995 B), then
  `make check` green end to end (**RC 0, zero FAIL**): `budget` 2848/3000, `test` 32/32,
  `check-lex` 126/126 (2 skipped), `check-ast` 126/126, `check-asm` 126/126, `check-obj`
  **32/32 identical to the frozen seed**, `check-bundle`, `bootstrap` at a fixed point
  (`mc2.o == mc3.o`, 941576 B; the `--dump-asm` diff between `mc1` and `mc2` is **empty**),
  `check-surface` 32/32 + 116 ok lines, `test-exe` 32/32, `check-mc` 11/11, `check-standalone`,
  `check-parts` (the five parts + `<mc/main>` == `<mc/core>`, 941576 B), `check-toml` 10/10,
  `check-build` **53/53** (main's `[target].libc`/`link` cases plus M45's), `check-sysroots`,
  `check-stubs` 9/9, `check-limits` 17/17 under 90%, `check-minimal`, `test-linux` 39/39,
  `test-linux-x86_64` 36/36, `test-linux-exe` 42/42 musl + 42/42 gnu,
  `test-linux-x86_64-exe` 39/39 + 39/39 -- so the M45 corpus (`090..093`, `072-int-return`) runs
  on the `--exe` legs main added, on both libcs -- `test-windows` 40/40 objects,
  `test-windows-x86_64` 38/38, `check-examples`, `check-lang`, `check-conc`, `check-desktop`,
  `check-float` (13/13 macos, 13/13 linux/aarch64, 13/13 linux/x86_64, 11/11 + 11/11 windows
  objects), `check-wide`, `check-kernel` (QEMU 11.0.1, `kernel.bin` 3304 B, exit 0), `check-avr`
  (simavr + QEMU, `avr.elf` 15255 B), `check-docs` (**188 symbols**, 22 flags, 20 TOML keys,
  10 directives, 48 samples, 287 links), `site` 85 pages + `check-site` 0 link problems.
  `make check-linux-host` RC 0 over all four cells -- linux/aarch64 musl (suite 39/39,
  `test-exe` 31/31 via `--exe --libc=musl`, `check-obj` 31/31), linux/aarch64 gnu (40/40
  natively), linux/x86_64 musl (36/36, `test-exe` 29/29, `check-obj` 29/29), linux/x86_64 gnu
  (37/37) -- each after its own `mc2l.o == mc3l.o` and with the cross proof
  (`mc2l --backend=macho src/mc.mc` byte for byte the macOS `build/mc2.o`) green.
  Inertness against `origin/main` e4a4c40, measured over e4a4c40's OWN tree (the pre compiler
  cannot read this branch's `examples/`, which now declare `extern i32`): **33 objects identical**
  (`tests/*.mc` + `src/mc.mc`), `lang`, `conc`, `desktop` and `kernel` identical through the
  taught compiler each side builds, and `DIFF` on `examples/api` alone -- the two synthesized
  `and x9, x9, #255` of the review batch above, confirmed here by diffing `--dump-asm` of
  `examples/api/main.mc` through each taught `mc-api`: exactly two added instructions, nothing
  else.
  The five goldens rewritten **once**, each only after its own criterion: `mc2.sha256`
  `26c9a7c8...923c06` -> `90ce56dcfc6f3c7a785013871b5df9f8ad6ed36ad24acb28256e60385435ee38`
  (empty `--dump-asm` diff + `cmp build/mc2.o build/mc3.o`); the Linux pair deleted and
  re-recorded by `make check-linux-host` --
  `mc2-linux-arm64.sha256` `8cb319f2648b2a1eb37dcdc19b46290ca111ad7543482fbd349c6c2bcb415856`,
  `mc2-linux-x86_64.sha256` `c0882f93933469e066ba73f461fe2be4caa13de558d09ba534955b0a80e19b93`,
  each recorded in its musl cell and re-verified by the gnu cell of the same architecture;
  the Windows pair cross-computed per `tests/golden/README.md` --
  `mc2-windows-arm64.sha256` `2c55021d3a87ebb087165f77d03fbf8d96f58bb6e4cfb428328f05c909382eab`
  (959407 B), `mc2-windows-x86_64.sha256`
  `af21fe6f17f6d0ca13554b122536178688284f759b990cc8ebb1ccb336ed947f` (978891 B), both also
  written byte for byte by `build/mc2`.
- Post-M45 Windows batch (the four Windows CI legs, `docs/specs/M45.md` § Implementation notes 7):
  the two findings only a Windows runner could see, and the local gate widened so the first of
  them cannot hide again. `stage0/` untouched (2848/3000); nothing in `src/` changed except the
  regenerated `src/bundle_data.mc`.
  1. **`tests/windows/073-int-return.mc` was in the wrong link mode.** `scripts/test-windows.sh`
     put it in the `self` list, and `self` means exactly one thing -- *the source includes
     `<sys_windows>` and therefore must NOT have `winrt.obj` next to it*. 073 deliberately does
     not include the layer (it declares the three kernel32 entry points it uses), but
     `winstart.obj` is in EVERY link line (M20) and its `mc_start` calls `win_setup`/`win_argv`,
     which live in `lib/sys_windows.mc` = `winrt.obj`: `lld-link: error: undefined symbol:
     win_setup` / `win_argv`, on both architectures. It is now a `kernel32` link; its own
     `extern`s resolve from the import library and none of its names (`wr`, `puti`, `nbuf`,
     `nio`, `main`) collides with the layer's. One list, read by both halves of the split through
     `$split/manifest`, so `--build-only` and `--run-only` moved together.
  2. **`close(-1)` answered 0 on Windows and -1 everywhere else.** `lib/sys_windows.mc`'s `close`
     handed anything outside 0..2 to `CloseHandle`, and `(HANDLE)-1` is not only
     `INVALID_HANDLE_VALUE`: it is the **pseudo-handle** `GetCurrentProcess()` returns, and
     `CloseHandle` on a pseudo-handle SUCCEEDS -- so `tests/mc/093-i32-return.mc` printed
     `-1 44 -32768 1 0` where the four other targets print `-1 44 -32768 1 1`. A defect of the
     LAYER, not of the test (a POSIX close of an invalid descriptor is -1/EBADF): `close` now
     refuses a negative descriptor itself, with the pseudo-handle reason on the line.
     `lib/sys_windows_host.mc` needed nothing -- it `#include`s `lib/sys_windows.mc` and has no
     `close` of its own. 093's header carried the false claim in prose and was corrected with the
     fix. **Only the Windows runners can prove the new behaviour**; here it is proved to compile,
     to link in every mode, and to change nothing else.
  3. **The gate.** The default mode of `scripts/test-windows.sh` linked THREE objects out of
     forty -- one per mode -- so a test in the wrong mode was invisible locally. An undefined
     symbol is a property of the pair `(object, mode)` and `lld-link` is on this machine, so the
     default mode now links **every object in the manifest with its recorded mode**, keeps the
     `IMAGE_FILE_MACHINE_*` assertion per linked `.exe` and reports the count: **40 executables
     linked for windows/aarch64, 38 for windows/x86_64**, nothing executed. Proved to have teeth
     by putting 073 back in the `self` list -- `make test-windows` then fails with the exact CI
     message and passes with the classification fixed. The `--run-only` half is unchanged.
     Widening it paid twice: it reported `undefined symbol: GetFileAttributesA` on a
     `build/sysroot/windows-aarch64` populated BEFORE M45 added that name, so
     `scripts/sysroot-windows.sh` now compares the generated `kernel32.def` with the one on disk
     instead of caching on the mere existence of `kernel32.lib` (CI never saw it: it builds the
     sysroot fresh every run).
  -- `make bundle` re-run BEFORE bootstrapping (`lib/sys_windows.mc` is bundled as `sys_windows`):
  78 files, raw 872055 -> LZ 407340, blob 408293 B. `make check` green end to end (**RC 0, zero
  FAIL**): `budget` 2848/3000, `test` 32/32, `check-lex` 126/126 (2 skipped), `check-ast` 126/126,
  `check-asm` 126/126, `check-obj` **32/32 identical to the frozen seed**, `check-bundle`,
  `bootstrap` at a fixed point (`mc2.o == mc3.o`, 941880 B; the `--dump-asm` diff between `mc1`
  and `mc2` is **empty**), `check-surface` 32/32 + 139 ok lines, `test-exe` 32/32, `check-mc`
  11/11, `check-standalone`, `check-parts`, `check-toml` 10/10, `check-build` 53/53,
  `check-sysroots` (13 rows), `check-stubs` 9/9, `check-limits` 17/17 under 90%, `check-minimal`,
  `test-linux` 39/39, `test-linux-x86_64` 36/36, `test-linux-exe` 42/42 musl + 42/42 gnu,
  `test-linux-x86_64-exe` 39/39 + 39/39, **`test-windows` 40/40 objects and 40 linked**,
  **`test-windows-x86_64` 38/38 and 38 linked**, `check-examples`, `check-lang`, `check-conc`,
  `check-desktop`, `check-float`, `check-wide`, `check-kernel` (`kernel.bin` 3304 B),
  `check-avr`, `check-docs` (188 symbols, 22 flags, 20 TOML keys, 10 directives, 48 samples,
  287 links), `site` 85 pages + `check-site` 0 link problems. `make check-linux-host` RC 0 over
  all four cells (aarch64 musl 39/39 and gnu 40/40, x86_64 musl 36/36 and gnu 37/37), each after
  its own `mc2l.o == mc3l.o` and with the cross proof green.
  `scripts/check-inert.sh build/mc1.pre build/mc1` (pre = the branch's HEAD before this batch):
  **33 objects identical** (`tests/*.mc` + `src/mc.mc`) and byte-identical artefacts for
  `examples/api`, `lang`, `conc`, `desktop` and `kernel` -- the change is in `lib/` and in a
  script, and the compiler emits exactly what it emitted.
  The five goldens rewritten **once**, each only after its own criterion -- the blob is the only
  thing that moved: `mc2.sha256` `90ce56dc...35ee38` ->
  `922c9feea7b755c03dc06fbdb4bb8067d4badff87438956ef7319cd3c2e2a444` (empty `--dump-asm` diff +
  `cmp build/mc2.o build/mc3.o`); the Linux pair deleted and re-recorded by
  `make check-linux-host` -- `mc2-linux-arm64.sha256`
  `957067bb9a8ca5d06c944f57b6a3944e43cf11077cc9e9597c0c8423e54fbd39`,
  `mc2-linux-x86_64.sha256`
  `26b1183013227288e1439cd2ada1a9c644fc729f7d453a5fd0e2a700725464aa`, each recorded in its musl
  cell and re-verified by the gnu cell of the same architecture; the Windows pair cross-computed
  per `tests/golden/README.md` -- `mc2-windows-arm64.sha256`
  `979336224f09e50f1b3cae3deb38984897aea55451950dca91519b256fbfa728` (959711 B),
  `mc2-windows-x86_64.sha256`
  `e4aa4ebe060c4ad36f55af6c5e19257aa38fdca78e731da834d040f3ee74cdcb` (979195 B), both also
  written byte for byte by `build/mc2`.
- M43 step A ✔ (`docs/specs/M43.md` § Implementation notes -- step A): **the syscall shim, the
  number tables and `<mc/core_sandbox>`**, proved before anything uses them (the M39/M42 probe
  discipline). `src/sysno.mc` (the `SN_*` enum, 60 names + `SN_ABSENT`) shared by the four host
  files -- ONE file, not four copies (deviation 1); `src/sysno_linux_aarch64.mc` (`sys6` as eight
  `#opcode` words, `mov x8,x0` first so the number is read before x0 moves) and
  `src/sysno_linux_x86_64.mc` (six `emit()` words = the 24 bytes `llvm-mc` assembles for
  `mov rax,rdi ... mov r9,[rbp+16]; syscall`, verified BEFORE the file was written); the host layer
  gained `host_syscall6`, `host_sysno(sn)` (the per-architecture table read, so `sandbox.mc` names
  no number and does no offset access) and `host_sandbox_supported()` (macOS/Windows answer -38 /
  an all-absent table / 0). `src/core_sandbox.mc` is the sixth part; `src/sandbox.mc` holds the
  option parser, `check` and the refusals (macOS/Windows: the Lima command, exit 126 for all three
  verbs; Linux `run`/`exec`: `not in this step`, exit 126). `scripts/check-shim.sh`
  (`make check-shim`): `getpid` through the shim == libc's, `openat` of a missing file == -2, a
  `write`, and a six-argument `mmap` at offset 4096 -- the only proof that parameter 7 reaches the
  kernel -- **rc 0 on linux/aarch64 (Lima mc-k7) and linux/x86_64 (the VPS), root and unprivileged**.
  `check-surface` asserts the eight AArch64 words, `check-parts` the six x86-64 words and that
  `<mc/core_min>` + `<mc/core_sandbox>` stands alone.
  **What did not survive contact with the kernel** (Ubuntu 26.04, 7.0.0-30, both arches):
  (1) with `kernel.apparmor_restrict_unprivileged_userns = 1` an unconfined process's
  `unshare(NEWUSER|NEWNS|NEWPID|NEWNET|NEWIPC|NEWUTS)` SUCCEEDS -- the kernel transitions it into
  the `unprivileged_userns` profile and the denial comes at the box's first `mount` (EACCES,
  `capable sys_admin` in dmesg) and at `sethostname` (EPERM); so `userns:` is a TWO-stage probe
  (unshare, then a mount in the child's private namespace), the step-B supervisor's first
  diagnostic is `cannot mount: EACCES`, and a deployment's AppArmor profile must grant `userns,`
  AND `mount,`. The sysctl = 0 cell is unmeasured here (the CI cell will close it).
  (2) `/proc/filesystems` lists only LOADED filesystems: the VPS has `overlay.ko.zst` and no engine
  that loaded it, and a child user namespace cannot `request_module`, so `check` says
  `overlay: not loaded (modprobe overlay)`. (3) Landlock is ABI 8 on this baseline (floor 4).
  (4) `check` exits 126, not 1, where the sandbox is refused outright. (5) **`MAXGLOBALS` of the
  frozen seed is the tight row: 420/512 -> 437/512 (85%)**, `check-limits` fails at 90% (460), and
  step B adds the BPF builder, the notif records and the profiles -- so the sandbox state lives in
  ONE arena record with accessors, at most 12 new globals, and the two ELF writers (87 globals
  between `backend_elf_exe`/`backend_exe`/`backend_elf`) are the global diet to take when needed.
  -- `stage0/`, `lib/`, `tests/*.mc` untouched; `make bundle` re-run (83 entries); `make check`
  RC 0 (`check-lex`/`ast`/`asm` 131/131, `check-obj` 32/32, fixed point 976696 B, `check-limits`
  17/17, four Linux cells RC 0, `check-docs` 191 symbols / 32 flags); `check-inert` identical
  everywhere (a registered subcommand emits nothing). Goldens rewritten once: `mc2.sha256`
  `aab9ae12a7ba7904f6667f45fe63460974295a12d0dd5f21c359b3ed6b97bd79`, Linux
  `57a959a5…28b613` / `ae26b4cb…224555`, Windows `938c4e93…568a25` / `04642639…4860d2`.
- `continue N` done (coop patch for teko/ngen, owner-approved): **the mirror of `break N`.**
  `stage0/` untouched (2848/3000). `continue;` has meant "the innermost loop" since the core had
  loops and `break N;` has had a level since M2; the consumer lowers a switch as a ONE-ITERATION
  `loop` whose arms leave it, so an arm that wants the enclosing loop's next round had no way to
  say it -- `break` falls into the code after the switch, `continue` restarts the switch itself.
  * **The level is stored only when it was written.** `src/parse.mc` reads an optional `T_INT`
    after `continue` and leaves `nd_val` at **0** when there is none, so a plain `continue;`
    builds the node the pre-level compiler built, byte for byte, and `dump_node` (which prints
    `val=` only when it is non-zero) prints nothing for it. `src/gen_walk.mc` reads 0 as 1. That
    is the whole inertness argument: `break;` defaults to 1 in the parser and can, `continue;`
    cannot, because 0 is what "absent" has to mean on a node the seed also builds.
  * Diagnostics: `continue expects a positive level` from the parser (`continue 0;`, at the
    statement's position, the `break 0;` message mirrored) and `continue out of range` from the
    walker (the depth is only known while lowering, like `break out of range`).
    `continue outside loop` is untouched and still comes FIRST, because it says the more useful
    thing when there is no loop at all.
  * **Cost: 23 added lines in `src/`, 11 of them neither comment nor blank** (`parse.mc` +15/7,
    `gen_walk.mc` +8/4, one of those four being the changed `lcont_at(nloops - lv)`).
  * Two modules read a jump's level to decide how many scopes to release and both tested for
    `N_BREAK` before reading `nd_val`, so a `continue N` would have released one loop's worth
    instead of N: `examples/lang/lang_stmt.mc` and `examples/conc/conc_stmt.mc` now read the value
    for either jump and clamp it, which is inert for every source that writes no level (0 clamps
    to 1, exactly what the old code hardcoded) -- `check-inert` proves it on both examples.
  Proofs: `tests/mc/094-continue-level.mc` (the consumer's shape: a one-iteration inner loop used
  as a switch, `continue 2` from an arm, the outer loop advancing and the statement after the
  switch skipped) and `tests/mc/095-continue-one.mc` (`continue 1;` == `continue;`, and a level
  counts enclosing LOOPS and not enclosing blocks -- `continue 3` from inside two `if` blocks).
  Both are portable to all five targets, picked up by the `tests/mc/0[89]*` globs in
  `scripts/test-linux.sh` and `scripts/test-windows.sh` and by `scripts/check-mc.sh`, which also
  asserts that the frozen seed REFUSES them (`expected ; after continue`) -- the reason they live
  in `tests/mc/`. `tests/err/075-continue-zero.mc` and `076-continue-range.mc` are asserted with
  their exact message in `scripts/check-surface.sh`, with the DEFAULT compiler (the feature is
  core, not taught, so `err_case` gained an optional third argument).
  -- `make bundle` re-run before bootstrapping (86 files, raw 1028411 -> LZ 482665, blob 483745 B).
  `make check` green end to end (**RC 0, zero FAIL**): `test` 32/32, `check-lex`/`check-ast`/
  `check-asm` 135/135 (2 skipped), `check-obj` **32/32 identical to the frozen seed**,
  `check-bundle`, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 1108184 bytes; the `--dump-asm`
  diff between `mc1` and `mc2` is **empty**), `check-surface` 32/32 + the two new `err_case` rows,
  `test-exe` 32/32, `check-mc` **15/15** (11 tests + 4 seed refusals), `check-standalone`,
  `check-parts`, `check-toml`, `check-build` 53/53, `check-stubs` 9/9, `check-limits` 17/17 under
  90%, `check-minimal`, `test-linux` 41/41 and `test-linux-exe` 44/44 musl + 44/44 gnu,
  `test-linux-x86_64` 38/38 and 41/41 + 41/41, `test-windows` **42/42** and
  `test-windows-x86_64` **40/40** objects cross-compiled (094/095 among them), `check-examples`,
  `check-lang`, `check-conc`, `check-desktop`, `check-float`, `check-wide`, `check-kernel`,
  `check-avr`, `check-sandbox` 55 ok, `check-docs` (196 symbols, 33 flags, 20 TOML keys, 10
  directives, 51 samples, 320 links), `site` + `check-site`. `make check-linux-host` RC 0 over all
  four cells (fixed point `mc2l.o == mc3l.o`, 1394856 B on aarch64 and 1303384 B on x86_64; suites
  41/41 and 38/38 musl, 42/42 and 39/39 gnu native; the cross proof green on all four).
  `scripts/check-inert.sh build/mc1.pre build/mc1` (pre = a `mc1` built from `origin/main`):
  **33 objects identical** (`tests/*.mc` and `src/mc.mc`) plus byte-identical artefacts for
  `examples/api`, `lang`, `conc`, `desktop` and `kernel` -- the corpus writes no level, so nothing
  it emits could move.
  The five goldens rewritten **once**, each only after its own criterion: `mc2.sha256`
  `aab9ae12...b97bd79` -> `897b18875ff43f3baee95036db3651269ed2dba4c764185a12882b43c5fcdf7d`
  (after the empty `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`); the Linux pair deleted and
  re-recorded by `make check-linux-host` -- `mc2-linux-arm64.sha256`
  `3544cfff8f7fa37710ccd65e76d952d4e3dfdbbc753706e301d02f83a6199e31`,
  `mc2-linux-x86_64.sha256`
  `0888bb6627ca2e778e54522794337bc6c0ec842decbb07f156fa3976ee41cef2`; the Windows pair
  cross-computed per `tests/golden/README.md` -- `mc2-windows-arm64.sha256`
  `b4b7bbc873f4a28865492c44a9992e09d279191bddb3f348c5a8fb78523b44f0` (1129998 B),
  `mc2-windows-x86_64.sha256`
  `7fe8f0832ebe7cc3a037d76e142c20435e015fe109edf2de51bb01cb51923e06` (1158890 B), both also
  written byte for byte by `build/mc2`.
  Docs: `docs/reference/language.md` § 3 (the grammar and the three messages),
  `docs/reference/diagnostics.md` (two new rows), `docs/core-language.md` (including what a level
  means inside a prelude `for`, whose step it skips for the same reason a bare `continue` does --
  measured, not assumed), `docs/guide/10-single-file.md`, `docs/reference/objects.md`, and
  `docs/reference/hooks.md` § `on_jump`, which is where the 0 matters to somebody else: the hook
  sees the `N_CONTINUE` **before** any level check, so a handler reading its level must read 0 as 1
  and may see a level the function's loop depth does not support.
- `syntax_type` done (coop patch for teko/ngen, owner-approved): **a module participates in the
  TYPE position.** `stage0/` untouched (2848/3000). The sibling of M41.5's `syntax_param`, and it
  comes from the same consumer: `T[]`, an element type spelled by the CORE and a container spelled
  by the module. `type_new` cannot buy it -- the word that opens the type is `i64`, and `word_add`
  refuses the core type words, so no keyed table can ever fire there.
  * **`void syntax_type(uptr fn)`** (`src/hooks.mc` +47/19 code, arena tag `T_SYNTYPE` after
    `T_SYNPARAM` -- `T_COUNT` 39 -> 40, `lim_names`/`lim_seeds` reconciled BY NAME, the M42
    lesson, and `mc limits` gains a `syntax_type` row). Handler `i64 f(i64 ty)`: it receives the id
    the core just read, may consume a SUFFIX it owns (`[]`, `?`, `*`) and answers another type id,
    typically one of its own `type_new`; **0 = "not mine"** and the core keeps `ty`. Registration
    order, first non-zero wins, and `nsyntype == 0` short-circuits the whole thing.
  * **One helper, six call sites** (`src/parse.mc` +59/28 code): `take_type(ty)` consumes the type
    word -- the `next()` each site used to make for itself -- and then offers the position to the
    chain, so `p_type()`, a local (`parse_var`), a cast, a parameter (`parse_params`), an `extern`
    and a top-level declaration are one line each and cannot drift apart.
  * **Three guards**, at the TYPE WORD's own position (the word is copied out before `next()`
    moves off it) and run ONCE after the whole chain, not per handler -- the post-M41.5 review's
    rule, which is why the broken fixtures are registered LAST:
    `syntax_type handler consumed tokens and returned 0: <word>` (declining is only sound from
    where the handler was called; otherwise the core reads the rest of the declaration from the
    middle of a type), `syntax_type handler consumed no tokens: <word>` and `syntax_type handler
    returned an invalid type: <word>` (`< 0` or `>= type_count()`; that id goes straight into
    `type_width`/`type_align`/`type_kind`).
  * **Cost: 126 added lines in `src/`, 61 of them neither comment nor blank** (`parse.mc` +59/28,
    `hooks.mc` +47/19, `arena.mc` +20/14, twelve of those last being the renumbered tags and the
    two seed rows). Three new globals -- the seed's `MAXGLOBALS` goes from 432/512 to **435/512
    (84%)**.
  * **The contract the teko session asked about, now written down** (`docs/reference/hooks.md`
    § 3): `type_new(w)` and `syntax_expr(w)` on the same word coexist BY CONSTRUCTION -- `tok_add`
    is idempotent, the two tables are consulted at disjoint grammar positions, and the one place
    they meet (the cast `(w)`) resolves to the type because `parse_primary` tests `type_of_token`
    first.
  Proofs: `lib/user_syntax_demo.mc` teaches `i64[]` (`type_new("i64[]", 8, 8, TK_INT)` -- a
  pointer-sized handle, and a lexeme the lexer can never form, which is why the spelling is free)
  and `scripts/check-surface.sh` compiles one source that uses it in ALL SIX source positions --
  a global, an `extern`, a return type, a parameter, a local and a cast -- runs it (`40 + 2`
  through `memcpy`, exit 42) and counts the nine `type=i64[]` nodes in `--dump-ast`. `sd_param`
  now reads its type with `p_type()` instead of `p_next()`, which is what puts the parameter
  position on the same path; and because that handler claims every typed parameter, the CORE's own
  `parse_params` site is proved by a second module, `lib/user_typearr.mc` (12 lines, `syntax_type`
  and nothing else), which compiles the same source to the same 42 and the same nine nodes. The
  default compiler refuses both halves (`name expected at top level`, and `variable name expected`
  for `i64[] xs;` in a local). `tests/err/077-type-consumed-zero.mc`, `078-type-noadvance.mc` and
  `079-type-badid.mc` are asserted with their exact message (fixtures `sd_teat`/`sd_tnop`/`sd_tbad`,
  each keyed on a `u8`/`u16`/`u32` followed by `[`, a shape no ordinary source has).
  **Inert by construction**: `lib/user_type_nop.mc` + `lib/mc_type_nop.mc` -- a module whose ONLY
  registration is `syntax_type` and whose handler answers 0 for every type word -- produce
  byte-identical `--dump-ast` and objects over the whole `tests/` corpus.
  -- `make bundle` re-run before bootstrapping (86 files, raw 1036368 -> LZ 485658, blob 486738 B;
  the four new `lib/` fixtures are deliberately NOT in `tools/bundle.list`, the M41 precedent for
  check-script-only modules). `make check` green end to end (**RC 0, zero FAIL**): `test` 32/32,
  `check-lex`/`check-ast`/`check-asm` 139/139 (2 skipped), `check-obj` **32/32 identical to the
  frozen seed**, `check-bundle`, `bootstrap` at a fixed point (`mc2.o == mc3.o`, 1113264 bytes;
  the `--dump-asm` diff between `mc1` and `mc2` is **empty**), `check-surface` 32/32 + the six new
  `syntax_type` cases, `test-exe` 32/32, `check-mc` 15/15, `check-standalone`, `check-parts`,
  `check-toml` 10/10, `check-build` 53/53, `check-stubs` 9/9, `check-limits` **17/17 under 90%**,
  `check-minimal`, `test-linux` 41/41 and `test-linux-exe` 44/44 musl + 44/44 gnu,
  `test-linux-x86_64` 38/38 and 41/41 + 41/41, `test-windows` 42/42 and `test-windows-x86_64`
  40/40 objects cross-compiled, `check-examples`, `check-lang`, `check-conc`, `check-desktop`,
  `check-float`, `check-wide`, `check-kernel`, `check-avr`, `check-sandbox` 55 ok, `check-docs`
  (**197 symbols**, 33 flags, 20 TOML keys, 10 directives, 51 samples, 321 links), `site` 87 pages
  + `check-site` (0 link problems). `make check-linux-host` RC 0 over all four cells.
  `scripts/check-inert.sh build/mc1.pre build/mc1` (pre = a `mc1` built from `origin/main`):
  **33 objects identical** (`tests/*.mc` and `src/mc.mc`) plus byte-identical artefacts for
  `examples/api`, `lang`, `conc`, `desktop` and `kernel`.
  The five goldens rewritten **once**, each only after its own criterion: `mc2.sha256`
  `897b1887...5fcdf7d` -> `8a84d434a26ff6163149645b4390107543ae1e4b9c515ac84b001b1b868b918f`
  (after the empty `--dump-asm` diff and `cmp build/mc2.o build/mc3.o`); the Linux pair deleted and
  re-recorded by `make check-linux-host` -- `mc2-linux-arm64.sha256`
  `df620903bd5cd48a69c586d2583cdf04a7eae0cb92598b9a9a71e91b470053f6`,
  `mc2-linux-x86_64.sha256`
  `14dc5fc814f1c82a59561b99b91313473032194aa976a75e003a649266d0c793`; the Windows pair
  cross-computed per `tests/golden/README.md` -- `mc2-windows-arm64.sha256`
  `7711f4866bda984f75029f0bcafa0c24b7b9ba729ae781e1956616604704263b` (1135198 B),
  `mc2-windows-x86_64.sha256`
  `d733d2aa7f07fda9fb551384a80084e8da2870c70b01a540fe7c5bde609f2b08` (1163986 B), both also
  written byte for byte by `build/mc2`.
  Docs: `docs/reference/hooks.md` (§ 3 is now six word registrations + **five** hooks that claim
  none, the `syntax_type` section with the six sites and the three guards, and the coexistence
  contract), `docs/reference/diagnostics.md` (three rows), `docs/surface.md` (the nine
  registrations, and a § "The type position"), `docs/reference/language.md` § 2 ("A suffix on a
  type word the core owns").
- M44 step 1 ✔ (`docs/specs/M44.md` § Implementation notes -- step 1; decision D20, the architect's
  addition (f)): **the baked version.** `src/version.mc` (`uptr mc_version()` = the literal
  `0.0.0-dev`, the sentinel; 33 lines, one of code), included by `src/core_min.mc` before `cli.mc`
  and bundled as `mc/version` -- so a taught compiler reports the version of the binary that built
  it, proved in both directions (`0.0.0-dev` -> `0.0.0-dev`, `9.9.9` -> `9.9.9`); `mc --version`
  prints `mc <version>` (no `v`: the tag owns the `v`, and this is the string `release-assets.sh`
  and a future `[deps]` minimum carry); `scripts/set-version.sh VERSION` rewrites the one literal
  and runs `make bundle`, refusing anything but `X.Y.Z[-suffix]` -- it CANNOT delegate the whole
  string to `next-version.sh`, which rejects every suffix on purpose while the sentinel itself is
  suffixed (deviation 1); `scripts/check-bundle.sh` guards the sentinel (a tree where
  `set-version.sh` ran FAILS naming it, after the staleness check so a stale-and-versioned tree is
  reported as stale first); `release.yml`'s "Build the compiler" split in three (seed, bake, build)
  so all five shipped binaries carry the tag from one call. Cost: **53 added lines in `src/`, 9 of
  them code**; globals unchanged at 432/512 (a string literal, not a global). `make check` RC 0
  (`check-obj` 32/32, fixed point 1109608 B, `check-docs` 196 symbols / 34 flags), four Linux cells
  RC 0, `check-inert` identical everywhere. Goldens rewritten once: `mc2.sha256`
  `8e5e127dd96e0d125fd8757b662e6bca61b661d415cdd7349afc9791be14e544`, Linux `6002790c…344380` /
  `1ca2ea58…b15516`, Windows `478e2f28…a50520` / `6d49bfc6…3e70f05`.
- Next: **M44** (packages, `docs/specs/M44.md`), then **M42 step 2** (PE `--exe`, CI-gated on the
  Windows runners). **M46** only on the owner's request; **M43 Layer 2** after 1.0.0. M13 and M18
  stay in the backlog (`docs/specs/M13.md`: sizing a program's memory at compile time -- the fixed
  4 MiB arena in `examples/api/lib/rt.mc` is one more motivating case; M18 is Linux x86 32-bit).
  Update this section when each milestone closes.
- i18n done (2026-09-03): the repository is fully in English — diagnostics, program/script
  output, identifiers, comments, and docs (`docs/*.md`, `docs/specs/*.md`, `CLAUDE.md`,
  `.claude/agents/*.md` re-synced to match `scripts/i18n-map.tsv`/`scripts/i18n-idents.tsv`).
  Language keywords were already English and untouched.
- CI (2026-09-03): `.github/workflows/` ci/tag/release/site; first run green (`make check` on macos-15 in 41 s, Linux arm64 suite native on ubuntu-24.04-arm in 28 s); site live at https://minicompiler.dev (rendered by `mcsite` since M27). See `docs/ci.md`.
