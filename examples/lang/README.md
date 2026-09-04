# examples/lang — `lx`, a language `mc` was taught by a prelude

```
../../build/mc1 build examples/lang        # the taught compiler, then main.lx
examples/lang/build/lang-demo              # 13 / 25 / 12 / box
sh examples/lang/test.sh                   # the whole suite (make check-lang)
```

`lx` has classes with single inheritance, `virtual`/`override`, interfaces,
generics with `where` constraints and const parameters, `ref` parameters,
namespaces with `import`/`using`, and automatic memory management by reference
counting. **None of that is in `mc`.** Everything lives in `lang.mc`, a module
that runs *inside* the compiler during the parse and hands the core nothing but
ordinary declarations. Replace `lang.mc` with a different file and the same `mc`
compiles a different language.

```
Box<Circle, 4> b = new Box<Circle, 4>();     what you write

uptr Box__Circle__4_new();                   what mc sees
void Box__Circle__4_push(uptr self, uptr s);
i64  Box__Circle__4_total(uptr self);
u8   Box__Circle__4_vt[24];
void Box__Circle__4_vt_init();
void Box__Circle__4_release(uptr self);
```

---

## The language

```c
class Shape {
    virtual i64 area(self) { return 0; }
    virtual str name(self) { return "shape"; }
}
class Circle : Shape {
    i64 r;
    override i64 area(self) { return 3 * self.r * self.r; }
    override str name(self) { return "circle"; }
}
interface Printable { str show(self); }

class Box<T, const N: i64> : Printable where T : Shape {
    T items[N];  i64 count;
    fn push(self, T s) { self.items[self.count] = s; self.count += 1; }
    fn total(self) -> i64 {
        i64 t = 0;
        for (i64 i = 0; i < self.count; i += 1) { t += self.items[i].area(); }
        return t;
    }
    str show(self) { return "box"; }
}

fn bump(ref i64 x) { x += 1; }

fn main() -> i64 {
    Box<Circle, 4> b = new Box<Circle, 4>();
    Circle c = new Circle(); c.r = 2; b.push(c);
    i64 n = 0; bump(ref n);
    print(b.total() + n);            // 13
    return 0;
}
```

| written | means |
|---|---|
| `fn f(T a) -> R { }` | a function; no `-> R` means it returns nothing |
| `class C : B { }` | single inheritance; `B` may also be an interface |
| `virtual` / `override` | a new vtable slot / the inherited one |
| `base.m(a)` | the parent's implementation, called directly |
| `interface I { R m(self); }` | a set of signatures; a class lists it after `:` |
| `class G<T, const N: i64> where T : B` | a generic; the body is recorded, not parsed |
| `fn g<T>(T a) where T : I -> T` | a generic function, instantiated per call site |
| `ref T x` | the parameter is an address; the call site writes `ref y` |
| `namespace n { }`, `namespace a.b { }`, `import n;`, `using n;`, `n.X`, `a.b.X` | namespaces |
| `new C(a, b)` | allocate, install the vtable, count = 1, call `init(self, a, b)` |
| `fn dispose(self) { }` | runs when the count reaches zero |
| `while`, `for`, `+=`, `-=`, `++`, `--` | statements the module and lib/prelude.lx add |
| `str`, `bool` | `type_alias` over `uptr` and `u8` |

The core language is still there underneath: `i64`/`u8`/`uptr`, `if`, `loop`,
`break N`, `ld64`/`st64`, `#include`, `#define`, `#rule`. `lib/rt.mc` is written
in nothing but the core -- the default `mc` compiles it unchanged -- and an
`.lx` file may drop into the core whenever it wants to.

---

## How it is built from the surface

`lang.mc` uses only the public hooks. Nothing below is a special case in `src/`:

| feature | mechanism |
|---|---|
| `class`, `interface`, `namespace`, `import`, `using`, `fn` | `syntax(word, &f)` — top-level position (M12) |
| `{`, `while`, `for`, and every class/interface/generic name | `syntax_stmt(word, &f)` — statement position (M12) |
| `new`, `ref`, every generic function, every namespaced function | `syntax_expr(word, &f)` — expression position (M21) |
| `a.b`, `a.b = c`, `a.m(x)`, `a[i]`, `a[i] = v` | `syntax_infix(word, prec, &f)` (M21) |
| `str`, `bool`, every class and interface name as a type | `type_alias(name, TY_*)` (M12) |
| the body of a generic | `p_skip_balanced` + `p_start` (M21) |
| one instantiation per argument tuple | `p_push_source` + `p_subst_name`/`p_subst_int` + `p_depth` (M21) |
| `Holder<Bag<Num, 2>>` closing with `>>` | `p_resplit_punct(1)` (M21) |

Three of those are worth their own paragraph.

**`syntax_stmt("{")` is what makes release happen per scope.** `K_LBRACE` is not
a core keyword, so the module may own every statement-position block — nested
ones included, and without recursing, because the core's `parse_block` consumes
its own brace. That is also why `while` and `for` are handlers here and not
`#rule`s: a rule's `block` hole is parsed by `parse_block`, which would walk past
the module's own block handler and with it every scope-exit release.

**`syntax_infix(".")` is what makes member access typed.** The handler receives
the left operand *already parsed* and reads the member name itself, so what it
emits depends on the static type the module recorded for that expression: a field
becomes `ldW`/`stW` at an offset, a virtual method becomes
`callp(ld64(ld64(obj) + slot), obj, ...)`, a plain method becomes a direct call
to `Owner_method`. Member **assignment** works because `=` is deliberately not in
the core's infix table: the Pratt loop has already stopped, the handler reads the
`=`, and the core sees a plain expression statement.

**Record and replay is the whole of generics.** At the declaration the module
reads the parameter names, records everything from just after the `>` to the end
of the body with `p_skip_balanced`, and creates **no class**. At a use it builds
the mangled name from the argument lexemes, returns early if that instantiation
already exists, then binds `T -> Circle` with `p_subst_name` and `N -> 4` with
`p_subst_int` and pushes `"class Box__Circle__4 " + the recorded span` as a
second source. Because the substitution happens in the lexer, `N` arrives as a
`T_INT` **token** and `T items[N]` folds like any other array bound, and a `T`
inside a string or inside `T_tag` is untouched. The `where` clause is re-parsed
in the instantiation, where the parameters are real names, which is why the
constraint error reads:

```
Box__Thing instantiated from tests/05-where-error.lx:14:1: constraint not satisfied: Thing : Shape
```

The provenance costs the core nothing: `err_at` prints `lex_file()`, which for a
pushed frame is the string the module composed.

---

## Layout

```
object                          vtable                       interface table
+0   vtable pointer             +0   &C_release              +0   count
+8   reference count            +8   C_itab, or 0            +8   interface id
+16  fields, base's first       +16  virtual slot 0          +16  &C_I_mt
                                +24  virtual slot 1          +24  the next pair
```

The base's fields come first, so a `Circle*` is a valid `Shape*` with no
adjustment, and the subclass's vtable is a prefix extension of its base's, so a
slot index means the same thing all the way down the chain. Slot 0 of the vtable
is always the class's `release`, which is what lets `rc_dec` in `lib/rt.mc` free
an object whose class it knows nothing about.

An interface value **is** the object pointer. Dispatch goes
`rt_itab(ld64(obj), IFACE_ID)` to find that class's method array for that
interface, then `callp` through it. A class inherits its bases' interfaces.

---

## Memory

Reference counting with size-class free lists, decided by the owner
(`docs/specs/M21.md` § 7.1). `lib/rt.mc` is a 4 MiB arena in `__bss`, sixteen
free lists (16, 32, ... 256 bytes) linked through word 0 of a free block, and:

```c
uptr rt_alloc(i64 n);        void rt_free(uptr p, i64 n);
void rc_inc(uptr p);         void rc_dec(uptr p);
uptr rt_own(uptr p);         void rt_store(uptr slot, uptr v);
void rt_store_own(uptr slot, uptr v);   void rt_release_array(uptr base, i64 n);
```

What the module injects:

- **`new C(...)`** → `rt_alloc(C_SIZE)`, vtable, count 1, then `C_init` if the
  class declares one. The value is **owned**.
- **a local of class type** owns one reference. `C x = e;` takes `e` as it is
  when `e` is owned and `rt_own(e)` when it is borrowed; `x = e;` becomes
  `rt_store(&x, e)`, which increments the new value before releasing the old one.
- **a field or an array element** of class type owns one reference:
  `o.f = e` and `a[i] = e` go through the same `rt_store`.
- **parameters are borrowed** — no traffic at all on a call.
- **every scope exit** releases the locals that scope declared, in reverse
  declaration order. `break N` and `continue` release every scope they leave.
- **`return e`** evaluates `e` into a temporary, increments it when the function
  returns a class and `e` was borrowed, releases every live local, and only then
  returns — so the caller receives a reference of its own.
- **`rc_dec` reaching zero** calls the class's `dispose` (its own or an inherited
  one), then releases the class-typed fields, most derived class first, then
  hands the block back to its size class.

`tests/08-release.lx` churns 200 000 objects through a 4 MiB arena and finishes
with `live() == 0` and `peak() == 64` — two blocks, the whole program.

---

## Limits

Known, deliberate, and none of them is a core limitation:

- **Cycles leak.** Reference counting alone cannot collect them; `a.b = b;
  b.a = a;` keeps both objects forever. There is no weak reference.
- **An owned temporary that is never bound leaks one reference.**
  `f(new C())` and `print(g().v)` allocate an object nobody releases; write
  `C t = new C(); f(t);` instead. The module classifies ownership per
  expression, not per statement, so there is no place to hang the temporary's
  release.
- **The receiver of a virtual or interface call is evaluated twice** (once to
  load the vtable, once as the argument). Every receiver in these tests is a
  name or a load, so it is idempotent; a call with side effects would run twice.
- **A namespace merges by prefix and nothing else.** Reopening `namespace geo`
  in a second file adds to the same prefix; `import geo;` is `#include "geo.lx"`
  plus `using geo;` and is once-only, and `using` lasts for the rest of the
  compilation rather than the rest of the file.
- **`ref` reaches a local or a parameter only.** `ref a[i]` and `ref o.f` are
  refused, because the core's `N_ADDR` carries a name and not an expression.
  `ref` of a class type is refused too — on the declaration (`fn f(ref C x)`)
  and at the use (`ref c` where `c` is a class-typed local or parameter):
  the address of such a slot is indistinguishable from a `ref i64`, and a write
  through it would corrupt the object pointer and with it the vtable
  (`tests/14-ref-class-error.lx`).
- **A class-typed parameter cannot be reassigned**, `self` included. Parameters
  are borrowed and the caller's reference was never counted on entry, so
  lowering `p = e` the way a local is lowered would release an object the caller
  still holds. Refused at parse time; copy it into a local first
  (`tests/13-param-reassign-error.lx`).
- **A bare core `loop { }` is not tracked**, so a `break` out of one does not
  release the scopes it leaves. `while` and `for` are the module's and do.
- **Arrays of class type exist only as class fields.** A local
  `Circle a[4];` is refused: a local array is not zeroed, and releasing garbage
  would be worse than the missing feature.
- **Every registered name is reserved program-wide.** A class, an interface, a
  generic, a namespace and a function declared inside a namespace all take their
  name out of the identifier vocabulary of the whole program — the single lexer
  word table, `docs/surface.md` § "Registration reserves the word for the whole
  program". `Rect` as a variable name is an error once some namespace declares a
  class `Rect`.
- **No overloads, no default arguments, no properties, no static members, no
  `null` check.** A class-typed local starts at 0 and using it faults.
- **At most 8 parameters**, `self` and the vtable pointer included: a virtual
  method takes at most 6 arguments besides `self`.

## The compiler is `<mc/core>` plus one module

`mc.toml` has no `[compiler].core`: the core comes from the binary's own bundle,
`#include <mc/core>`. This directory therefore contains no path into `src/` at
all — the whole language is `lang.mc` and its five files.

It was not always so. Until M21.5 the example shipped `lang_core.mc` (a copy of
`src/core.mc`'s module list, minus the bundle and the ELF backend) and
`lang_main.mc` (a copy of the CLI), because `<mc/core>` carried
`src/bundle_data.mc` as `u64 bundle_blob[] = { ... }` with about 22 000
elements, and `mc` turned every element into one 104-byte AST node. Those 2.3 MB
of arena, next to a module this size, were what did not fit in the 32 MiB arena
(`HEAP_SIZE` in `src/arena.mc`).

M21.5 removed the cause: the copy of the bundle that the binary regenerates
carries the blob as `#embed bundle_blob "bundle.bin"`, which is ONE AST node
instead of 22 000 (`docs/build.md` § The bundle). Measured on this checkout,
`mc limits examples/lang` for the taught compiler:

| | nodes | heap used |
|---|---|---|
| `<mc/core>` before M21.5 | 80 312 | 21.7 MiB, reserve past 32 MiB (64 MiB) |
| `<mc/core>` after M21.5 | 58 216 | 20.0 MiB of the 32 MiB static arena |

`[limits] tolerance = 1.0` in `mc.toml` is what keeps the `nodes` and `ins`
tables from doubling mid-build; the reserve still fits inside the static arena,
so nothing is mapped and the numbers above are what `mc limits` prints.

---

## Files

| file | lines | what it is |
|---|---|---|
| `lang.mc` | 88 | the module: the includes and `user_init`, where every hook is registered |
| `lang_solo.mc` | 9 | the empty default of `lg_more()`, the chain point `user_init` ends with: a compiler holds one `user_init`, so a module STACKED on this one (`examples/conc`) registers from there and supplies its own `lg_more` instead of this file |
| `lang_tab.mc` | 297 | every table, as flat records with named getters |
| `lang_util.mc` | 374 | names, node builders, the linear lookups |
| `lang_type.mc` | 318 | reading a type, resolving a name, record/replay of a generic, `where` |
| `lang_class.mc` | 667 | `class`, `interface`, `namespace`, `import`, `using`, and the code a class generates |
| `lang_stmt.mc` | 671 | `fn`, the block, `while`/`for`, reference counting, `ref` rewriting |
| `lang_expr.mc` | 294 | `.`, `[`, `new`, `ref`, qualified names, generic calls |
| `lib/rt.mc` | 204 | the runtime: arena, free lists, reference counting, printing |
| `lib/prelude.lx` | 30 | what every `.lx` includes: the runtime plus `+=`/`-=`/`++`/`--` |
| `main.lx`, `geo.lx` | 65 + 26 | the spec's sample, extended with a namespace in a second file |
| `tests/*.lx` | 14 tests | one per feature, with `expect-stdout`/`expect-exit`/`expect-error` headers |
| `test.sh` | 151 | builds with `mc build --compiler-only`, runs the suite, checks determinism, `--dump-asm` and `--dump-rules` |
