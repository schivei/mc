# 30 — Teaching the compiler

The core language is deliberately small. What makes `mc` interesting is that the parts it leaves
out are not missing — they are **teachable**, from ordinary `mc` source, in three escalating
steps.

| step | you write | you get |
|---|---|---|
| 1 | `#token` + `#infix` / `#prefix` | new operators |
| 2 | `#rule stmt:` | new statements, by pattern and template |
| 3 | a module with `syntax*` / `type_alias` handlers | new declarations, statements, expressions, operators and types, written as code |

`docs/surface.md` calls steps 1 and 2 together **Tier 1** (directives), and step 3 **Tier 3**
(syntax taught by code). Its **Tier 2** — `pass()` and `backend()`, which change what the
compiler *emits* rather than what it *parses* — is [40-backends.md](40-backends.md).

The rule that holds at every step: **nothing is textual**. A template is parsed by the parser
that already exists and expanded as a tree copy, and a handler builds AST nodes directly. There
are no precedence surprises and no macro capture.

---

## Step 1 — new operators

`#token` registers a lexeme; `#infix` and `#prefix` add a row to the same Pratt table the core's
own operators live in. `$1` and `$2` are the operands.

```mc
// expect-exit: 42
#token "<+>"
#token "~~"

#infix  "<+>" 9 left ($1 + $2) * 2
#prefix "~~"  0 - $1

i64 main() {
    i64 v = 10 <+> 11;            // (10 + 11) * 2 = 42
    if (~~5 != 0 - 5) return 1;
    return v;
}
```

`#token` first is not optional. Without it the lexer never produces `<+>` at all — it hands out
`<`, `+`, `>`, the Pratt parser consumes `a <` looking for an operand, and the error surfaces far
from the cause as `expression expected`.

Precedence is 1..100; the core occupies 1..10, so anything above 10 binds tighter than `*`.
`--dump-rules` prints the whole table, taught rows included:

```
$ mc --dump-rules prog.mc
infix || prec 1 left
infix && prec 2 left
...
infix * prec 10 left
infix / prec 10 left
infix % prec 10 left
infix <+> prec 9 left template
prefix -
prefix ~
prefix !
prefix &
prefix ~~ template
```

The core's rows come first, then the taught ones, in registration order. `template` marks a row
that carries a `#infix`/`#prefix` expansion; a row taught by `syntax_infix` carries `handler`
instead.

---

## Step 2 — new statements

`#rule stmt: PATTERN => TEMPLATE`. The pattern is a **flat** sequence of literal tokens and holes
`nt $name`, with `nt` ∈ `expr | stmt | block | ident`. The template is one statement, parsed at
definition time.

```mc
// expect-exit: 42
#token "+="
#rule stmt: ident $x += expr $e ;   => $x = $x + $e;
#rule stmt: swap ( ident $a , ident $b ) ;
    => { i64 $$t = $a; $a = $b; $b = $$t; }

i64 main() {
    i64 a = 2;
    i64 b = 40;
    swap(a, b);
    a += b;
    return a;
}
```

Four things make this mechanism small enough to trust:

- **Dispatch is by the opening token.** The rule table is linear and indexed by it, so there is
  no backtracking. Once a rule is chosen, every item must match. The only pattern that does not
  open with a literal is a leading `ident $x`, for compound forms like `x += e` — and even then
  dispatch happens on the `+=`, with the name already read by the normal statement path.
- **The template is a tree.** `$name` becomes a hole at definition time, and expansion is a tree
  copy. Expansion of a rule that uses an earlier rule happens once, at definition — infinite
  recursion is impossible by construction.
- **Hygiene is gensym only.** `$$t` becomes a fresh local per expansion, named `$g1`, `$g2`, …
  The `$` is load-bearing: the lexer never forms an identifier containing `$`, so no name you can
  write can collide with a gensym.
- **An opening word becomes a reserved word.** `#rule stmt: repeat …` registers `repeat` in the
  lexer; from that point on it is never an identifier again, even over a function declared
  earlier. Choose words you do not intend to use as names.

A core keyword as the dispatch literal is refused outright:

```mc
// expect-error: cannot redefine core keyword
#rule stmt: if ( expr $c ) block $b => loop { $b }
i64 main() { return 0; }
```

### The prelude is nothing but this

`while`, `for`, `+=`, `-=`, `++` and `--` are six `#rule`s and four `#token`s in `lib/prelude.mc`
— bundled as `<prelude>`, entering only through an explicit include.

| written | becomes |
|---|---|
| `while (c) { B }` | `loop { if (!c) break; { B } }` |
| `for (INIT COND ; x = STEP) { B }` | `{ INIT loop { if (!COND) break; { B } x = STEP; } }` |
| `x += e;` | `x = x + e;` |
| `x++;` | `x = x + 1;` |

Which explains three things that surprise people: the body must be a block, `for`'s step is
`i = i + 1` rather than `i++` (assignment is a statement in the core, so a bare expression there
could only be a call), and `for (; c; s)` does not exist, because the pattern needs a `stmt $init`
and the core has no empty statement.

### Where step 2 stops

A `#rule` pattern is flat: no alternation, no optional items, no recursion, no `type $t` hole.
That last one is why there is no `struct`. When you need to *read* something — a type, a
variable-length argument list, a name on the right of an operator — you have to run code. That is
step 3.

---

## Step 3 — code inside the compiler

A taught compiler is a **file**, not an edit to `src/`. `<mc/core>` is the whole compiler minus
exactly one function:

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

`mc build` does both steps for you through `[compiler]` in `mc.toml`
([20-project-toml.md](20-project-toml.md)).

### The five registrations

Each claims a word in the lexer and a position in the grammar. Full signatures, guards and
errors: [../reference/hooks.md](../reference/hooks.md).

| registration | position | handler | delivers |
|---|---|---|---|
| `syntax(word, &f)` | top-level declaration | `void f()` | `top_add(n)` |
| `syntax_stmt(word, &f)` | statement | `i64 f()` | the returned node |
| `syntax_expr(word, &f)` | expression | `i64 f()` | the returned node |
| `syntax_infix(word, prec, &f)` | binary operator | `i64 f(i64 left)` | the returned node |
| `type_alias(name, TY_*)` | a type word | — | — |

A handler is stopped **on** its word and consumes tokens with the parser's public API — `p_id`,
`p_next`, `p_ident`, `p_type`, `p_expect`, `parse_expr(0)`, `parse_stmt()`, `parse_block()`,
`parse_params()` — and builds nodes with `node_new` and `set_nd_*`. Nothing is a special case in
`src/`; these are the same routines the core's own parser uses, under stable names.

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
    i64 neg = node_new(N_UNARY, line, fl);       // !cond
    set_nd_op(neg, K_BANG);
    set_nd_a(neg, c);
    i64 n = node_new(N_IF, line, fl);
    set_nd_a(n, neg);
    set_nd_b(n, b);
    return n;
}
```

A `syntax` handler can produce **zero, one or many** declarations. `enum Name { A, B, C }`
produces none at all — its whole effect is on the `#define` table and the alias table:

```c
void sd_enum() {
    i64 line = p_line();
    uptr fl = p_file();
    p_next();                                    // the `enum` word
    uptr name = p_ident();
    p_expect(K_LBRACE, "expected { in enum");
    i64 v = 0;
    loop {
        if (p_id() == K_RBRACE) break;
        def_add(p_ident(), v, line, fl);         // rejects an already-defined name
        v = v + 1;
        if (!p_accept(K_COMMA)) break;
    }
    p_expect(K_RBRACE, "expected } in enum");
    type_alias(name, TY_I64);                    // `Color c = GREEN;` now parses
}
```

### Record and replay

Four more functions turn "read this later" into a mechanism, which is what a generic
instantiation needs:

- `p_skip_balanced(open, close, &len)` records a delimited region **without parsing it**,
  counting depth over real tokens — so a `}` inside a string or a comment is harmless. The span
  is a slice of the source buffer, which lives in the arena for the whole compilation, so a
  module may keep it and replay it as often as it likes.
- `p_push_source(name, text, len)` parses it, with `#include`'s exact semantics. `name` is what
  every error inside will print, so a module gets
  `slot__i64__3 instantiated from prog.mc:15` in front of its diagnostics without the core
  knowing what an instantiation is.
- `p_subst_name(from, to)` and `p_subst_int(from, v)` substitute identifiers in the pushed
  source, by exact lexeme, in the lexer's identifier branch only — never inside a string.
- `p_resplit_punct(n)` undoes a longest-match decision: `>>` becomes `>` with another `>` still
  to come, which is what `Holder<Bag<Num, 2>>` needs.

### A worked toy language

`lib/user_syntax_demo.mc` teaches nine things with all five registrations and every function
above. It is deliberately **not** a class system — the point is that the same mechanisms carry a
language that looks nothing like the one they were designed against.

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
| `make slot<i64, 3>;` | `p_push_source` + `p_subst_name`/`p_subst_int` |

`lib/mc_syntax_demo.mc` wires it in — two `#include`s and nothing else:

```c
// lib/mc_syntax_demo.mc
#include "../src/core.mc"
#include "user_syntax_demo.mc"
```

```
$ mc --exe lib/mc_syntax_demo.mc -o build/mc-syntax-demo
```

And here is a program that only *that* compiler accepts. The default `mc` rejects its first line
with `type expected at top level`, because `enum` there is just an identifier:

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

`examples/lang` goes the whole distance with the same five registrations: classes with single
inheritance and virtual dispatch, interfaces, generics with `where` constraints, `ref`
parameters, namespaces and reference counting — 2,831 lines of module, nothing in `src/`
([60-examples.md](60-examples.md)).

---

## Three rules that will save you an afternoon

**A registration reserves the word for the whole program**, not just for its grammar position.
Whoever registers `log` removes `log` from the source's identifier vocabulary — and the parser
says so plainly rather than leaving you with a mysterious `name expected`:

```
$ build/mc-syntax-demo prog.mc -o prog.o          # i64 unless = 1;
prog.mc:2: name reserved by a syntax/type_alias registration: unless
```

Choose words a source would not use as an identifier (`class`, `interface`, `unless`, `enum`),
and capitalise `type_alias` names (`Todo`, `Request`).

**`user_init()` runs after `tok_init()`, and before the first token is read.** Both halves
matter: the core's keyword ids are fixed at 256..269, so registering a token *earlier* would
shift them and break everything; and because the lexer is incremental, a registration made there
still applies to the whole source.

**The mechanism is inert when nothing is registered.** That is the acceptance criterion for all
of this, and `scripts/check-surface.sh` enforces it: with an empty `user_init`, every object and
every `--dump-ast` is byte-identical to what the frozen C seed produces — a compiler that has
none of these hooks at all.

## Next

Teaching the compiler what to *parse* is one half. Teaching it what to *emit* — raw instructions,
an AST pass, or a whole new object format — is [40-backends.md](40-backends.md).
