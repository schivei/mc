# macho-notes.md — verified Mach-O/AArch64 notes

Values verified by reading `stage0/macho.c` (implemented and in use since M0) — not a transcript
of the plan, this is what the code actually writes.

## Header and constants

```c
MH_MAGIC_64                 = 0xfeedfacf
CPU_TYPE_ARM64               = 0x0100000C   // subtype 0
MH_OBJECT                    = 1
MH_SUBSECTIONS_VIA_SYMBOLS   = 0x2000
LC_SEGMENT_64                = 0x19
LC_SYMTAB                    = 0x2
LC_DYSYMTAB                  = 0xb
LC_BUILD_VERSION             = 0x32
N_UNDF = 0x00   N_EXT = 0x01   N_SECT = 0x0e
```

Section flags in use today: `S_REGULAR=0x0`, `S_ZEROFILL=0x1`, `S_CSTRING_LITERALS=0x2`,
`S_ATTR_PURE_INSTRUCTIONS=0x80000000`, `S_ATTR_SOME_INSTRUCTIONS=0x00000400` (the last two
combined into `TEXT_FLAGS`, `stage0/mc.h`).

### `S_CSTRING_LITERALS` coalescing — why an embedded `\0` is forbidden

Apple's `ld` treats every section marked `S_CSTRING_LITERALS` as a C string pool: it can coalesce
two literals whose content matches **up to the first `\0`**, to save space — this is how two
different `.o` files with the same string literal end up sharing one address after linking. `mc0`
already does its own dedup (a linear search by full content, byte for byte,
`stage0/gen_arm64.c`) before writing `__cstring`, so identical strings from the same module
already come out with a single symbol (confirmed: two calls to `puts("dup")` in the same file
produce a single `l_str0` in `--dump-syms`, a 4-byte `__cstring` section). The problem is the case
`mc0`'s dedup does **not** see the same way `ld` does: `mc0` compares the entire byte sequence
(`"a\0b"` with 3 bytes of content is different from `"a"` with 1), but `ld`'s coalescing only
looks up to the first `\0` — in the bytes written, `"a\0b\0"` and `"a\0"` share the same prefix up
to the first NUL, and `ld` would treat them as the same literal, silently giving them the same
address. Since `mc0` doesn't replicate `ld`'s merge rule in its own dedup, the result would
diverge from what `mc0` "thinks" it compiled. That's why `\0` inside a string literal is a
compile-time error (M5.5, see `docs/core-language.md`) instead of one more case in the dedup.

`macho_write()` always emits **4 load commands** (`ncmds=4`): a single `LC_SEGMENT_64` (which
carries every section in the module), then `LC_BUILD_VERSION`, `LC_SYMTAB`, `LC_DYSYMTAB`, in that
order.

## Address layout

Two passes over the sections: first the regular ones, in the order `sec_new` created them (first
section created = first address), then the `S_ZEROFILL` ones. Each section is aligned to
`1 << align` before its size is added to the accumulated VM. The segment's `filesz` is the VM
right before entering the zerofill sections — zerofill takes no file space, only VM.

## Section order (`gen_sections`, M5.5)

The **creation** order via `sec_new` — which is also the address order of the previous section —
always follows this recipe, fixed since M5.5 (`stage0/gen_arm64.c:gen_sections`, comment in the
code itself: "`__text`, `__cstring`, `__data`, and `__bss` (whichever the module uses), and only
then the `#section` ones, in order of first appearance in the source"):

1. `__TEXT,__text` — always created, even if empty.
2. `__TEXT,__cstring` (`S_CSTRING_LITERALS`) — only if the module has a string literal.
3. `__DATA,__data` — only if there's an initialized global (scalar or array) without a custom
   section.
4. `__DATA,__bss` (`S_ZEROFILL`) — only if there's an uninitialized global without a custom
   section.
5. Custom sections declared via `#section`, in order of each one's **first appearance** in the
   source (registered in their own linear table; `#section` with no arguments doesn't count as an
   appearance, it only returns to the default).

Confirmed with a real `--dump-syms`: `tests/030-section.mc` (which uses `__DATA,__tbl`,
`__DATA,__zt`, and `__TEXT,__hot` via `#section`) produces, in that exact order, `__TEXT,__text` →
`__DATA,__data` → `__DATA,__tbl` → `__DATA,__zt` → `__TEXT,__hot`; `tests/040-arrinit.mc` (no
`#section`, with strings and an initialized array) produces `__TEXT,__text` → `__TEXT,__cstring`
→ `__DATA,__data`; `tests/024-arena.mc` (uninitialized global array) produces `__TEXT,__text` →
`__DATA,__data` → `__DATA,__bss`.

## Relocations — 4 types + the `ADDEND` modifier

```c
R_UNSIGNED   = 0   // pointer in __data, len=3 (2^3 = 8 bytes)
R_SUBTRACTOR = 1   // reserved in the enum, unused so far
R_BRANCH26   = 2   // bl
R_PAGE21     = 3   // adrp — high part of a string/global/array address
R_PAGEOFF12  = 4   // add/ldr — low part
R_ADDEND     = 10  // precedes another reloc when there's a constant sum (addend)
```

These same four constants (`UNSIGNED BRANCH26 PAGE21 PAGEOFF12`) are predefined in the surface's
`#define` table for use in `reloc(TYPE, "symbol")` (`docs/surface.md`).

### `R_UNSIGNED` in `__data` — a global `uptr` array initializer

Since M5.5, a string-literal element inside `type v[] = {...}` writes 8 zero bytes in `__data`
and pins an `R_UNSIGNED` relocation (len=3, pcrel=0, extern=1) at that offset, pointing at the
local symbol `l_strN` for that string in `__cstring` — it's `ld`, at link time, that resolves the
pointer by adding `l_strN`'s final address. Confirmed with `otool -r` on
`tests/040-arrinit.mc` (`uptr names[] = {"zero", "um", "dois"};`):

```
Relocation information (__DATA,__data) 3 entries
address  pcrel length extern type    scattered symbolnum/value
00000010 0     3      1      0       0         2
00000008 0     3      1      0       0         1
00000000 0     3      1      0       0         0
```

`type=0` is `R_UNSIGNED`, `length=3` is 8 bytes, `pcrel=0` (absolute address, not PC-relative) —
one reloc per array pointer, in decreasing address order (the general rule from the previous
section).

Each relocation is 8 bytes: offset (u32) + bitfield word (u32), LE, layout
`symbolnum:24 | pcrel:1 | length:2 | extern:1 | type:4` (bit 0 through 31), written like this in
`macho_write()`:

```c
buf_u32(&o, r->off);
buf_u32(&o, (symnum & 0xffffff) | (pcrel << 24) | (len << 25) | (ext << 27) | (type << 28));
```

`symnum` is the symbol's index in the symtab's **final order**, not its creation index — that's
why `macho_write` builds `pos[]` (creation index → final position) before emitting relocations.
`ext=0` only when `type == R_ADDEND` (uses the addend's raw value instead of a symbol index).
Relocations are emitted in **decreasing address order** within each section — the same behavior
as Apple's `clang`/`ld`, important for golden-matching (M7).

## Symtab order

A stable partition into 3 classes, always in this order: **locals → defined externs →
undefined** (`sym_class`: `sect==0` → undefined; else `global` → extern; else local).
`LC_DYSYMTAB` describes this partition's indices: `ilocalsym=0`, `nlocalsym=count[local]`,
`iextdefsym=count[local]`, `nextdefsym=count[extern]`,
`iundefsym=count[local]+count[extern]`, `nundefsym=count[undef]`. `n_sect` is 1-based (section 0
= "none"; undefined symbols use `n_sect=0`). The string table starts with a `\0` and is padded
(`buf_pad`) to a multiple of 8.

## `LC_BUILD_VERSION` is mandatory

Without this load command, the modern `ld` refuses the `.o` (behavior observed at M0). Values
hardcoded in `macho.c` (determinism rule 4 — never read the installed SDK's version at runtime):
`platform=1` (macOS), `minos=0x000D0000` (13.0.0), `sdk=0x000D0000` (13.0.0), `ntools=0`.

## Link

`scripts/link.sh OUT IN.o [...]`:
```sh
ld -arch arm64 -platform_version macos 13.0 13.0 -syslibroot "$(xcrun --show-sdk-path)" -lSystem -o "$out" "$@"
```
`ld` remains allowed even after the cord is cut (M8) — only `gcc`/`cc`/`clang` are left out (
stage0 is the only thing compiled by `clang`, exactly once).

## Syscalls (`x16` + `svc #0x80`)

BSD/Darwin arm64 convention: syscall number in `x16`, arguments in `x0..x5`, `svc #0x80`, result
in `x0`. Numbers used today (verified against the SDK's `sys/syscall.h`):

| Syscall | Number |
|---|---|
| `exit`  | 1 |
| `read`  | 3 |
| `write` | 4 |
| `open`  | 5 |
| `close` | 6 |

`m05()` in `stage0/main.c` already uses this: `mov x16, #4` + `svc #0x80` for `write`,
`mov x16, #1` + `svc #0x80` for `exit`.

## Empirical finding from M0.5: a static binary is killed by the kernel

Tested: generate the M0.5 `.o` and link it **statically** (`ld -static -e _start ...`), which
produces an executable with `LC_UNIXTHREAD` as its entry point. Result: the process is killed
with **SIGKILL** by the kernel right at startup — even after `codesign -s - <binary>` (an ad-hoc
signature). The same `.o`, linked **dynamically** (`ld -e _start -lSystem -syslibroot ... -o out out.o`,
the path `scripts/link.sh` implements), runs normally and `svc` works as expected.

**Conclusion:** today's macOS (Xcode 26 / ld-1267, darwin arm64) no longer accepts fully static
Mach-O executables, even ad-hoc signed ones — dyld/`LC_LOAD_DYLINKER` is mandatory. Always link
with `-lSystem`/dyld (`scripts/link.sh` already does this); raw syscalls (`x16` + `svc`) keep
working fine under dyld — the restriction is about the binary being static, not about emitting
`svc` directly. This implies M11 (direct executable, `MH_EXECUTE`) always needs to include
`LC_LOAD_DYLINKER` + `LC_LOAD_DYLIB libSystem`, as already stated in M11's acceptance criteria in
the plan.

## M11 — direct executable (`MH_EXECUTE`), without `ld`

Everything below was verified against the binaries `src/backend_exe.mc` actually writes
(`otool -l`, `otool -s`, `nm -m`, `xxd`, `codesign -dvvv`), compared field by field with the
reference produced by `ld` (`build/mc1 tests/001-return42.mc -o t.o && scripts/link.sh t t.o`).
The modern `ld` uses *chained fixups*; to get a reference in the classic format that M11 writes,
generate it with `ld ... -no_fixup_chains` — it produces `LC_DYLD_INFO_ONLY` and `__stubs`, and
runs normally. This proves, as a side effect, that this macOS's `dyld` (Darwin 25.6) still
accepts bind/rebase via opcodes.

### Segment layout

One `LC_SEGMENT_64` per **distinct segname** among the module's sections, in order of first
appearance — since `__TEXT,__text` is always the first section `gen_sections` creates, `__TEXT`
is always first. `__DATA` is created even without globals when there's an imported symbol (that's
where `__got` lives). Inside each segment: regular sections in creation order, `S_ZEROFILL` last
— the same rule `macho_write` follows.

```
__PAGEZERO   vmaddr 0            vmsize 0x100000000   fileoff 0      filesize 0       prot 0
__TEXT       vmaddr 0x100000000  vmsize 0x4000        fileoff 0      filesize 16384   prot 5 (r-x)
__DATA       vmaddr 0x100004000  vmsize 0x4000        fileoff 16384  filesize 16384   prot 3 (rw-)
__LINKEDIT   vmaddr 0x100008000  vmsize 0x4000        fileoff 32768  filesize 586     prot 1 (r--)
```

(real values from `build/mc1 --exe tests/021-strings.mc`). Confirmed rules:

- **16 KiB page** (arm64's `vm_page_size`): every segment's `vmaddr` and `fileoff` are multiples
  of 16384. `filesize` is the regular content rounded up (the file is padded with zeros up to
  there); `vmsize` is the total content, zerofill included, rounded up.
- **VM and file advance separately.** The next segment has `vmaddr = vmaddr + vmsize` and
  `fileoff = fileoff + filesize` of the previous one, computed independently — that's what allows
  a 32 MiB `__bss` (`heap[]` in `src/arena.mc`) without a 32 MiB file. Confirmed against `ld`:
  `build/mc1` has `__DATA` with `vmsize 0x2030000` and `filesize 16384`, and `__LINKEDIT` at
  `vmaddr 0x10205c000` = `0x10002c000 + 0x2030000`.
- **The header lives inside `__TEXT`**: `__TEXT` starts at `fileoff 0` and the first section
  starts at `32 + sizeofcmds`, rounded up to its own alignment.
- **`LC_MAIN`'s `entryoff` is `_main`'s file offset.** Since `__TEXT` has `fileoff 0` and
  `vmaddr = 0x100000000`, it's simply `addr(_main) - 0x100000000`. `dyld`/`libdyld` calls that
  address as `main(argc, argv, envp, apple)` and does `exit(return value)` — which is why an
  `i64 main()` that returns 42 gives `$? == 42` without any hand-written `_start`.

Header flags: `MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE` = `0x200085`. `ld` sets
`MH_NOUNDEFS` even with imported symbols (confirmed with `otool -hv` on the reference) — the flag
means "nothing was left unresolved by the link", not "there's no undefined symbol in the symtab".

### Load commands (13, in this order)

`LC_SEGMENT_64` x4 · `LC_DYLD_INFO_ONLY` · `LC_SYMTAB` · `LC_DYSYMTAB` · `LC_LOAD_DYLINKER` ·
`LC_UUID` · `LC_BUILD_VERSION` · `LC_MAIN` · `LC_LOAD_DYLIB` · `LC_CODE_SIGNATURE`.

```c
LC_DYLD_INFO_ONLY = 0x80000022   /* 0x22 | LC_REQ_DYLD */   cmdsize 48
LC_LOAD_DYLINKER  = 0x0e   cmdsize 32   name "/usr/lib/dyld" at offset 12
LC_UUID           = 0x1b   cmdsize 24
LC_MAIN           = 0x80000028   cmdsize 24   entryoff u64, stacksize u64 = 0
LC_LOAD_DYLIB     = 0x0c   cmdsize 56   "/usr/lib/libSystem.B.dylib" at offset 24,
                                        timestamp 2, current 1356.0.0, compat 1.0.0
LC_CODE_SIGNATURE = 0x1d   cmdsize 16   dataoff, datasize
```

`LC_LOAD_DYLINKER` + `LC_LOAD_DYLIB` are mandatory: the empirical finding from M0.5 (previous
section) is that a static binary gets killed by the kernel even when signed. `LC_BUILD_VERSION`
comes out with `ntools = 0` (cmdsize 24), unlike `ld`, which appends a tool entry (cmdsize 32) —
`dyld` doesn't care, and `ntools=0` is more deterministic (no linker version in the file).

### `__stubs` and `__got` — calling an imported symbol

Every undefined symbol gets a 12-byte stub in `__TEXT,__stubs` and an 8-byte slot in
`__DATA,__got`. Every `BRANCH26` to an undefined symbol is resolved to the **stub's address**;
`PAGE21`/`PAGEOFF12` for an undefined symbol also point at the stub, which is what makes `&write`
work in the direct executable (in `.o` + `ld` it's still M10's known limit, see
`docs/core-language.md`).

```
__TEXT,__stubs   flags 0x80000408 (S_SYMBOL_STUBS|PURE|SOME)  reserved2 = 12 (stub size)
__DATA,__got     flags 0x00000006 (S_NON_LAZY_SYMBOL_POINTERS)
```

The stub's content, verified with `otool -s __TEXT __stubs`:

```
0000000100000000  90000030 f9400210 d61f0200
                  adrp x16, slot's page
                           ldr  x16, [x16, #off]
                                    br   x16
```

`reserved1` is the index into the indirect symbol table; it lists the imported symbols **twice**,
first for `__stubs` (`reserved1 = 0`) and then for `__got` (`reserved1 = nundef`), each entry
being the symbol's index in the final symtab. The modern `dyld` doesn't use it (the bind opcodes
are what fill `__got`), but `nm -m`/`otool` do.

Undefined symbol in the symtab: `n_type = N_UNDF|N_EXT`, `n_sect = 0`,
**`n_desc = 0x0100`** — bits 8..15 of `n_desc` are the dylib's ordinal in the two-level namespace
(`MH_TWOLEVEL`), and 1 is the file's only `LC_LOAD_DYLIB`. Confirmed against `ld`'s reference
(`xxd` of the symtab: `_write` comes out with `n_desc` `00 01` little-endian) and in the result:
`nm -m` shows `(undefined) external _write (from libSystem)`.

### Bind and rebase (`LC_DYLD_INFO_ONLY`)

Only `rebase_off/size` and `bind_off/size`; `weak`, `lazy`, and `export` stay zeroed (every bind
is immediate, and an executable doesn't need to export anything). Real bytes from
`tests/021-strings.mc`, which only imports `_write`:

```
$ xxd -s 32768 -l 14 tmp/e-021-strings
1151 405f 7772 6974 6500 7200 9000
 |  |  |   \_ "_write\0"          |  \_ 0x00 BIND_OPCODE_DONE
 |  |  \_ 0x40 SET_SYMBOL_TRAILING_FLAGS_IMM (flags 0)
 |  \_ 0x51 SET_TYPE_IMM 1 (BIND_TYPE_POINTER)
 \_ 0x11 SET_DYLIB_ORDINAL_IMM 1        0x72 SET_SEGMENT_AND_OFFSET_ULEB seg=2 (__DATA), off=0
                                        0x90 DO_BIND
```

This is byte for byte the same shape `ld` emits (confirmed with `-no_fixup_chains`, which
produces `1140 "dyld_stub_binder" 0051 7200 9000` for its own lazy binder).

Rebase from `tests/040-arrinit.mc` (`uptr names[] = {"zero", "um", "dois"}` — three
`R_UNSIGNED` in `__data`):

```
$ xxd -s 32768 -l 11 tmp/e-040-arrinit
1122 0051 2208 5122 1051 00
 |    \_ 0x22 SET_SEGMENT_AND_OFFSET_ULEB seg=2, off=0 · 0x51 DO_REBASE_IMM_TIMES 1
 \_ 0x11 REBASE_OPCODE_SET_TYPE_IMM 1 (REBASE_TYPE_POINTER)   ... off=8 ... off=16 ... 0x00 DONE
```

The corresponding `__data` holds the address **without the slide**, and `dyld` adds the slide
during rebase:

```
$ otool -s __DATA __data tmp/e-040-arrinit
0000000100004000  000006d8 00000001 000006dd 00000001 000006e0 00000001 ...
```

(`0x1000006d8`, `0x1000006dd`, `0x1000006e0` are the three `__cstring` literals.) Without the
rebase entry the pointer would point to the wrong place as soon as ASLR applied a slide — tested
by running the binary three times in a row, with identical stdout each time.

An `R_UNSIGNED` in a segment section that is **not writable** is refused with
`relocated pointer in __TEXT: the segment is r-x and dyld will not rebase it` — there's no way
for `dyld` to write there, and a clear error beats a SIGKILL.

### Resolving the four relocations

Done by `mc` itself, patching the already-encoded word in the section:

| type | how it's computed |
|---|---|
| `BRANCH26` | `imm26 = (target - pc) / 4`, ±128 MiB; written into the low 26 bits of the `bl` |
| `PAGE21` | `imm = (page(target) - page(pc)) / 4096`; `immlo` in bits 29:30, `immhi` in bits 5:23 of the `adrp` |
| `PAGEOFF12` | `imm12 = target & 0xfff` for `add`; for `ldr`/`str` with an unsigned offset (`(w & 0x3b000000) == 0x39000000`), divided by the access width (bits 31:30) |
| `UNSIGNED` | 8 bytes with the absolute address without a slide + a rebase entry (or bind, if the symbol is imported) |

`R_ADDEND` and `R_SUBTRACTOR` are refused: the core never emits them (see the relocations
section above) and the surface only predefines `UNSIGNED BRANCH26 PAGE21 PAGEOFF12`.

### Ad-hoc signature (`LC_CODE_SIGNATURE`)

Without a signature, the kernel kills the process. The blob sits at the end of `__LINKEDIT`,
aligned to 16, and is the last thing in the file. Every field is **big-endian** — unlike the rest
of Mach-O.

```
CS_SuperBlob   magic 0xfade0cc0, length, count = 1
  CS_BlobIndex type 0 (CSSLOT_CODEDIRECTORY), offset 20
CS_CodeDirectory (at +20)   magic 0xfade0c02
  version       0x20400        <- the version that has execSeg*
  flags         0x2 (CS_ADHOC)
  hashOffset    88 + len(identifier)+1
  identOffset   88             <- fixed header size for v0x20400
  nSpecialSlots 0
  nCodeSlots    ceil(codeLimit / 4096)
  codeLimit     the blob's own file offset
  hashSize 32 · hashType 2 (SHA-256) · platform 0 · pageSize 12 (1<<12 = 4 KiB)
  spare2, scatterOffset, teamOffset, spare3, codeLimit64 = 0
  execSegBase   __TEXT's fileoff (0)
  execSegLimit  __TEXT's filesize
  execSegFlags  1 (CS_EXECSEG_MAIN_BINARY)
  NUL-terminated identifier, followed by nCodeSlots 32-byte hashes
```

The offsets `identOffset = 88` and `hashOffset = 90` (identifier `"t\0"`) were read byte by byte
from an `ld` signature with `xxd`, and `execSegLimit = __TEXT's filesize` from a
`codesign -f -s -` signature (`ld`, in its *linker-signed* signature, writes `__text`'s size
there, not the segment's — it works, but `codesign` is the better reference). Each slot is the
SHA-256 of a 4 KiB page **of the file**, with the last page partial (the hash only covers up to
`codeLimit`).

Result:

```
$ codesign -dvvv tmp/t1
CodeDirectory v=20400 size=251 flags=0x2(adhoc) hashes=5+0 location=embedded
Executable Segment base=0
Executable Segment limit=16384
Executable Segment flags=0x1
Page size=4096
$ codesign --verify --verbose=4 tmp/t1
tmp/t1: valid on disk
tmp/t1: satisfies its Designated Requirement
```

The identifier is the **basename of the output file** (`-o tmp/t1` → `t1`), the same convention
`codesign` uses.

### Deterministic `LC_UUID`

The 16 bytes are the first 16 of the SHA-256 of the whole file **with the UUID field zeroed and
without the signature** (i.e. of bytes `[0, codeLimit)`), with the version bits
(`byte[6] = (b & 0x0f) | 0x50`) and variant bits (`byte[8] = (b & 0x3f) | 0x80`) forced as RFC
4122 requires. No date, path, or SDK version enters into it — two builds of the same source for
the same output name give the same UUID, and therefore the same binary byte for byte.

### Execute permission

`arena.mc`'s `write_file` uses `creat(path, 0644)`. The executable uses `creat(path, 0755)`
**and** a `chmod(path, 0755)` after closing: `creat` only applies the mode when it *creates* the
file, so overwriting a pre-existing `-o` with a different permission would keep the old one.
`chmod` is the only `extern` M11 added.
