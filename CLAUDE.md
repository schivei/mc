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
- Next: M18 or M24 (`docs/plan.md`); M40 (the word-size sweep AVR/PIC need) is
  named in `docs/plan.md`; M13 stays in the backlog (`docs/specs/M13.md`:
  sizing a program's memory at compile time — the fixed 4 MiB arena in `examples/api/lib/rt.mc` is
  one more motivating case).
  Update this section when each milestone closes.
- i18n done (2026-09-03): the repository is fully in English — diagnostics, program/script
  output, identifiers, comments, and docs (`docs/*.md`, `docs/specs/*.md`, `CLAUDE.md`,
  `.claude/agents/*.md` re-synced to match `scripts/i18n-map.tsv`/`scripts/i18n-idents.tsv`).
  Language keywords were already English and untouched.
- CI (2026-09-03): `.github/workflows/` ci/tag/release/site; first run green (`make check` on macos-15 in 41 s, Linux arm64 suite native on ubuntu-24.04-arm in 28 s); site live at https://minicompiler.dev (rendered by `mcsite` since M27). See `docs/ci.md`.
