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
  section with more than 65535 relocations is refused with a message instead of written wrong.
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
- Next: M18/M20 or M24 (`docs/plan.md`); M13 stays in the backlog (`docs/specs/M13.md`:
  sizing a program's memory at compile time — the fixed 4 MiB arena in `examples/api/lib/rt.mc` is
  one more motivating case).
  Update this section when each milestone closes.
- i18n done (2026-09-03): the repository is fully in English — diagnostics, program/script
  output, identifiers, comments, and docs (`docs/*.md`, `docs/specs/*.md`, `CLAUDE.md`,
  `.claude/agents/*.md` re-synced to match `scripts/i18n-map.tsv`/`scripts/i18n-idents.tsv`).
  Language keywords were already English and untouched.
- CI (2026-09-03): `.github/workflows/` ci/tag/release/site; first run green (`make check` on macos-15 in 41 s, Linux arm64 suite native on ubuntu-24.04-arm in 28 s); site live at https://minicompiler.dev (rendered by `mcsite` since M27). See `docs/ci.md`.
