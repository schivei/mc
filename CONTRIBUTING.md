# Contributing to mc

Development happens on branches and lands through pull requests. **Every merged
pull request cuts a version**: the merge pushes a tag, the tag builds and
publishes a GitHub Release, and a documentation change deploys the site. There
is no separate "release day" and no `VERSION` file to bump — the tags are the
version, and merging is what creates them.

`docs/ci.md` is the reference for the workflows themselves. This page is the
flow.

---

## Who does what

The project is run by one owner working with an architect session and a set of
implementer agents (`.claude/agents/`, described in `CLAUDE.md`). The roles are
not decoration: they decide who touches `main`.

| role | does | never does |
|---|---|---|
| **Owner** | merges the pull request, by squash | — |
| **Architect** | creates the branch, delegates the work, assembles the batch report, opens the pull request | merges; writes the code |
| **Implementer agents** (`stage0-dev`, `mc-dev`, `docs-writer`, `designer`, `ts-dev`, …) | commit on the branch the architect made | commit on `main`; open or merge the pull request |
| **`reviewer`, `verifier`** | read, run, and report facts — commands and their output | change anything |

**The architect never merges.** Only the owner does, and only by squash.

---

## The flow

1. **Branch.** The architect creates one branch per milestone, named
   `mNN-short-name` — `m12-structs`, `m13-lsp`. A change that is not a
   milestone uses the same shape with a word instead of a number:
   `docs-ci-rewrite`, `fix-reloc-guard`.

2. **Commit on the branch.** Implementer agents commit there. Nobody commits on
   `main`.

3. **Run `make check` locally.** It is the gate, and it is the same thing CI
   runs:

   ```sh
   make stage0     # clang compiles the C23 seed -- once, and never again
   make mc1        # the seed compiles src/mc.mc into the real compiler
   make check      # everything: see below
   ```

   `make check` runs `budget`, `test`, `check-lex`, `check-ast`, `check-bundle`,
   `check-asm`, `check-obj`, `bootstrap` (the fixed point plus the golden
   SHA-256), `check-surface`, `test-exe`, `check-mc`, `check-standalone`,
   `check-toml`, `check-build`, `check-limits`, `test-linux`, `check-examples`,
   `check-lang`, `check-docs`, `site` and `check-site`.

   `test-linux` self-skips without `ld.lld` and Docker, and `check-site` skips
   its Python validators without `python3`. Everything else has to be green
   before the pull request is opened. Report the counts it printed, not the fact
   that you ran it.

4. **Open the pull request.** The architect opens it against `main`, filling in
   `.github/pull_request_template.md`: the milestone and its spec, what changed,
   the **batch report** (what each agent did, the commands they ran, and the
   output they printed), and the local `make check` result.

   The **title is the release note**. It ends up in the tag annotation and in
   the GitHub Release body, so write it as a line someone reading the releases
   page would want: `M12: structs, taught from the surface`, not `m12 wip`.

5. **Label the release level.** No label means **patch**. Add exactly one of
   `release:minor`, `release:major` or `release:skip` when patch is wrong — see
   the table below. The label must be on the pull request **before** it is
   merged.

6. **Wait for CI.** Two required checks run on the pull request:
   *make check (macOS arm64)* and *Link and run the suite (linux/arm64)*.

7. **The owner merges, by squash.** "Ready for merge" means all three of:

   - CI is green;
   - the batch report is in the pull request body;
   - the release label is set, when the change is not a patch.

8. **The merge does the rest**, with nobody pressing anything: `autotag.yml`
   computes the next version, pushes the annotated tag, and starts
   `release.yml`, which builds `mc`, runs the whole suite with the binary it is
   about to ship, packages it, and publishes the Release. A change under
   `docs/` or `site/` also redeploys <https://minicompiler.dev>.

---

## Release labels

| label | effect on the version | when |
|---|---|---|
| *(none)* | `0.4.2` → `0.4.3` | the default: a fix, a refactor, a new test, a doc |
| `release:minor` | `0.4.2` → `0.5.0` | a new capability that breaks nothing |
| `release:major` | `0.4.2` → `1.0.0` | a break in the language, the CLI or the file formats |
| `release:skip` | none — merged, no tag, no release | a change that cannot affect a user of the binary |

Only one label is read. If several are present the highest wins, in the order
`release:skip`, `release:major`, `release:minor`, patch.

Versions are plain semantic versions, `X.Y.Z`. **There are no pre-releases**:
no `-rc1`, no `-beta`. If one is ever needed it is a hand-pushed tag, not
something a merge can produce.

---

## Direct pushes to `main`

`main` is protected: no force pushes, no deletions, and the two CI checks are
required. Administrators are **not** included in the restriction, on purpose —
the owner can still push a one-line documentation fix straight to `main` without
opening a pull request.

Such a push is not a release. `autotag.yml` looks for the pull request the
commit came from, finds none, logs *"this push to main is not a pull-request
merge — no tag, no release"*, and stops. Nothing breaks; the change simply does
not get a version. The next merged pull request carries it along.

Use it for typos and broken links. Anything that touches `stage0/`, `src/`,
`lib/`, `tests/` or `scripts/` goes through a pull request, because those are
the things `make check` is about.

---

## What the code has to look like

`CLAUDE.md` is the short version and `docs/plan.md` is the long one. The rules
that fail a build if broken:

- **`stage0/*.c` is under 3000 lines in total** (`make budget`). Over is a
  build failure, not a warning.
- **stage0 uses five libc functions**: `open`/`read`/`write`/`close`/`_exit`.
  No stdio, no malloc, no qsort.
- **Every file field is written byte by byte, little-endian**, through
  `buf_u8`/`u16`/`u32`/`u64`. Never `fwrite(&struct)`.
- **Determinism** (`docs/determinism.md`): no pointer hashing, no iteration over
  a hash table to produce output, no `__FILE__`, no dates, no absolute paths,
  padding zeroed. Two builds of the same source are the same bytes.
- **The C is shaped like the `.mc` it becomes**: small functions, flat data in
  an arena, no struct-in-file, no clever textual macros.
- **Comments, messages, and docs are in English; identifiers are ASCII.**
  No emoji.
- **Do not read or copy code from other projects.**

## Where things live

| path | what |
|---|---|
| `stage0/` | the C23 seed, compiled by `clang` exactly once |
| `src/` | the compiler, in `mc` — the transliteration of the seed, plus everything past it |
| `lib/` | the bundled library: `sys.mc`, `prelude.mc`, `io.mc`, `mc/core` |
| `tests/` | the suite `scripts/test.sh` runs |
| `examples/` | the worked examples `make check-examples` builds |
| `docs/` | the documentation, rendered to the site by `site/gen` |
| `site/` | `mcsite`, the site generator, written in `mc` |
| `scripts/` | every check `make check` calls |
| `.github/workflows/` | CI, autotag, release, site — see `docs/ci.md` |

## Reporting a bug

Open an issue with the source that reproduces it, the command, and what the
command printed. `mc` is small enough that a ten-line reproducer is usually the
whole bug report.
