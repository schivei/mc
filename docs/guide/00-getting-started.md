# 00 — Getting started

`mc` is a compiler small enough to read, written in itself. It compiles a schoolbook-C language —
seven types, one opaque pointer, `if` and `loop` — into AArch64 Mach-O, and it writes and signs
the executable itself. Everything the core leaves out, you teach it from ordinary `mc` source.

This page gets you from nothing to a running binary. It takes about two minutes.

## What you need

- **macOS on Apple Silicon (arm64).** That is the only host today. `mc` *targets* Linux arm64 as
  well ([50-cross-compile.md](50-cross-compile.md)), but the compiler itself runs on macOS.
- Nothing else. No `make`, no `clang`, no linker, no SDK, no package manager. The standard
  library travels inside the binary, and `mc --exe` writes a signed executable with no `ld`.

## Install

### From a release

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
whoever downloaded the file; the signature itself stays valid
(`codesign --verify --verbose=4 mc`).

### From source

```sh
make stage0     # clang compiles the 2,846-line C23 seed — once, and never again
make mc1        # the seed compiles src/mc.mc into the real compiler: build/mc1
make check      # everything: tests, the fixed point, the demos, the examples
```

`clang` appears exactly once in that chain, and never again. Why that matters, and how the
compiler reproduces itself afterwards, is [70-bootstrap.md](70-bootstrap.md).

## Your first program

```mc
// expect-exit: 42
i64 main() {
    return 42;
}
```

```sh
$ mc --exe hello.mc -o hello
$ ./hello; echo $?
42
```

`--exe` writes a Mach-O executable directly: address layout, relocations, `dyld` bind opcodes and
an ad-hoc code signature, all from `mc` itself. No linker was involved, and the binary is already
`0755` and runnable.

```sh
$ codesign --verify --verbose=2 hello
hello: valid on disk
hello: satisfies its Designated Requirement
```

## Printing something

The core language has no I/O. `#include <sys>` brings in libSystem's
`open/creat/read/write/close/exit` plus three helpers written in the language itself —
`strlen`, `puts`, `putnum`. The angle brackets mean "from the bundle inside this binary": no
path, no checkout, no include flag.

```mc
// expect-exit: 0
// expect-stdout: 46368
#include <sys>

i64 fib(i64 n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

i64 main() {
    putnum(fib(24));
    write(1, "\n", 1);
    return 0;
}
```

```sh
$ mc --exe fib.mc -o fib && ./fib
46368
```

## `while` and `for` are not in the language

They are six `#rule` macros in a file called `<prelude>`, written in `mc` itself. Include it and
they exist; leave it out and they do not. That is the whole idea of the project in one line.

```mc
// expect-exit: 0
// expect-stdout: 45
#include <sys>
#include <prelude>

i64 main() {
    i64 s = 0;
    for (i64 i = 0; i < 10; i = i + 1) {
        s += i;
    }
    putnum(s);
    write(1, "\n", 1);
    return 0;
}
```

## The other output: an object file

```sh
$ mc hello.mc -o hello.o
$ ld -arch arm64 -syslibroot $(xcrun --show-sdk-path) -lSystem -o hello hello.o
```

Without `--exe`, `mc` writes a Mach-O `MH_OBJECT` for the system linker. Both paths use the same
code generator and produce the same instructions; they differ only in the envelope. The `.o` path
is useful when you want the linker to catch an undefined symbol at build time, or when you are
linking against something `mc` does not know about
([10-single-file.md](10-single-file.md) § `extern`).

## Looking inside

Five flags print deterministic text and produce no object. They exist since the first milestone,
and they are how the two compilers in this repository are compared against each other.

```sh
$ mc --dump-tokens hello.mc     # the lexer's output, one token per line
$ mc --dump-ast    hello.mc     # the tree, after macro expansion and after your passes
$ mc --dump-rules  hello.mc     # every #rule and every operator, with precedence
$ mc --dump-asm    hello.mc     # the lowered instructions, before encoding
$ mc --dump-syms   hello.mc     # sections and symbols
```

```
$ mc --dump-asm hello.mc
_main:
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  movz x9, #42
  mov x0, x9
  b L1
L1:
  ldp x29, x30, [sp], #16
  ret
```

Every flag is in [../reference/cli.md](../reference/cli.md).

## Where to go next

| you want to | read |
|---|---|
| write a real program in one file | [10-single-file.md](10-single-file.md) |
| build a project with dependencies and a linker | [20-project-toml.md](20-project-toml.md) |
| add syntax to the language | [30-teaching.md](30-teaching.md) |
| emit your own bytes, or a whole new object format | [40-backends.md](40-backends.md) |
| target Linux | [50-cross-compile.md](50-cross-compile.md) |
| see two real, complete examples | [60-examples.md](60-examples.md) |
| understand how it compiles itself | [70-bootstrap.md](70-bootstrap.md) |

The exhaustive side is `docs/reference/`: [language](../reference/language.md),
[directives](../reference/directives.md), [CLI](../reference/cli.md),
[mc.toml](../reference/toml.md), [hooks](../reference/hooks.md),
[objects](../reference/objects.md), [diagnostics](../reference/diagnostics.md),
[bundle](../reference/bundle.md).
