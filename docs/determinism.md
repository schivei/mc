# determinism.md — the 8 rules of determinism

Source: `docs/plan.md` § Determinism. Final goal: `mc1 mc.mc → mc2.o` and `mc2 mc.mc → mc3.o`
produce byte-for-byte identical `.o` files (fixed point, **M7**). Each rule below has an example
of a violation (what not to do) and the correct form — the correct form, where code already
exists, is quoted from `stage0/arena.c`/`stage0/macho.c`, which have followed these rules since
M0.

## 1. Never hash pointers; never iterate a hash table to generate output

Violation:
```c
for (int i = 0; i < table.cap; i++)      // order = the hash table's internal layout,
    if (table.slot[i].used)              // depends on address/hash: not deterministic
        emit_symbol(table.slot[i]);
```
Correct: a parallel array in insertion order — `sym_new()` in `stage0/macho.c` always does an
`append` into `symbols[nsymbols++]`, never a hash insert.

## 2. Symtab via a stable partition; no `qsort`

Violation:
```c
qsort(symbols, nsymbols, sizeof(Symbol), cmp_by_addr);  // qsort's tie-breaking is not stable
                                                          // (and can vary between libc's)
```
Correct: a stable partition into 3 classes (local, defined extern, undefined), preserving
insertion order within each class — the loop in `macho_write()`:
`for (c = 0; c < 3; c++) for (i = 0; i < nsymbols; i++) if (sym_class(&symbols[i]) == c) ...`.

## 3. stage0's C I/O has the same shape as the `.mc` version

Violation:
```c
FILE *f = fopen(path, "rb");             // stdio buffers/formats differently from the .mc
fread(buf, 1, n, f);                     // version, which will only have open/read/write/close (no stdio)
```
Correct: `open`/`read` in a loop until `r == 0`, then `close` — it's literally `read_file()` in
`stage0/arena.c`, so it can be transliterated 1:1 later.

## 4. No `__FILE__`, date, absolute path, `N_OSO`/stabs, `ar`

Violation:
```c
buf_u32(&o, LC_BUILD_VERSION); buf_u32(&o, 24);
buf_u32(&o, 1); buf_u32(&o, sdk_version_from_env()); ...   // varies by machine/installed SDK
```
Correct: hardcoded values — `stage0/macho.c` always writes `platform=1, minos=0x000D0000,
sdk=0x000D0000, ntools=0`, regardless of machine or build date.

## 5. Zero every padding/alignment byte explicitly

Violation:
```c
o.len += pad;   // "skips" bytes without writing them; the arena heap's content may not be zeroed
```
Correct: `buf_pad(Buf *b, size_t align) { while (b->len % align) buf_u8(b, 0); }`
(`stage0/arena.c`) — writes zero byte by byte up to the alignment, never advances the cursor
without writing.

## 6. Fixed reference builds

Reference: plain `-O1` (`make stage0`). Additional CI: `-O0 -fwrapv -fno-strict-aliasing
-fsanitize=undefined,address` (`make stage0-san`). Violation: comparing `.o` files generated with
different flags (e.g. local `-O2` vs `-O1` in CI) and treating a compiler-optimization divergence
as an `mc` determinism bug — always compare builds made with the same flags.

## 7. `--dump-tokens/--dump-ast/--dump-syms/--dump-asm` with deterministic text since M1

Violation: a dump that prints a pointer address (`%p`) or iterates the compiler's internal hash
table. Correct: fixed text by index/field, one line per item, in emission/insertion order —
already required at M1's acceptance (`docs/specs/M1.md`: run `--dump-tokens`, `--dump-ast`,
`--dump-asm` twice and `diff` shows no difference).

## 8. Compare `.o` files, not linked executables

Violation: `diff <(./mc1_linked) <(./mc2_linked)`, or comparing post-`ld` binaries — Apple's
linker can introduce layout/UUID not controlled by `mc`. Correct: compare the `.o` the compiler
emits before `ld` (`cmp mc2.o mc3.o`); versioned golden SHA-256 of `mc2.o` in `tests/golden/`.

## Capacity never reaches the output (M23)

Since M23 every table in `src/` is an arena block that **doubles on demand**, sized before the
first append from a pre-scan estimate times `1 + tolerance` (`docs/build.md` § limits). None of
that may reach a single byte of what the compiler emits, and it does not:

* `grow()` copies the elements already there into the new block **in the same order** and returns
  a bigger block. Nothing else changes: no index moves, no id is recomputed, no table is re-sorted.
  A table that grew four times holds exactly what the same table would hold had it been reserved
  correctly the first time.
* Nothing in the compiler reads a capacity. `nnodes`, `nsymbols`, `nstrs` and friends are the only
  counters codegen and the writers ever consult; `nodecap`, `symcap`, `strcap` exist solely for
  `grow()`.
* The arena grows by **mapping one more chunk**, never by moving one. Chunks are never freed, so
  a pointer handed out before a growth is still the same pointer after it, and no address of an
  arena block is ever hashed, compared for ordering, or written to a file (rule 1).
* `build/.mc-usage.toml` and `[limits].tolerance` change capacities and nothing else. That is what
  makes the acceptance possible: `mc build` twice on the same source, once with a cold estimate
  and once with the remembered one, produces byte-identical output — `make check`'s `check-obj`
  (32/32) and `bootstrap` (`mc2.o == mc3.o`) are exactly that comparison.

Violation to watch for: a table whose *iteration bound* is its capacity instead of its count, e.g.
`for (i = 0; i < strcap; i++) emit(...)`. That would put reserved-but-unused slots into the output
and make it depend on the tolerance. The correct form is what every loop here already does —
iterate to the counter, never to the capacity.

## Fixed-point diagnosis (M7)

When `mc1 src/mc.mc` and `mc2 src/mc.mc` diverge:

1. Generate both `.o` files normally and confirm the divergence with `cmp mc2.o mc3.o`.
2. Run `diff <(mc1 --dump-asm src/mc.mc) <(mc2 --dump-asm src/mc.mc)`. Since the dump is
   deterministic text (rule 7), the first differing line already points at the culprit
   instruction/symbol, with no need to compare raw `.o` bytes.
3. Bisect by function: isolate half the functions of `src/mc.mc` (comment them out, or compile a
   subset via `#include`) and repeat the diff until the exact diverging function remains.
4. Check against the rules above before fixing — usual causes from the plan (§ Risks/§
   Milestones): table ordering (rules 1/2), unzeroed padding (rule 5), a short file read (rule
   3).
5. Fix, rebuild `mc1`/`mc2`/`mc3`, and repeat `cmp` until it matches byte for byte.
