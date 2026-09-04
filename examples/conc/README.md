# examples/conc — threads, channels and `await` taught by a second module

```
../../build/mc1 build examples/conc          # the taught compiler, then main.lx
examples/conc/build/conc-demo                # channel / parallel sum / await chain
sh examples/conc/test.sh                     # the whole suite (make check-conc)
```

`lx` — the language of [examples/lang](../lang/README.md) — gains threads,
channels, a worker pool, `lock`, and `await` with no `async` anywhere. **None of
that is in `mc`, and none of it is in `lx` either.** It lives in `conc.mc`, a
second module *stacked on top of* `lang.mc`:

```toml
[compiler]
modules = ["../lang/lang.mc", "conc.mc"]
```

The two modules run inside the same compiler, during the same parse. `lx` still
owns classes, generics and reference counting; the concurrency module owns five
words and chains over the host wherever the two meet.

```
intent a = part(0, 2000000);                 what you write
intent b = part(2000000, 4000000);
await ra = a;
await rb = b;

uptr a = it_submit(it_arg(it_arg(              what mc sees
             it_new(&part, 2, 0), 0, 0, 0), 1, 2000000, 0));
uptr b = it_submit(...);
i64  ra = it_take(a);
i64  rb = it_take(b);
rc_dec(b); rc_dec(a);                        // the scope exit lx already had
```

---

## The language additions

| written | means |
|---|---|
| `spawn f(a, b);` | submit `f(a, b)` to the pool and forget it |
| `intent x = f(a);` | submit it **now**, bind the running call to a local |
| `await x;` | wait for `x`, discard its result |
| `await r = x;` | wait for `x` and bind its result; `r` has `f`'s declared type |
| `await r = f(a);` | the fused form: the intent is a temporary |
| `await f(a);` | the same, result discarded |
| `lock (m) { … }` | hold `m` for the block, on **every** way out of it |
| `chan c = chan_new(8);` | `chan` is an alias of `uptr`; the channel is a bounded ring |
| `chan_send(c, o)` / `chan_recv(c)` / `chan_close(c)` / `chan_len(c)` | the channel API |
| `mutex_new()` · `gate_new(n)` / `gate_wait` / `gate_post` | a mutex, and a counting semaphore |
| `quiesce()` · `reserve(n)` · `workers()` | the pool: wait for it, size it, count it |
| `atomic_add(&g, v)` · `atomic_cas(e, n, &g)` · `atomic_fence()` | LSE atomics as functions |
| `live()` · `used()` · `peak()` | the arena, as in `lx` — read them after `quiesce()` |

`await` needs no `async`, in any function, because it lowers to an ordinary call
to a blocking runtime function. There is no CPS transform, no colouring, and no
core change: `docs/specs/M31.md` § 1 is the argument, `it_wait` is the
implementation.

### Dispatch: eager, with steal-on-await

`intent x = f(a)` submits **at the call**, not at the `await`. Recording a thunk
and running it at the `await` would make `await r = f()` identical to `r = f()`
and the whole feature vacuous.

Eager submission alone starves a fixed pool the moment a task awaits, so `await`
**steals**: it CASes the intent from QUEUED to RUNNING and, winning, runs it
inline on the awaiting thread, while the worker that later pops it skips it.
Consequences, all intended:

- back-to-back `await r = f();` degrades to a direct call plus bookkeeping;
- parallelism appears exactly where intents are left **in flight**;
- user code cannot assume which thread it runs on.

`spawn` uses the same pool but is never awaited and so never stolen. The pool
grows a worker when a submit finds no parked one, capped at `MAXTHREADS - 1`;
`reserve(n)` starts `n` up front, which is what a test needing two tasks alive
*at the same time* must do rather than hope.

---

## The ownership convention

`lx` counts references and releases per scope. Concurrency adds exactly one
rule, and it is not about counters.

**A direct call borrows. An intent and a channel capture.**

A direct call borrows because the caller outlives the callee. An intent's callee
may run after the caller's scope is gone, so `it_arg(it, i, v, own)` captures:
`own = 1` increments a borrowed value, `own = 2` moves an already-owned
temporary in with no increment, and the intent's release drops what it holds.

```lx
{
    Item x = new Item(7);
    spawn use_later(x);
}                       // x is released HERE; the task has not run yet
quiesce();
print(live());          // 0 — the intent held the second reference
```

A channel likewise takes a reference **of its own** on send and hands it out on
receive, so the sender's scope exit cannot free an object the consumer still
holds (`tests/03-channel.lx`: a producer on another thread sends 100 objects and
drops each one immediately; the consumer sums them and every one is disposed).

This — not atomic counts — is what closes the producer/consumer race. Atomic
`rc_inc`/`rc_dec` fixes the *counter*; nothing about the counter tells you who
owns the object across a thread boundary.

`chan_recv` is the one expression the module registers with `syntax_expr`, and
its only job is to mark the result **already owned** so the binding does not take
a second reference.

**A channel carries objects, not scalars.** `chan` is an alias of `uptr`, so
neither the surface nor the host's type checker can tell `chan_send(c, it)` from
`chan_send(c, 1)`; the send takes a reference of its own, and the payload's word
at `+8` therefore has to be a live reference count. `chan_send(c, 1)` used to
reach `rc_inc(1)` — an atomic read-modify-write at address 9 — and the program
died of `Bus error: 10` (exit 138) with nothing to read. The runtime now
bounds-checks the payload against the object arena, which every object comes from
and no scalar is inside, and panics with `chan_send: the payload must be a
reference counted object, not a scalar` (exit 70). `0` is refused too: it is the
value `chan_recv` returns for *closed and drained*. `tests/20-chan-scalar.lx` is
the case. To move numbers between threads, send an object that holds them, or use
`atomic_add` on a global.

### The one slot two threads may not share

The rule above says who **owns** an object across a thread boundary. It says
nothing about a *slot* two threads write at the same time, and this is the sharp
edge of the module:

```lx
fn hammer(Node shared, i64 n) -> i64 {
    i64 i = 0;
    while (i < n) { shared.next = new Node(i); i = i + 1; }   // UNSYNCHRONISED
    return 0;
}
spawn hammer(shared, 30000);
spawn hammer(shared, 30000);
```

`obj.field = value` on a class-typed field is `rt_store`, four separate steps —
`rc_inc(v)`, read the old pointer, store the new one, `rc_dec(old)` — with no
lock. Two threads interleaving them read the *same* old pointer and both release
it, which is not a wrong number but a **hard abort**:

```
$ ./t2
lx: rc_dec: reference count below zero        (exit 70)
```

Measured on this checkout: 3 of 40 runs of exactly that program. It is a race, so
the rate is a property of the machine and the day — the failure is not. Treat a
class-typed field of a shared object as owned by one thread, or wrap **every**
write and read of it in the same `lock (m) { … }`; that is what `lock` is for.
`rt_store` is deliberately unlocked (a per-store mutex on every field assignment
in the language would be the wrong price for the common case), and there is no
locked variant: `lock` around the statement is the supported answer.

---

## `intent` is not a type, structurally

`intent` is registered with `syntax_stmt` and **never** with `type_alias`. A
word that is not a type word is not a type in *any* grammar position, so all
four forbidden positions reject it by construction — there is no check to
forget:

| written | refused with |
|---|---|
| `fn h() -> intent { … }` | `type expected` |
| `fn h(intent x) { }` | `type expected` |
| `class C { intent x; }` | `type expected` |
| `Box<intent>` | `unknown type: intent` |
| `fn h() -> $Intent { … }` | `type expected` |

Those messages are the **host's**, not the module's. `docs/specs/M31.md` § 4
wanted `` `intent` is not a type: it may only declare a local `` and noted that
three lines at the top of the host's own type reader would produce it; this
milestone leaves `examples/lang` alone (see *The one line in examples/lang*
below), so the sentence stays the host's. The refusal is the same either way.

**The tag class is `$Intent$`, with a `$` at each end.** The spec proposed
`$Intent`, on the ground that the lexer never forms an identifier containing a
`$`. That is true — but the lexer *does* form `$Intent` as one hole token whose
**lexeme** is exactly `"$Intent"`, and `lx` resolves a type by lexeme
(`lg_read_type` → `lg_is_uname` → `lg_resolve`). Measured on this checkout,
`fn h() -> $Intent` was accepted and handed back the tag. A trailing `$` cannot
be part of any single token — a hole is `$` followed by identifier characters,
and `$` is not one — so `$Intent$` is unspellable. `tests/13-tag-unnameable.lx`
is the case.

The tag is a row in the host's class table with no vtable, no `_new` and no
`_release`: `it_new` writes the vtable itself and slot 0 of it is `it_release`,
which is all `rc_dec` looks at. What the row buys is everything `lx` already
does for an object — an intent local is released at scope exit, at `break N` and
before `return`, and `ref` of one is refused.

### The errors the module owns

```
an intent must be initialized by a call: x
the callee of spawn/intent/await must be a named function: …
unknown function: f
wrong number of arguments: f
an intent takes at most 7 arguments: f
intent is never awaited in this scope: a
this intent was already awaited: a
this intent has no value to bind: use "await x;": a
await expects an intent: z
await while holding a lock: release it first
```

`an intent takes at most 7 arguments` is the **call site's** count, and it is not
the host's `too many parameters`: a callee *declared* with eight parameters never
reaches this module (`lx` refuses the declaration itself), but nothing stops a
source from writing eight arguments at a call to a seven-parameter function, and
that is where this message comes from — before `wrong number of arguments`, and
before the module's fixed-size argument buffers would overflow.
`tests/19-too-many-args.lx` is the case.

and at run time, from the runtime: `deadlock: await cycle`,
`intent awaited twice`, `await of a null intent`, `await of a released intent`,
`chan_send on a closed channel`, `chan_send: the payload must be a reference
counted object, not a scalar`, `intent queue full`, plus `conc: this runtime
needs ARMv8.1 LSE atomics …`.

---

## `lock` and the exit edges

```lx
fn early(i64 x) -> i64 {
    lock (gm) {
        if (x > 3) { return x * 10; }        // the unlock is on this edge
        return x;                            // and on this one
    }
}
```

Appending the unlock after the body — the obvious version — misses exactly the
jumps: a `return` inside the body leaps over it and the next call hangs forever.
`on_jump` (M31 § 2.2) fires where the **core** builds the `N_RETURN`, *before*
any `on_stmt` hook and therefore before `lx` rewrites the jump into its own
block of releases, which is why a second module can place code there at all.

- `return` leaves every open lock in the function.
- `break` / `continue` leave a lock only when the loop they target was opened
  **outside** it; the module compares the host's own loop nesting (`lg_nlp`)
  against the value recorded when the lock body opened.
- `return f()` puts the value in a temporary **before** the unlock, so the
  expression is not evaluated outside the lock. The temporary carries the
  expression's ownership, so `lx` does not count it a second time.
- `await` inside a `lock` is refused at parse time: a thread blocked on a mutex
  is invisible to the wait-for graph, so that cycle could not be detected.

`tests/05-lock-exits.lx` calls every one of those functions **twice on the same
mutex**. A missed unlock is a hang, which is why `test.sh` runs every test under
a timeout.

---

## Deadlock detection

Every thread has a slot; a blocked thread records the intent it waits on, and a
running intent records its runner. Before each wait the runtime walks the
wait-for chain and panics with `deadlock: await cycle` (exit 70) if it comes back
to itself. Stealing cannot break such a cycle — each intent is already RUNNING on
the other thread — so the detector is not redundant. A waiter broadcasts before
it sleeps, so the thread that published the second edge wakes the first one to
re-walk. `tests/08-deadlock.lx` builds a real two-task cycle.

---

## The runtime

`lib/` is **program** code, written in the core language only, so the default
`mc` compiles it unchanged (`test.sh` checks that).

| file | lines | what it is |
|---|---|---|
| `lib/atomic.mc` | 60 | `a_add`, `a_cas`, `a_fence` — three `#opcode` words |
| `lib/thread.mc` | 62 | the platform layer: `pthread_*`, `dispatch_semaphore_*`, `sysctlbyname` |
| `lib/rt.mc` | 253 | the `lx` runtime, made thread safe |
| `lib/conc_rt.mc` | 575 | mutexes, gates, channels, the pool, the intent |
| `lib/prelude.lx` | 51 | what every `.lx` here includes |

**Atomics are whole functions**, not expressions: `#opcode` folds constants only,
so an atomic cannot take an operand. The `lib/sys_svc.mc` pattern applies —
the parameters already sit in `x0..x7`, the prologue does not clobber them, and a
function with no `return` ends in an epilogue that leaves `x0` alone
(`docs/reference/objects.md` § 4, the ABI contract M31 § 2.3 asked for):

```c
#opcode ldaddal(rs, rt, rn)  0xF8E00000 | (rs << 16) | (rn << 5) | rt
i64 a_add(uptr p, i64 v) { movx(2, 0); ldaddal(1, 0, 2); }   // returns the old value
```

Apple's disassembler prints those back as `ldaddal x1, x0, [x2]` and
`casal x0, x1, [x2]`. Four threads × 200 000 increments give exactly 800 000
where the plain `ld64`/`st64` version loses most of them
(`tests/04-parallel-sum.lx` asserts both).

**`PTHREAD_MUTEX_INITIALIZER` is a global array initializer.** A statically
initialized mutex is `{ 0x32AAABA7, 0, … }` (64 bytes) and a condition variable
`{ 0x3CB0B1BB, 0, … }` (48), which is how this runtime avoids the
chicken-and-egg of a lock protecting its own initialization.

**The differences from `examples/lang/lib/rt.mc`** are three and no more:
`rc_inc`/`rc_dec` go through `a_add`; `rt_alloc`/`rt_free` run under one global
mutex; `rt_nlive`/`rt_npeak` move atomically. The allocator is the other half of
the problem — atomic counts alone leave two threads corrupting an unsynchronised
free list. One lock is a convoy; per-thread arenas need an owning-arena header
and are a later milestone (`docs/specs/M31.md` § 8, question 5).

**The intent** is 208 bytes — inside the 256-byte free-list ceiling, so intents
recycle — laid out as vtable, count, state, callee, arity, flags, result, taken,
runner, 8 argument words and 8 ownership tags. No per-callee trampoline is
needed: `callp` takes the pointer plus up to 7 arguments, so one arity switch
covers every callee, `self` included.

---

## Limits

Known, deliberate, and each one is a decision rather than an oversight:

- **arm64 with LSE only.** `LDADDAL`/`CASAL` are ARMv8.1. A retry loop of
  `ldaxr`/`stlxr` split across two one-word `#opcode` functions is **not** an
  alternative — the frame store and the `ret` between the halves may clear the
  exclusive monitor, and it passes on Apple silicon anyway, which makes it a
  silent portability trap. Real `ldaxr`/`stlxr` sequences arrive with M24's
  `#machine`. Until then the module registers a `pass()` that calls
  `conc_boot()` at the top of `main`, which reads
  `hw.optional.arm.FEAT_LSE` and exits 70 with a sentence rather than dying of
  SIGILL on the first `rc_inc`. It is a **startup** refusal and not a build-time
  one because the core exposes no way for a module to ask what the target is.
- **No cancellation, no timeouts, no `select`, no structured concurrency**, and
  no typed `Chan<T>` with member syntax — the last wants the chainable
  `syntax_infix` that M21 § 7.3 deliberately refused. Free functions ship first.
- **Cycles leak**, as in `lx`: reference counting alone cannot collect them, and
  an intent that captures an object that transitively holds the intent keeps both
  forever. There is no weak reference.
- **No `Send`/`Sync`, no data-race analysis.** `spawn f(&shared)` compiles and
  races. A module sees only what it parsed.
- **`rt_store` / `rt_store_own` are not locked**: a slot — a local, a field, an
  array element — has one owner thread by the language's own convention. Two
  threads writing the same class-typed field do not merely disagree about the
  value: they double-decrement one refcount and the process aborts with
  `rc_dec: reference count below zero`, exit 70. See *The one slot two threads
  may not share* above for the measured repro and the `lock` that fixes it.
- **A `chan` carries objects only**, never scalars and never a `uptr` that is not
  a live counted object — the send takes a reference of its own. Enforced at run
  time by a bounds check against the object arena
  (`tests/20-chan-scalar.lx`); the type checker cannot help, because `chan` is an
  alias of `uptr`.
- **`intent is never awaited in this scope` is a lint, not a lifetime
  guarantee.** It asks whether the word `await` was written in the block, not
  what became of the intent's value. Copying that value into an untyped local
  (`uptr saved = x;`) takes no reference — only the `$Intent` local is
  class-tracked — so the block is still freed at the scope's close and `saved`
  dangles. The escape is the host language's, not this module's: an untyped alias
  skips reference counting in plain `lx` too, with ordinary objects and no module
  on top. What the *pool* adds is that the freed 208 bytes go to a free list
  another thread allocates from, so a stale intent pointer can come to alias a
  different, live intent. `it_release` therefore poisons the state word before
  freeing, and the first intent operation on a stale pointer panics with
  `await of a released intent` (`tests/21-escaped-intent.lx`) instead of quietly
  reading someone else's block. A raw `ld64` on the escaped address is of course
  still a raw read of freed memory; nothing in a language with `ld64` can stop
  that. The companion caveat is the *other* direction: a branch that awaits on
  only one path passes the check and reaches the blocking release, which is safe.
- **`decl_find` sees only what has been parsed so far**, so the callee of a
  `spawn` must be declared *above* it. `spawn f(…)` inside `f` itself is
  `unknown function: f`. The escape the core documents is to ask again from a
  `pass()`, which this module does not need.
- **At most 7 arguments** to a spawned or awaited call: `callp` takes the pointer
  plus seven. Everything packs as an 8-byte integer, so no floats until M24. The
  module's own message is about the **call site** — a callee declared with eight
  parameters is refused earlier, by `lx` itself (`tests/19-too-many-args.lx`).
- **Channels and mutexes are never freed.** They come from the runtime's own
  256 KiB arena and not from `rt_alloc`, deliberately: counting them would make
  `live()` — the number every ownership test asserts — mean two things at once.
- **`live()` is racy the moment threads exist.** Every assertion on it needs
  `quiesce()` first, and every concurrent test asserts a deterministic total.
  Program *output* under a scheduler is not deterministic; compiled output is.
- **`continue` inside an `lx` `for` jumps over the step.** That is the host
  language's own trap and has nothing to do with `lock`, but a `lock` body is a
  good place to meet it, so `tests/05-lock-exits.lx` uses a `while` for its
  `continue` case and says why.

### Reserved words

`spawn`, `await`, `intent`, `chan` and `lock` are words of the **whole
program**, like every Tier 3 registration (`docs/surface.md` § "Registration
reserves the word for the whole program"), and so is `chan_recv`. A program that
wants `lock` as a variable name has to rename it, or drop `conc.mc` from
`[compiler].modules`. `test.sh` asserts the refusal for each of the five.

---

## The one line in `examples/lang`

A compiler holds exactly **one** `user_init`, and in this stack it is
`lang.mc`'s. So `lang.mc` ends its `user_init` with

```c
    lg_more();
```

and `examples/lang/lang_solo.mc` — a new five-line file, listed last in that
project's `[compiler].modules` — is the empty default. Stacking a module means
leaving `lang_solo.mc` out and defining `lg_more` in the new module instead,
which is what `conc.mc` does. That is the entire change to `examples/lang`:
one call, one file, one TOML line. Nothing about threads, channels, intents or
locks is anywhere in it.

Everything else the two modules share goes through public API:

| what | how |
|---|---|
| `{`, so that a scope close can check for un-awaited intents | `syntax_stmt_find(K_LBRACE)` + `syntax_stmt_fn_at` + `callp` — the host's own handler, wrapped |
| the callee's declared signature | `decl_find` / `decl_ret` / `decl_nparams` (M31 § 2.1) |
| the exit edges of a `lock` | `on_jump` + `p_blockdepth` (M31 § 2.2) |
| whether a result or an argument is an object | the host's own `lg_ecls` / `lg_eif` / `lg_eown` |
| an intent local that the host releases like any object | a row in the host's class table |
| `conc_boot()` at the top of `main` | `pass(&f)` (Tier 2) |

---

## Files

| file | lines | what it is |
|---|---|---|
| `conc.mc` | 65 | the module: the includes and `lg_more()`, where every hook is registered |
| `conc_tab.mc` | 167 | the tables, as flat records with named getters |
| `conc_stmt.mc` | 367 | the four statements, `chan_recv`, the chained `{`, `on_jump`, the boot pass |
| `lib/*.mc` | 950 | the runtime (see above) |
| `lib/prelude.lx` | 51 | what every `.lx` here includes |
| `main.lx` | 83 | the demo: a channel of objects, a parallel sum, an await chain |
| `tests/*.lx` | 21 tests | ten that run — three of them to a runtime panic — and eleven that must be refused |
| `test.sh` | 220 | builds with `mc build --compiler-only`, runs the suite under a timeout, checks determinism, `--dump-asm` and the reserved words |

`mc limits examples/conc` on a clean tree, for the taught compiler: 60 572
nodes, 22.4 MiB of the 32 MiB static arena, **grow 0** everywhere (`ins` reports
`tight`, which is the report saying the reserve is close, not that anything
failed). `[limits] tolerance = 1.0` is what buys that: at the default 0.25 the
`nodes`, `ins` and heap tables all double mid-build.
