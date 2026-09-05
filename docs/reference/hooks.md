# The parser and hook API

Everything a module may call to teach the compiler, with its exact signature, when the compiler
calls it, what it returns, and what it refuses. This is the API of Tier 2 (passes and backends)
and Tier 3 (syntax taught by code).

**These hooks exist only in the self-hosted compiler.** The C seed is frozen: it implements Tier 1
(`#token`, `#infix`, `#rule`, `#section`, `#opcode`) and nothing here. That costs zero lines of C,
because the compiler being taught is the one written in the language itself.

**A taught compiler is a file, not an edit to `src/`.** `src/core.mc` is the whole compiler minus
exactly one function, `void user_init()`; your module supplies it:

```c
// my-compiler.mc
#include <mc/core>
#include "my_syntax.mc"

void user_init() {
    syntax_stmt("unless", &my_unless);
    type_alias("bool", TY_U8);
}
```

```
$ mc --exe my-compiler.mc -o my-mc
$ ./my-mc --exe program.mc -o program
```

`mc build` automates exactly this through `[compiler]` in `mc.toml` ([toml.md](toml.md)).

---

## 1. When each hook runs

```
main()
  ├── backend("macho" | "macho-exe" | "elf-obj", …)     the three built-ins
  ├── lim_plan()  tok_init()  lex_init(source)
  ├── user_init()                     <-- every registration below happens here
  ├── parse_unit()                    <-- syntax / syntax_stmt / syntax_expr /
  │                                       syntax_infix / type_alias / #rule,
  │                                       on_jump on every return/break/continue
  │                                       and on_stmt on every statement node
  ├── run_passes()                    <-- pass(&f), in registration order
  ├── fold()
  └── callp(backend_fn_at(i), …)      <-- backend(&f)
```

`user_init()` is called **after** `tok_init()` and `lex_init()` and **before** the first token is
read. Both halves matter: the ids `K_U8..K_EXTERN` are fixed at 256..269, so a `tok_add` before
`tok_init` would shift the whole core table; and because the lexer is incremental, a registration
made here still applies to the entire source.

Registration tables are linear and walked in **registration order**; lookups scan back to front,
so the last registration of a word wins. Nothing is hashed and nothing is sorted — rule 1 of
`docs/determinism.md`.

---

## 2. Tier 2 — passes and backends

### `void pass(uptr fn)`

Registers an AST pass. `fn` is `&f` where `f` has the shape

```c
i64 f(i64 root)          // returns the root: the same one, or a different one
```

Passes run right after `parse_unit()`, in registration order, each one receiving what the
previous returned — and **before** `fold()` and before `--dump-ast`, so a pass sees the tree in
the source's own shape and constant folding cleans up whatever it produces.

```c
// lib/pass_demo.mc: rewrite `x * 1` into `x`, in place
i64 pass_mul1(i64 root) {
    i64 n = 1;
    while (n < nnodes) {
        if (nd_kind(n) == N_BINARY && nd_op(n) == K_MUL
            && nd_kind(nd_b(n)) == N_INT && nd_val(nd_b(n)) == 1) {
            i64 keep = nd_next(n);           // the sibling list is not ours to move
            node_assign(n, nd_a(n));
            set_nd_next(n, keep);
        }
        n = n + 1;
    }
    return root;
}
```

### `void backend(uptr name, uptr fn)`

Registers an object writer under `--backend=NAME`. `fn` is `&f` where

```c
void f(i64 root, uptr out)     // root = the folded unit, out = the output path
```

The last registration of a name wins, as in the `#rule` table. Three are always registered before
`user_init()` runs: `macho` (the default `.o`), `macho-exe` (alias `--exe`) and `elf-obj`. What a
backend has to work with is [objects.md](objects.md).

### `i64 backend_find(uptr name)`

Index of the backend called `name`, or `-1`. Searches back to front, so the newest registration
answers.

### `void backend_die(uptr name)`

Prints `unknown backend: <name>` followed by `registered:` and every registered name, then exits
1. This is what the driver calls when `--backend=` names something that is not there.

### `uptr backend_name_at(i64 i)` · `uptr backend_fn_at(i64 i)` · `uptr pass_fn_at(i64 i)`

Read one row of the registration tables: the name and the function pointer of backend `i`, and
the function pointer of pass `i`. `backend_fn_at` is what the driver hands to `callp` to run the
chosen backend; the other two exist so a module can inspect what is registered.

### `void backend_macho(i64 unit, uptr out)` · `void backend_exe(i64 root, uptr out)` · `void backend_elf(i64 root, uptr out)` · `void backend_elf_x86(i64 root, uptr out)` · `void backend_coff(i64 root, uptr out)` · `void backend_coff_x86(i64 root, uptr out)`

The six built-in backends themselves, callable by name if a module wants to wrap or delegate to
one. `backend_macho` is literally `gen_lower` + `gen_encode_all` + `macho_write`; `backend_exe`
adds what `ld` used to do (segment layout, relocation resolution, stubs, bind opcodes, an ad-hoc
signature); `backend_elf` writes an ELF64 `ET_REL` for `EM_AARCH64` and `backend_elf_x86` the
same file for `EM_X86_64`; `backend_coff` writes a COFF `.obj` for `IMAGE_FILE_MACHINE_ARM64` and
`backend_coff_x86` the same file for `IMAGE_FILE_MACHINE_AMD64`. Each pair shares every line of
its writer, and each begins with `machine_use` — `arm64`, `x86_64`, or `x86_64-win` for
`backend_coff_x86`, which is where the Win64 calling convention comes from — because an object
records its architecture and therefore has to name the machine that produced it.

### `void machine(uptr name, uptr tab)` · `i64 machine_find(uptr name)` · `void machine_use(uptr name)`

Registers the table of instruction-selection tasks the walker drives, and picks which one is in
effect. `tab` is `MTASK_COUNT` entries of `&fn`, in `MTASK_*` order; the full contract — every slot,
its signature, and what the walker keeps for itself — is [machine.md](machine.md). Unlike
`backend()`, registering a machine also **makes it the one in effect**: a machine is chosen by the
target, not by a flag, and the compiler always has exactly one. `machine_use` switches between
registered ones; an unknown name is `unknown machine`.

`src/machine_arm64.mc` fills its own table with `void machine_task(i64 task, uptr fn)` and
registers it from `void machine_arm64_init()`; `src/machine_x86_64.mc` does the same with
`void x86_task(i64 task, uptr fn)` and `void machine_x86_64_init()`. `main()` calls both before
any backend can lower, and then `machine_use("arm64")`, because each registration also makes its
machine current and the host's is the default.

`void machine_freeze()` is called once by `main()`, after the built-in machines are registered and
before `user_init()` runs: it takes the snapshot `--dump-machine` ([cli.md](cli.md)) reads to tell
a bundled slot from a taught one. A compiler that never calls it reports every slot as taught,
which is the honest answer for a registry it cannot vouch for.

Registering a name that is **already registered reuses that name's slot** (M24, decision D5)
rather than appending, so stacking taught modules that each shadow `arm64` does not walk the table
towards `too many machines`. `machine_find` already searched back to front, so nothing observable
changes.

### `uptr machine_tab(uptr name)` · `void machine_slot(uptr tab, i64 task, uptr fn)`

The two functions a module **deriving** a machine uses (M24). `machine_tab` returns a registered
table, to copy from (`unknown machine` otherwise); `machine_slot` writes one slot of a table the
caller owns, bounds-checked against `MTASK_COUNT` (`machine_slot outside the task table`). It lives
in `src/gen_walk.mc`, beside `mach()` and the `MTASK_*` list it checks against.

Do **not** use `machine_task` or `x86_task` for this: they write the bundled global `m_arm64` /
`m_x86_64` by name, so a module following that recipe corrupts the built-in machine for the rest
of the compilation. The recipe is:

```
pr_tab  = xalloc(MTASK_COUNT * 8);        // the table the walker will drive
pr_orig = xalloc(MTASK_COUNT * 8);        // ...and a PRISTINE copy to delegate to
uptr src = machine_tab("arm64");
i64 t = 0;
loop {
    if (t >= MTASK_COUNT) break;
    st64(pr_tab  + t * 8, ld64(src + t * 8));
    st64(pr_orig + t * 8, ld64(src + t * 8));
    t = t + 1;
}
machine_slot(pr_tab, MTASK_BIN, &my_bin);  // one slot replaced
machine("arm64+mine", pr_tab);
```

Two copies, and the one trap worth naming: a wrapper delegates through `pr_orig`, never through
`pr_tab` — reading the patched table from inside a wrapper makes every wrapper call itself.
Delegation needs no further names, which is what keeps `a64_bin`/`a64_const` from becoming frozen
surface. `lib/machine_probe.mc` is the worked example, and `examples/avx` the one that adds an
instruction.

`examples/kernel/machine_riscv64.mc` is the other worked case: a machine written from nothing rather than derived -- 31 slots of its own, `rv_task` as the setter, registered from a module under `examples/` with no line added to `src/`.

Who calls `machine_use` in a normal build: **the object backend**, once, as its first statement.
That keeps `target()`'s four columns (below) — `[target].arch` is a *file format* question, and
the backend that answers it is the same one that knows which instruction set it is writing.
`--machine=NAME` ([cli.md](cli.md)) is the other caller, for the `--dump-*` modes, which never
reach a backend.

### `void target(uptr os, uptr arch, uptr obj, uptr exe)`

Registers an `(os, arch)` pair `mc build` accepts, with the backend it writes objects with and the
one it writes direct executables with. **A 0 in either slot is a registration too**, and says that
role does not exist for this target: `exe = 0` says there is no direct executable and the build
always goes through `[linker]` — which is what `os = "windows"` does, and what `os = "linux"` did
until M42 gave ELF one — and `obj = 0` says there is no separable object step, which is what a
bare board registers when the
image it writes *is* the artefact. Asking the driver for the role that is 0 is a diagnostic at the
`[target]` value's own position ([diagnostics.md](diagnostics.md) § 10), never a null handed to
`backend_find()`. **Five** are registered before `user_init()` runs (`src/core_writers.mc`, `mc_writers_init`):

```c
target("macos", "aarch64", "macho", "macho-exe");
target("linux", "aarch64", "elf-obj", "elf-exe");
target("linux", "x86_64", "elf-obj-x86_64", "elf-exe-x86_64");
target("windows", "aarch64", "coff-obj-arm64", 0);
target("windows", "x86_64", "coff-obj-x86_64", 0);
```

A module can add a sixth, and since **M39.5** `mc build` reaches it: `drv_run` keeps
`[target].os`/`.arch` as strings and the registry is consulted inside `drv_parse`, after
`user_init()` and before `parse_unit()` (gap G1 of `docs/specs/M39.md`). `examples/kernel` is the
worked case — `target("none", "riscv64", "rv-image", "rv-image")` in its `user_init`, `[target] os
= "none" / arch = "riscv64"` in its `mc.toml`, and `mc build examples/kernel` writes the image.
`mc sysroot stub` runs the same resolution ([sysroot.md](sysroot.md) § 7).

**A module may also re-register the HOST pair, and since the post-M41 review the single-file CLI
honours it for both slots.** `target_find` searches back to front, so the last registration wins,
and `src/cli.mc` resolves what the host answers for — the exe slot for `--exe`, the object slot for
a plain `mc x.mc -o x.o` — after `user_init()` and after the `--dump-*` modes have returned, the
same rule M39.5 wrote for the driver. Before that the object half was resolved while the flags were
being read, so a re-registration was honoured by `mc build` and silently ignored by the CLI. A 0 in
either slot is refused there too, in the wording a command line can act on:
`<os> requires a linker: there is no direct executable` for the exe slot and
`<os>/<arch> has no object backend: use --exe` for the object one
([cli.md](cli.md), [diagnostics.md](diagnostics.md) § 9). `tests/proj/objswap.mc`,
`tests/proj/noobjhost.mc` and `tests/proj/noexe.mc` are the three cases, in
`scripts/check-build.sh`.

### `i64 backend_is_exe(uptr name)`

1 when `name` is the **executable** backend of some registered target, 0 otherwise — a linear walk
of the same table, skipping the 0 slots. There is no flag on a `backend()` registration saying what
kind of file a writer produces, and there must not be one: what makes a writer an executable writer
is that a `target()` names it in its exe slot. So a module that registers
`target("none", "riscv64", "rv-image", "rv-image")` makes `rv-image` an executable writer by
saying so, and no backend name is ever special-cased.

The caller is `src/cli.mc` (post-M42 review): `--libc`, `--interp` and `--link` describe a Linux
dynamic executable and are read by nobody else, so a command line that writes an object —
`mc x.mc -o x.o`, or a `--backend=` this answers 0 for — is refused with
`--libc applies to an executable: use --exe` instead of accepting a flag it would ignore
([cli.md](cli.md), [diagnostics.md](diagnostics.md) § 9).

`src/driver.mc` reads nothing but this table: `target_find(os, arch)` gives the row,
`tgt_obj_at(i)` / `tgt_exe_at(i)` the two backends, `target_os_known(os)` whether the operating
system exists at all, and `target_os_list()` / `target_arch_list(os)` build the diagnostics
(`only macos, linux and windows (see docs/build.md)`, and per operating system
`only aarch64 and x86_64 (see docs/build.md)` for Linux) **from the registry**, so a target a module registers appears in them. Registering one is how a new operating
system or architecture becomes reachable from `mc.toml` without editing the driver.

---

## 3. Tier 3 and Tier 4 — the six word registrations, and the four hooks that claim no word

Each of the six claims a **word** in the lexer and a **grammar position**. All six refuse a core
keyword (`cannot redefine core keyword`), and all six reserve the word for the *whole program*,
not just their own position: whoever registers `log` removes `log` from the source's identifier
vocabulary, and the parser says so plainly —
`name reserved by a syntax/type_alias registration: log`.

| registration | grammar position | handler signature | delivers via |
|---|---|---|---|
| `syntax(word, &f)` | top-level declaration | `void f()` | `top_add(n)` |
| `syntax_stmt(word, &f)` | statement | `i64 f()` | the returned node |
| `syntax_expr(word, &f)` | expression (primary) | `i64 f()` | the returned node |
| `syntax_infix(word, prec, &f)` | binary operator | `i64 f(i64 left)` | the returned node |
| `type_alias(name, ty)` | a type word | — | — |
| `type_new(name, w, a, kind)` | a type word, for a **new** primitive (M24) | — | the type id it returns |

In every case the parse is stopped **on the registered word**; consuming it is the handler's job.

`on_stmt(&f)` (M21.5), `on_jump(&f)` (M31), `syntax_lit(&f)` (M24) and `syntax_param(&f)` (M41.5)
are the four registrations that claim no word — and `intrinsic(name, …)` (M24) claims a *call name*
rather than a lexeme, so none of the paragraph above applies to it either. They observe, replace or
own nodes at a position the grammar reaches on its own. Each has its own section below.

### `void syntax(uptr word, uptr fn)`

`word` opens a top-level declaration. The handler produces zero, one or many declarations and
hands each to `top_add`; `parse_top` then returns 0. A handler that consumes no token is
`syntax handler consumed no tokens` — the guard that stops an infinite loop.

```c
// enum Name { A, B, C }  ->  #define A 0, #define B 1, ... and an alias of i64
void sd_enum() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `enum` word
    uptr name = p_ident();
    p_expect(K_LBRACE, "expected { in enum");
    i64 v = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        def_add(p_ident(), v, line, fl);
        v = v + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RBRACE, "expected } in enum");
    type_alias(name, TY_I64);
}
```

### `void syntax_stmt(uptr word, uptr fn)`

`word` opens a statement. The handler returns the statement node's index; returning 0 makes the
parser put an empty `N_BLOCK` there instead, so the sibling list of whoever called it is not
broken. Consuming nothing is `syntax_stmt handler consumed no tokens`.

`K_LBRACE` is not a core keyword, so `syntax_stmt("{")` is legal and lets a module own **every**
block — which is how `examples/lang` runs a scope exit at every closing brace. Since M21.5
`parse_block()` consults `syntax_stmt_find(K_LBRACE)` too, so a function body and a `#rule`'s
`block $b` hole reach the handler as well, not only the blocks that arrive in statement position.
The handler must therefore **not** call `parse_block()` itself — that is infinite recursion; it
reads the braces with `p_expect(K_LBRACE, …)` / `parse_stmt()` in a loop, as `examples/lang` does.

```c
// unless (cond) block  ->  if (!cond) block
i64 sd_unless() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `unless` word
    p_expect(K_LPAR, "expected ( after unless");
    i64 c = parse_expr(0);
    p_expect(K_RPAR, "expected ) after unless condition");
    i64 b = parse_block();
    i64 neg = node_new(N_UNARY, line, fl);
    set_nd_op(neg, K_BANG);
    set_nd_a(neg, c);
    i64 n = node_new(N_IF, line, fl);
    set_nd_a(n, neg);
    set_nd_b(n, b);
    return n;
}
```

### `void syntax_expr(uptr word, uptr fn)`

`word` opens an **expression**. `parse_primary` consults this table first. This is the position
`#prefix` cannot reach: a `#prefix` template parses exactly one operand with `parse_unary` into a
fixed tree, so it can read neither a type (`bits i64`) nor an argument list
(`pipe(x, f, g)`). Two guards apply: `syntax_expr handler consumed no tokens`, and
`syntax_expr handler produced no expression` when it returns 0 — an expression position has no
empty node to fall back on.

### `void syntax_infix(uptr word, i64 prec, uptr fn)`

Teaches a **binary operator**. There is no new table: the `#infix` entry gains a handler column,
which is what puts a taught operator and a `#infix` one into one comparable precedence order.
`prec` must be 1..100 (`precedence out of 1..100`).

The handler receives the left side **already parsed** and the operator **already consumed**, so it
owns everything to the right: a name, a type, an argument list, or an `=` it decides to read
itself — the last one works precisely because `=` is not in the core's infix table. Returning 0 is
`syntax_infix handler produced no expression`.

Teaching the same token twice is `operator already taught` — a second registration is a mistake,
not an override. A `#infix` on the same token afterwards is *not* an error: it goes through
`infix_set`, which clears the handler column, and the template wins.

**A core operator may be taught (M41.5).** `word_add` refuses the core *keywords* (`if`, `i64`,
`extern` …), but `+`, `*`, `==` and the rest are punctuation and were never in that range, so
`syntax_infix("+", 9, &f)` has always been accepted. Until M41.5 it was accepted and then silently
undone: the core precedence table was filled by `ops_init()` as `parse_unit`'s first statement —
*after* `user_init()` — and filling an entry clears its handler column, so the handler never fired
and `1 + 2` still compiled to `3`. `ops_init()` is now built **on first use** and `syntax_infix`
calls it before it looks the operator up, so the core entry is already there when a module reaches
for it. This is the parser-level counterpart of what M24 already allowed one seam later, where a
module replaces the machine slot that lowers `+` (`lib/user_badmach.mc`).

Three consequences, all tested by `scripts/check-surface.sh` against `lib/mc_coreop.mc`:

* **The module's `prec` wins.** `syntax_infix` *re-declares* the entry, exactly as a `#infix` on
  the same token would: precedence, associativity (left) and template are rewritten and the
  handler is installed. A module that wants to keep the core's grouping has to repeat the core's
  number — they are in [language.md](language.md) § 3, and `--dump-rules` prints the table in
  effect. Teaching `*` at 3 really does make `a - b * c` parse as `star(a - b, c)`.
* **`#infix` in the source still drops it.** M21's rule is untouched: a `#infix "+"` written in a
  program compiled by the taught compiler rewrites the whole entry, handler column included, and
  the template wins from that point on.
* **The first registration on a core operator is allowed, a second is not.** A core operator
  carries no handler, so there is nothing to override; once one is installed,
  `operator already taught: +`.

A taught core operator is also a word the registration reserved, so `err_name` may now blame it
(`name reserved by a syntax/type_alias registration: +`) where a name was expected — in that
compiler, `+` really is taught. The rewrite is unconditional and program-wide: the handler sees
every `+` in every source that compiler reads, including the ones inside the functions the rewrite
calls. A module that wants an operator only for its own type has to look at the operands and
rebuild the core's node when they are not its own.

### `void type_alias(uptr name, i64 base)`

Makes `name` a valid type word resolving to a type that already exists. `base` is one of
`TY_VOID`, `TY_U8`, `TY_U16`, `TY_U32`, `TY_U64`, `TY_I64`, `TY_UPTR` — or, since M24, any id a
`type_new` returned; anything outside `0 .. type_count() - 1` is `type_alias with invalid type`.
The alias applies everywhere `type_of_token` is consulted: declarations, parameters, `extern`,
casts, array elements and `p_type()`.

Prefer capitalised names (`Todo`, `Request`) and words a source would not use as an identifier —
the registration takes the word away from the whole program.

### `i64 type_new(uptr name, i64 width, i64 align, i64 kind)` — a new primitive (M24)

Registers a type the core has never heard of and returns its id, which is at or above `TY_MAX`.
`width` and `align` are in bytes and must be at least 1; `kind` is one of

| kind | meaning to a machine |
|---|---|
| `TK_INT` | an integer the core's own operators fit, **unsigned** |
| `TK_FLOAT` | a floating-point value |
| `TK_WIDE` | wider than a register; lives in a frame slot |
| `TK_OPAQUE` | the core knows nothing about it but its size |
| `TK_SINT` | an integer the core's own operators fit, **signed** (M45) |

It is primarily what a machine dispatches on when it does not know the exact id
(`type_new with an unknown kind` otherwise). Since M45 **the core reads it too, in exactly three
places**, and nowhere else:

- `type_signed(t)` — `t == TY_I64 || type_kind(t) == TK_SINT` — decides `/`, `%` and `>>` at
  run time (`bin_op`) and at compile time (`const_bin`);
- `fold_taught(n)` — the folder runs for `TK_INT` and `TK_SINT` and stands aside for `TK_FLOAT`,
  `TK_WIDE` and `TK_OPAQUE`, whose arithmetic is the module's;
- `walk_narrow(t)` — a `TK_INT` or `TK_SINT` narrower than the word (and not `uptr`) is extended by
  the walker after a call and before a `return`, through `MTASK_CAST`
  ([machine.md](machine.md), contract version 4).

`TK_INT` keeps the number 0 and `TY_I64` keeps answering `TK_INT` from `type_kind`, so nothing a
module already wrote moves. What the fifth kind buys is that a signed narrow integer is **one
line**: `type_new("i16", 2, 2, TK_SINT)` gets a sign-extending load, a sign-extending cast, signed
division and shifting, a signed comparison and a narrowed call result, with no line in `src/` and
no line in a machine that honours the kind.

The id a registration returns is **not surface**: it is `TY_MAX + n` for the *n*-th registration in
this process, the core's own `i32` is the first of them, and a module keeps it in a global
(`i64 ty_f64 = 0;` … `ty_f64 = type_new(...)`) rather than writing the number down.

The word is reserved through the same `word_add` every registration above uses, so `type_new("if",
…)` is `cannot redefine core keyword: if`, and it is entered in the same table `type_alias` writes,
so the name is valid in all seven type positions at once. It is an ordinary function called from
`user_init()`: no keyword and no directive, so `tok_init()` is untouched, the ids `K_U8..K_EXTERN`
do not shift, and `scripts/check-lex.sh` keeps cross-checking the two lexers over the whole tree.

What the core then does with the id is `type_width`, `type_align`, `type_name` and the three
`kind` reads above, and is spelled out in [language.md](language.md) § 2. Arithmetic,
literals, the ABI and the instructions belong to the module: `syntax_lit` below, `intrinsic`
(§ 2), and a derived machine table ([machine.md](machine.md) § 3).

### The type registry, read side

| function | returns |
|---|---|
| `i64 type_count()` | how many type ids exist: the seven core ones plus the registered ones |
| `i64 type_width(i64 t)` | its width in bytes (1, 2, 4, 8 for the core types) |
| `i64 type_align(i64 t)` | its alignment; a core type aligns to its own width |
| `i64 type_kind(i64 t)` | its `TK_*`; every core type answers `TK_INT` |
| `i64 type_signed(i64 t)` | whether `/ % >>` are signed for it: `TY_I64` or a `TK_SINT` (M45) |
| `uptr type_name(i64 t)` | the name `--dump-ast` prints; `"?"` for an id that is not registered |
| `i64 type_of_token(i64 id)` | the type a token names — core word, `type_alias` or `type_new` — or -1 |

### `void intrinsic(uptr name, i64 nargs, i64 ty, uptr fn)` — a named hardware instruction (M24)

Registers `void f(i64 d, i64 nargs)` under `name`. A call to `name(...)` in any source this
compiler reads stops being a call: the arguments are lowered to depths `d .. d + nargs - 1`, with
`walk_depth_type` filled in for each, and then the handler runs **instead of** the call sequence.
The value it leaves at depth `d` has type `ty`.

The lookup sits in one place in the dispatch `res_call` and `gen_call` already run in that order:
**after `#opcode`, before a declared signature**. So

- a core intrinsic (`ld64`, `st64`, `emit`, `reloc`, `callp`) can never be shadowed —
  `intrinsic("ld64", …)` is `cannot shadow a core intrinsic: ld64`, refused where it is written;
- an ordinary **function** of the same name *is* shadowed, silently, which is the price of a named
  call and the reason to pick names a program would not otherwise use;
- every existing diagnostic keeps its order, and `wrong number of arguments` is the one a bad
  arity produces.

No word is reserved: an intrinsic is a name resolved at the call site, not a lexer word, so
`word_add` is not involved and the name stays an ordinary identifier everywhere else.
`i64 intrinsic_find(uptr name)` is the lookup (-1 if none), with `intrinsic_name_at(i)`,
`intrinsic_nargs_at(i)`, `intrinsic_type_at(i)` and `intrinsic_fn_at(i)` reading a row.

The handler finds its operands through the machine in effect: `val_reg(d, scratch)`,
`dst_reg(d)`, `dst_done(d, reg)` — the three names contract version 3 publishes
([machine.md](machine.md) § 3). `lib/user_syntax_demo.mc`'s `rbit` is the smallest example: one
`ei(I_EMIT, …)` between `val_reg` and `dst_done`, and it works on an arbitrary expression and at a
spilled depth.

**Why it has no zero-line alternative**, traced: `#opcode` refuses a non-constant argument, so a
named instruction can only be applied to registers that *happen* to be pinned inside a whole leaf
function (`examples/conc/lib/atomic.mc`'s own header records that ceiling, and that an
`ldaxr`/`stlxr` retry loop cannot be expressed at all); `syntax_expr` can build any node the core
already lowers, but `gen_expr` ends in `expression with no codegen`, so a module cannot introduce a
node kind; and `gen_call` ends in `call to unknown function`, so it cannot introduce a call.

### `void syntax_lit(uptr fn)` — the numeric-literal position (M24)

Registers `i64 f()`, consulted by `parse_primary` at the one point where it is about to build the
`N_INT`/`N_CHAR` node. The handler returns the node it built, or **0** meaning "the core handles
this one" — which is what lets a module that only wants `1.5` leave `1` alone. Handlers run in
registration order and the first non-zero node wins.

This is the one grammar position Tier 3 cannot reach: every other hook is keyed by a token
`word_add` created, and `word_add` can never yield `T_INT`. It says *numeric literal*, not
*float*: the decimal-to-binary conversion lives in the module, and `lex_number` stays exactly what
the frozen `stage0/lex.c` does — which is what keeps `--dump-tokens` comparable over the whole
tree.

The handler reads the raw source with `p_start()`, scans forward to at most `p_src_end()`, says
where its literal ends with `p_take_lit(q)`, and advances with `p_next()` before returning
(§ 4). The node it returns is an **ordinary `N_INT`** whose `val` is the representation and whose
`nd_type` is the module's type id; everything downstream follows from that, with no new node kind
and no new machine task — an initializer list accepts it, `glob_place` writes `type_width` bytes of
it, `res_expr` keeps its type, `fold` leaves it alone, and `MTASK_CONST` carries it to the machine.

A module that registers `syntax_lit` and answers 0 for every literal must produce byte-identical
trees and objects to a compiler without the hook; `lib/user_lit_nop.mc` is that module, and
`scripts/check-surface.sh` runs it over the whole `tests/` corpus.

Declining has the same rule the parameter position has: **0 means the handler read nothing.** A
handler that moved the cursor with `p_take_lit` and then answered 0 would leave the core building
its `N_INT` out of a token whose span no longer covers what was read, and the bytes it swallowed
would be gone with no diagnostic; that is `syntax_lit handler consumed tokens and returned 0:
<literal>` (M41.5, from the review).

### `void syntax_param(uptr fn)` — the parameter position (M41.5)

Registers `i64 f()`, consulted by `parse_params` at the head of its loop — **right after the `)`
test and before `type_of_token`**. The handler returns the index of an `N_PARAM` it built, or **0**
meaning "the core handles this one". Handlers run in registration order and the first non-zero
answer wins; with none registered the branch is not taken at all.

That placement is the whole point, and it is what no existing hook could give:

* a parameter that opens with a **word the module taught** (`params i64 xs`) has to reach the
  handler before the core demands a type. `syntax` sees only the *declaration's first token*, and
  `word_add` refuses the core type words, so no keyed table can ever fire on `i64`;
* a parameter with a **trailer** (`i64 y = 10`) has to be read *whole* by whoever wants the
  trailer: `p_type()`, `p_ident()`, then `p_accept(K_ASSIGN)` and `parse_expr(0)` for what the
  module records privately.

It is a `syntax_*` registration and not an `on_param`: the `on_*` family runs *after* a node exists
and cannot consume tokens, which is exactly what a default parameter has to do.

```c
i64 my_param() {
    if (type_of_token(p_id()) < 0) return 0;     // not ours: the core diagnoses it
    i64 ty = p_type();
    uptr nm = p_ident();
    if (p_accept(K_ASSIGN)) {
        i64 e = fold(parse_expr(0));             // the default: recorded by the MODULE
        my_record(p_decl_name(), e);             // ...keyed by the function it belongs to
    }
    return param_new(ty, nm);
}
```

The core does nothing with what the handler recorded: **completing the call is the module's own
half**. `lib/user_syntax_demo.mc` does it from a `pass()`, where the whole unit exists, with
`decl_find` + `decl_nparams` (§ 4).

`p_decl_name()` is what makes that record belong to something. It is set by the core on the
`parse_top` / `parse_extern` / `parse_function` path — the paths where the core reads the name
itself. A `syntax` handler that owns a *container* and declares its members with the public
`parse_params()` and `parse_function()` reads those names itself, so it has to announce each one
with **`p_set_decl_name(name)` before calling `parse_params()`**; without it every member answers
the enclosing declaration's name, or 0, and two members with a default at the same parameter index
are indistinguishable. `lib/user_syntax_demo.mc`'s `capsule Name { … }` is that shape, and
`scripts/check-surface.sh` compiles two members that differ only in the value of the default at
the same index.

**Declining is only sound from the position the handler was called at.** 0 means "I read nothing
and the core reads this parameter", so a handler that consumed tokens and *then* answered 0 would
leave `parse_params` in the middle of a parameter and the core would read whatever is left as a
whole one — a handler that ate `i64 x ,` turns `i64 f(i64 x, i64 y, i64 z)` into a two-parameter
`f(y, z)` that compiles clean and runs with the wrong arity. The core checks it.

Three guards, all raised at the parameter's own position:

| message | when |
|---|---|
| `syntax_param handler consumed no tokens: <word>` | the handler returned a node without advancing — `parse_params` would offer it the same token forever |
| `syntax_param handler consumed tokens and returned 0: <word>` | the handler read part of the parameter and then declined (M41.5, from the review) |
| `syntax_param handler did not return a parameter` | what came back is not an `N_PARAM`. That node goes straight into a list `gen_lower` walks by `nd_type`/`nd_name`, so anything else is a wrong frame layout later, not a diagnostic here |

The `MAXPARAMS` count and the `at most 12 parameters` diagnostic apply to what the handler returns,
exactly as they apply to what the core reads.

A module that registers `syntax_param` and answers 0 for every parameter must produce
byte-identical trees and objects to a compiler without the hook; `lib/user_param_nop.mc` is that
module, and `scripts/check-surface.sh` runs it over the whole `tests/` corpus.

### The lookup side

| function | returns |
|---|---|
| `i64 syntax_find(i64 tok)` | index of the `syntax` registration for token `tok`, or -1 |
| `i64 syntax_stmt_find(i64 tok)` | the same for `syntax_stmt` |
| `i64 syntax_expr_find(i64 tok)` | the same for `syntax_expr` |
| `uptr syntax_fn_at(i64 i)` | the handler pointer of `syntax` row `i` |
| `uptr syntax_stmt_fn_at(i64 i)` | the handler pointer of `syntax_stmt` row `i` |
| `uptr syntax_expr_fn_at(i64 i)` | the handler pointer of `syntax_expr` row `i` |

All three `*_find` scan back to front, so the newest registration wins. The parser uses them; a
module can too, for instance to check whether a word is already claimed before claiming it.

### `void on_stmt(uptr fn)` — every statement, core or taught

The one registration that is **not** keyed by a word: it reserves nothing, teaches nothing, and
sees everything. `parse_stmt` calls each registered hook, in registration order, with the index of
the statement node it has just produced — the core's `i64 x = …;`, `return`, `break`, `continue`,
`if`, an assignment, an expression statement, and a taught statement too.

```c
i64 my_count(i64 n) {
    nstmt = nstmt + 1;
    return n;                       // the same node: rewrites nothing
}
void user_init() { on_stmt(&my_count); }
```

The handler returns **the same node**, **a replacement**, or **0 to drop it** — in which case the
parser puts an empty `N_BLOCK` there, exactly as it does for a `syntax_stmt` handler that returns
0, so the sibling list of whoever called it never breaks. A 0 short-circuits: a dropped statement
is not offered to the hooks registered behind it.

**Order is fixed**: the taught `syntax_stmt` handler for the word runs *first* and builds the node,
then every `on_stmt` hook runs over the result, in registration order. A module can teach `unless`
and observe it in the same compiler without the two racing — the node the hook sees is the `N_IF`
the handler built, not the word.

What it is for: wrapping, rewriting or merely watching the **core** statements without re-teaching
them — scope tracking, instrumentation, ownership and borrow rules, coverage. A core-declared
local (`i64 n = 0;`) is observable here as the `N_VAR` node; there is no separate hook for it.

With nothing registered the parser does not even make the call (`nonstmt == 0`), which is what
keeps an untaught compiler byte for byte what it was — `scripts/check-surface.sh` proves exactly
that (`on_stmt + syntax_stmt("{") leave the AST byte for byte unchanged`).

`uptr onstmt_fn_at(i64 i)` is the lookup side: the handler pointer of row `i`.

### `void on_jump(uptr fn)` — the exit edges of a scope

```c
i64 f(i64 n, i64 kind, i64 depth)
```

Called by `parse_stmt_core` at the moment it builds an `N_RETURN`, an `N_BREAK` or an `N_CONTINUE`:
**before** any `on_stmt` hook and before any other module has had the chance to rewrite the node.
`n` is the node, `kind` is its node kind, and `depth` is how many blocks are open in the function
being parsed. Handlers run in registration order, each receiving what the previous returned; a
handler returns the same node, a replacement, or 0 to drop the jump — in which case an empty
`N_BLOCK` takes its place, the same convention `syntax_stmt` and `on_stmt` already had. A 0
short-circuits the hooks behind it.

Why `on_stmt` is not a substitute: the first module to see a `return` normally *rewrites* it —
`examples/lang` turns it into an `N_BLOCK` of reference releases — so a module registered behind it
can no longer recognise the jump, let alone place code on that edge. A scope guard (`lock (m) { … }`,
`defer`) has to cover **every** exit edge or it is a deadlock waiting to happen; appending the
release after the body, which is the obvious version, misses exactly the jumps.

```c
// guard tick() { … } — the action on every edge out of the block
i64 my_jump(i64 n, i64 kind, i64 depth) {
    if (depth <= guard_depth) return n;           // not inside the guard body
    if (kind == N_BREAK && nd_val(n) > 1)
        err_node(n, "guard: break N leaves more than the guard body");
    i64 st = act_stmt();                          // a fresh copy of the action
    set_nd_next(st, n);                           // action, then the jump
    i64 b = node_new(N_BLOCK, nd_line(n), nd_file(n));
    set_nd_a(b, st);
    return b;
}
void user_init() { on_jump(&my_jump); }
```

`depth` is what tells a jump inside the guard's own body from one the module reached by driving the
parser somewhere else: `parse_function` rebases the counter, so a declaration the module generates
mid-body starts its own function back at 1. Read the current value with `p_blockdepth()` — the guard
records it when it opens its body and compares.

**What it does not see.** `on_jump` fires where the *core* parses a jump. A node another module
fabricates — `examples/lang`'s `for`, which builds an `N_BREAK` by hand — never goes through
`parse_stmt_core` and is that module's own business.

With nothing registered the parser does not even make the call (`nonjump == 0`); the objects an
untaught compiler produces are byte for byte what they were.
`uptr onjump_fn_at(i64 i)` is the lookup side, and `i64 run_on_jump(i64 n, i64 kind, i64 depth)` is
what the parser calls.

---

## 4. The parser's public API

Fixed names, in `src/parse.mc` (and three in `src/lex.mc`). A module that teaches syntax depends
on these, on `node_new`/`nd_*`/`set_nd_*` from `src/ast.mc`, and on the registrations above —
nothing else.

### Reading the current token

| function | returns |
|---|---|
| `i64 p_id()` | the current token's id: a class `T_*` or a lexeme `K_*` |
| `i64 p_val()` | its value — meaningful for `T_INT`, `T_CHAR`, `T_DIR`, `T_HOLE` |
| `uptr p_name()` | its lexeme, copied into the arena as a NUL-terminated string |
| `i64 p_line()` | its line |
| `uptr p_file()` | the file it came from, as `err_at` would print it |
| `uptr p_start()` | where it starts in the source buffer being lexed |
| `i64 p_depth()` | how many sources the lexer has pushed — used to notice that a pushed source has been exhausted |
| `i64 p_blockdepth()` | how many blocks are open in the function being parsed — the same number an `on_jump` handler receives as `depth`, rebased to 0 by `parse_function` |
| `uptr p_decl_name()` | the name of the top-level declaration being parsed, or 0 between declarations. Set the moment `parse_top`/`parse_extern` read the name — so it is already there in `parse_params` — by `parse_function` for the duration of the body, and cleared by `top_add`. The pointer does not move while the declaration is read, so a handler may compare it by identity to notice that a new parameter list has started (M41.5) |
| `void p_set_decl_name(uptr name)` | say whose declaration is being read. **Required** of a handler that owns a declaration and calls `parse_params()` itself: `p_decl_name()` is trustworthy on the `parse_top`/`parse_extern`/`parse_function` path, and only there — the core never sees a member name a `syntax` handler read, so without this call `p_decl_name()` answers the enclosing declaration's name, or 0, for every member (M41.5) |

### Advancing

| function | effect |
|---|---|
| `void p_next()` | advance one token |
| `i64 p_accept(i64 id)` | consume the token if its id is `id`; returns 1 if it did, 0 if not |
| `void p_expect(i64 id, uptr msg)` | require the token; otherwise `err_at` with `msg` at its position |
| `uptr p_ident()` | require a `T_IDENT` that is not a `#define` name, return it and advance (`name expected`) |
| `i64 p_type()` | require a type word — core or alias — return the `TY_*` and advance (`type expected`) |
| `uptr decl_name(uptr msg)` | the name in a *declaration*: a `T_IDENT`, or, inside a `#rule` template, an `ident $x` hole or a `$$t` gensym. `msg` is the error. `p_ident()` is the plain version; this is the one to use when the handler may be expanded from a `#rule` |

### Descending into the grammar

These four are the parser's own entry points, under stable names:

| function | reads |
|---|---|
| `i64 parse_expr(i64 minprec)` | an expression. Pass `0` for a full expression |
| `i64 parse_stmt()` | one statement |
| `i64 parse_block()` | a `{ … }` block — routed through the `syntax_stmt("{")` handler when one is registered (M21.5), so a handler for `{` must never call it |
| `i64 parse_params()` | a parameter list including the parentheses, returning the `N_PARAM` list |

### Building declarations

| function | effect |
|---|---|
| `i64 parse_function(i64 ty, uptr name, i64 params)` | reads the body block and returns the assembled `N_FUNC`. The parameter list is passed in **already built**, which is how a `class` handler prepends `self` to every method. `p_decl_name()` answers `name` while the body is being read, and the previous value is restored on return (M41.5) |
| `void top_add(i64 n)` | append an `N_FUNC`/`N_GLOBAL`/`N_EXTERN`/`N_PROTO` — or a list of them — to the unit, in order, tagged with the `#section` in effect. The only way out for a `syntax` handler |
| `void def_add(uptr name, i64 val, i64 line, uptr fl)` | register a `#define`; refuses a repeated name |
| `i64 param_new(i64 ty, uptr name)` | a standalone `N_PARAM`, to prepend to a list |
| `i64 list_append(i64 head, i64 n)` | append `n` to the end of the `nd_next` list and return the head |
| `uptr p_cat(uptr name, uptr sfx, i64 off, i64 len)` | `name` followed by `len` bytes of `sfx` starting at `off`, fresh in the arena. Two suffixes out of one literal — how the compiler builds `NAME_size` and `NAME_raw` from a single `"_size_raw"` |

### Asking about a declaration the core already parsed

A module that lowers a call needs the **callee's** declared signature: the return type decides what
the result may be bound to, and the parameter types decide what has to be marshalled. That answer
lives in the unit the parser is building, and these five are the sanctioned way to it — before M31
the only route was to walk `unit_head`, a parser internal.

| function | returns |
|---|---|
| `i64 decl_find(uptr name)` | the node index of `name`'s `N_FUNC`, `N_PROTO` or `N_EXTERN`, or -1 |
| `i64 decl_ret(i64 d)` | its declared return type as a `TY_*`, or -1 |
| `i64 decl_nparams(i64 d)` | how many parameters it declares, or -1 |
| `i64 decl_param_type(i64 d, i64 i)` | the declared type of parameter `i`, 0-based, or -1 |
| `i64 decl_valid(i64 d)` | 1 when `d` is one of those three declaration kinds |

The walk is linear over the unit in declaration order — `docs/determinism.md`, rule 1 — and the
first declaration of a name answers, a prototype ahead of its definition carrying the same
signature. The three readers answer -1 for anything that is not a declaration, so an unchecked
`decl_ret(decl_find(f))` after a -1 gives -1 rather than reading the node table at random.

**Only what has been parsed so far is visible** — that is, only declarations `top_add` has already
appended. The core resolves names at lowering time, which is how a call to a function declared
further down works; a module that needs a callee declared *after* the use site asks again from a
`pass()`, when the whole unit exists.

In particular **the enclosing function is not visible from its own body**: `parse_top` appends it
only once `parse_function` has read the whole body, so `decl_find` called from a `syntax_stmt`
handler inside `f` answers -1 for `f`, and a recursive call is *not* an error. Whatever a module
wants to know about the function it is standing in, it either tracks itself — `p_decl_name()` is
the name, and the parameter list is whatever its own `syntax_param` handler built — or asks for
from a `pass()`.

```c
// widen x = f(a);  ->  T x = f((P0) a);   with T and P0 from f's declaration
i64 d = decl_find(callee);
if (d < 0)                  err_at2(fl, line, "widen: unknown function", callee);
if (decl_ret(d) == TY_VOID) err_at2(fl, line, "widen: cannot bind a void result", callee);
i64 pt = decl_param_type(d, i);          // -1: more arguments than parameters
```

### Record and replay

The four functions that let a module read a region now and parse it later — what a generic
instantiation needs.

| function | effect |
|---|---|
| `uptr p_skip_balanced(i64 open, i64 close, uptr plen)` | with the parse sitting on the opening token, record the whole delimited region **without parsing it**: returns the source bytes, delimiters included, writes the length through `plen`, and leaves the parser just past the closing token |
| `void p_push_source(uptr name, uptr text, i64 len)` | parse a second source with `#include`'s exact semantics: the lexer pops on its own at the end, and `name` is what `err_at` prints for everything inside |
| `void p_resplit_punct(i64 n)` | the current punctuation token, of length > `n`, becomes the punctuation formed by its first `n` bytes; the cursor rewinds to just after them |
| `void p_take_lit(uptr q)` | the current numeric token really ends at `q`: the cursor moves there, the token's length grows with it, and the next token is lexed from `q` (M24) |
| `uptr p_src_end()` | where the source being lexed ends — what a handler scanning raw bytes forward has to stop at (M24) |
| `uptr p_cp()` | the lexer's **cursor**: the first byte of the source that has not been lexed yet, i.e. just past the current token (M45) |

`p_skip_balanced` counts depth over **real tokens**, which is what makes a `}` inside a string or
a comment harmless — a byte scan could not do that. An unterminated region is reported at the
**opening** token (`unterminated region`), because that is the position that tells the reader
which region never closed. A span is a slice of one buffer, so a region whose file ran out in the
middle is refused (`region crosses a file boundary`) rather than returning a bogus byte range.
The span lives in the arena for the whole compilation, so a module may keep it and push it back
as many times as it likes.

The boundary test compares the `#include` frame the **opening** delimiter was read in against the
one the **closing** delimiter was read in — not the frame the parser is in once it has moved past
the closer. The two differ at exactly one place, and it is a common one: a region that ends on the
last token of an included file. `lex_next` pops an exhausted frame *before* it produces the next
token, so the lookahead past the closer already belongs to the includer. A region that ends flush
with the end of a file is therefore accepted (it is a slice of one buffer, which is all the rule
ever meant), and one whose `{` is in an include and whose `}` is in the includer — or the reverse —
is still refused, at the opening token's position. An `#include` opened *and* closed inside the
region is fine and always was: the frame depth goes up and comes back down. Fixed in M45; before
it, a `tmpl`-style module could not put a template in a file of its own without a trailing token
after it.

`p_push_source` has one contract worth memorising: the push does **not** touch the pending
lookahead token, so the `p_next()` after it discards the lookahead and reads the first token of
the pushed source. A handler must therefore sit on the **last** token of its own construct when
it pushes — exactly what `#include` does.

Error attribution then costs nothing: `err_at` prints `lex_file()`, so a module that pushes under
the name `Pair__i64__3 instantiated from prog.mc:15` gets that in front of every error inside the
instantiation, without the core knowing what an instantiation is.

`p_resplit_punct` is the one longest-match decision a parser can undo. It is guarded by "the token
was just lexed from the source being read", never a string and never a substituted identifier
(`p_resplit_punct expects a longer punctuation token`,
`p_resplit_punct: unknown punctuation`). Its use is `Holder<Bag<Num, 2>>` closing on a `>>`.

`p_take_lit` is the other half of a `syntax_lit` handler, under the same guard and for the same
reason (`p_take_lit outside the source token`). The lexer stops a number where *its* grammar ends
— `1.5` is the token `1` with the cursor left on the `.` — so a handler that scanned further says
where its literal really ended. `q` may not be before the cursor (a handler cannot un-read) and
may not be past `p_src_end()`.

**`p_cp()` and `p_start()` are not the same position, and the difference matters exactly once.**
`p_start()` is where the CURRENT TOKEN starts. On a token `p_subst_name()` replaced, `subst_apply`
swaps `tok_start`/`tok_len` for the **replacement string**, which lives in the arena — so inside a
`p_push_source` frame a scan that begins at `p_start()` reads the arena lexeme and runs off the
end of it, while the source the handler meant to read is somewhere else entirely. `p_cp()` is the
lexer's cursor and still points into the pushed text, just past the token. A handler that scans
raw source FORWARD from the token it was given — the `syntax_lit` shape — should read from
`p_cp()` and stop at `p_src_end()`; `p_start()` is for a handler that wants the token's own
lexeme, and for `p_skip_balanced`-style span recording, where the token is one the lexer really
read. `scripts/check-surface.sh` asserts the four values a substituted frame produces.

### Hygienic substitution

Applied by the lexer in the **identifier branch only**, by exact lexeme, to the source the next
`p_push_source` will push. Pending entries sit in the slot the next frame will occupy, so the push
binds them by construction, and `lex_pop` clears the slot it vacates — nested frames are
independent.

| function | effect |
|---|---|
| `void p_subst_reset()` | drop the substitutions pending for the next push |
| `void p_subst_name(uptr from, uptr to)` | the identifier `from` becomes the name `to`, resolved through the token table (so `T` may become the keyword `i64`) |
| `void p_subst_int(uptr from, i64 v)` | the identifier `from` becomes a `T_INT` token with value `v`, so a substituted bound folds like any constant |

Too many entries for one frame is `too many substitutions`.

---

## 5. A worked example

`lib/user_syntax_demo.mc` is the reference module: it teaches eleven things with all five
registrations, both node hooks and every record/replay function, and it is deliberately *not* a
class system, so that the generality of the mechanism is demonstrated rather than asserted.

| taught | mechanism |
|---|---|
| `unless (c) { … }` | `syntax_stmt` |
| `enum Name { A, B }` | `syntax` + `def_add` + `type_alias` |
| `bool` | `type_alias(…, TY_U8)` |
| `bits u32` | `syntax_expr` — a **type** in expression position |
| `pipe(x, f, g)` | `syntax_expr` — a variable-length argument list |
| `a .+ b` | `syntax_infix` — saturating add |
| `p ~> len`, `p ~> len = 3`, `p ~> at(i)` | `syntax_infix` reading a name, an `=`, or a call |
| `tmpl slot<T, N> { … }` | `p_skip_balanced` + `p_start` |
| `make slot<i64, 3>;` | `p_push_source` + `p_subst_name`/`p_subst_int` + `p_depth` |
| `widen x = f(a);` | `decl_find` + `decl_ret` + `decl_nparams` + `decl_param_type` |
| `guard tick() { … }` | `on_jump` + `p_blockdepth` |
| `i64 f(i64 x, i64 y = 10)` | `syntax_param` + `p_decl_name` + `pass` + `decl_find` + `decl_nparams` |
| `i64 g(params i64 xs)` | `syntax_param` — a parameter that opens with a taught word |

`lib/mc_syntax_demo.mc` is the compiler that wires it in — two `#include`s and nothing else. The
program below is compiled by *that* compiler; the default `mc` rejects its very first line with
`type expected at top level`, because `enum` there is just an identifier.

```mc taught=lib/mc_syntax_demo.mc
// expect-exit: 42
enum Color { GREEN, YELLOW, RED }

i64 dbl(i64 x) { return x * 2; }
i64 inc(i64 x) { return x + 1; }

u64 box[4];

i64 flag(bool b) {                 // `bool` is an alias of u8
    unless (b == 0) {              // taught statement
        return 2;
    }
    return 0;
}

i64 main() {
    Color c = YELLOW;              // the enum's alias of i64
    i64 n = c + flag(1);           // 1 + 2 = 3
    uptr p = box;
    p ~> len = 3;                  // the infix handler read the `=` itself
    n = n + p ~> len;              // 6
    n = n + pipe(2, dbl, inc);     // inc(dbl(2)) = 5 -> 11
    n = n + (90 .+ 30) - 100;      // saturating add stops at 100 -> 11
    return n + bits u32 - 1;       // 32 - 1 = 31 -> 42
}
```

Two more registrations in that module, `nop` and `nil`, are broken on purpose: they exist only so
that `tests/err/064-expr-noadvance.mc` and `tests/err/065-expr-nonode.mc` can prove the two
`syntax_expr` guards fire.

`scripts/check-surface.sh` runs every case, plus the one that matters most: with nothing
registered, every object and every `--dump-ast` is byte-identical to what the frozen C seed
produces. The mechanism is **inert by construction**.

---

## 6. The host layer

Everything above is about the program being compiled. This section is about the compiler itself:
which operating system it is *running on*. `src/core.mc` says nothing about that — one small file,
included before the core by the entry point, answers all of it (M37,
[../guide/90-linux-host.md](../guide/90-linux-host.md)):

| entry point | host file |
|---|---|
| `src/mc.mc` | `src/host_macos.mc` |
| `src/mc_linux.mc` | `src/host_linux_aarch64.mc` (+ `src/host_linux.mc`) |
| `src/mc_linux_x86_64.mc` | `src/host_linux_x86_64.mc` (+ `src/host_linux.mc`) |
| `src/mc_windows.mc` | `src/host_windows_aarch64.mc` (+ `src/host_windows.mc`) |
| `src/mc_windows_x86_64.mc` | `src/host_windows_x86_64.mc` (+ `src/host_windows.mc`) |

A taught compiler gets one from the bundle: `mc build` writes `#include <mc/host>` above
`#include <mc/core>`, and `<mc/host>` is the host file of the compiler that is running
([bundle.md](bundle.md)).

| function | returns |
|---|---|
| `host_os()` | the operating system this binary runs on, in `[target].os` vocabulary: `"macos"`, `"linux"` or `"windows"` |
| `host_arch()` | its architecture, in `[target].arch` vocabulary: `"aarch64"` or `"x86_64"` |
| `host_machine()` | the machine name the walker drives for it (`machine_use`): `"arm64"`, `"x86_64"` or `"x86_64-win"` |
| `host_sys()` | the bundled system layer a program on this host includes for its I/O: `"sys"`, `"sys_linux"` or `"sys_windows"` |
| `host_include()` | the bundle name `<mc/host>` resolves to for this host |
| `host_environ()` | the environment block, ready for `posix_spawnp` — `ld64(_NSGetEnviron())` on macOS, the `envp` `main` was called with on Linux, `0` on Windows (a null `lpEnvironment` makes `CreateProcessA` give the child this process's own) |
| `host_init(envp)` | called by `main` before anything else, with the third argument the C runtime passed. macOS and Windows ignore it; Linux stores it |
| `host_exe_suffix()` | what this host appends to the name of an executable it is about to write and then run: `""` on macOS and Linux, `".exe"` on Windows. `mc build` is the only caller — `[compiler].out` names a taught compiler the driver links and immediately spawns (M38) |
| `host_has_sdk()` | 1 when `xcrun --show-sdk-path` exists, which is what the `{sdk}` placeholder of `[linker].args` runs. 0 makes `{sdk}` a config error instead of a failed spawn |
| `host_home()` | the user's home directory, or 0 when there is none. `HOME` out of `host_environ()` on macOS and Linux; on Windows `host_environ()` is 0, so `src/host_windows.mc` asks kernel32 for `USERPROFILE` through `GetEnvironmentVariableA`. The one caller is the sysroot cache, `~/.mc/sysroots/<os>-<arch>` (M25, [sysroot.md](sysroot.md) § 4) |
| `host_downloader()` | the program `mc sysroot fetch` spawns to download a pinned archive: `"curl"` on macOS and Linux, `"curl.exe"` on Windows. `mc` speaks no HTTP and no TLS |
| `host_downloader_alt()` | the one to try when the first is not on `PATH`: `"wget"` on Linux, 0 on macOS and Windows, where `curl` ships with the system |
| `host_bundle_open(name, base, pcanon, plen)` | the lexer's one door into the bundle (`src/core_bundle.mc`): resolves `mc/host` to `host_include()` and passes everything else through to `bundle_open` |
| `host_syscall6(n, a, b, c, d, e, f)` | issue system call `n` on this host and hand back the kernel's own result — a small negative value is `-errno`. Linux implements it as `sys6`, eight `#opcode` words on AArch64 and six `emit()` words on x86-64 (`src/sysno_linux_aarch64.mc`, `src/sysno_linux_x86_64.mc`); macOS and Windows answer `-38` (`ENOSYS`). It exists because `prctl`, `syscall` and `clone` are variadic in every libc and this language has no variadic extern, and because `seccomp`, `landlock_*`, `pidfd_*` and `close_range` have no wrapper at all (M43) |
| `host_sysno(sn)` | the number of the system call `sn` on this host, or `-1` when this architecture does not have it. `sn` is an `SN_*` index of `src/sysno.mc`, never a number: that is what lets `src/sandbox.mc` compile unchanged for both architectures and for a host with no such calls |
| `host_sandbox_supported()` | 1 when `mc sandbox run\|exec\|check` can do anything at all here — 1 on Linux, 0 on macOS and Windows, where the subcommand prints the command to run instead ([sandbox.md](sandbox.md) § Hosts). It is not "the box will work": that is what `mc sandbox check` measures against the running kernel |

`host_syscall6`, `host_sysno` and `host_sandbox_supported` are the M43 additions, and they follow
the same rule as everything else on this page: the question "can you issue system call N?" is a
question about the system the compiler is *running on*, so it belongs here and nowhere else.
`<mc/core_sandbox>` therefore compiles on every host, and what refuses on a Mac is `host_os()`
rather than a missing symbol.

The host file also declares `posix_spawnp`, `posix_spawn_file_actions_*`, `waitpid`, `mkdir` and
`unlink` — the same declarations on all three systems, so the compiler's own code does not change
shape between hosts — and the two `O_*` values that differ (`O_CREAT`, `O_TRUNC`: `0x200`/`0x400`
on macOS, `0x40`/`0x200` on Linux, `0x100`/`0x200` on Windows). On macOS and Linux those seven
names are in libSystem and in musl; on Windows none of them exists, and they are shims over
kernel32 in `lib/sys_windows_host.mc`, compiled once into `build/mcrt-windows-<arch>.obj` and
linked next to the compiler ([../guide/95-windows-host.md](../guide/95-windows-host.md) § 3).

Those declarations say `i64` where C says `int` — `open`, `creat`, `close`, `waitpid`, `mkdir`,
`unlink`, `chmod` — because the files that carry them are also compiled by the frozen C seed,
which has no 32-bit type. The sign therefore comes from **`c_int(v)`** (`src/arena.mc`): the low 32
bits of `v`, sign-extended from bit 31, which is what a C `int` result is worth once the
unspecified bits above it are discarded. `if (c_int(waitpid(...)) < 0)` and
`i64 fd = c_int(open(...))` are the whole of its use in the compiler. Code outside the seed set
declares the width instead — `extern i32 f(...)` — and the compiler extends at the call site
([language.md](language.md) § 6).

What the host layer decides, in the driver and the CLI:

* an `mc.toml` with no `[target]` targets the host (`host_os()`, `host_arch()`);
* `mc x.mc -o x.o` with no `--backend` uses the host's object backend;
* `--dump-asm` with no `--machine=` lowers for `host_machine()`;
* `mc build` links the taught compiler with the host's executable backend when it has one, and
  with `[linker]` when it does not.
* `{sysroot}` probes the running system only when `host_os()`/`host_arch()` equal the target's,
  and caches under `host_home()` when nothing else answered ([sysroot.md](sysroot.md)).

## 7. M41 — the composable core

Eight registrations, all in `src/hooks.mc`, all called from `user_init()` (or,
for the ones a PART owns, from that part's own `*_init`). They exist so that a
compiler assembled from a subset of `<mc/core>`'s parts still has a working
command line, and so that a dialect can take a word out of the language.

See `docs/reference/bundle.md` § The parts for what the parts are, and
`docs/guide/98-recreating-the-compiler.md` for the whole shape.

### `void backend_default(uptr name)` · `uptr backend_default_name()`

Names the backend `mc x.mc -o x.o` uses when there is no `--backend=` and no
`--exe`. `mc_main` asks the target registry first — a host that is a registered
`target()` keeps behaving exactly as before — and falls back to this. With
neither, it dies with `no backend: use --backend=NAME`.

There is deliberately no "if exactly one backend is registered, use it": the
module says which one.

```
void user_init() {
    backend("avr-image", &backend_avr);
    backend_default("avr-image");
}
```

`backend_default_name()` is the read side; it answers 0 when nobody called it.

### `i64 machine_use_if(uptr name)`

`machine_use(name)` for a name that may not exist: 1 when it was found and is
now current, 0 when there is nothing by that name. `mc_main` uses it for the
HOST's machine, which a compiler built for a foreign target does not have and
must not die at startup for.

`machine_use` itself is unchanged and still dies with `unknown machine`, which
is what `--machine=` and an object backend want.

### `void subcommand(uptr name, uptr fn, uptr use)` · `i64 subcommand_find(uptr name)` · `void subcommand_usage()`

The eighth registry of the same shape: a linear table in registration order,
the last registration of a name winning. `fn` is `i64 f(i64 argc, uptr argv)`
and its result is `mc`'s exit code; `use` is the exact text `usage()` prints
for it, newline included, with several lines allowed in the one string.

`mc build`, `mc limits` and `mc sysroot` are three of these, registered by
`<mc/core_build>`. A compiler without that part has none, and `mc` with no
argument prints two usage lines instead of six — which is the honest answer,
since those subcommands are not in it.

The ceiling is fixed (16), like `machine()` and `target()`: the number of
subcommands is a property of the compiler, not of the program it compiles.

### `void on_plan(uptr fn)` · `void run_on_plan(uptr src, uptr label)`

`f` is `void f(uptr src, uptr label)`, called by `mc_main` exactly where M23's
`lim_plan` call used to be — before `tok_init()`, so that every table can be
pre-sized before the first one exists. `<mc/core_build>` registers one, which
is `lim_plan` with the default tolerance.

Unregistered, nothing is pre-sized and the tables grow from the seeds in
`src/arena.mc`. That is not a degradation to be afraid of: it is what
`src/astdump.mc` has always done.

### `void type_disable(i64 ty)`

Removes the **word** from the surface. Every position that names a type —
global, local, parameter, `extern`, cast, array element, `p_type()` — goes
through `type_of_token`, and after `type_disable(TY_U32)` each of them refuses
`u32` with

```
prog.mc:3: u32: removed by this compiler
```

**It does not remove the type from the model.** `ld32()` still yields `TY_U32`,
`type_width(TY_U32)` is still 4, `type_name(TY_U32)` is still `u32` and a
machine still sees the id. Read it as "this dialect has no such declaration",
never as "the type is gone" — a `type_alias` of a disabled type is refused too,
under the core type's own name.

The read side is `type_disabled(t)`, which is what `type_of_token` asks and what
a module can ask too; the write side is this function and nothing else.

Disabling `TY_I64`, `TY_UPTR` or `TY_VOID` is permitted and makes the language
unusable: a literal is `TY_I64`, `&f` and every pointer are `TY_UPTR`, and a
function with no result is `TY_VOID`. There is no special case.

### `void intrinsic_disable(uptr name)`

Removes the **name**: a call to it is refused at the call site with

```
prog.mc:4: ld64: removed by this compiler
```

It covers the core intrinsics (`emit`, `reloc`, `callp`, `ld8`..`st64`) and the
ones `intrinsic()` registered, by name, so the rule is the same for both. The
named caller is a target whose word is narrower than eight bytes: there,
`ld64`/`st64` are silently wrong, and the dialect offers its own `ldw`/`stw`
(`intrinsic()`) after making the wide pair unreachable.

The ceiling is fixed (32), for the same reason as the subcommand table.

### `void type_set_width(i64 ty, i64 w)`

Declares how wide a pointer is; `ty` must be `TY_UPTR` and `w` one of 1, 2, 4,
8. Every other type is refused with `type_set_width only declares the width of
uptr`: `i64` folds in 64 bits at parse time and would disagree with the
machine, and `u8`/`u16`/`u32`/`u64` are their own names. A module that wants a
different primitive registers one with `type_new()`.

What follows it, all in `src/gen_walk.mc` and all through `type_width(TY_UPTR)`:

* `walk_word()` — the granule `slot_new` rounds a frame slot to;
* `walk_align()` — twice the word: the alignment of a frame, of a local array
  and of a zerofill placement;
* the pointer a string literal writes into a `uptr[]` initializer: `w` zero
  bytes and an `R_UNSIGNED` relocation whose length is log2 of `w`;
* `src/parse.mc`'s local-array bound, for free.

Inert when nobody calls it: the width is 8, the granule 8, the alignment 16 and
the initializer 8 bytes — byte for byte what the compiler did before the
mechanism existed. Declare it from `user_init()`, before a byte of the source
is read.

### `i64 mc_main(i64 argc, uptr argv, uptr envp)`

Not a registration, but the other half of the same idea: the whole command line
of `mc`, in `<mc/core_min>`, so that a recreated compiler writes a five-line
`main()` instead of copying two hundred. Its contract:

* it must be called after every part's `*_init` and after `host_init(envp)`;
* it calls `user_init()` after `tok_init()` (the ids `K_U8..K_EXTERN` are
  frozen there) and before the first token, which is the timing every Tier 3
  registration depends on;
* nothing before it may call `tok_add` — a part that needs to is a `user_init`
  client like everyone else;
* with no machine registered it says `no machine registered` before it lowers
  anything.
