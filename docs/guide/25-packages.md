# Using a package

You have `mc build` and an `mc.toml` ([A project](20-project-toml.md)). This page adds one thing:
source that did not come from your tree.

> This is the half of packages that is finished: **resolving** a dependency that is already on the
> disk. Fetching one — `mc pkg sync`, the registry, `mc install` — is the next step of the same
> milestone (`docs/specs/M44.md`), so for now a lock and a tree arrive by hand, by `git`, or
> vendored into your repository. Everything below is exactly what will still be true afterwards.

---

## 1. Three lines in `mc.toml`

```toml
[deps]
geo = "1.2.0"
```

is a **minimum**, not a pin. What is actually used is in `mc.lock`, beside `mc.toml`:

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

`sh scripts/pkg-hash.sh .` prints the tree hash of a checkout; it is what a registry row will
carry, and until `mc pkg hash` exists it is how you write one.

## 6. What you can check today

```console
$ mc build myproject --libs-dir ~/.mc/libs
compiler build/mc-app.mc -> build/mc-app
compile main.mc -> build/app
```

and, when something is wrong:

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
