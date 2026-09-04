# Plan: `mc` — a self-hosting mini compiler, teachable via its surface

Read `docs/plan.md` before any work: it fixes the language, the teaching surface, the
architecture, the budget, and the milestones. This file just summarizes the operating rules.

## Context

Empty repository (`main` with no commits). The goal is a compiler that is deliberately **tiny**
at its core — basic types, an opaque pointer, arithmetic/logic, bitwise/shift, `loop {}` — whose
distinguishing feature is **teaching tooling via the surface**: the source code itself registers
new lexemes/tokens, extends the parser, operates on the AST, and emits object-file bytes saying
which section/symbol they go into.

Decisions fixed with the user:

| Decision | Choice |
|---|---|
| stage0 host | **C23**, as small as possible, compiled by clang **exactly once** |
| Critical requirement | Stage1 onward is **self-hosted**: never uses gcc/cc/clang again |
| Initial target | **AArch64 + Mach-O** (this machine: darwin arm64, Xcode 26 / ld-1267) |
| Extension | **Via the surface**, in the language itself; other ISAs/outputs are taught this way later |
| Output | Phase 1: `.o` (MH_OBJECT) + Apple's `ld`. Phase 2 (post fixed point): direct executable with an ad-hoc signature |
| Syntax | **"schoolbook C / Arduino C"**: `type name`, no `fn`/`->`/`:`; a **single, opaque `uptr`** pointer (no `*` sigils); `#...` directives to teach the compiler |
| External references | Write everything from scratch in this repository |

Organizing thesis: **stage0 doesn't need to compile "the language"; it needs to compile one
program — `src/mc.mc`.** Every scope question is answered with "does this appear in the
compiler's own source?".

Name: `.mc` files, `mc` binary.

---

## The language, by example (this is what stage0 compiles)

```c
#include "sys.mc"                 // textual include, once-only

#define HEAP_SIZE 1048576         // constant folded at compile time (constant expressions only)

u8  heap[HEAP_SIZE];              // global array = reservation in __bss; the name is worth a uptr
i64 hp = 0;                       // global in __data

uptr alloc(i64 n) {
    uptr p = heap + hp;           // uptr is opaque: byte arithmetic, no scaling
    hp = hp + ((n + 7) & ~7);
    return p;
}

i64 fib(i64 n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

void putnum(i64 v) {
    u8 buf[24];                   // local array = space in the frame
    i64 i = 24;
    loop {
        i = i - 1;
        st8(buf + i, '0' + v % 10);   // memory access by explicit width
        v = v / 10;
        if (v == 0) break;
    }
    write(1, buf + i, 24 - i);
}

i64 main(i64 argc, uptr argv) {
    uptr first = ld64(argv);      // argv[0] with no sigil: ld64 reads 8 bytes at argv
    putnum(fib(24));              // prints 46368
    write(1, "\n", 1);            // string literal is worth a uptr into __cstring
    return 0;
}
```

### Core — what stage0 implements (and nothing else)

**Types (7 words):** `u8 u16 u32 u64 i64 uptr void`. `i64` is the working integer type; `u8` for
bytes; `u16/u32` because Mach-O fields require them (`n_desc`, `n_strx`); `uptr` is the only
pointer — opaque, no pointee type, byte arithmetic. No `i8/i16/i32`, no float, no bool
(comparisons yield `i64` 0/1). Comparisons are always signed (addresses < 2^63; documented,
not enforced).

**Memory (intrinsics, not syntax):** `ld8 ld16 ld32 ld64` (read, zero-extend) and
`st8 st16 st32 st64(p, v)` (write); `&x` gives the `uptr` of a local/global; an array name decays
to `uptr`. No `*p`, no `p->f`, no `p[i]`.

**Operators:** `+ - * / %` · `& | ^ ~ << >>` (`>>` arithmetic only on `i64`) ·
`== != < <= > >=` · `&& || !` **with short-circuit evaluation** (required:
`p != 0 && ld8(p) == 'x'`) · unary `-` and `&` · C-style cast `(u32) x` (unambiguous: a type
keyword always follows `(`) · assignment is `=` only.

**Control:** `if (c) stmt [else stmt]`, `loop { }`, `break;` / `break 2;` (N levels, no labels
needed), `continue;`, `return [e];`. No `while`/`for`/`switch`/`goto` — those come from the
prelude.

**Declarations (schoolbook C):** `type name(type a, ...) { }` (max. 8 params → never passes an
argument on the stack; exceeding it is an error; no varargs); `type x = e;` local; `type x[N];`
local/global array (N constant); top-level globals with a constant initializer;
`extern type name(type a, ...);` (undefined symbol — this is how `write`/`open` from libSystem
come in; the compiler prefixes `_`). Two top-level passes → mutual recursion without forward
declarations.

**Literals:** decimal/hex integer, char `'a'` `'\n'`, string (goes to `__cstring`,
NUL-terminated).

**Allocation:** a static `u8 heap[...]` arena in `__bss` + bump pointer, no `free`. Comes zeroed
by the kernel. No malloc, no mmap.

**I/O:** only what's in `lib/sys.mc`: `open read write close exit`. Default impl = libSystem
`extern`; alternate impl via `#opcode svc` (number in `x16`, `svc #0x80`;
`SYS_exit=1 read=3 write=4 open=5 close=6`, verified against the SDK's `sys/syscall.h`), selected
by a flag.

**Mandatory style for `mc.mc`:** never a raw `ld64(n + 16)` in the middle of the code; always
`#define NODE_LHS 16` + accessors `node_lhs(n)` / `set_node_lhs(n, v)`. When `struct` arrives via
the surface, you swap 20 accessors, not 3,000 call sites.

Core lexemes: 7 types + `if else loop break continue return extern` + directives
`#include #define #token #infix #prefix #rule #section #opcode` + punctuation
`( ) { } [ ] , ;` + the operators above. Everything else is taught.

---

## Teaching surface (Tier 1 — already works in the C stage0)

Preprocessor-style `#...` directives, processed **at compile time, in order of appearance**,
mutating the core's tables:

```c
// 1. Lexer: new lexeme (sequential id >= 256, matched by longest prefix)
#token "<=>"
#token "+="

// 2. Expression parser: Pratt table. $1/$2 are the operands; the expansion is
//    parsed right away and becomes an AST with holes.
#infix  "<=>" 6 left   cmp3($1, $2)
#prefix "~~"           bitrev($1)

// 3. Statement parser: flat pattern -> template. Each item is a literal token
//    or "nt $name" (nt: expr | stmt | block | ident | type), read as a C parameter.
//    The 1st item is always a literal token: rules are indexed by it (zero backtracking).
#rule stmt: while ( expr $c ) block $b
    => loop { if (!$c) break; $b }

#rule stmt: for ( stmt $init expr $cond ; ident $i = expr $step ) block $b
    => { $init loop { if (!$cond) break; $b $i = $step; } }   // the step is an assignment: in the core `=` is a statement

#rule stmt: ident $x += expr $e ;
    => $x = $x + $e;

// 4. Placement: everything emitted afterward goes to this section until the next #section
//    ("say where they go"). Default: __TEXT,__text for code, __DATA,__data
//    for initialized globals, __DATA,__bss for arrays without an initializer.
#section __DATA __mytable 0
u64 table[64];

#section __TEXT __text 0x80000400

// 5. Encoders: teach one instruction. Called with constant arguments, it emits the
//    folded word directly into the current function's code stream.
#opcode mov16(rd, imm)   0xD2800000 | (imm << 5) | rd
#opcode svc(imm)         0xD4000001 | (imm << 5)

i64 sys_write(i64 fd, uptr buf, i64 n) {
    mov16(16, 4);            // x16 = SYS_write; x0..x2 already carry the args on entry
    svc(0x80);               // result ends up in x0, which is the return value
}

// 6. Raw bytes and relocations, for what #opcode doesn't cover:
//    emit(u32 constant); reloc(TYPE, "_symbol") binds a relocation to the next word.
void call_helper() {
    reloc(BRANCH26, "_helper");
    emit(0x94000000);
}
```

Rules that keep the mechanism small:
1. A `#rule` pattern is a flat sequence — no alternation, optional items, or recursion in the
   pattern.
2. The first item is a literal token (optionally preceded by a single `ident $x`, already read
   via the normal path) → indexed by token, no backtracking.
3. The template is parsed by the existing parser at definition time (`$name` becomes `Hole(i)`);
   expansion is a tree copy — never textual substitution, so there are no precedence bugs.
4. Hygiene: gensym only — `$$tmp` in the template becomes a fresh local per expansion. Nothing
   else.
5. Re-expansion of the result, capped at 64 levels.
6. Frame size is computed **after** expansion (gensyms are locals).
7. `#define` is a folded constant, not a textual macro; `#opcode` only accepts constant arguments
   (otherwise it's an error).

**Tier 2 — programmatic (stage1+, zero cost in C):** since the compiler is written in `.mc`, a
new AST pass or backend is a `.mc` module included via `#include` that calls `pass(fn)` /
`backend("name", fn)` at init time. Recompiling `mc` with that module **is** teaching the
compiler. No interpreter, no dylib, no plugin ABI. The AST is flat data in an arena with
`#define` offsets, and the output primitives are ordinary functions: `sec_new(seg, sect, flags)`,
`sym_def(name, sec, off, global)`, `reloc_add(sec, off, sym, type, pcrel, len)`,
`emit_u32(sec, w)`. A surface backend is just code that calls them.

---

## Architecture

```
 L1  surface (.mc)       #token #infix #prefix #rule #section #opcode  emit() reloc()
                         + .mc modules with pass()/backend()  (stage1+)
 ───────────────────────────────────────────────────────────────────────────────────
 L0  core                lexer w/ mutable token table
     (stage0 in C,        table-driven Pratt + statements + #rule expander
      later in mc.mc)     flat AST in arena → minimal type checking
                         linear instruction buffer → AArch64 encoders → Mach-O writer
```

### Repository layout

```
mini_compiler/
  Makefile                    targets: stage0, test, bootstrap, budget
  stage0/                     C23, <= 3000 lines (checked in CI); only open/read/write/close/exit from libc
    arena.c  lex.c  parse.c  ast.c  types.c  gen_arm64.c  macho.c  main.c  mc.h
  lib/
    sys.mc                    open/read/write/close/exit (extern libSystem by default; #opcode svc behind a flag)
    prelude.mc                while/for/+=/-=/++/-- via #rule (M9) — only via explicit #include, versioned
  src/                        self-hosted compiler (same split as stage0)
    mc.mc  lex.mc  parse.mc  ast.mc  types.mc  gen_arm64.mc  macho.mc  obj.mc
  tests/
    NNN-name.mc              header `// expect-exit: N` / `// expect-stdout: ...`
    golden/                   SHA-256 of mc2.o
  scripts/
    build-stage0.sh  test.sh  link.sh  bootstrap.sh  loc-budget.sh
  docs/
    core-language.md  surface.md  determinism.md  macho-notes.md
```

stage0 budget (target <= 3000 lines): lexer + token table 350 · Pratt + table 250 · statements +
`#rule` 400 · `#define/#section/#opcode` + constant folder 150 · types 150 · symbols 200 ·
instruction buffer + ~40 encoders 700 · Mach-O 550 · driver/arena/errors/dumps 250.

### Codegen and Mach-O

- **No IR.** AST → linear buffer `{opcode, operands, label}` → encoders. Needed anyway (for
  branch fixups), gives `--dump-asm` for free, and is the seam where `#opcode`/`emit()` and a
  surface backend plug in.
- **Registers by depth:** expression-stack depth is static (statements != expressions — a
  documented invariant). Depth 0..6 → `x9..x15`; >= 7 spills to the frame. Locals and local
  arrays are **always** on the frame, addressed as `[sp, #k]` (positive offset, resolved once the
  frame size is known; equivalent to `[x29, #-k]` but covers the full 4095 bytes with scaled
  `ldr/str` — `[x29,#-k]` would need 256-byte `ldur/stur`). Before a `bl`: spill whatever is live,
  `ldr` the args into `x0..x7`, result in `x0`. Frame aligned to 16; `sub sp` capped at 4095 → a
  clear error.
- **Fixed prologue/epilogue:** `stp x29,x30,[sp,#-16]!; mov x29,sp; sub sp,sp,#N; str args` / the
  reverse + `ret`. Args are written to the frame but `x0..x7` stay intact → `#opcode`-only
  functions (like `sys_write`) see the arguments in the ABI registers.
- **Mach-O `.o`** (values verified against the SDK headers): `MH_MAGIC_64=0xfeedfacf`,
  `CPU_TYPE_ARM64=0x0100000C`, subtype 0, `MH_OBJECT=1`, flags
  `MH_SUBSECTIONS_VIA_SYMBOLS=0x2000`. Load commands: `LC_SEGMENT_64` (empty segname;
  `__TEXT,__text` flags `0x80000400`; `__TEXT,__cstring` `S_CSTRING_LITERALS`; `__DATA,__data`;
  `__DATA,__bss` `S_ZEROFILL`; plus whatever `#section` creates), `LC_BUILD_VERSION`
  (**mandatory** for the modern ld; platform 1, minos/sdk hardcoded), `LC_SYMTAB`, `LC_DYSYMTAB`
  (locals → extdefs → undefs, **stable** partition). `n_sect` is 1-based; strtab starts with
  `\0`, padded to a multiple of 8.
- **Relocations — four:** `BRANCH26=2` (bl), `PAGE21=3` + `PAGEOFF12=4` (adrp/add for strings,
  globals, arrays), `UNSIGNED=0` len 3 (pointers in `__data`); `ADDEND=10` precedes one when
  there's an addend. LE bitfield word `symbolnum:24 | pcrel:1 | length:2 | extern:1 | type:4`,
  emitted in decreasing address order.
- **Every field is written byte by byte with LE helpers** (`put_u32`, `put_u64`) — never
  `fwrite(&struct)`. Transliterates 1:1 to `.mc` (which has no struct).
- **Link:** `ld -arch arm64 -platform_version macos 13.0 <sdk> -syslibroot $(xcrun --show-sdk-path) -lSystem -o out out.o`
  in `scripts/link.sh`. `main(argc, argv)` arrives in `x0/x1`.

---

## Determinism (`docs/determinism.md`)

1. Never hash pointers; never iterate a hash table to produce output — a parallel array in
   insertion order.
2. Symtab via a stable partition; no `qsort`.
3. stage0's C I/O has the **same shape** as the `.mc` version (`open`/`read` in a loop/`close`),
   no `stdio`.
4. No `__FILE__`, date, absolute path, `N_OSO`/stabs, `ar`. `LC_BUILD_VERSION` hardcoded.
5. Zero every padding/alignment byte explicitly.
6. Reference build of stage0 with `-O1`; additional CI with
   `-O0 -fwrapv -fno-strict-aliasing -fsanitize=undefined,address`.
7. `--dump-tokens/--dump-ast/--dump-syms/--dump-asm` with deterministic text **since M1**.
8. Compare `.o` files, not linked executables. Versioned golden SHA-256 of `mc2.o`.

---

## Milestones

| # | Milestone | Acceptance | Where it usually breaks |
|---|---|---|---|
| **M0** | `stage0/macho.c` hand-writes a `.o` with `movz x0,#42; ret` in `_main` | `link.sh && ./t; echo $?` → `42` | missing `LC_BUILD_VERSION`, `n_sect` being 1-based, segment offsets |
| **M0.5** | same `.o` with `_start` + `svc #0x80` writing `hi` (link `-static -e _start`) | prints `hi` | syscall number, ld refusing a static link |
| **M1** | lexer + `#token` + Pratt + `#infix/#prefix` + `i64 main() { return 40 + 2; }` | exit 42; stable `--dump-tokens/--dump-ast` | sp alignment, x29/x30 |
| **M2** | locals, if/else, loop/break N, calls, recursion, `/ %`, local arrays, `ld*/st*` | `fib(24)` prints `46368` via `putnum` in `.mc` | calling convention, spilling before `bl` |
| **M3** | globals, global arrays, strings, `&x`, `#include`, `#define`, `extern`, arena | program opens its own source and prints the line count | sign extension, `u16/u32` alignment |
| **M4** | tokenizer written in `.mc` | own-source token histogram == the C stage0's | — (free cross-check) |
| **M5** | 4 relocations, `#section`, `#opcode`, `emit()`/`reloc()`; `sys.mc` via `svc` | `otool -r`/`nm` look sane; `sys_write` via `svc` runs | `PAGEOFF12` in `add` vs `ldr`, `r_extern` |
| **M6** | `src/mc.mc` complete, **core only** (no `#rule`, no prelude) → `mc1` | `mc1` passes the same suite as stage0 | everything — this is where the `--dump-*` flags pay off |
| **M7** | fixed point | `mc1 mc.mc → mc2.o`, `mc2 mc.mc → mc3.o`, `cmp` identical; golden recorded | table ordering, padding, short reads |
| **M8** | cut the cord | `make bootstrap` uses clang only for stage0; binaries not versioned; `loc-budget.sh` <= 3000 |
| **M9** | `#rule` in stage0 **and** in `mc.mc`; `lib/prelude.mc` with `while`/`for`/`+=`/`++` (`struct` deferred: it requires `type $t` and a layout, more than `#rule` delivers; accessors + `#define` cover the case) | a program with `while`/`struct` produces an **identical** `.o` under stage0 and `mc1`; migrate a leaf module of `mc.mc` and recheck M7 | expansion order, gensym |
| **M10** | backend taught via the surface: a `.mc` module with `backend("asm", fn)` emitting AArch64 text | the surface backend's `__text` byte-for-byte equal to the built-in one, across the corpus | insufficient emission primitives (which is what this milestone exists to discover) |
| **M11** | direct executable (`MH_EXECUTE`): `__PAGEZERO/__TEXT/__DATA/__LINKEDIT`, `LC_LOAD_DYLINKER`, `LC_LOAD_DYLIB libSystem`, `LC_MAIN`, binding `_open/_read/_write/_close/_exit`, ad-hoc `LC_CODE_SIGNATURE` (CodeDirectory v0x20400, SHA-256 per 4 KiB page, `CS_ADHOC`) | `mc --exe` runs without `ld`; `codesign -dvvv` valid; the fixed point still holds along this path | SHA-256 in `.mc` (~150 lines), `execSegBase/Limit`, bind opcodes |
| **M12** | Tier 3, `.mc` only: syntax hooks (`syntax`/`syntax_stmt` + the parser's public API), `type_alias`, `#dylib`; `examples/api` (HTTP + SQLite + `class`/`interface` taught by `oop.mc`) | `make -C examples/api test` green with an `--exe` binary; `make check` with `check-examples` | insufficient parser API; bind by ordinal; sockets |
| **M13** | (backlog) size the program's arena at compile time — profiling, annotation, or bound analysis (`docs/specs/M13.md`) | `--mem-report` + `HEAP_SIZE` written by the compiler | undecidable in general; only profiling is universal |

Non-negotiable order: **M6 and M7 before M9.** A prelude before the fixed point couples the two
hardest problems and blocks bisection.

---

## Verification

- `make stage0` — clang C23 (`-std=c2x -O1 -Wall -Wextra`) generates `build/mc0`;
  `make stage0-san` with sanitizers.
- `make test` — `scripts/test.sh <compiler>` compiles each `tests/*.mc`, links via `link.sh`,
  compares exit code/stdout against the header; runs with `mc0`, `mc1`, `mc2`.
- `make bootstrap` — `mc0 src/mc.mc → mc1` · `mc1 src/mc.mc → mc2.o` · `mc2 src/mc.mc → mc3.o` ·
  `cmp` · checks the golden hash.
- `make budget` — fails if `stage0/*.c` > 3000 lines.
- Manual inspection at the Mach-O milestones: `otool -hlv`, `otool -r`, `nm -m`,
  `codesign -dvvv` (M11).
- Divergence at M7: `diff <(mc1 --dump-asm src/mc.mc) <(mc2 --dump-asm src/mc.mc)` and bisect by
  function.

## Risks that kill the project (and the brake on each one)

1. `mc.mc` without accessors → M7 becomes unbearable. **Accessors from the first line.**
2. A prelude before the fixed point. **M9 only after M7.**
3. The surface mechanism turning into a Scheme. **3000-line cap in CI.**
4. `--dump-*` left for later. **It's in M1.**
5. Without M10, extensibility is just a hypothesis. **M10 is part of the scope.**
6. M11 (signing) delaying everything. **Stays behind the fixed point; `ld` remains a valid path.**

---

# Phase 2 — standalone distribution and cross-OS targets

Owner's direction (2026-09-03): a developer downloads the `mc` binary and compiles their own code
with no make/clang/gcc and without cloning this repository; everything the compiler needs is served
by the self-hosted binary. Programs must be buildable for other operating systems, with the
developer telling `mc` how (object format, linker, static libraries such as musl `libc.a` or mingw
`kernel32.lib`). A TOML definitions file is read by default. Bundled includes are resolved with
`#include <name>`, `#embed` (optionally compressed) is available to programs, and `mc` finds what to
compile with little ceremony.

## Principles carried over
- stage0 (C) stays the seed and is frozen except for bug fixes; every Phase 2 feature lives in
  `src/*.mc` (Tier 2/3 style), so the self-hosted `mc` grows while the C stays under budget.
- Determinism and the fixed point still gate every milestone (`make check`); the bundle is
  generated deterministically and checked in as source.
- Teaching by surface remains the extension mechanism: target-specific object writers are backends,
  system layers are `.mc` libraries, and configuration is data (TOML), not code.

## Target order decided by the owner (2026-09-03)
Linux arm64 -> Linux x86 (32-bit) -> Linux x64 -> Windows arm64 -> Windows x64, in stages. `mc`
itself keeps running on macOS arm64 for now (cross-hosting comes later with CI). Foreign targets are
produced as objects and linked by an external linker configured in the TOML (`ld.lld`, `lld-link`).
Linux binaries are executed for real in Docker (linux/arm64 native; amd64 via emulation).

Architect's caveat, to be decided when the stage arrives: 32-bit x86 is expensive for semantic, not
encoding, reasons — `i64` needs register pairs and `uptr` becomes 4 bytes, which breaks the
8-bytes-per-field layouts the language (and the compiler itself) assume. Recommended: x64 before x86,
and x86 only if still wanted afterwards.

## Rule for every change (owner, 2026-09-04)
Every pull request that touches `src/`, `lib/`, `examples/`, `stage0/` or `tools/` also updates
`docs/` (guide, reference or example pages); the `Docs updated` check enforces it and the site is
regenerated from `docs/` on merge. A change without documentation is not finished.

## Rule for every new target (owner, 2026-09-03)
A milestone that adds an OS or an architecture ships, in the same PR, its CI leg (a job that links
and RUNS the suite on a runner of that platform: `ubuntu-latest` for linux/x86_64, `windows-11-arm`
and `windows-latest` for Windows, node for wasm) and the architect adds that job to the `main`
branch protection as a required status check at merge time. No target is "supported" without a
gate.

## Milestones (specs in `docs/specs/M14.md`...)
| # | Deliverable | Acceptance |
|---|---|---|
| **M14** | Project driver + TOML: `mc build [dir]` reads `mc.toml` (`[project] entry/out/kind`, `[target] os/arch`, `[linker] cmd/args` with `{out} {obj} {libs}`, `[libs]` paths, `[externs] symbol-or-prefix = lib`, `[include] paths`, `[compiler] modules` to build a taught compiler first); TOML subset parser in `.mc` with line/column errors; externs' libraries from the TOML feed the same ordinal table as `#dylib` | `examples/api` builds and passes with `mc build` alone (no Makefile); `tests/toml/*` dumps match; `make check` green, golden rewritten once |
| **M15** | Bundled standard library + `#embed`: `#include <name>` served from a deterministic LZ-compressed bundle embedded in the binary (`tools/bundle.mc` generates `src/bundle_data.mc` from `lib/` and the compiler core; `<mc/core>` lets a taught compiler be built anywhere); `#embed name "file" [lz]` declares a byte array (+ sizes) for programs; `src/lz.mc` implements both directions | `mc` copied alone into an empty directory compiles a program using `<sys>`/`<prelude>` and a taught compiler from `<mc/core>`; `make bundle` is reproducible byte for byte; fixed point holds with the bundle |
| **M16** | Linux arm64: ELF64 relocatable writer (`R_AARCH64_CALL26`, `ADR_PREL_PG_HI21`, `ADD_ABS_LO12_NC`, `LDST*_ABS_LO12_NC`, `ABS64`), `<sys/linux>` (syscalls via `svc #0`, number in `x8`), `_start` shim or musl `libc.a`, linker invocation from TOML | the test suite compiled with `[target] os = "linux"`, linked with `ld.lld` + musl from Alpine, executed in Docker linux/arm64 with identical stdout/exit |
| **M17** | x86 family groundwork: split `gen_lower` into a target-independent walker (frames, depth stack, labels, calls) and a machine interface (~30 primitives) implemented by `arm64`; then the `x86-64` machine (SysV ABI, ModRM/SIB/REX encoder) as a `.mc` backend; ELF for Linux x64 executed in Docker linux/amd64 | suite green under emulation; arm64 objects unchanged byte for byte after the refactor |
| **M18** | Linux x86 (32-bit) — only if still wanted: `i64` via register pairs, `uptr` = 4 bytes, layout audit of the language and the runtime | suite green in Docker linux/386 |
| **M19** | Windows arm64: COFF writer (`IMAGE_REL_ARM64_BRANCH26/PAGEBASE_REL21/PAGEOFFSET_12A/ADDR64`), `<sys/windows>` on kernel32 (`WriteFile`, `ReadFile`, `CreateFileA`, `ExitProcess`), `lld-link` from TOML against mingw `kernel32.lib` | objects link; PE inspected with `llvm-readobj`; executed when a Windows host exists |
| **M20** | Windows x64: COFF x64 relocations + Win64 ABI on the x86-64 machine | same as M19 |
| **M21** | Tier 3 completion: `syntax_expr`, `syntax_infix` (code, not template), `syntax_type` (generic instantiation at use), `on_func_end`, token record/replay with identifier substitution (`docs/specs/M21.md`) | `check-surface` covers each hook; `make check` green |
| **M22** | `examples/lang`: a higher-level language from a prelude — `fn`, classes with single inheritance and `virtual/override`, interfaces, generics with C#-style `where` constraints and `const N: i64`, `ref` parameters, namespaces as sugar over includes (`namespace`, `import`, `using`, qualified names), automatic memory (reference counting with free lists) (`docs/specs/M22.md`) | `examples/lang/test.sh` green with the taught compiler; 100k-object churn inside a 4 MiB arena proves real deallocation |
| **M21.5** | Tier 3 follow-ups from `examples/lang`: bundle as `#embed` bytes (zero nodes), `arena exhausted` with position and estimate, `mc build --compiler-only`, `on_stmt` hook, `parse_block` through `syntax_stmt("{")` (`docs/specs/M21.5.md`) | `examples/lang` builds on `<mc/core>` with the default arena; demos in `check-surface`; objects inert |
| **M23** | Dynamic limits: growable tables in the self-hosted `mc`, best-effort estimate (static pre-scan + remembered usage) reserved at `estimate * (1 + tolerance)`, single `[limits] tolerance` float in [0,1] (basis points internally), `mc limits` checker (ok/grew/tight, CI exit codes), `mc build --fix-limits` adjusting only the tolerance with consent, `check-limits` on the seed's headroom (`docs/specs/M23.md`) | 5k-function/5k-string program builds with no TOML change; `tolerance = 0` grows and is reported; `make check` warns before the seed's tables fill |
| **M24** | `f32`/`f64` in the self-hosted `mc` (literals, arithmetic, comparisons, casts, `ldf*/stf*`, AAPCS64 float args/returns, `putf64`) as new tasks of the M17 machine table; `#machine ARCH task(params) ENCODING` lets the developer name the hardware instruction for a task per architecture, with `--dump-machine` auditing (`docs/specs/M24.md`; depends on M17 step A) | bit-exact float tests in `tests/mc/`; `#machine` override observed; x86-64 SSE2 tasks with M17 step B |
| **M25** | Sysroots and cross-compilation resolution: explicit path -> running system -> `~/.mc/sysroots` cache -> precise instructions; Apple: synthesized text stubs from the program's externs by default, or `mc sysroot fetch macos-*` from community SDK mirrors with the `mc.toml` lines printed (nothing redistributed by `mc`); `mc sysroot fetch` for musl (Alpine apk) and mingw-w64 import libs (llvm-mingw) with checksums and offline fallback; `mc sysroot list` (`docs/specs/M25.md`) | link on macOS without an SDK via synthesized stubs; fetch into a temp cache and build for linux; offline paths exit with instructions |
| **M31** | Concurrency taught by a module (owner's test, 2026-09-03): threads with mutex/semaphore, `spawn f(args)` fire-and-forget with channels, `await res = f()` without `async` (the call widens to `Intent`/`Intent<T>`; `intent` allowed only on locals), thread-safe reference counting via `#opcode`/`#machine` atomics — design panel first to find what the core lacks (`docs/specs/M31.md`) | delivered as an example under `examples/` (a concurrency module for `lx` or a sibling example) with its own tests in `make check`: producer/consumer over channels, parallel sum, an `await` chain; determinism of the compiled output; the core-gap list is empty or spec'd |
| **M32** | Desktop UI test (owner, 2026-09-03): `examples/desktop` drives GTK4 from `mc` via `extern` + `[externs]` prefix mapping over four dylibs (windows, header bar, buttons, entry, list, transient dialog, callbacks by `&fn`), then a declarative UI language taught by the surface lowering to the same calls; `--self-test` for CI, screenshots via the desktop tooling for the visual check (`docs/specs/M32.md`) | both variants build with `--exe`, `otool -L` shows gtk4/gobject/gio, self-tests identical; `check-desktop` skips without GTK4 |
| **M33** | WebAssembly (owner, 2026-09-03, last in the queue): a `.mc` backend consuming the AST (structured control flow, `call_indirect` for `callp`, imports for `extern`, data segments; `wasm32` by default with `uptr` still 8 bytes — only the address operand narrows — and `wasm64` opt-in) with two writers, binary `.wasm` and text `.wat`; `<sys/wasi>` and `<sys/browser>`; `examples/wasm` with a WASI CLI (run under wasmtime) and a browser page with JS glue (checked in the in-app browser); architecture sweep first to list what the core would need (`docs/specs/M33.md`) | suite subset runs under node's WASI (wasmtime when present); the page runs in the browser; `.wat` round-trips through `wat2wasm` when installed; depends on M17 step A (`gen_resolve`, target registry) |
| **M34** | `examples/minimal`: the smallest executable per target with a reproducible `measure.sh` (size, code bytes, segments, max RSS, footprint, own mappings, startup); baseline macOS `--exe` 16 692 B / 28 B of code / 1.33 MB RSS; Linux `-nostdlib` as the true floor; ceilings guarded in `make check` (`docs/specs/M34.md`) | table printed; ceilings hold; guide page on the site |
| **M35** | Benchmark and memory tooling as bundled `.mc` modules activated by flags: `<bench>` (`--bench`, CSV history, CI job, numbers page) and `<memcheck>` (`--paranoid` / `[profile] mem = "paranoid"`: shadow arena, red zones, poisoning, use-after-free, double free, leaks, UBSan-style checks via a Tier 2 pass; the seed keeps `stage0-san`) (`docs/specs/M35.md`) | `tests/mem/*` each caught with the right message; clean program reports nothing; overhead documented; CSV rows deterministic except timings |
| **M36** | Multi-target builds (owner, 2026-09-03, last): `[[targets]]` in `mc.toml`, `mc build` producing every output in one run (`--target=NAME`, `--list-targets`, `--keep-going`), per-target overrides of linker/sysroot/libs/limits/run, taught compiler built once, byte-identical outputs alone or in batch (`docs/specs/M36.md`) | `examples/minimal` and `examples/wasm` build all available targets in one command; CI covers macOS, wasm and Linux entries |
| **M37** | `mc` hosted on Linux (owner, 2026-09-04, promoted: the cloud runs only Linux; releases must ship `mc` for every landed OS/arch, and a target alone does not make a host): host layer (`host_macos`/`host_linux`), `mc-linux-<arch>` cross-built and released, `scripts/bootstrap-linux.sh` fixed point on Linux from a published seed, Linux `make check` subset, CI jobs on both Linux runners, Linux release assets (`docs/specs/M37.md`) | fixed point on linux/x86_64 and linux/arm64; `mc-linux src/mc.mc` == macOS `mc2.o`; CI green |
| **M38** | `mc` hosted on Windows (owner's rule, 2026-09-04: every landed OS/arch gets a release asset of `mc` itself): `host_windows.mc` over kernel32 (spawn via `CreateProcessA`, environment, file API), cross-built `mc-windows-{arm64,x64}.exe` verified on the Windows runners, release matrix entries enabled | fixed point on the Windows runners; release assets for both Windows targets |

---

# Phase 3 — documentation, website, identity, editor experience

Owner's direction (2026-09-03): detailed documentation of every use case and of every element of the
`mc` API; a `site/` directory with a static site generator **written in mc** (Hugo-like) producing the
documentation website for GitHub Pages; designer agents, an attractive but simple layout and an icon
that expresses `mc`; and a VS Code extension with an LSP and a debugger. The LSP must give developers
back the syntax they created themselves (colors, navigation, tracking of definitions and uses).

## Architecture decisions
- **The language server is the taught compiler.** `mc lsp` (JSON-RPC over stdio, in `.mc`) serves
  semantic tokens, diagnostics, definitions, references and hover from the real lexer/parser with the
  project's hooks registered — the extension launches the project's taught compiler (from `mc.toml`),
  so a `class`/`namespace`/`ref` taught by `examples/lang` is colored and navigable exactly as parsed.
- **The debugger is standard.** `mc` emits DWARF (line table, subprograms, locals with frame offsets)
  into `.o` and `--exe` outputs; the extension uses `lldb-dap`. Line rows point at the developer's
  source (`.lx` or `.mc`), because every node carries `file:line`.
- **Docs are the single source; the site renders them.** `docs/` stays plain Markdown; `site/` holds
  the generator (`mcsite`, an `mc` program), templates, CSS and the icon; GitHub Pages serves
  `site/public`.
- New agent roles: `designer` (layout, CSS, typography, SVG icon, accessibility), `ts-dev` (VS Code
  extension in TypeScript, DAP/LSP client glue). The LSP server itself is `mc-dev` work; its detailed
  design goes through a design panel like M21 before implementation.

## Milestones
| # | Deliverable | Acceptance |
|---|---|---|
| **M26** | Documentation set: `docs/guide/` (getting started, single file, project + `mc.toml`, teaching the compiler, Tier 1-3 recipes, cross-compiling, examples walkthroughs) and `docs/reference/` (language, directives, CLI, TOML keys, parser/hook API with the meaning of every public function, object primitives, machine tasks, diagnostics catalogue); `scripts/check-docs.sh` verifies every public `p_*`/hook/CLI flag appears in the reference and every code sample compiles (`docs/specs/M26.md`) | `make check` gains `check-docs`; zero undocumented public symbols |
| **M27** | `site/`: `mcsite` static generator in `mc` (Markdown subset -> HTML, code fences highlighted by the bundled lexer, nav/search index/sitemap from `site/site.toml`, templates with placeholders), layout by the designer agent, SVG icon/favicon, GitHub Pages workflow YAML (`docs/specs/M27.md`) | `mc build site` renders `site/public` from `docs/`; pages validate (HTML, links, a11y review); icon delivered as SVG + PNG set |
| **M28** | `mc lsp`: JSON-RPC/stdio server in `.mc` (JSON in `.mc`, UTF-16 offsets), incremental full-document reparse, semantic tokens incl. taught words/operators, diagnostics, go-to-definition, references, hover, document symbols; project awareness via `mc.toml` (taught compiler) (`docs/specs/M28.md`, design panel first) | LSP conformance tests with a scripted client; `examples/lang` files colored/navigable through the taught compiler |
| **M29** | VS Code extension (`editor/vscode`): TextMate baseline grammar, LSP client, build/run commands, problem matcher, `lldb-dap` launch configs; packaged `.vsix` (`docs/specs/M29.md`) | extension installs from `.vsix`; smoke test in the Extension Host |
| **M30** | DWARF in `.o`/`--exe` (macOS) and ELF (Linux): `.debug_line`, `.debug_info`/`.debug_abbrev` with subprograms and locals, `.debug_str`; `lldb` steps through `.mc` and `.lx` sources (`docs/specs/M30.md`) | `lldb` breakpoints by file:line and `frame variable` show mc locals; extension debug session works end to end |
