# Packages

> **Trust.** A library package is source `mc` compiles; a compiler-module package is code that
> RUNS on your machine at build time, inside the taught compiler `mc build` spawns. The brakes are
> the lock (nothing runs that is not the bytes you reviewed) and the closure rule (a package reads
> its own tree, libraries the binary ships, and its declared dependencies — nothing else). They do
> not stop a module that opens a file through an `extern`. Until `mc sandbox` wraps the spawn,
> **a compiler-module package is trusted code**.

This page is the reference for what a package IS, how `#include <name>` is resolved, what
`mc.lock` says, what `mc build` refuses, and what `mc pkg` does — the registry, minimal version
selection, the fetch, the lock writer and vendoring.

---

## 1. Angle brackets are libraries, quotes are my files

```c
#include "vec.mc"              // a file of mine, next to the includer or on [include].paths
#include <geo/geo.mc>          // a file of the package `geo`, at the version mc.lock pins
#include <geo>                 // the same, through geo's `lib` entry
#include <float>               // a library this binary ships — unless a lock says otherwise
#include <mc/core>             // the compiler's own source
```

`<name>` means **a library that is not in my tree**. It is never resolved against the working
directory, so the answer to `<float>` is a function of *(this binary, this lock, the installed
packages)* and of nothing else — dropping a `float.mc` next to `main.mc` cannot change it.

A trailing `.mc` is dropped from every `<...>` name, so `<geo/geo.mc>` and `<geo/geo>` are one
name and both land on `geo.mc` on disk. A payload with another extension keeps it
(`<pack/table.txt>` for an `#embed`).

The same spelling goes into `[compiler].modules`:

```toml
[compiler]
out     = "build/mc-app"
modules = ["<teach/mc_teach.mc>", "user.mc"]
```

A value that starts with `<` is emitted into the generated compiler source verbatim, with no
`../` adjustment — the rule `[compiler].core` has carried since M41.

## 2. The resolution order

`#include <X>` is answered by the first of three steps that has it.

| step | who answers | for which names |
|---|---|---|
| 1 | the **lock** | `X`'s first path component is a package `mc.lock` names, and the file asking is allowed to reach it (§ 5) |
| 2 | the **bundle** — the copy inside this binary ([bundle.md](bundle.md)) | every name in the manifest, plus `<mc/bundle_data>` and `<mc/bundle.bin>` |
| 3 | the **installed `mc` package** under `<libs>/mc/v<version>/` | the same names as step 2, when the binary carries no bundle |
| — | nobody | `prog.mc:1: unknown bundled include: no/such/module` |

Step 1 exists only where a lock was read, which is `mc build`. The single-file CLI
(`mc x.mc -o x.o`) has no project and therefore no step 1: `<geo/geo.mc>` there is
`unknown bundled include: geo/geo`, and `--include=DIR` plus a quote include is the hand road.

Step 3 is reached only on a bundle miss. For a binary that carries the blob — which is every
binary this build produces — that means a name nobody ships, so a full `mc` behaves exactly as it
did before packages existed unless a lock says otherwise.

**Where a locked package's tree is**, in order:

1. `deps/<pack>/` beside `mc.toml` — the vendored tree. When it is there the installation is not
   consulted at all: `deps/` plus `mc.lock` in git is the fully offline project.
2. `<libs>/<pack>/v<version>/`, and only that version. A `v1.0.0/` sitting beside a locked
   `v1.2.0/` is never opened, so it cannot change a byte.

`<libs>` is `--libs-dir DIR` when given, else `$HOME/.mc/libs`. CI passes the flag so that no job
depends on `HOME`, exactly as `--sysroot-dir` does for [sysroots](sysroot.md).

## 3. The package manifest

A package is a source tree with an `mc.toml` at its root carrying a `[package]` table:

```toml
[package]
name   = "geo"
files  = ["geo.mc", "vec.mc"]
lib    = "geo.mc"        # optional: what a bare `#include <geo>` means
module = "mc_geo.mc"     # optional: the file a COMPILER includes

[deps]
mathx = "1.0.0"
```

`files` is not documentation. It is the hash's input, the vendor-copy list, and the boundary
§ 5 enforces. It is written by hand because `mc` has no directory listing — the same reason
`tools/bundle.list` exists.

**Every entry is a relative path inside the package, and that is checked.** An entry may not

* be empty, or start with `/`;
* contain a `.` or a `..` component, or an empty one (`a//b`), or end with `/`;
* contain a backslash, any byte below `0x20`, or one of the characters Windows reserves in a
  name -- `:` (a drive letter, an NTFS stream), `<`, `>`, `"`, `|`, `?`, `*` -- because the rule is one
  rule for the three hosts and `C:/x` is absolute to a Windows extractor;
* resolve, after normalisation, to anything outside the package's own directory.

Anything else is `<pack> <ver>: files entry escapes the package: <entry>`, exit 2, at every place
the list is used: the tree hash `mc build` recomputes, the cache manifest a fetch writes, the copy
`mc pkg vendor` makes, and the per-file attribution of a mismatch. The reason is that the list
arrives inside a downloaded tree and is then handed to `open`, to `write` and (before this rule)
to `unlink`: `files = ["../../../../.ssh/id_rsa"]` used to be read on every build, and
`mc pkg vendor` used to write it outside the project.

**A package never defines `user_init`.** It exports `<name>_init()` and the project's own module
calls it, because a compiler holds exactly one `user_init` and the order of initialisation is the
project's decision:

```c
// user.mc, in the project
void user_init() {
    teach_init();
}
```

## 4. The lock

`mc.lock` sits beside `mc.toml`, is written only by `mc pkg sync` (§ 10), and has one
`[[package]]` row per resolved package, sorted by name — a total order over unique keys, so two
runs of `sync` write the same bytes:

```toml
# written by `mc pkg sync` -- do not edit (docs/reference/packages.md)
[[package]]
name    = "geo"
version = "1.2.0"
lib     = "geo.mc"
sha256  = "ba1924dc...9776f"
deps    = ["mathx"]

[[package]]
name    = "mathx"
version = "1.0.0"
lib     = "mathx.mc"
sha256  = "374cae18...f1398"
deps    = []
```

`deps` is the edge list § 5 reads. `lib` is what a bare `<geo>` means. `sha256` is the tree hash.

**The lock is checked, not trusted**: `mc build` rehashes every locked package on **every** build
and refuses on any disagreement. A dependency's source is about to be lexed anyway.

### The tree hash

For `mc.toml` first and then each entry of `[package].files` **in manifest order**, one line

```text
<64 hex of sha256(file bytes)><space><byte length of the path><colon><path><LF>
```

and the tree hash is the `sha256` of those lines, in plain hex. This is the shape of Go's
`dirhash.Hash1`, without its `h1:` base64 spelling — **and with the path length-prefixed**, which
Go's is not. Go derives its file list from a zip it built; here the list is an array in an mc.toml
that was downloaded, so a path is attacker-controlled and `<hex><two spaces><path><LF>` cannot say
which file list produced a given stream of lines. A control byte in a `files` entry is refused
outright (§ 3), so the ambiguity has no way in; the length prefix is what stops the *format* from
being able to express it.

What makes it stable across hosts: it is over **content**, never over an archive (GitHub
regenerated its tag tarballs in 2023 and broke every archive-checksum consumer; a content hash did
not move); it names each file explicitly instead of listing a directory; and it carries no mtime,
no mode and no ordering of its own — manifest order is the canonical order. Bytes are taken
exactly as they are on disk, so a checkout that translates line endings changes the hash. This
repository sets `* -text` in `.gitattributes` for that reason.

`mc pkg hash DIR` prints it. `scripts/pkg-hash.sh DIR` is the same rule in shell, and
`make check-pkg` compares the two implementations against every lock checked into `tests/pkg` on
every run — a divergence between the compiler and this page is a red `make check`, not a surprise
at a consumer.

### The cache manifest

Beside an installed tree, `<libs>/<pack>/v<version>.toml` records what was installed:

```toml
[source]
name    = "geo"
version = "1.2.0"
sha256  = "ba1924dc...9776f"

[[file]]
path   = "mc.toml"
sha256 = "..."
```

It is written **last**, after the tree is complete, so it is the claim that the directory holds
what the lock says: a half-extracted tree has no manifest and is reported as *not fetched* rather
than as *does not match*. It is also what lets a mismatch name the FILE that moved — the lock
carries one hash per package, so without a manifest (a vendored tree) the refusal names the tree.

## 5. A package is closed

A file under a package root may read:

* its own tree, with quotes and relative paths;
* `<...>` names the bundle or the installed `mc` package answers;
* `<dep/...>` where `dep` is in its own lock row's `deps` — or itself.

Anything else is refused, for `#include` and for `#embed` alike:

```text
geo/vec.mc:3: package geo reaches outside its tree: /etc/hosts
```

A `<...>` name whose first component is a locked package the file may NOT reach is not silently
downgraded to the bundle's answer and it is not silently allowed: step 1 is skipped, and if
nothing else answers, the refusal above is what comes out.

After the parse, every file the build actually READ under a package root is checked against that
package's `files`:

```text
geo/extra.mc:1: not declared in geo's [package].files
```

That is what makes `files` a boundary. An author who forgets a file ships one that fails loudly at
the first consumer; a file planted inside a fetched tree is refused even though the tree hash — which
covers only what the manifest lists — did not move.

## 6. Names

`[a-z][a-z0-9_]*`, at most 32 bytes: a bare TOML key, a valid path component on all three hosts,
and a valid identifier prefix (`geo_init`). Upper case and `-` are out so that one spelling is the
only spelling.

Reserved, in `[deps]` and in the registry: **`mc`** and every `mc/...` name, **`deps`** and
**`build`**. `mc` is the compiler's own package — `<mc/core>` is the source of the compiler that
is *running*, and a taught compiler assembled from a foreign one would not be the compiler that
built it.

A bundled library name is **not** reserved. A registry package may carry `float`, `sys` or `i128`,
and a project that pins `[deps] float = "1.3.0"` gets that tree for `<float>` and
`<float/float_rt.mc>` instead of the blob. That is safe on both counts that matter: the row pins a
content hash and `mc build` rehashes, so two machines with the same binary, lock and bytes resolve
the same bytes; and a project with no such line is byte for byte what it was.

## 7. Development: `[replace]`

```toml
[replace]
geo = "../geo"
```

points a name at a local tree. A replaced package is **not pinned and not hashed**, and `mc build`
says so on stdout:

```text
replaced geo: ../geo -- not pinned by mc.lock
```

Go's `go.sum` omits path-replaced modules for the same reason.

## 8. Refusals

Every one of these is exit **2** — "the environment is not ready" — except the two that are about
the source, which are exit 1. See [diagnostics.md](diagnostics.md) § 13.

| disagreement | message | exit |
|---|---|---|
| a file's bytes differ from the manifest's line | `mc: geo 1.2.0: vec.mc does not match mc.lock` | 2 |
| the tree hash differs but no file line does (the `files` list changed) | `mc: geo 1.2.0: mc.toml does not match mc.lock` | 2 |
| the same, with no manifest to attribute it to (a vendored tree) | `mc: geo 1.2.0: the tree does not match mc.lock` | 2 |
| `[deps]` names a package the lock lacks, or asks a minimum above the lock | `mc: mc.lock is stale: geo` | 2 |
| the lock names a version that is neither vendored nor installed | `mc: geo 1.2.0 is not fetched` | 2 |
| a package reads outside its tree | `geo/vec.mc:3: package geo reaches outside its tree: ...` | 1 |
| a file the build read is not in that package's `files` | `geo/extra.mc:1: not declared in geo's [package].files` | 1 |
| a reserved or malformed name in `[deps]`/`[replace]` | `mc.toml:8:6: reserved package name: deps.mc` | 1 |
| a `[package].files` entry that leaves the package (§ 3) | `mc: geo 1.2.0: files entry escapes the package: ../x` | 2 |
| an archive member that is a link | `mc: v1.2.0.tar.gz: archive member is a link: geo-1.2.0/x` | 2 |
| an archive member that leaves the destination | `mc: v1.2.0.tar.gz: member escapes the archive: ../x` | 2 |
| a body over its cap (64 MiB for an archive, 1 MiB for an index file) | `mc: larger than the cap of 67108864 bytes: <source>` | 2 |

The exit-2 refusals carry the M25 `run:` line:

```text
mc: mathx 1.0.0 is not fetched
  run:   mc pkg sync --yes
```

## 9. What `mc build` does NOT do

**It never downloads.** There is no downloader in the read side at all: it reads the lock, finds
each tree in `deps/` or `<libs>`, hashes, registers the roots, compiles. `make check-pkg` proves
it rather than asserting it — the whole run has a `curl`, a `wget` and a `tar` on `PATH` that fail
if they are invoked.

**It never opens a directory no lock names**, and it never guesses a version.

A compiler assembled without `<mc/core_pkg>` cannot download even in principle: it has no
fetcher, no registry and no lock writer, and it still builds every project above. That is the
CI and consumer shape ([bundle.md](bundle.md) § The parts).

---

## 10. `mc pkg` — resolving, fetching and locking

Everything below is `<mc/core_pkg>`'s. The command lines are in [cli.md](cli.md) § 3d.

### The registry

One file per package, at `<registry>/index/<name>.toml`:

```toml
# index/geo.toml
[package]
name        = "geo"
repo        = "https://github.com/schivei/mc-geo"
description = "2-D vectors"

[[versions]]
version = "1.0.0"
url     = "https://github.com/schivei/mc-geo/archive/refs/tags/v1.0.0.tar.gz"
strip   = 1
sha256  = "<the tree hash of that tag's checkout>"
deps    = ["mathx 1.0.0"]

[[versions]]
version = "1.2.0"
url     = "https://github.com/schivei/mc-geo/archive/refs/tags/v1.2.0.tar.gz"
strip   = 1
sha256  = "..."
deps    = ["mathx 1.1.0"]
yanked  = true          # optional, and the ONLY thing a published row may gain
```

`sha256` is the **tree hash** of § 4, never the archive's: a forge that regenerates its tag
tarballs (GitHub did, in 2023) does not move it. `strip` is what `tar --strip-components` gets, 1
for the `<repo>-<version>/` top directory a tag archive has. `deps` carries each requirement as
`"<name> <minimum>"`, which is what lets version selection run over the index alone, with no
archive downloaded.

**Where the index comes from.** `--registry`, else `[registry].url`, else
`https://minicompiler.dev/registry` — a package **server** that produces exactly this layout out
of the git repositories registered with it. The compiler's side of that is a reader and a
constant: there is no API client here, no JSON, no search and no transparency log. A **directory**
with the same layout is a registry too, read in place, which is what a private tap costs: a
`git clone` and one line of TOML. A URL registry is fetched one file at a time into
`<libs>/index/<name>.toml`, the snapshot every later `mc pkg` in that project reads.

### Minimal version selection

Go's algorithm (`cmd/go/internal/mvs`), exactly:

1. the build list starts from the project's `[deps]` minimums;
2. for every selected `(name, version)`, the requirements of **that** version's index row are
   added;
3. a name's selected version is the **maximum over every minimum that mentions it**;
4. repeat to a fixed point.

No search, no SAT and no "latest": the answer is a function of the index alone, and the lock then
freezes it, so the index can move afterwards without moving the build. A project asking for
`mathx 1.0.0` whose `plot` asks for `mathx 1.1.0` gets **1.1.0** — not 1.0.0, and not the 2.0.0
the registry also carries.

**Two majors of one name are refused, not solved:**

```text
mc: mathx: 1.0.0 and 2.0.0: different majors: no solver
```

exit 1, and no lock is written. Semantic import versioning (`/v2` in the name) is out of scope.

**Yanked** is Go's `retract`: `mc pkg add` and `mc update` skip such a row, and a lock that
already pins one keeps working — a published build never breaks retroactively. `mc update` also
stays inside the current major: raising a minimum across a major is not an update, it is the case
above.

### The fetch

In `mc sysroot fetch`'s order of operations, and for the same reasons:

1. download the archive to `<libs>/<pack>/v<version>.tar.gz` (an `https://` url through
   `curl`/`wget` with the HTTPS-only flags; a source with no scheme is a local path, copied).
   **An archive is refused above 64 MiB and an index file above 1 MiB**, before either is read:
   `mc: larger than the cap of 67108864 bytes: <source>`, exit 2;
2. **list the archive and check every member** (below), then `tar -xzf` it into
   `<libs>/<pack>/v<version>/` with the row's `strip`;
3. **hash the tree and compare it to the row, before anything else.** On a mismatch every file the
   EXTRACTION wrote is unlinked and no manifest is written:

   ```text
   mc: checksum mismatch for geo 1.2.0
     expected ba1924dc...
     got      2b7c01f9...
   ```

   exit 2. The archive itself is not checksummed — § 4 says why — so unlike a sysroot the refusal
   comes after the bytes are on disk, but still before any manifest exists and before any build
   can consume the tree;
4. write `<libs>/<pack>/v<version>.toml` **last**. That file is the claim.

A download that fails leaves no claim either: `mc: the download failed (exit 22): <url>` for a URL
and `mc: cannot open: <path>` for a path, exit 2, and the next `mc build` says `is not fetched`
rather than reading debris. So does a tree whose `mc.toml` is refused after extraction — an entry
that escapes (§ 3), or one naming a file the archive does not carry: the tree is cleared first and
the message comes second, and what is cleared is the member list from step 2, never the list in
the mc.toml that has just been refused.

#### The archive member rule

`tar` is not trusted with a file somebody else produced. Before any extraction the archive is
listed twice — `tar -t...f` for the names, one per line, and `tar -tv...f` for the ls-style type
character — and a member is refused when it

* is a symbolic link or a hard link (`mc: <archive>: archive member is a link: <member>`);
* is absolute, or carries a `.`/`..` component, or lands outside the destination once
  `--strip-components` has been applied
  (`mc: <archive>: member escapes the archive: <member>`);
* is one of more than 1 MiB of names, or the two listings disagree.

Every refusal is exit 2 and unlinks the archive. After the extraction each listed member has to be
there as a file `open` can read, which is what says tar wrote what tar said it would; that last
check is skipped when the caller asked for a subset of members, which only `mc sysroot fetch`
does. A member is never named back to `tar` on the extraction: an argument list is
space-separated here and a member name may contain a space.

Nothing downloads without `--yes`. Without it every verb that would fetch prints the plan and
stops:

```text
fetch  plot 1.0.0
url    /path/to/archives/plot-1.0.0.tar.gz
sha256 f5e0f0c64e85...
into   /path/to/libs/plot/v1.0.0/
nothing was downloaded: re-run with --yes
```

`mc` has no `isatty`, so there is no prompt — the plan is the prompt.

### The lock writer

`mc pkg sync` writes every row from the tree it just resolved, never from the index's claim about
it: `version` is what selection chose, `lib` and `deps` come out of the package's **own**
`mc.toml`, and `sha256` is the tree hash of what is on the disk. A `[replace]`d package gets a
`path` line and no hash (§ 7). Rows nothing requires are dropped, because the lock is written from
the build list and from nothing else.

### Vendoring

`mc pkg vendor` copies each locked tree into `deps/<pack>/` — `mc.toml` plus `[package].files`,
which is the same list the hash is over, checked entry by entry against § 3 before a byte is
written — and then verifies. `deps/` plus `mc.lock` in git is the
fully offline project: a build with an empty `<libs>` produces a byte-identical object, and
`make check-pkg` asserts exactly that.

### `mc pkg check` — the registry gate

What the registry's CI runs on every changed index file, and what an author runs before opening
the pull request. It refuses:

* a `[package].name` outside the name rule (§ 6) or a reserved one — `mc` above all;
* a row with no `url`, no `sha256`, or a `sha256` that is not 64 hex characters;
* with `--yes`, a row whose **archive** disagrees with it: the tree hash, the package name, or the
  set of `[deps]` — `the archive requires a package the row does not list: mathx`;
* against the registry's current copy, any edit to a published row except adding `yanked = true`:
  `mc: plot 1.0.0: a published row was edited: only yanked = true may be added`, and
  `a published version was removed` for a row that vanished.

Rows are immutable because that is the one property of a checksum database worth keeping when you
have no server to run one on: the git history of the index IS the audit log.

**The immutability check never passes by default.** Comparing needs the published copy, so with a
URL registry it needs `--yes` — without it, `check` says so and stops
(`mc: check needs --yes to compare against the published index: <name>`, exit 2) rather than
answering "unchanged" by doing nothing. With `--yes`, only the downloader's own "no such file"
(`curl -f` exits 22, `wget` 8) means *a new package*; any other failure is
`mc: check: cannot read the published index for <name>: <reason>`, exit 2. With a directory
registry the comparison is free and neither case arises.

## See also

* [guide/25-packages.md](../guide/25-packages.md) — using one and publishing one, by example
* [toml.md](toml.md) — `[deps]`, `[replace]`, `[registry]`, `[package]`
* [bundle.md](bundle.md) — what the binary ships, and why a bundled name can be overridden
* [cli.md](cli.md) — `--libs-dir`
* [diagnostics.md](diagnostics.md) — every message above, with cause and fix
