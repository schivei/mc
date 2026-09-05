# Recreating the compiler

You want a compiler for one target and nothing else: your machine, your object
format, your word width, and none of the three writers, two machines and one
project driver that `mc` carries because `mc` is hosted on macOS, Linux and
Windows. This page is how.

Nothing here edits `src/`. The whole of it is an entry file, a module or two,
and a `mc.toml` — the same surface `examples/kernel` (a RISC-V 64 micro-kernel)
and `examples/lang` (a language with classes and generics) are built on.

## 1. The core is five parts

`<mc/core>` is not one thing. Since M41 it is the sum of five parts, each a
bundled name you include or leave out:

| part | what is in it | you need it when |
|---|---|---|
| `<mc/core_min>` | `arena` `lz` `objmodel` `lex` `ast` `parse` `gen_resolve` `gen_walk` `hooks` `cli` | always — it is the compiler |
| `<mc/core_machines>` | the AArch64 and x86-64 machines | your target is one of those two |
| `<mc/core_writers>` | `sha256`, the Mach-O writer and the direct-executable, ELF and COFF backends | you emit one of those formats |
| `<mc/core_build>` | `toml` `driver` `sysroots` `sysroot` `stubs` `limits` | you want `mc build`, `mc limits`, `mc sysroot` |
| `<mc/core_bundle>` | the LZ-compressed standard library | you want `#include <name>` |

[`examples/avr`](../../examples/avr/README.md) is this page done for real, and the
numbers in it are measured: `<mc/core_min>` + `<mc/core_build>` + an AVR machine
+ an ELF32 writer + four taught words is **339 187 bytes against `mc`'s 776 467**
(the same `macho-exe` backend building both), and
because it leaves `<mc/core_bundle>` out, every `#include` in that project is a
relative path.

`src/core.mc` is literally those five plus `main.mc`, and
`scripts/check-parts.sh` compiles both spellings and `cmp`s the two objects —
so the table above cannot drift from the code.

## 2. The smallest compiler that exists

```
#include <mc/host>
#include <mc/core_min>
#include "machine_avr.mc"
#include "image_avr.mc"

i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    return mc_main(argc, argv, envp);
}

void user_init() {
    machine_avr_init();                    // your machine, 31 task slots
    backend("avr-image", &backend_avr);    // your writer
    backend_default("avr-image");          // what `mc x.mc -o x.bin` means here
    type_set_width(TY_UPTR, 2);            // your pointers are two bytes
    intrinsic_disable("ld64");             // ... so the wide pair is unreachable
}
```

**`backend_default()` did not always work, and the fix is worth knowing about.**
Until the post-M41 review batch, `mc_main` resolved the default backend BEFORE
it called `user_init()`, so a compiler whose only backend is registered there
still needed `--backend=NAME` on the command line -- and needed it even for
`--dump-ast` and `--dump-asm`, which never reach a backend at all. The
resolution now happens after `user_init()` and after the dump modes have
returned (`src/cli.mc`), which is the same rule M39.5 wrote for `[target]` in
`mc build`. `examples/avr` was written while the old order was still in place
and still passes `--backend=avr-image` on every single-file command; it does not
have to any more.

Six lines of `user_init` and a `main` that names the parts. That is the whole
mechanism; everything else on this page is what each of those lines buys and
what leaving a part out costs.

`mc_main(argc, argv, envp)` is `<mc/core_min>`'s: the flags, the `--dump-*`
modes, `user_init()` at the one correct moment, and the parse → passes → fold →
backend pipeline. `main()` is yours, and it is the only file that names the
parts — which is exactly what `src/main.mc` is for `mc` itself.

## 3. What each omitted part costs

Measured on this machine, with `mc --dump-syms` on each spelling. The compiler
in the first row is `<mc/core_min>` plus the probe machine and null writer of
`lib/user_core_min.mc`; the last row is `mc` itself.

| spelling | `__text` | `__cstring` | `__data` | on disk |
|---|---|---|---|---|
| `<mc/core_min>` only (probe machine, null writer) | 147 224 | 7 034 | 2 496 | **219 417** |
|  + `<mc/core_machines>` | 183 664 | 7 795 | 6 224 | 260 543 |
|  + `<mc/core_writers>` | 232 712 | 8 683 | 6 640 | 315 934 |
|  + `<mc/core_build>` | 289 484 | 15 093 | 6 936 | 395 820 |
|  + `<mc/core_bundle>` | 293 180 | 15 454 | 374 800 | 760 013 |
| `mc` itself (`<mc/core>` + `<user_default>`) | 292 968 | 15 443 | 374 800 | **759 875** |

The last two rows differ by a few hundred bytes and nothing else: the cumulative
spelling carries the probe machine and the null writer that the first row needs,
`mc` carries `src/main.mc` and an empty `user_init`. So each part costs:

| part | `__text` | on disk |
|---|---|---|
| `<mc/core_machines>` | +36 440 | +41 126 |
| `<mc/core_writers>` | +49 048 | +55 391 |
| `<mc/core_build>` | +56 772 | +79 886 |
| `<mc/core_bundle>` | +3 696 | **+364 193** |

**A compiler with one machine and one writer of its own is 219 KB against `mc`'s
760 KB — 29%, about a third.** Of the 540 KB it does not pay, 364 KB is the
bundle blob and 146 KB is code. Reproduce the table with
`sh scripts/check-parts.sh` (its two rows) or by spelling out the cumulative
includes yourself; nothing here is written down twice.


The capability column is the part of this that is not a number:

| omitted | you lose |
|---|---|
| `<mc/core_machines>` | nothing, once you register a machine of your own. With none at all, `mc_main` says `no machine registered` before it lowers anything. |
| `<mc/core_writers>` | every built-in backend: `macho`, `macho-exe` (`--exe`), `elf-obj`, `elf-obj-x86_64`, `coff-obj-arm64`, `coff-obj-x86_64`. Your own writer is a `backend()` registration and `backend_default()` names it. |
| `<mc/core_build>` | `mc build`, `mc limits` and `mc sysroot` — the compiler becomes a LEAF: it compiles a source file, it does not read a project and it cannot build another compiler. `mc` with no argument prints two usage lines instead of six. You also lose the pre-scan that pre-sizes the tables (M23); they grow from the seeds in `src/arena.mc` instead, which is what `src/astdump.mc` has always done. |
| `<mc/core_bundle>` | `#include <name>` entirely. Your programs use relative includes, as `examples/kernel/lib` already does — or you ship your own blob (§ 6). |

## 4. Removing what the core still offers

Two mechanisms, both meant for a dialect that must not let a word through:

* `type_disable(TY_U32)` — `u32 x;` is refused with
  `u32: removed by this compiler`, at the token. It removes the **word from the
  surface**, not the type from the model: `ld32()` still yields `TY_U32` and
  `type_width(TY_U32)` is still 4. Disabling `i64`, `uptr` or `void` is
  permitted and makes the language unusable; there is no special case.
* `intrinsic_disable("ld64")` — a call is refused with
  `ld64: removed by this compiler`, at the call site. It covers the core
  intrinsics and the ones `intrinsic()` registered, by name.

There is no `backend_remove`, `machine_remove` or `target_remove`, and there
will not be: once the registrations live in the parts, "not registered" is the
default and removal has no caller.

## 5. Overriding the last fixed decision

`type_set_width(TY_UPTR, w)` declares how wide a pointer is. Three things in
the walker follow it: the granule a frame slot is rounded to, the alignment of
a frame, of a local array and of a zerofill placement, and the size of the
pointer a string literal writes into a `uptr[]` initializer (with a relocation
of the matching length). Every other type refuses: `i64` folds in 64 bits at
parse time and would disagree with the machine.

It is inert when nobody calls it — the width is 8, the granule 8, the alignment
16 — which is why every object `mc` produces is unchanged by the mechanism's
existence.

Two consequences worth writing on the wall of a project that uses it:

* `uptr t[1000]` is 8000 bytes and refused as `local array too large` on
  arm64, and 2000 bytes and accepted at width 2. The same source, two answers.
* `#define`d record offsets (`#define NEXT 8`) mean different fields at
  different widths. `sizeof` does not exist in this language; write them as
  `N * W` and define `W` per dialect.

What is NOT overridable, and why: `MAXDEPTH` (expression depth, not a target
fact), `MAXPARAMS` (the ABI — since M38 the machines implement the stack half),
the section names (`__TEXT,__text` and friends are opaque labels your writer
maps, as `backend_elf` and `backend_coff` already do), the entry symbol
`_main` (the writer's), and `HEAP_SIZE` (it is `bss`, absent from the file, and
dynamic since M23 — a static array's size cannot be set from `user_init`).

## 6. Your own bundle

A debloated compiler can still have `#include <name>`, with its own, much
smaller library and at zero core lines. `tools/bundle.mc` is four includes —
`<mc/arena>`, `<lz>`, `<mc/bundle_data>`, `<mc/bundle>` — over a manifest of
`NAME<TAB>PATH` lines. Write the same tool against those bundled names,
generate a `bundle_data.mc` from your own manifest, and have your compiler
include that file plus `<mc/bundle>` instead of `<mc/core_bundle>`:

```
#include <mc/host>
#include <mc/core_min>
#include "my_bundle_data.mc"
#include <mc/bundle>
#include "machine_avr.mc"

i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    lex_set_bundle(&bundle_open);
    return mc_main(argc, argv, envp);
}
```

`bundle.mc` needs nothing but `BUNDLE_COUNT` and the two arrays the generator
emits. See `docs/reference/bundle.md` § Your own bundle.

## 7. Building it with `mc build`

`[compiler].core` takes a bundled name as well as a path: a value that starts
with `<` is emitted verbatim into the generated compiler source.

```toml
[project]
name  = "blink"
entry = "main.mc"
out   = "build/blink.bin"

[compiler]
core    = "<mc/core_min>"
modules = ["machine_avr.mc", "image_avr.mc", "avr.mc"]
out     = "build/mc-avr"
```

`mc build` then writes `build/mc-avr.mc` = `#include <mc/host>` +
`#include <mc/core_min>` + your three modules, compiles it with the HOST's
executable backend, and runs it on `main.mc`. Nothing about the compiler it
builds has to run on the host's architecture — it is a program like any other.

## 8. Where to look next

* `docs/reference/bundle.md` § The parts — the authoritative list and the
  naming rule.
* `docs/reference/hooks.md` — `backend_default`, `machine_use_if`,
  `subcommand`, `on_plan`, `type_disable`, `intrinsic_disable`,
  `type_set_width`, and the seven older registrations.
* `docs/reference/machine.md` — the 31 tasks a machine fills, and the two
  functions (`walk_word`, `walk_align`) the declared width feeds.
* `docs/guide/97-a-new-architecture.md` — writing the machine itself.
* `examples/kernel` — a complete recreated compiler that keeps `<mc/core>`,
  because it wanted `mc build` and the bundle. It would work on
  `<mc/core_min>` plus its own writer too; what it would give up is § 3's table.
