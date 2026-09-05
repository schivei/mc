# Packages

> **Trust.** A library package is source `mc` compiles; a compiler-module package is code that
> RUNS on your machine at build time, inside the taught compiler `mc build` spawns. The brakes are
> the lock (nothing runs that is not the bytes you reviewed) and the closure rule (a package reads
> its own tree, libraries the binary ships, and its declared dependencies — nothing else). They do
> not stop a module that opens a file through an `extern`. Until `mc sandbox` wraps the spawn,
> **a compiler-module package is trusted code**.

This page is the reference for what a package IS, how `#include <name>` is resolved, what
`mc.lock` says and what `mc build` refuses. Fetching a package, writing the lock and the registry
itself are `mc pkg`'s, and they are not in this build yet — everything below works from a lock and
a tree that are already on the disk.

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

`mc.lock` sits beside `mc.toml`, is written only by `mc pkg`, and has one `[[package]]` row per
resolved package, sorted by name:

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
<64 hex of sha256(file bytes)><two spaces><path><LF>
```

and the tree hash is the `sha256` of those lines, in plain hex. This is the shape of Go's
`dirhash.Hash1`, without its `h1:` base64 spelling.

What makes it stable across hosts: it is over **content**, never over an archive (GitHub
regenerated its tag tarballs in 2023 and broke every archive-checksum consumer; a content hash did
not move); it names each file explicitly instead of listing a directory; and it carries no mtime,
no mode and no ordering of its own — manifest order is the canonical order. Bytes are taken
exactly as they are on disk, so a checkout that translates line endings changes the hash. This
repository sets `* -text` in `.gitattributes` for that reason.

`scripts/pkg-hash.sh DIR` is the same rule in shell, and `make check-pkg` compares the two
implementations against every lock checked into `tests/pkg` on every run.

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

## 10. Not in this build

`mc pkg` — `sync`, `add`, `list`, `vendor`, `verify`, `hash`, `check` — the registry, minimal
version selection and `mc install`/`update`/`upgrade` are the later steps of the same milestone
(`docs/specs/M44.md`). Until they land, a lock and a tree are produced by hand or by
`scripts/pkg-hash.sh`, which is exactly what `tests/pkg` does.

## See also

* [guide/25-packages.md](../guide/25-packages.md) — using one and publishing one, by example
* [toml.md](toml.md) — `[deps]`, `[replace]`, `[registry]`, `[package]`
* [bundle.md](bundle.md) — what the binary ships, and why a bundled name can be overridden
* [cli.md](cli.md) — `--libs-dir`
* [diagnostics.md](diagnostics.md) — every message above, with cause and fix
