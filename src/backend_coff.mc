// backend_coff.mc — backend `coff-obj-arm64`: a COFF object for Windows on ARM,
// the relocatable `.obj` a Windows linker (`lld-link`, `link.exe`) takes
// (M19, docs/specs/M19.md).
//
// It is the third writer over the same lowering. `gen_lower` turns the AST into
// sections, symbols and relocations, `gen_encode_all` encodes the words, and
// this file only says those three things in COFF's spelling:
//
//   sections     one COFF section per module section, in creation order, so the
//                1-based section number is exactly the module's `sym_sect` and
//                nothing has to be renumbered. `__TEXT,__text` -> `.text`,
//                `__TEXT,__cstring` -> `.rdata`, `__DATA,__data` -> `.data`,
//                `__DATA,__bss` -> `.bss`, and `#section SEG SECT` -> `.seg.sect`
//                with the same lowercasing the ELF writer does. Alignment is not
//                a field here: it is three bits inside Characteristics.
//   symbols      18 bytes each, no auxiliary records. Windows on ARM has NO
//                leading underscore, so the compiler's `_main` becomes `main`
//                exactly as it does in ELF, and the string labels become the
//                Microsoft convention for a compiler temporary, `$str.N`.
//                The stable partition macho.mc already computes (`sym_order`)
//                is reused: COFF does not require locals first, but keeping the
//                one order every writer uses is what makes the three objects
//                comparable.
//   relocations  10 bytes each, no addend field — like Mach-O and unlike ELF,
//                the addend lives in the instruction, and the encoder leaves it
//                zeroed. Sorted by ascending offset (elf_rel_order, which has
//                nothing ELF in it).
//
// The object is NOT an executable: `os = "windows"` in mc.toml always goes
// through `[linker]` (src/driver.mc). There is no `--exe` equivalent here, for
// the same reason there is none for Linux.
//
// Depends on arena.mc (buf_*, xalloc, die, write_file), on macho.mc (sections,
// symbols, relocations, sym_order and the R_* / S_* constants), on gen_walk.mc
// (gen_lower/gen_encode_all, ivec_at/set_ivec_at, isec_*), on toml.mc (tm_cat,
// tm_num_str) and on backend_exe.mc (`exe_segname`, 16 fixed bytes as a string).
// It borrows two pure helpers from backend_elf.mc — `elf_put_lower` (a Mach-O
// name lowercased with its leading underscores dropped) and `elf_rel_order`
// (relocations by ascending offset); neither has anything ELF in it.

#include "../lib/prelude.mc"

// ---- IMAGE_FILE_HEADER ----
#define IMAGE_FILE_MACHINE_ARM64 0xAA64
#define COFF_HDR_SIZE   20
#define COFF_SHDR_SIZE  40
#define COFF_SYM_SIZE   18
#define COFF_REL_SIZE   10

// ---- section Characteristics ----
#define SCN_CNT_CODE     0x00000020
#define SCN_CNT_INIT     0x00000040
#define SCN_CNT_UNINIT   0x00000080
#define SCN_MEM_EXECUTE  0x20000000
#define SCN_MEM_READ     0x40000000
#define SCN_MEM_WRITE    0x80000000
// IMAGE_SCN_ALIGN_<2^n>BYTES is (n + 1) << 20, from 1 byte (1 << 20) to
// 8192 bytes (14 << 20). Anything above that has no encoding at all.
#define SCN_ALIGN_SHIFT  20
#define SCN_ALIGN_MAX    13

// ---- symbols ----
#define COFF_SYM_UNDEFINED 0
#define COFF_SYM_TYPE_FUNC 0x20            // (IMAGE_SYM_DTYPE_FUNCTION << 4)
#define COFF_SYM_CLASS_EXTERNAL 2
#define COFF_SYM_CLASS_STATIC   3

// ---- relocations (IMAGE_REL_ARM64_*) ----
// The numbers are the ones the object files clang --target=aarch64-windows-msvc
// produces carry; note that ADDR64 is 0x000E, not 0x0001 (that is ADDR32).
#define IMAGE_REL_ARM64_BRANCH26       0x0003
#define IMAGE_REL_ARM64_PAGEBASE_REL21 0x0004
#define IMAGE_REL_ARM64_PAGEOFFSET_12A 0x0006
#define IMAGE_REL_ARM64_PAGEOFFSET_12L 0x0007
#define IMAGE_REL_ARM64_ADDR64         0x000E

// The COFF string table: names longer than 8 bytes, for sections and for
// symbols alike, with a 4-byte length prefix that counts itself. An offset in
// it is therefore never 0 for a real name, which is what lets 0 mean "the name
// fits inline".
u8 co_str[BUF_SIZE];

i64 coff_str_add(uptr n) {
    i64 at = buf_len(co_str);
    buf_put(co_str, n, cstrlen(n) + 1);
    return at;
}

// ---- section attributes ----
i64 coff_sec_zf(i64 i)   { return (sec_flags(sec_at(i)) & 0xff) == S_ZEROFILL; }
i64 coff_sec_exec(i64 i) { return (sec_flags(sec_at(i)) & S_ATTR_PURE_INSTRUCTIONS) != 0; }

i64 coff_sec_size(i64 i) {
    if (coff_sec_zf(i)) return sec_zsize(sec_at(i));
    return buf_len(sec_data(sec_at(i)));
}

// `#section SEG SECT` -> `.seg.sect` (`__TEXT,__hot` -> `.text.hot`), the same
// spelling the ELF writer gives it. The four sections the core itself creates do
// not come through here: they carry the names a Windows linker expects.
uptr coff_custom_name(i64 i) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_u8(b, '.');
    elf_put_lower(b, exe_segname(sec_seg(sec_at(i))));
    buf_u8(b, '.');
    elf_put_lower(b, exe_segname(sec_sect(sec_at(i))));
    buf_u8(b, 0);
    return buf_p(b);
}

uptr coff_sec_name(i64 i) {
    if (i == isec_text) return ".text";
    if (i == isec_cstr) return ".rdata";
    if (i == isec_data) return ".data";
    if (i == isec_bss)  return ".bss";
    return coff_custom_name(i);
}

// Alignment is three bits of Characteristics, not a field: log2 of the byte
// alignment plus one, shifted to bit 20. sec_align already holds the log2.
i64 coff_sec_align_char(i64 i) {
    i64 a = sec_align(sec_at(i));
    if (a > SCN_ALIGN_MAX) die2("section alignment above 8192 bytes",
                                exe_segname(sec_sect(sec_at(i))));
    return (a + 1) << SCN_ALIGN_SHIFT;
}

// Code for a pure-instructions section, uninitialised data for zerofill,
// read-only initialised data for the literals, read/write for the rest — the
// same four shapes clang gives .text/.bss/.rdata/.data.
i64 coff_sec_char(i64 i) {
    i64 c = coff_sec_align_char(i);
    if (coff_sec_exec(i)) return c | SCN_CNT_CODE | SCN_MEM_EXECUTE | SCN_MEM_READ;
    if (coff_sec_zf(i))   return c | SCN_CNT_UNINIT | SCN_MEM_READ | SCN_MEM_WRITE;
    if (i == isec_cstr)   return c | SCN_CNT_INIT | SCN_MEM_READ;
    return c | SCN_CNT_INIT | SCN_MEM_READ | SCN_MEM_WRITE;
}

// ---- names ----
// Mach-O name -> COFF name. Windows on ARM has no leading underscore, so the one
// the compiler prefixes goes away — the same rule ELF follows — and a string
// label becomes the Microsoft spelling of a compiler temporary.
uptr coff_sym_name(uptr n) {
    if (ld8(n) == 'l' && ld8(n + 1) == '_') {
        if (ld8(n + 2) == 's' && ld8(n + 3) == 't' && ld8(n + 4) == 'r')
            return tm_cat("$str.", n + 5);
        return tm_cat("$", n + 2);
    }
    if (ld8(n) == '_') return n + 1;
    return n;
}

// ---- symbol attributes ----
i64 coff_sym_class(uptr s) {
    if (sym_sect(s) == 0) return COFF_SYM_CLASS_EXTERNAL;
    if (sym_global(s))    return COFF_SYM_CLASS_EXTERNAL;
    return COFF_SYM_CLASS_STATIC;
}

// a symbol defined in a pure-instructions section is a function; everything else
// (data, and every undefined symbol) has no type at all
i64 coff_sym_type(uptr s) {
    if (sym_sect(s) == 0) return 0;
    if (coff_sec_exec(sym_sect(s) - 1)) return COFF_SYM_TYPE_FUNC;
    return 0;
}

// ---- relocations ----
// COFF is Mach-O's shape, not ELF's: the addend lives in the instruction and
// there is no field for it. PAGEOFF12 is one Mach-O relocation and two COFF
// ones — the 12-bit immediate of an `add` is the offset itself (12A), that of an
// ldr/str is scaled by the access width and the LINKER reads the scale off the
// instruction (12L). Same classifier as elf_pageoff12 and exe_fix_pageoff12.
i64 coff_rel_type(uptr sec, uptr r) {
    i64 t = rel_type(r);
    if (t == R_BRANCH26) return IMAGE_REL_ARM64_BRANCH26;
    if (t == R_PAGE21)   return IMAGE_REL_ARM64_PAGEBASE_REL21;
    if (t == R_UNSIGNED) {
        if (rel_len(r) != 3) die("UNSIGNED that does not occupy 8 bytes");
        return IMAGE_REL_ARM64_ADDR64;
    }
    if (t != R_PAGEOFF12) die("relocation not supported in the COFF object");
    i64 w = ld32(buf_p(sec_data(sec)) + rel_off(r));
    if ((w & 0x3b000000) != 0x39000000) return IMAGE_REL_ARM64_PAGEOFFSET_12A;
    return IMAGE_REL_ARM64_PAGEOFFSET_12L;
}

// NumberOfRelocations is 16 bits. Past 0xFFFF the format needs
// IMAGE_SCN_LNK_NRELOC_OVFL and a synthetic first relocation carrying the real
// count; nothing this compiler emits comes close, so it is refused with a
// message instead of written wrong.
void coff_put_relocs(uptr o, i64 i, uptr pos) {
    uptr s = sec_at(i);
    uptr ord = elf_rel_order(s);
    i64 j = 0;
    while (j < sec_nrel(s)) {
        uptr r = rel_at(sec_rel(s), ivec_at(ord, j));
        buf_u32(o, rel_off(r));
        buf_u32(o, ivec_at(pos, rel_sym(r)));
        buf_u16(o, coff_rel_type(s, r));
        j = j + 1;
    }
}

// ---- writing ----
// The 8 bytes of a name, zero-padded; a name longer than that is written by the
// two callers below, which do NOT spell it the same way.
void coff_put_name8(uptr o, uptr n) {
    i64 k = 0;
    i64 len = cstrlen(n);
    while (k < 8) {
        i64 c = 0;
        if (k < len) c = ld8(n + k);
        buf_u8(o, c);
        k = k + 1;
    }
}

// A SECTION name too long for the field is `/` and the decimal offset into the
// string table, as text inside the same 8 bytes.
void coff_put_sec_name(uptr o, uptr n, i64 stroff) {
    if (stroff == 0) {
        coff_put_name8(o, n);
        return;
    }
    coff_put_name8(o, tm_cat("/", tm_num_str(stroff)));
}

// A SYMBOL name too long for the field is four zero bytes followed by the
// offset as a 32-bit number. The two encodings are different on purpose: a
// section header is read by tools that print the name, a symbol record is not.
void coff_put_sym_name(uptr o, uptr n, i64 stroff) {
    if (stroff == 0) {
        coff_put_name8(o, n);
        return;
    }
    buf_u32(o, 0);
    buf_u32(o, stroff);
}

void coff_put_shdr(uptr o, i64 i, uptr nameoff, uptr rawoff, uptr reloff) {
    coff_put_sec_name(o, coff_sec_name(i), ivec_at(nameoff, i));
    buf_u32(o, 0);                              // VirtualSize: 0 in an object
    buf_u32(o, 0);                              // VirtualAddress: idem
    buf_u32(o, coff_sec_size(i));               // zerofill still declares its size
    buf_u32(o, ivec_at(rawoff, i));             // 0 when there are no bytes
    buf_u32(o, ivec_at(reloff, i));
    buf_u32(o, 0);                              // PointerToLinenumbers
    buf_u16(o, sec_nrel(sec_at(i)));
    buf_u16(o, 0);                              // NumberOfLinenumbers
    buf_u32(o, coff_sec_char(i));
}

void coff_put_symtab(uptr o, uptr order, uptr strx) {
    i64 k = 0;
    while (k < nsymbols) {
        i64 oi = ivec_at(order, k);
        uptr s = sym_at(oi);
        coff_put_sym_name(o, coff_sym_name(sym_name(s)), ivec_at(strx, oi));
        buf_u32(o, sym_value(s));
        buf_u16(o, sym_sect(s));                // 0 = IMAGE_SYM_UNDEFINED
        buf_u16(o, coff_sym_type(s));
        buf_u8(o, coff_sym_class(s));
        buf_u8(o, 0);                           // NumberOfAuxSymbols
        k = k + 1;
    }
}

void coff_write(uptr path) {
    uptr order = xalloc(8 * (nsymbols + 1));
    uptr pos   = xalloc(8 * (nsymbols + 1));
    uptr strx  = xalloc(8 * (nsymbols + 1));
    u8   count[24];
    sym_order(order, pos, count);               // local / defined global / undefined

    uptr nameoff = xalloc(8 * (nsections + 1));
    uptr rawoff  = xalloc(8 * (nsections + 1));
    uptr reloff  = xalloc(8 * (nsections + 1));

    // one string table for both kinds of name, sections first: the offsets have
    // to exist before the section headers are written, and putting them in a
    // fixed order is what makes the file reproducible.
    buf_init(co_str);
    buf_u32(co_str, 0);                         // the size, patched at the end
    i64 i = 0;
    while (i < nsections) {
        uptr n = coff_sec_name(i);
        set_ivec_at(nameoff, i, 0);
        if (cstrlen(n) > 8) set_ivec_at(nameoff, i, coff_str_add(n));
        i = i + 1;
    }
    i64 k = 0;
    while (k < nsymbols) {
        uptr n = coff_sym_name(sym_name(sym_at(k)));
        set_ivec_at(strx, k, 0);
        if (cstrlen(n) > 8) set_ivec_at(strx, k, coff_str_add(n));
        k = k + 1;
    }
    buf_patch32(co_str, 0, buf_len(co_str));

    // layout: header, section headers, the bytes of each section, the
    // relocations of each section, the symbol table, the string table. Every
    // block is on 4, which is what clang's own objects do.
    i64 cur = COFF_HDR_SIZE + COFF_SHDR_SIZE * nsections;
    i = 0;
    while (i < nsections) {
        set_ivec_at(rawoff, i, 0);
        if (!coff_sec_zf(i) && coff_sec_size(i) > 0) {
            cur = exe_up(cur, 4);
            set_ivec_at(rawoff, i, cur);
            cur = cur + coff_sec_size(i);
        }
        i = i + 1;
    }
    i = 0;
    while (i < nsections) {
        set_ivec_at(reloff, i, 0);
        i64 nr = sec_nrel(sec_at(i));
        if (nr > 0) {
            // 0xffff is not a count: it is the sentinel that says the real
            // count is in the VirtualAddress field of an extra leading
            // IMAGE_RELOCATION, with IMAGE_SCN_LNK_NRELOC_OVFL set. Writing it
            // as a count would be read back as that overflow form, so the
            // ceiling is 65534 relocations, not 65535.
            if (nr >= 0xffff) die2("65535 or more relocations in one section",
                                   coff_sec_name(i));
            cur = exe_up(cur, 4);
            set_ivec_at(reloff, i, cur);
            cur = cur + COFF_REL_SIZE * nr;
        }
        i = i + 1;
    }
    cur = exe_up(cur, 4);
    i64 symoff = cur;

    u8 o[BUF_SIZE];
    buf_init(o);
    buf_u16(o, IMAGE_FILE_MACHINE_ARM64);
    buf_u16(o, nsections);
    buf_u32(o, 0);                              // TimeDateStamp: 0, determinism
    buf_u32(o, symoff);
    buf_u32(o, nsymbols);
    buf_u16(o, 0);                              // SizeOfOptionalHeader
    buf_u16(o, 0);                              // Characteristics
    i = 0;
    while (i < nsections) {
        coff_put_shdr(o, i, nameoff, rawoff, reloff);
        i = i + 1;
    }
    i = 0;
    while (i < nsections) {
        if (ivec_at(rawoff, i) != 0) {
            buf_pad(o, 4);
            buf_put(o, buf_p(sec_data(sec_at(i))), buf_len(sec_data(sec_at(i))));
        }
        i = i + 1;
    }
    i = 0;
    while (i < nsections) {
        if (ivec_at(reloff, i) != 0) {
            buf_pad(o, 4);
            coff_put_relocs(o, i, pos);
        }
        i = i + 1;
    }
    buf_pad(o, 4);
    coff_put_symtab(o, order, strx);
    buf_put(o, buf_p(co_str), buf_len(co_str));
    write_file(path, o);
}

// the backend itself: the same lowering and the same two-pass encoder the other
// writers use, over the arm64 machine, and only the writing differs
void backend_coff(i64 root, uptr out) {
    machine_use("arm64");
    gen_lower(root);
    gen_encode_all();
    coff_write(out);
}
