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

**A module writes its own setter.** `machine_task` is not a general helper: it writes into
`m_arm64` **by name**, and `x86_task` writes into `m_x86_64`. Until M39 this page told a module
author to "copy the table, overwrite the slot with `machine_task`, and register the copy" —
following that recipe corrupts AArch64's table instead of filling the module's own
(`docs/specs/M39.md` § G9, decision D7). The shape that works is two lines, and every machine in
the repository has its own:

```c
uptr m_mine[MTASK_COUNT];
void my_task(i64 task, uptr fn) { st64(m_mine + task * 8, fn); }

void my_machine_init() {
    i64 t = 0;
    while (t < MTASK_COUNT) {                    // start from an existing machine, if you like
        st64(m_mine + t * 8, ld64(m_arm64 + t * 8));
        t = t + 1;
    }
    my_task(MTASK_ENCODE, &my_encode);           // ...and replace what you mean to replace
    machine("mine", m_mine);
}
```

`examples/kernel/machine_riscv64.mc` is the worked case: 31 slots of its own, `rv_task` as the
setter, registered from a module under `examples/` with no line added to `src/`.

Who calls `machine_use` in a normal build: **the object backend**, once, as its first statement.
That keeps `target()`'s four columns (below) — `[target].arch` is a *file format* question, and
the backend that answers it is the same one that knows which instruction set it is writing.
`--machine=NAME` ([cli.md](cli.md)) is the other caller, for the `--dump-*` modes, which never
reach a backend.

### `void target(uptr os, uptr arch, uptr obj, uptr exe)`

Registers an `(os, arch)` pair `mc build` accepts, with the backend it writes objects with and the
one it writes direct executables with. `exe = 0` says the target has no direct executable and
always goes through `[linker]` — which is what `os = "linux"` and `os = "windows"` do. **Five** are
registered before `user_init()` runs (`src/main.mc`):

```c
target("macos", "aarch64", "macho", "macho-exe");
target("linux", "aarch64", "elf-obj", 0);
target("linux", "x86_64", "elf-obj-x86_64", 0);
target("windows", "aarch64", "coff-obj-arm64", 0);
target("windows", "x86_64", "coff-obj-x86_64", 0);
```

A module can add a sixth, but `mc build` will not reach it yet: `drv_run` resolves `[target]`
**before** `user_init()` has run, so the parent process refuses a pair only the taught compiler
knows. That is gap G1 of `docs/specs/M39.md`, deferred to M39.5; until then a module-defined
target is reached through the single-file CLI, where `--backend=` and `--machine=` are resolved
after `user_init()` (`examples/kernel`).

`src/driver.mc` reads nothing but this table: `target_find(os, arch)` gives the row,
`tgt_obj_at(i)` / `tgt_exe_at(i)` the two backends, `target_os_known(os)` whether the operating
system exists at all, and `target_os_list()` / `target_arch_list(os)` build the diagnostics
(`only macos, linux and windows (see docs/build.md)`, and per operating system
`only aarch64 and x86_64 (see docs/build.md)` for Linux) **from the registry**, so a target a module registers appears in them. Registering one is how a new operating
system or architecture becomes reachable from `mc.toml` without editing the driver.

---

## 3. Tier 3 — the five word registrations, and the two node hooks

Each one claims a **word** in the lexer and a **grammar position**. All five refuse a core
keyword (`cannot redefine core keyword`), and all five reserve the word for the *whole program*,
not just their own position: whoever registers `log` removes `log` from the source's identifier
vocabulary, and the parser says so plainly —
`name reserved by a syntax/type_alias registration: log`.

| registration | grammar position | handler signature | delivers via |
|---|---|---|---|
| `syntax(word, &f)` | top-level declaration | `void f()` | `top_add(n)` |
| `syntax_stmt(word, &f)` | statement | `i64 f()` | the returned node |
| `syntax_expr(word, &f)` | expression (primary) | `i64 f()` | the returned node |
| `syntax_infix(word, prec, &f)` | binary operator | `i64 f(i64 left)` | the returned node |
| `type_alias(name, TY_*)` | a type word | — | — |

In every case the parse is stopped **on the registered word**; consuming it is the handler's job.

`on_stmt(&f)` (M21.5) and `on_jump(&f)` (M31) are the two registrations that claim no word, so none
of the paragraph above applies to them — they observe nodes the parser has just built. Each has its
own section below.

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

### `void type_alias(uptr name, i64 base)`

Makes `name` a valid type word resolving to a core type. `base` is one of `TY_VOID`, `TY_U8`,
`TY_U16`, `TY_U32`, `TY_U64`, `TY_I64`, `TY_UPTR`; anything else is
`type_alias with invalid type`. The alias applies everywhere `type_of_token` is consulted:
declarations, parameters, `extern`, casts and `p_type()`.

Prefer capitalised names (`Todo`, `Request`) and words a source would not use as an identifier —
the registration takes the word away from the whole program.

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
| `i64 parse_function(i64 ty, uptr name, i64 params)` | reads the body block and returns the assembled `N_FUNC`. The parameter list is passed in **already built**, which is how a `class` handler prepends `self` to every method |
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

**Only what has been parsed so far is visible.** The core resolves names at lowering time, which is
how a call to a function declared further down works; a module that needs a callee declared *after*
the use site asks again from a `pass()`, when the whole unit exists.

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

`p_skip_balanced` counts depth over **real tokens**, which is what makes a `}` inside a string or
a comment harmless — a byte scan could not do that. An unterminated region is reported at the
**opening** token (`unterminated region`), because that is the position that tells the reader
which region never closed. A span is a slice of one buffer, so a region whose file ran out in the
middle is refused (`region crosses a file boundary`) rather than returning a bogus byte range.
The span lives in the arena for the whole compilation, so a module may keep it and push it back
as many times as it likes.

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
| `host_bundle_open(name, base, pcanon, plen)` | the lexer's one door into the bundle (`src/main.mc`): resolves `mc/host` to `host_include()` and passes everything else through to `bundle_open` |

The host file also declares `posix_spawnp`, `posix_spawn_file_actions_*`, `waitpid`, `mkdir` and
`unlink` — the same declarations on all three systems, so the compiler's own code does not change
shape between hosts — and the two `O_*` values that differ (`O_CREAT`, `O_TRUNC`: `0x200`/`0x400`
on macOS, `0x40`/`0x200` on Linux, `0x100`/`0x200` on Windows). On macOS and Linux those seven
names are in libSystem and in musl; on Windows none of them exists, and they are shims over
kernel32 in `lib/sys_windows_host.mc`, compiled once into `build/mcrt-windows-<arch>.obj` and
linked next to the compiler ([../guide/95-windows-host.md](../guide/95-windows-host.md) § 3).

What the host layer decides, in the driver and the CLI:

* an `mc.toml` with no `[target]` targets the host (`host_os()`, `host_arch()`);
* `mc x.mc -o x.o` with no `--backend` uses the host's object backend;
* `--dump-asm` with no `--machine=` lowers for `host_machine()`;
* `mc build` links the taught compiler with the host's executable backend when it has one, and
  with `[linker]` when it does not.
* `{sysroot}` probes the running system only when `host_os()`/`host_arch()` equal the target's,
  and caches under `host_home()` when nothing else answered ([sysroot.md](sysroot.md)).
