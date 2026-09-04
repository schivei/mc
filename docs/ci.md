# ci.md — the GitHub Actions workflows

Five workflows live in `.github/workflows/`. Two constraints shape them.

**`mc` only builds and runs on macOS arm64 today** (`docs/plan.md` § Phase 2 — "mc itself keeps
running on macOS arm64 for now; cross-hosting comes later with CI"), while part of what
`make check` proves has to happen on a Linux machine. That is why `ci.yml` is two jobs and why
every build job runs on `macos-15`.

**Development happens on pull requests, and every merged pull request cuts a version.** There is
no `VERSION` file and no release day: merging is what creates the tag, and the tag is what builds
the release. The contributor-facing half of that is
[CONTRIBUTING.md](https://github.com/schivei/mc/blob/main/CONTRIBUTING.md); the machinery is here.

| workflow | trigger | machine | what it does |
|---|---|---|---|
| `ci.yml` | pull requests to `main`, push to `main` | `macos-15` + `ubuntu-24.04-arm` | `make check`, then the Linux suite in two halves |
| `autotag.yml` | push to `main` | `ubuntu-24.04` | if the push is a merged pull request: computes the next version from its labels, pushes the annotated tag `vX.Y.Z` and starts `release.yml` |
| `tag.yml` | manual | `ubuntu-24.04` | the escape hatch: validates `X.Y.Z` against the newest tag, pushes the tag and starts `release.yml` |
| `release.yml` | dispatched by `autotag.yml`/`tag.yml`, tag `v*`, or manual | `macos-15` | builds `mc`, verifies it, packages it, publishes the GitHub Release |
| `site.yml` | push to `main` touching `site/**` or `docs/**`, or manual | `macos-15` + `ubuntu-24.04` | renders `docs/` with `mcsite` and deploys it to GitHub Pages (<https://minicompiler.dev>) |

All five set `concurrency` groups and per-job `timeout-minutes`, and each declares the narrowest
`permissions` it needs.

## Who touches what

The workflows encode a division of labour, so it is worth writing down once:

- the **architect** creates the branch (`mNN-name`) and opens the pull request; it never merges;
- **implementer agents** commit on that branch, never on `main`;
- the **owner** merges, and the only merge method is **squash**.

"Ready for merge" is three things at once: CI green, the batch report in the pull request body,
and the release label set when the change is not a patch. Everything after the merge button is
`autotag.yml` and `release.yml`.

## Versioning

The **tags are the only source of truth**. `git tag -l 'v*' --merged HEAD --sort=-v:refname | head -1`
is the current version, and nothing in the working tree records it — the `VERSION` file that used
to exist was deleted when releases moved to pull requests, because two sources of truth is one too
many. `release-assets.sh` takes the version from its first argument, which `release.yml` derives
from the tag.

Versions are plain semantic versions, `X.Y.Z`. **No pre-releases**: `release.yml` still marks a
`-`-suffixed tag as a GitHub pre-release, but neither `autotag.yml` nor `tag.yml` will make one,
and `scripts/next-version.sh` rejects `0.2.0-rc1` with a message that says so. If a pre-release is
ever wanted it is a hand-pushed tag, deliberately outside the automation.

The arithmetic lives in one place:

```sh
scripts/next-version.sh 0.1.9 minor    # -> 0.2.0
scripts/next-version.sh v1.4.2 major   # -> 2.0.0
scripts/next-version.sh --gt 0.2.0 0.1.99   # exit 0: strictly newer
scripts/next-version.sh --test         # 40 assertions, no framework, no network
```

Three lines of arithmetic with no test is how a release ends up as `0.1.10` when `0.2.0` was
meant, so the assertions are part of the script and `--test` runs them anywhere.

---

## `ci.yml`

Triggers: `pull_request` against `main`, and `push` to `main`. The concurrency group is
`ci-${{ github.event.pull_request.number || github.ref }}` with `cancel-in-progress: true`, so a
new push to a pull request cancels its previous run.

**The two job names are the required status checks on `main`** — `make check (macOS arm64)` and
`Link and run the suite (linux/arm64)`. Renaming a job means updating the branch protection in the
same breath, or `main` starts requiring a check that no longer exists and nothing can merge.

### Job `check` — `macos-15`

Runs `make check` unchanged: `budget`, `test`, `check-lex`, `check-ast`, `check-bundle`,
`check-asm`, `check-obj`, `bootstrap` (the fixed point plus the golden SHA-256), `check-surface`,
`test-exe`, `check-mc`, `check-standalone`, `check-toml`, `check-build`, `check-limits`,
`test-linux`, `check-examples`, `check-lang`, `check-docs`, `site` and `check-site`. No
environment variable is passed and the `Makefile` is not touched: the `test-linux` target already
guards itself, and `check-site` skips `checkhtml.py`/`contrast.py` when `python3` is absent
(the link check still runs).

`site.yml` therefore duplicates only the last two: the deploy job needs the rendered tree as an
artifact, not merely the proof that it renders.

```make
test-linux: build/mc1
	@if ! command -v ld.lld > /dev/null 2>&1; then \
	    echo "test-linux: SKIPPED (ld.lld not in PATH; brew install lld)"; \
	elif ! docker info > /dev/null 2>&1; then \
	    echo "test-linux: SKIPPED (docker is not running; ...)"; \
```

GitHub's macOS runners have neither `ld.lld` nor Docker, so this target skips and the build stays
green. **The workflow installs nothing** — no Homebrew step and no Homebrew cache. Installing
`lld` would only change which of the two reasons the skip message names, because the runner would
still have no Docker to run a Linux binary in; and the half of the Linux work that does happen
here — cross-compiling to ELF — needs no linker at all. The Linux suite runs for real on the job
below.

Two artifacts come out:

- `mc-macos-arm64` — `build/mc-exe`, the self-hosted, `ld`-free compiler `make check` already
  builds for `check-standalone`. GitHub's artifact zip does not carry the executable bit, so a
  download needs `chmod +x mc-exe` (and, off a browser download, `xattr -d com.apple.quarantine`).
- `linux-arm64-objects` — the input to the second job, described next.

### The two-stage Linux design

`scripts/test-linux.sh` does three things in one pass locally: cross-compile each test to an ELF64
object, link it with `ld.lld` against a musl sysroot, and run it under
`docker --platform linux/arm64`. Those three steps do not fit on one runner:

- only the macOS runner has `mc`, so only it can cross-compile;
- only a linux/arm64 runner can execute the result without emulation;
- GitHub's macOS runners have no Docker, so the local trick of running the binaries in a container
  is not available there.

So the script grew two flags, and the default (no flag) is byte-for-byte what it always was:

```sh
scripts/test-linux.sh                          # unchanged: build + link + run in Docker
scripts/test-linux.sh --build-only OUTDIR [MC] # cross-compile only
scripts/test-linux.sh --run-only OUTDIR        # link and run
```

`--build-only` needs `mc` and nothing else — no `ld.lld`, no Docker, no sysroot. It writes an
`mc.toml` with `kind = "obj"`, so the driver stops at the ELF object, and fills `OUTDIR` with:

```
OUTDIR/<name>.o         the ELF64 relocatable
OUTDIR/<name>.expect    "exit: N" and, when the test declares one, "stdout: TEXT"
OUTDIR/manifest         one "<name> <linkmode>" line per object, in test order
OUTDIR/skipped          the `// skip-linux:` tests and their reasons
```

`<linkmode>` is `musl` (crt objects plus `libc.a`) or `nolibc` (`-nostdlib -e _start`, the
`tests/linux/070-nolibc.mc` case).

`--run-only` reads the manifest, links each object with `ld.lld` — the same argument lists the
default mode puts in `[linker].args`, minus the `{libs}` placeholder, which is empty for these
tests — and runs it. On a linux/arm64 host it runs the binary directly; anywhere else it falls
back to the same `docker run --platform linux/arm64 alpine:3` the default mode uses, which is how
the split can be exercised end to end on a Mac. It needs `ld.lld` and the sysroot, and it does
**not** need `mc`. The repository still has to be checked out and the working directory still has
to be its root, because `tests/025-linecount.mc` opens its own source by a relative path.

`MC_SYSROOT` overrides the sysroot directory (default `build/sysroot/linux-aarch64`) for the two
modes that link.

### Job `linux-arm64` — `ubuntu-24.04-arm`

Downloads `linux-arm64-objects`, installs `lld` from apt, obtains the musl sysroot, and runs
`scripts/test-linux.sh --run-only`. `ubuntu-24.04-arm` runners are free for public repositories.

The sysroot is the same four files the local flow uses (`crt1.o crti.o crtn.o libc.a`), fetched by
`scripts/sysroot-linux.sh` out of an `alpine:3` container — Docker *is* available on the Ubuntu
runners. It is cached on the hash of that script, and the script is itself a cache: with the four
files present it does nothing. If Docker is ever unavailable there, the step falls back to
Debian's `musl-dev` (`/usr/lib/aarch64-linux-musl/`), which ships the same four objects.

---

## `autotag.yml`

Runs on **every push to `main`**. Most of the time that push is a squash-merged pull request, and
then this workflow is the whole release button.

### 1. Which pull request is this?

Three lookups, in order; the first that answers wins.

```sh
gh api "repos/$REPO/commits/$SHA/pulls" --jq '[.[] | select(.merged_at != null) | .number] | max // empty'
gh pr list --state merged --search "$SHA" --limit 1 --json number --jq '.[0].number // empty'
git log -1 --format=%s "$SHA"     # `Title (#12)`, or `Merge pull request #12 from ...`
```

The **API lookup is the primary method** because it is the one that works for a squash merge,
which is the only merge method this repository allows. A squash produces a brand-new commit on
`main` with no parent inside the pull request, so nothing about its ancestry names the pull
request — but GitHub still associates the commit with it, and
`GET /repos/{owner}/{repo}/commits/{sha}/pulls` returns it. The search index is a fallback for the
seconds after a merge when the association may not be queryable yet. The commit subject is the
last resort, and it handles both shapes: `(#12)` at the end of a squash subject, and
`Merge pull request #12 from …` for a merge commit, which this repository does not produce but a
fork might.

Whatever number is found is then confirmed with `gh pr view`: the pull request has to be
**MERGED**. A hand-written commit subject that happens to end in `(#12)` therefore cannot cut a
release for an unrelated pull request.

If no pull request is found the job stops with a notice — *"this push to main is not a
pull-request merge — no tag, no release"* — and the run is green. **That path is deliberate and
has to keep working**: `main` allows administrator pushes so the owner can fix a typo or a broken
link without opening a pull request. Such a push simply does not get a version.

### 2. Which bump?

From the pull request's labels, highest first:

| label | bump | `0.4.2` becomes |
|---|---|---|
| `release:skip` | none — merged, no tag, no release | `0.4.2` |
| `release:major` | major | `1.0.0` |
| `release:minor` | minor | `0.5.0` |
| *(none)* | patch — the default | `0.4.3` |

The label has to be on the pull request before it is merged; `autotag.yml` reads the labels of the
pull request it just identified, at the moment the push arrives.

### 3. Which version?

```sh
base=$(git tag -l 'v*' --merged HEAD --sort=-v:refname | head -n 1)
version=$(scripts/next-version.sh "$base" "$BUMP")
```

With **no `v*` tag reachable at all**, there is nothing to bump: the first release is the
`SEED_VERSION` written at the top of the workflow — `0.1.0`, the value the deleted `VERSION` file
carried — cut exactly as written. That branch runs once in the life of the repository.

The job then refuses to move a tag that already exists, creates the annotated tag on the merge
commit, and pushes it with `GITHUB_TOKEN`:

```
mc v0.1.1

#12 M12: structs, taught from the surface

https://github.com/schivei/mc/pull/12
```

That annotation is the release body (`release.yml` reads it back), which is why the pull request's
title is written as a release note. The title is untrusted text: it is passed between steps
through a file in `$RUNNER_TEMP`, never interpolated into a script.

### 4. Start the release

The same `gh workflow run release.yml --ref "v$VERSION" -f tag="v$VERSION"` that `tag.yml` uses,
with the same `continue-on-error` and the same job summary — see *Why the dispatch* below.

### Concurrency, and what is not checked

`concurrency: group: autotag, cancel-in-progress: false`, shared with `tag.yml`. Two merges landing
seconds apart must produce two tags in order, not one tag and one lost release, so nothing here is
ever cancelled.

`autotag.yml` does **not** wait for `ci.yml` on `main`, and does not re-check that the tree is
green. It does not have to: the required checks ran on the pull request before it could be merged,
and `release.yml` builds `mc` from the tag and runs the entire suite with the binary it is about
to ship. A tree that would fail fails there, loudly, before anything is published — the cost is a
tag pointing at a commit with no release, which `tag.yml` can supersede with the next number.

---

## `tag.yml`

The **manual escape hatch**, for the cases the merge path cannot express: a version that has to
skip a number, a re-release after a tag was deleted, or a release for a commit that reached `main`
without a pull request. `workflow_dispatch` with two inputs: `version` (required, `X.Y.Z`) and
`notes` (optional). It

1. rejects anything that is not a plain `X.Y.Z` — `scripts/next-version.sh` does the parsing, so
   the definition of a version lives in exactly one place;
2. refuses to overwrite an existing tag;
3. **fails unless the version is strictly newer than the newest existing tag**
   (`scripts/next-version.sh --gt`) — with the `VERSION` file gone, the tags are what a new
   version has to beat;
4. creates the annotated tag `vX.Y.Z` whose annotation is `mc vX.Y.Z` plus `notes`, and pushes it.

The input is read through an environment variable, never interpolated into the shell.

Then it starts the release:

```sh
gh workflow run release.yml --ref "v$VERSION" -f tag="v$VERSION"
```

### Why the dispatch, and why it works with the default token

*(The same reasoning applies to `autotag.yml`, which does the same thing.)*

**A tag *pushed* with the default `GITHUB_TOKEN` does not start another workflow.** That is
GitHub's guard against recursive runs, and it means `release.yml`'s `on: push: tags` trigger will
*not* fire for a tag either of these workflows created. The guard has exactly two documented
exceptions —
`workflow_dispatch` and `repository_dispatch` — so **dispatching** the release explicitly, with
the very same `GITHUB_TOKEN`, does start it. No personal access token and no extra secret are
involved; the job just needs `actions: write`, which it declares.

The dispatch targets `--ref "v$VERSION"`, the tag's own ref, so the release is built from the
workflow definition that was tagged rather than from whatever `main` looks like later.

The step is `continue-on-error: true`: if the dispatch fails, the tag is still pushed and the job
summary says to start `release.yml` by hand (Actions -> Release -> Run workflow -> the tag
`vX.Y.Z`). Nothing is lost either way, because `release.yml` also accepts the tag as an input.

---

## `release.yml`

Triggered by pushing a tag matching `v*`, or manually with the tag as an input.

Job `build` is a matrix with a single `include` entry today, `{ os: macos-15, target:
macos-arm64 }`. It checks out the tag and **derives the version from the tag name**: `v0.1.1`
becomes `0.1.1`, and the shape is validated by `scripts/next-version.sh`, the one place that knows
what a version looks like. There is nothing to cross-check it against — the tag *is* the version.
Then:

```sh
make mc1
build/mc1 --exe src/mc.mc -o dist/mc     # the ld-free, ad-hoc signed executable (M11)
codesign --verify --verbose=4 dist/mc
scripts/test.sh dist/mc                  # the whole suite, run by the binary being shipped
scripts/release-assets.sh "$VERSION" macos-arm64 dist/mc dist
```

The output is built directly as `dist/mc` on purpose: the identifier inside an ad-hoc signature is
the output file's basename (`docs/bootstrap.md` § M11), so the binary a user installs as `mc` has
to have been *written* as `mc`.

Job `build-future-hosts` is `if: false`. It holds the four targets that are not possible yet —
`linux-arm64`, `linux-x86_64`, `windows-arm64`, `windows-x86_64` — and turns on when **`mc` itself
runs on Linux and Windows**. What blocks each one is written next to it: `mc` is a macOS arm64
program (`src/driver.mc` uses `_NSGetEnviron`, which is libSystem-only — `docs/build.md` § Limits
of M14, M15 and M16), and Windows additionally waits for the COFF writer of M19/M20. M16 gave
Linux arm64 *targets*, not a Linux *host*. The milestone that flips `if: false` to `if: true` is
**"mc hosted on Linux/Windows"** — that one name covers all four entries, and until it lands the
job is skipped without allocating a runner.

Job `publish` collects the artifacts, takes the **tag's annotation as the release body**, appends
an install snippet and the checksums, and calls `gh release create --verify-tag`. A version with a
`-` suffix (`0.2.0-rc1`) is published as a pre-release. Only this job has `contents: write`.

---

## `site.yml`

Runs on a push to `main` that touches `site/**` or `docs/**`, and on demand.

Three commands, on `macos-15` because building the site needs `mc`:

```sh
make mc1                     # the compiler
build/mc1 build site         # site/mc.toml -> build/mcsite (the generator, written in mc)
build/mcsite site --check    # docs/ -> site/public, then validate it
```

`site/public` is then copied to `public/` and uploaded as the Pages artifact. `--check` is what
fails the job: it validates every internal link and every fragment, and it spawns
`site/tools/checkhtml.py` (structure, landmarks, ids, accessible names, `/static/...` on disk) and
`site/tools/contrast.py` (WCAG ratios read out of `site.css`) — which is why no separate HTML-check
step exists any more.

The URL prefix is **data, not a workflow substitution**: `[site] base_url` in `site/site.toml` is
`/` and `[site] origin` is `https://minicompiler.dev`, which is the custom domain this repository
serves from. A fork publishing under a GitHub Pages project path changes those two lines instead of
patching the HTML. With Actions as the Pages source the custom domain lives in the repository
settings, so no `CNAME` file has to be part of the artifact.

Deployment uses `actions/configure-pages`, `actions/upload-pages-artifact` and
`actions/deploy-pages`, with `permissions: pages: write, id-token: write` and
`environment: github-pages`.

---

## Repository settings

**These are already applied on `schivei/mc`.** They are written down so that a fork, or a
re-created repository, knows what the workflows assume.

1. **Pages source = GitHub Actions** — Settings -> Pages -> Build and deployment -> Source:
   *GitHub Actions*. Without it `deploy-pages` fails; nothing else does. *Applied.*
2. **Custom domain `minicompiler.dev`, with *Enforce HTTPS* on** — Settings -> Pages -> Custom
   domain. With Actions as the source the domain is a repository setting, not a `CNAME` file in
   the artifact, so the workflow does not write one. *Applied.*
3. **Actions enabled, repository public** — which is what makes the `ubuntu-24.04-arm` runner free.
   *Applied.*
4. **Workflow permissions = Read and write** — Settings -> Actions -> General -> Workflow
   permissions. *Applied.* Each workflow still narrows its own token (`contents: read` by default,
   `contents: write` only where a tag or a release is created, `actions: write` only in
   `autotag.yml` and `tag.yml`, `pull-requests: read` only in `autotag.yml`), so the
   repository-wide setting is a ceiling, not what any job actually runs with.
5. **Squash is the only merge method**, and the branch is deleted on merge. `autotag.yml` handles
   merge commits too, but allowing exactly one method means exactly one commit shape to reason
   about, and the squash subject is the one that carries `(#N)`.

   ```sh
   gh api -X PATCH repos/schivei/mc \
     -F allow_squash_merge=true \
     -F allow_merge_commit=false \
     -F allow_rebase_merge=false \
     -F delete_branch_on_merge=true
   ```

No repository secret is needed. `scripts/release-assets.sh` writes into `dist/`, which is in
`.gitignore`.

---

## Branch protection

`main` is protected so that the required checks are what gate a merge, and so that a merge is the
only way ordinary work reaches it — while leaving the owner able to push a documentation hotfix
directly. Four decisions:

- **required checks**: `make check (macOS arm64)` and `Link and run the suite (linux/arm64)`, the
  two job names in `ci.yml`;
- **strict (up to date before merging) is off**: `mc` builds are minutes long and the project is
  one person's; requiring every pull request to re-run against a moved `main` buys little and
  costs a rebase loop. `release.yml` rebuilds and re-runs the whole suite from the tag anyway;
- **zero required approvals**: there is no second reviewer to wait for. The `reviewer` and
  `verifier` agents do that job before the pull request is opened, and their findings are in the
  batch report;
- **administrators are not enforced**: this is what keeps direct pushes possible for the owner,
  and `autotag.yml` handles them by not releasing them;
- **no force pushes, no deletions**: history on `main` is append-only.

`required_pull_request_reviews` is present with a count of **0**. That combination is what says
"a pull request is required, but nobody has to approve it" — and because `enforce_admins` is
`false`, the owner can still push a documentation fix straight to `main`. Both halves of the
design are in that one pair of settings.

The exact call, for the architect to run:

```sh
gh api -X PUT repos/schivei/mc/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["make check (macOS arm64)", "Link and run the suite (linux/arm64)"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

`required_status_checks`, `enforce_admins`, `required_pull_request_reviews` and `restrictions` are
all **required** keys of that endpoint — `null` is how the last one says "nobody is restricted",
and omitting any of the four is an error, not a default.

Two more keys are available and deliberately not set: `"required_linear_history": true` (squash-only
merging already produces one, so it would only add a way to fail) and
`"required_conversation_resolution": true` (there is no second reviewer leaving comments to
resolve). Add them if the project ever gains outside contributors.

Verify it took, and read it back later, with:

```sh
gh api repos/schivei/mc/branches/main/protection \
  --jq '{checks: .required_status_checks.contexts, strict: .required_status_checks.strict,
         admins: .enforce_admins.enabled, approvals: .required_pull_request_reviews.required_approving_review_count,
         force: .allow_force_pushes.enabled, deletions: .allow_deletions.enabled}'
```

---

## Cutting a release

There is no procedure. **Merging a pull request is the procedure.**

1. Open the pull request, with the release label if the change is not a patch
   ([CONTRIBUTING.md](https://github.com/schivei/mc/blob/main/CONTRIBUTING.md)). `ci.yml` runs on
   it.
2. The owner merges it, by squash.
3. `autotag.yml` finds the pull request behind the squash commit, reads its labels, computes the
   next version from the newest reachable tag, pushes `vX.Y.Z`, and dispatches `release.yml`.
4. `release.yml` builds `mc`, verifies the signature, runs the whole suite with the binary being
   shipped, packages it, and publishes the Release with `mc-X.Y.Z-macos-arm64.tar.gz` and its
   `.sha256`.

If step 3's dispatch fails, its job summary says so — the tag is pushed either way, and
Actions -> Release -> Run workflow -> the tag finishes the job.

For a release that a merge cannot express — skipping a number, re-releasing a deleted tag,
releasing a commit that was pushed directly — use Actions -> **Tag** -> Run workflow instead.

## Consuming the release binary

```sh
tar xzf mc-0.1.0-macos-arm64.tar.gz
cd mc-0.1.0-macos-arm64
shasum -a 256 -c ../mc-0.1.0-macos-arm64.tar.gz.sha256
xattr -d com.apple.quarantine mc      # see below
install -m 755 mc /usr/local/bin/mc
```

`mc` is **ad-hoc signed, not notarized** (`codesign -dvvv` shows `flags=0x2(adhoc)`). Anything
downloaded through a browser carries the `com.apple.quarantine` extended attribute, and Gatekeeper
refuses to run an ad-hoc signed binary that has it. Removing the attribute is a one-time action by
the person who downloaded it; the signature itself stays valid
(`codesign --verify --verbose=4 mc`). The same note is inside the tarball, in `INSTALL.txt`.

The binary is the whole toolchain: the standard library travels inside it (`#include <sys>`,
`<prelude>`, `<io>`, `<mc/core>` — M15), and `--exe` writes a signed executable with no `ld`
(M11). `docs/build.md` describes `mc build` and `mc.toml`.

## `scripts/next-version.sh`

```sh
scripts/next-version.sh BASE BUMP    # 0.1.9 minor -> 0.2.0
scripts/next-version.sh --gt A B     # exit 0 when A is strictly newer than B
scripts/next-version.sh --test       # 40 assertions
```

`BASE` and the comparands are `X.Y.Z` with an optional leading `v`, which is stripped; the output
never carries one, because the caller is what turns a version into a tag name. Pre-release
suffixes and leading zeros are rejected, with a message that names the rule.

`autotag.yml` uses it for the bump, `tag.yml` for both the shape check and the
newer-than-the-newest-tag check, and `release.yml` for the shape check on the tag it was handed.
That is the point of the file: **one definition of what a version is**, exercised by `--test`
before any of them trusts it.

## `scripts/release-assets.sh`

```sh
scripts/release-assets.sh VERSION TARGET BINARY [OUTDIR]
```

`VERSION` comes from the release tag — `release.yml` passes what it derived from `v0.1.1`. A
leading `v` is stripped, so `v0.1.1` and `0.1.1` name the same archive.

Writes `OUTDIR/mc-VERSION-TARGET.tar.gz` and its `.sha256` (the `shasum -c` / `sha256sum -c`
format). The tarball holds one directory, `mc-VERSION-TARGET/`, with `mc`, a generated
`INSTALL.txt`, plus `README.md` and `LICENSE` when the repository has them.

It is deterministic — two runs over the same tree produce the same bytes — which took five
decisions:

- the member list is built and sorted here, never left to a directory walk;
- every staged file is stamped with mtime 0 (`TZ=UTC touch -t 197001010000`), which is what makes
  **bsdtar** reproducible: macOS's `tar` has no `--mtime`;
- owner, group and their names are forced to `0/0/empty`;
- the archive format is pinned to `ustar`, so GNU tar and bsdtar agree byte for byte;
- `gzip -n -9` writes a header with no name and no timestamp.

GNU tar (`gtar`, or a `tar` that reports itself as GNU) gets the documented
`--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner`; bsdtar gets
`--uid 0 --gid 0 --uname '' --gname '' --numeric-owner` and relies on the `touch`. Both are pinned
to `--format ustar`. Nothing is installed to make this work: plain macOS is enough.

---

## What changes at the milestone "mc hosted on Linux/Windows"

That is the name of the milestone the `if: false` job in `release.yml` waits for. The shape is
already there; four things move.

1. **`release.yml`** — delete the `if: false` from `build-future-hosts`, or move its `include`
   entries into `build`'s matrix. The steps differ per host: `codesign` and the quarantine note
   are macOS-only, a Linux build ends in `ld.lld` (there is no `--exe` for ELF — `docs/build.md`
   § Limits), and Windows needs the COFF writer plus `lld-link`.
2. **`ci.yml`** — the split disappears for the targets whose host can compile. A `linux-arm64`
   runner that has `mc` can run `scripts/test-linux.sh` in its default mode, with `native=1`
   picking direct execution over Docker; `--build-only`/`--run-only` stay for the targets that are
   still cross-built from another host.
3. **`scripts/release-assets.sh`** — nothing, by design. It is target-agnostic; `INSTALL.txt`
   already switches its quarantine paragraph on the target name, and a Windows package would want
   a `.zip` alongside the tarball.
4. **The version** — nothing. One tag covers every target; `release-assets.sh` puts the target
   in the file name.

The blocker to watch is the one `docs/build.md` names: `src/driver.mc` reaches `environ` through
`_NSGetEnviron`, which musl does not have. Until that is abstracted, `mc` cannot spawn tools on
Linux, and `mc build`'s `[compiler]` and `[linker]` sections are exactly what needs spawning.
