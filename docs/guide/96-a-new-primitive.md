# A new primitive

Everything in [30-teaching.md](30-teaching.md) changes what the compiler **parses**. This page is
about the layer under it: teaching `mc` a **value type it has never heard of** — a floating-point
number, a 128-bit integer, a half-float, a 256-bit vector — together with the way its literals are
written, the instructions that operate on it, and the registers it travels in. None of that is in
`src/`, and none of it needs to be.

The rule the core follows is a single number. **A type id below `TY_MAX` (7) is a core type and
behaves exactly as it always has. An id at or above it was registered by a module, and every
decision about it is delegated.** The core keeps three questions for itself — how wide is it, how
is it aligned, what is it called — and hands over the rest.

| you want | you use | it lives in |
|---|---|---|
| the type to exist, and its name to work as a type word | `type_new(name, width, align, kind)` | your module |
| `sqrt_f64(x)` to be one instruction, not a call | `intrinsic(name, nargs, ty, &f)` | your module |
| `1.5` to be writable | `syntax_lit(&f)` | your module |
| `x + y` on it to select the right instruction | a **derived machine**, `machine_tab` + `machine_slot` | your module |
| a `f64` argument to reach `v0` and not `x0` | `walk_depth_type(d)` in your machine's `MTASK_CALL` | your module |

The reference pages are [../reference/hooks.md](../reference/hooks.md) § 3 for the registrations,
[../reference/machine.md](../reference/machine.md) § 3 for the machine contract, and
[../reference/language.md](../reference/language.md) § 2 for what the core does with a registered
id.

---

## 1. The type

```
i64 my_ty = 0;

void user_init() {
    my_ty = type_new("fix", 8, 8, TK_INT);
}
```

That is the whole registration. `width` and `align` are bytes; `kind` is `TK_INT`, `TK_FLOAT`,
`TK_WIDE` or `TK_OPAQUE` and is **never read by the core** — it is what a machine dispatches on
when it does not know your exact id, which is what lets one float machine serve `f32`, `f64` and
somebody else's `f16`.

From that moment `fix` is a type word in all seven positions at once — global, local, parameter,
`extern`, cast, array element and `p_type()` — because they all end in the same lookup. Three core
behaviours follow from `width` alone, with no further code:

- `fix v;` reserves `type_width` bytes of frame, so a 16-byte type gets 16;
- `fix tbl[8];` and a global of that type are sized and aligned by the registry;
- `--dump-ast` prints `type=fix`, not `type=?`.

The word is taken from the whole program: after this, `fix` is not available as an identifier.
That is why the bundled `<float>` is **not** in `lib/user_default.mc` — the stock `mc` has no
floats, and a program that wants them says so.

## 2. The literal

The lexer is frozen. `lex_number` stops at the `.`, exactly as the C seed's does, which is what
keeps `--dump-tokens` comparable between the two lexers over the whole tree. So `1.5` is read by
**your module**, at the one grammar position `syntax*` cannot reach:

```
i64 my_lit() {
    uptr s = p_start();                  // where the token starts in the source
    uptr e = p_src_end();                // where the source ends
    // ... scan; return 0 if this literal is not yours ...
    i64 line = p_line();
    uptr fl = p_file();
    p_take_lit(q);                       // it really ended at q
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, bits);                 // the REPRESENTATION
    set_nd_type(n, my_ty);
    p_next();
    return n;
}
```

Returning **0** means "not mine, the core handles this one", so a module that only wants `1.5`
leaves `1` alone, and a module that registers the hook and always answers 0 is indistinguishable
from one that never registered it.

The node is an ordinary `N_INT`. That one decision is what removes four would-be mechanisms:
an initializer list accepts it, so `f64 tbl[] = {1.5, 2.5};` parses; `glob_place` writes
`type_width` bytes of it into `__data` with no float-aware code in any object writer; `res_expr`
keeps the type you put on it; and `MTASK_CONST(d, val)` carries it to your machine, which
materialises it however the hardware wants — no literal pool, no relocation, no new task.

And the core **stops folding** it: `1.5 + 2.5`, `-1.5`, `~1.5`, `!1.5` and casts either way are
left in the tree for your machine, because the core has no arithmetic for a representation it did
not define.

## 3. The instructions

Copy the machine, patch the slots you need, delegate the rest:

```
uptr my_tab;
uptr my_orig;                            // a PRISTINE copy, to delegate through

void my_bin(i64 op, i64 d, i64 d2) {
    if (walk_depth_type(d) != my_ty) { callp(ld64(my_orig + MTASK_BIN * 8), op, d, d2); return; }
    // ... your instruction, over val_reg(d, scratch) / dst_reg(d) / dst_done(d, r) ...
}
```

`walk_depth_type(d)` is the whole reason a second register file needs no new task slot: the walker
tells you what is at each depth, so `MTASK_BIN` picks `fadd` instead of `add`, `MTASK_RET` returns
in `v0`, and `MTASK_CALL` walks `walk_depth_type(d + i)` and runs the AAPCS64 NGRN/NSRN split —
the whole ABI, inside your module. `walk_ret_type()` is its companion: during `MTASK_CALL`, depth
`d` already holds *argument 0*, so the type the call is about to produce has to be asked for
separately.

The trap, and it is the only one: delegate through the **pristine** copy. A wrapper that reads the
table it patched calls itself.

For an operation the hardware has but the core's operator set does not — `sqrt`, a bit reversal,
one AVX instruction — `intrinsic(name, nargs, ty, &f)` gives you a *named call* whose arguments
arrive already lowered to depths, with `walk_depth_type` filled in, and whose handler emits
whatever it likes over `val_reg`/`dst_reg`/`dst_done`. `#opcode` is the zero-line alternative and
its ceiling is real: it folds constants only, so an operand has to *happen* to sit in a fixed
register, and a retry loop cannot be expressed at all.

Register the copy under a name and use it:

```
machine("arm64+fix", my_tab);            // registering also makes it current
```

A registration that shadows an existing name reuses that name's slot, so stacking two taught
modules does not run into `too many machines`.

## 4. What you cannot get this way

`type_new` gives **primitives**. Aggregates, members, `a[i]` on your type, typed pointers,
generics and user-defined conversions are not here — a module that wants structure lowers to
`uptr` the way `examples/lang` does, which is a fine answer and is said plainly rather than
hidden. Two mechanisms are deferred with a price written down in `docs/specs/M24.md`: `emitb` +
`MTASK_BYTES` for naming a VEX3 instruction from a source file, and `MTASK_DEPTH_SPAN` for a value
that lives in a register **pair** rather than in a 16-byte slot.

## 5. `<float>`, worked

```
build/mc1 --exe lib/mc_float.mc -o build/mc-float     # the taught compiler
build/mc-float --exe prog.mc -o prog                  # ...and a float program
```

or, from `mc.toml`, `[compiler] modules = ["user_float.mc"]`. The program says

```
#include <sys>
#include <float_rt>

i64 main() { putf64(1.5 + 2.5, 3); return 0; }        // 4.000
```

Three types are registered: `f64` (8 bytes), `f32` (4) and `f64raw` (8, an integer) — the last is
the reinterpretation, so `(f64raw) x` and `(f64) r` are one `fmov`/`movq` and not a numeric
conversion, which is how a NaN is written down in a source that has no NaN literal. Eight
intrinsics name the instructions the core's operator set does not have: `ldf32` `ldf64` `stf32`
`stf64` `sqrt_f64` `fabs` `fmin` `fmax`. `%` on a float is `no float remainder`, raised by the
module's own machine — the core's `bin_op` maps `%` to `MOP_UMOD` for any non-`i64` type and has no
opinion beyond that.

The run-time half is `<float_rt>`, a separate include and not a source the module pushes: pushing
it would put `putf64` — and therefore a call to `write` — into every program the taught compiler
compiles, including ones with no system layer at all. `putf64(x, digits)` is fixed-precision and
says so; `fmt_f64(buf, x, digits)` is the half that needs no `write`.

What it cost in `src/`: nothing. What it cost in mechanism: the eight of M24, which is the point.

## 6. Where to look

- `lib/float.mc`, `lib/machine_arm64_float.mc`, `lib/machine_x86_64_float.mc`,
  `lib/user_float.mc`, `lib/float_rt.mc` — the first library built on all of this: `f32` and `f64`,
  their literals, their arithmetic, and their ABI on four targets. `git diff src/` for the whole of
  it is empty.
- `lib/machine_probe.mc` — the smallest complete derived machine: it changes no instruction and
  asserts the depth-type contract on every task.
- `lib/user_badmach.mc` — the same, with one slot deliberately wrong, so the override is visible
  in the program's answer and in `--dump-machine`.
- `lib/user_syntax_demo.mc` — a fixed-point type and its literal, in about sixty lines, next to the
  Tier 3 toys.
