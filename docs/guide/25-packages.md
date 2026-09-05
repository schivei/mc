# Using a package

You have `mc build` and an `mc.toml` ([A project](20-project-toml.md)). This page adds one thing:
source that did not come from your tree.

> `mc install` and `mc upgrade` — the compiler's own libraries, and the slim binary that has to
> fetch them — are the next step of the same milestone (`docs/specs/M44.md`). Everything on this
> page works today.

---

## 1. Three lines in `mc.toml`

```toml
[deps]
geo = "1.2.0"
```

is a **minimum**, not a pin — and the usual way to write it is not to write it:

```console
$ mc pkg add geo --yes
add geo 1.2.0 -> myproject/mc.toml
fetch  geo 1.2.0
url    https://github.com/schivei/mc-geo/archive/refs/tags/v1.2.0.tar.gz
sha256 ba1924dc0d40b458...
into   /Users/me/.mc/libs/geo/v1.2.0/
package geo 1.2.0 -> /Users/me/.mc/libs/geo/v1.2.0/
lock   myproject/mc.lock (2 packages)
```

`mc pkg add` writes exactly one line into `[deps]` and leaves every other byte of your `mc.toml`
alone, and then does what `mc pkg sync` does. What is actually used is in `mc.lock`, beside
`mc.toml`:

```toml
[[package]]
name    = "geo"
version = "1.2.0"
lib     = "geo.mc"
sha256  = "ba1924dc...9776f"
deps    = ["mathx"]
```

Both files go into git. The lock is the reproducible half: it names an exact version and the hash
of its exact bytes, and `mc build` re-checks that hash every single time.

The version in it is not the newest one published, and that is on purpose. `mc` uses **minimal
version selection**: every requirement is a minimum, and what gets selected is the lowest version
that satisfies all of them. Adding a dependency cannot silently upgrade another one, and a build
only moves when you move it — with `mc update`:

```console
$ mc update --yes                 # every dependency, inside its own major
$ mc update geo --yes             # just this one
```

## 2. Angle brackets in the source

```c
#include <geo/geo.mc>     // a named file of the package
#include <geo>            // its `lib` entry — the same file, once-only
```

The rule to remember is one sentence: **angle brackets are libraries, quotes are my files.** A
quote include is resolved against the includer's directory and `[include].paths`; an angle include
is resolved against the lock, the libraries this binary ships, and the installed `mc` package — in
that order, and never against the working directory.

That last part is what makes a build reproducible: a `geo.mc` you happen to have next to `main.mc`
cannot become `<geo>`.

## 3. Where the tree comes from

Two roads, and `mc build` takes the first that exists:

```text
deps/geo/                       vendored, checked into your repository
~/.mc/libs/geo/v1.2.0/          installed, one directory per exact version
```

Vendoring is the fully offline project: `deps/` plus `mc.lock` in git and the build needs nothing
else. Both roads are hashed against the lock, so the choice cannot change your output — that is
asserted byte for byte by `make check-pkg`.

`--libs-dir DIR` moves the second road, which is what CI should do so that no job depends on
`HOME`.

`mc pkg vendor` takes the first road from the second:

```console
$ mc pkg vendor
vendor geo 1.2.0 -> deps/geo/ (3 files)
vendor mathx 1.0.0 -> deps/mathx/ (2 files)
vendored 2 packages into deps/
```

It copies `mc.toml` plus `[package].files` and nothing else, and then verifies. The object your
project produces afterwards is byte for byte the one it produced from the installation.

`mc pkg list` says which road each package took, and `mc pkg verify` rehashes everything without
compiling:

```console
$ mc pkg list
geo          1.2.0    ba1924dc0d40 vendored
mathx        1.0.0    374cae18effd vendored
```

## 4. A compiler-module package

A package can also teach the compiler. It goes in `[compiler].modules`, in the same spelling:

```toml
[compiler]
out     = "build/mc-app"
modules = ["<teach/mc_teach.mc>", "user.mc"]
```

and the project writes the six lines that decide the order:

```c
// user.mc
void user_init() {
    teach_init();
}
```

A package **never defines `user_init`** — a compiler holds exactly one, and stacking two packages
that each defined it would be a link error rather than a decision. It exports `<name>_init()`
instead.

**A compiler module is code that runs on your machine at build time.** Read it before you pin it;
see the warning at the top of [reference/packages.md](../reference/packages.md).

## 5. Publishing one

A package is a source tree with an `mc.toml` at its root:

```toml
[package]
name   = "geo"
files  = ["geo.mc", "vec.mc"]
lib    = "geo.mc"        # what a bare `#include <geo>` means
module = "mc_geo.mc"     # the file a COMPILER includes, if there is one

[deps]
mathx = "1.0.0"
```

Three things about `files`:

* it is written by hand, because `mc` has no directory listing;
* it is the input to the tree hash, so forgetting a file changes nothing and adding one changes
  the hash;
* it is a **boundary**: a file inside your tree that is not on the list is refused at the
  consumer, with `not declared in geo's [package].files`.

And one thing about what a package may read: **its own tree, the libraries the binary ships, and
the dependencies it declared.** Nothing else — not the consumer's files, not an absolute path, not
a package it did not name. `#embed` is included in that rule.

### Registering it

The road, end to end:

```console
$ mc pkg hash .                    # the tree hash of this checkout
ba1924dc0d40b4582669baca5a31c34f28dac13753cc0ac2a64be71bb309776f
$ git tag v1.2.0 && git push --tags
```

Then register it: a `[[versions]]` row in `index/<name>.toml`, added by pull request to the
registry the package server at `minicompiler.dev` publishes ([reference/packages.md](../reference/packages.md)
§ 10):

```toml
[[versions]]
version = "1.2.0"
url     = "https://github.com/you/mc-geo/archive/refs/tags/v1.2.0.tar.gz"
strip   = 1
sha256  = "ba1924dc0d40b4582669baca5a31c34f28dac13753cc0ac2a64be71bb309776f"
deps    = ["mathx 1.0.0"]
```

`sha256` is the tree hash, never the tarball's: a forge that regenerates its tag archives does not
break your row. Check it before you send it — this is what the registry's CI runs:

```console
$ mc pkg check index/geo.toml --yes
ok     geo 1.2.0
check  index/geo.toml: 1 rows
```

It downloads the tag, re-derives the hash, and compares the row against the archive's own
`mc.toml` — the name and every `[deps]` entry. A published row never changes afterwards; the one
edit allowed is `yanked = true`, which makes `add` and `update` skip the version without breaking
anybody who already locked it.

**A private registry costs nothing**: any directory or URL with the same `index/<name>.toml`
layout is one.

```console
$ mc pkg sync --registry ../our-tap --yes
```

or `[registry] url = "../our-tap"` in `mc.toml`.

`sh scripts/pkg-hash.sh .` is the same hash in shell, which is how `make check-pkg` keeps the
compiler and the specification honest about each other.

## 6. What a build does, and does not do

```console
$ mc build myproject --libs-dir ~/.mc/libs
compiler build/mc-app.mc -> build/mc-app
compile main.mc -> build/app
```

`mc build` **never downloads**: it reads the lock, finds each tree, hashes it, and compiles. When
something is wrong it says so and stops:

```console
$ mc build myproject
mc: geo 1.2.0: vec.mc does not match mc.lock
  run:   mc pkg verify
$ echo $?
2
```

Exit **2** is always "the environment is not ready" — a tree that moved, a package that is not
there, a lock that no longer answers the manifest — and never "your program does not compile",
which stays exit 1. A script can tell them apart.

## Next

* [reference/packages.md](../reference/packages.md) — the exhaustive version: the resolution
  order, the lock format, the hash, the closure rule, every message
* [reference/toml.md](../reference/toml.md) — `[deps]`, `[replace]`, `[registry]`, `[package]`
* [Teaching the compiler](30-teaching.md) — what a compiler-module package can actually do
