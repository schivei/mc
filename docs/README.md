# `mc` documentation

A compiler small enough to read, written in itself. `mc` compiles a schoolbook-C language — seven
types, one opaque pointer, `if` and `loop` — into AArch64 Mach-O and ELF, writes and signs the
executable itself, and reaches a fixed point where one generation is byte-identical to the next.
Everything the core leaves out — `while`, `for`, classes, a second backend, a whole object
format — you teach it from ordinary `mc` source.

**New here? Start at [guide/00-getting-started.md](guide/00-getting-started.md).** It goes from
nothing to a running signed binary in about two minutes.

---

## The guide — task-oriented, read in order

| page | what it covers |
|---|---|
| [Getting started](guide/00-getting-started.md) | install, first program, `--exe`, the five dumps |
| [One file, one program](guide/10-single-file.md) | the working tour of the language: types, memory, control flow, `extern`, function pointers |
| [A project](guide/20-project-toml.md) | `mc build` and every `mc.toml` section by example |
| [Teaching the compiler](guide/30-teaching.md) | `#token`/`#infix`/`#prefix`, `#rule` and the prelude, then the syntax hooks with a worked toy language |
| [Emitting bytes](guide/40-backends.md) | `#section`, `#opcode`, `emit()`/`reloc()`, `pass()`, `backend()`, and the `arm64-surface` proof |
| [Cross-compiling](guide/50-cross-compile.md) | Linux arm64 targets, sysroots, external linkers |
| [Two worked examples](guide/60-examples.md) | `examples/api` and `examples/lang`, walked through |
| [How `mc` compiles itself](guide/70-bootstrap.md) | the bootstrap chain, the fixed point, and the determinism rules for contributors |
| [Footprint](guide/80-footprint.md) | what the smallest program costs per target, floor by floor, and the ceilings that guard it |
| [`mc` on a Linux host](guide/90-linux-host.md) | the host layer, the Linux bootstrap chain, cross-building the compiler, what `make check` skips on Linux and why |
| [A new primitive](guide/96-a-new-primitive.md) | teaching `mc` a value type it has never heard of: `type_new`, `syntax_lit`, a derived machine, `intrinsic` |
| [`mc` on a Windows host](guide/95-windows-host.md) | the same for Windows: no C runtime at all, the kernel32 runtime object, the `.exe` suffix, CRLF, and the Windows `make check` subset |
| [Recreating the compiler](guide/98-recreating-the-compiler.md) | "I want a compiler for X and nothing else": the five parts of `<mc/core>`, what each omitted one costs in bytes and in capability, removing a type or an intrinsic, and declaring the width of `uptr` |
| [A new architecture](guide/97-a-new-architecture.md) | adding an instruction set and an output format from OUTSIDE the compiler: the three registrations, how to prove the encoder, which families it reaches (including 8-bit parts, since M40) and which one it excludes permanently |

## The reference — exhaustive, read by lookup

| page | what it lists |
|---|---|
| [language.md](reference/language.md) | grammar, types, precedence, semantics, limits |
| [directives.md](reference/directives.md) | all ten `#` directives, with errors and examples |
| [cli.md](reference/cli.md) | every command, flag, dump and exit code |
| [toml.md](reference/toml.md) | every `mc.toml` key: type, default, meaning |
| [hooks.md](reference/hooks.md) | every public function of the parser and hook API |
| [sysroot.md](reference/sysroot.md) | where a cross link finds its files: the resolution chain, the cache, the messages |
| [objects.md](reference/objects.md) | the object model (`sec_*`, `sym_*`, `reloc_add`) and the codegen accessors (`gen_*`) |
| [machine.md](reference/machine.md) | the machine task contract: the 31 tasks, and the three instruction sets side by side |
| [diagnostics.md](reference/diagnostics.md) | every message the compiler emits, with cause and fix |
| [bundle.md](reference/bundle.md) | every `#include <name>` the binary carries |
| [sandbox.md](reference/sandbox.md) | `mc sandbox`: the box, the shim, `check`, and what is *not* isolated |

## The design documents

These predate this tree and record *why* things are the way they are. The guide and the reference
describe the compiler as it is; these describe the decisions that produced it.

| document | subject |
|---|---|
| [plan.md](plan.md) | the language, the teaching surface, the architecture, the budget, the milestones |
| [core-language.md](core-language.md) | the core language as specified milestone by milestone |
| [surface.md](surface.md) | the teaching surface, tier by tier, with the acceptance criteria |
| [build.md](build.md) | `mc build`, the bundle, `#embed`, Linux targets, limits |
| [bootstrap.md](bootstrap.md) | cutting `clang`, then `ld`, then the checkout |
| [determinism.md](determinism.md) | the rules that make the output reproducible |
| [macho-notes.md](macho-notes.md) | every Mach-O field, with its verified value |
| [ci.md](ci.md) | the GitHub Actions workflows and the release process |
| [specs/](specs/) | one spec per milestone, `M1.md` … `M30.md` |

There is deliberate overlap between the design documents and this tree — `surface.md` and
`guide/30`+`guide/40`, `build.md` and `guide/20`+`guide/50`, `core-language.md` and
`reference/language.md`, `bootstrap.md` and `guide/70`. The guide and reference are written
against the compiler as it stands today and are checked mechanically; the design documents keep
the reasoning and the milestone history.

---

## How this documentation is checked

`scripts/check-docs.sh`, inside `make check`, does three things:

1. **Coverage.** Every `p_*`, `syntax*`, `type_alias`, `pass`, `backend*`, `machine*`, `sec_*`,
   `sym_*`, `reloc_add` and `gen_*` definition in `src/`, every CLI flag, every TOML key the
   driver looks up, and every directive in the lexer's table must appear in `reference/`. The
   lists are extracted from the source, never written down in the script, so a new public
   function fails the check until it is documented.
2. **Samples.** Every fenced ```` ```mc ```` block in this tree is compiled by the real compiler.
   A block that declares `// expect-exit:` or `// expect-stdout:` is built with `--exe` and
   **run**, and its output compared; one that declares `// expect-error:` must fail to compile
   with that text on stderr. A block may name the compiler that should build it —
   ```` ```mc taught=examples/lang ```` — in which case `mc build` produces that compiler first.
3. **Links.** Every relative markdown link in this tree resolves to a file that exists.

So every command, every message and every program you see here was actually run.
