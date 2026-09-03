# ci.md — the GitHub Actions workflows

Four workflows live in `.github/workflows/`. They exist because the project has a hard
constraint: **`mc` only builds and runs on macOS arm64 today** (`docs/plan.md` § Phase 2 — "mc
itself keeps running on macOS arm64 for now; cross-hosting comes later with CI"), while part of
what `make check` proves has to happen on a Linux machine. Everything below follows from that.

| workflow | trigger | machine | what it does |
|---|---|---|---|
| `ci.yml` | push to `main`, pull requests | `macos-15` + `ubuntu-24.04-arm` | `make check`, then the Linux suite in two halves |
| `tag.yml` | manual | `ubuntu-24.04` | validates `X.Y.Z` against the `VERSION` file, pushes the annotated tag `vX.Y.Z` and starts `release.yml` |
| `release.yml` | tag `v*`, or manual | `macos-15` | builds `mc`, verifies it, packages it, publishes the GitHub Release |
| `site.yml` | push to `main` touching `site/**` or `docs/**`, or manual | `macos-15` + `ubuntu-24.04` | renders `docs/` with `mcsite` and deploys it to GitHub Pages (<https://minicompiler.dev>) |

All four set `concurrency` groups and per-job `timeout-minutes`, and each declares the narrowest
`permissions` it needs.

---

## `ci.yml`

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

## `tag.yml`

`workflow_dispatch` with two inputs: `version` (required, `X.Y.Z`, optionally `X.Y.Z-suffix`) and
`notes` (optional). It

1. rejects anything that is not a semantic version;
2. reads `VERSION` at `HEAD` and **fails with a message naming both values** if they differ —
   the tag is never the source of truth, the file is;
3. refuses to overwrite an existing tag;
4. creates the annotated tag `vX.Y.Z` whose annotation is `mc vX.Y.Z` plus `notes`, and pushes it.

The input is read through an environment variable, never interpolated into the shell.

Then it starts the release:

```sh
gh workflow run release.yml --ref "v$VERSION" -f tag="v$VERSION"
```

### Why the dispatch, and why it works with the default token

**A tag *pushed* with the default `GITHUB_TOKEN` does not start another workflow.** That is
GitHub's guard against recursive runs, and it means `release.yml`'s `on: push: tags` trigger will
*not* fire for a tag this workflow created. The guard has exactly two documented exceptions —
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
macos-arm64 }`. It checks out the tag, **verifies that the tag matches `VERSION` at that commit**,
then:

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
   `contents: write` only where a tag or a release is created, `actions: write` only in `tag.yml`),
   so the repository-wide setting is a ceiling, not what any job actually runs with.

No repository secret is needed. `scripts/release-assets.sh` writes into `dist/`, which is in
`.gitignore`.

---

## Cutting a release

1. Edit `VERSION` (a single line, `X.Y.Z`) and open a pull request. `ci.yml` runs on it.
2. Merge into `main`. `ci.yml` runs again on `main`.
3. Actions -> **Tag** -> Run workflow -> `version` = the same `X.Y.Z`, `notes` = the release notes.
   The workflow refuses to run if the two do not agree.
4. `tag.yml` starts `release.yml` itself. If that dispatch failed, its job summary says so —
   start it by hand: Actions -> Release -> Run workflow -> the tag.
5. The release appears with `mc-X.Y.Z-macos-arm64.tar.gz` and its `.sha256`.

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

## `scripts/release-assets.sh`

```sh
scripts/release-assets.sh VERSION TARGET BINARY [OUTDIR]
```

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
4. **`VERSION`** — nothing. One version covers every target.

The blocker to watch is the one `docs/build.md` names: `src/driver.mc` reaches `environ` through
`_NSGetEnviron`, which musl does not have. Until that is abstracted, `mc` cannot spawn tools on
Linux, and `mc build`'s `[compiler]` and `[linker]` sections are exactly what needs spawning.
