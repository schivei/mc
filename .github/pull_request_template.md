<!--
Merging this pull request cuts a release: a tag, a GitHub Release with the
binary, and a Pages deploy. Read CONTRIBUTING.md once before the first one.

The OWNER merges, and the only merge method is SQUASH. The squash commit's
subject is what autotag.yml reads, and the title of this pull request becomes
the tag annotation and the release note -- so write the title as a release note,
not as "fixes".
-->

## Milestone

<!-- MNN and its spec, e.g. M12 - docs/specs/M12.md. "None" for a hotfix. -->

- Milestone:
- Spec:

## What changed

<!-- What a reader of the diff would not guess. Name the files that carry the
     decision, not every file that was touched. -->

## Batch report

<!-- The facts each agent reported back, assembled by the architect: what was
     built, the commands that were run, and their output. Suppositions do not
     belong here -- only commands and what they printed. -->

## Checks run locally

<!-- `make check` is the whole gate. Paste the counts it printed. -->

```
$ make check
```

- [ ] `make check` is green on macOS arm64 (tests, the bootstrap fixed point,
      the taught-surface demos, the examples, the docs)
- [ ] `make budget` still fits: stage0 is under 3000 lines
- [ ] `tests/golden/mc2.sha256` was rewritten only if the codegen really
      changed, and the reason is written above
- [ ] `CLAUDE.md` § Estado carries this milestone's entry

## Release

<!-- No label = patch. Add exactly one of these when patch is wrong.
     The label has to be on the pull request BEFORE it is merged: autotag.yml
     reads the labels of the pull request the squash commit came from. -->

- [ ] `release:minor` — a new capability, nothing broken
- [ ] `release:major` — a break in the language, the CLI or the file formats
- [ ] `release:skip` — merge without cutting a version (CI-only, docs-only)
- [ ] none of the above: this is a **patch**, and the default is correct
