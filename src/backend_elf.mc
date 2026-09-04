// backend_elf.mc — backends `elf-obj` and `elf-obj-x86_64`: an ELF64 `ET_REL`,
// the relocatable object a Linux linker (`ld.lld`) takes (M16,
// docs/specs/M16.md; the x86-64 half is M17 step B, docs/specs/M17.md).
//
// Everything before this file is format-neutral: `gen_lower` lowers the AST into
// sections, symbols and relocations, `gen_encode_all` encodes the words. This
// backend only says the same three things in ELF's spelling:
//
//   sections     one ELF section per module section, in creation order, so the
//                file comes out null, .text, .rodata, .data, .bss and then the
//                `#section` ones. Zerofill becomes SHT_NOBITS.
//   symbols      the compiler's leading `_` is dropped (`_main` -> `main`) and
//                the string labels become assembler temporaries
//                (`l_str0` -> `.Lstr0`). ELF requires every local before every
//                global, which is exactly macho.mc's stable partition
//                (`sym_order`), so the order is the same one the Mach-O symtab
//                already has.
//   relocations  Elf64_Rela with an explicit addend (always 0 — the encoder
//                leaves the immediate field zeroed and Mach-O reads the addend
//                out of the instruction the same way), sorted by ascending
//                offset, which is the ELF convention.
//
// M17 step B: the SAME writer serves both architectures. Only three things are
// architecture-dependent — `e_machine`, the relocation numbers and the addend —
// and each backend entry point picks its machine (`machine_use`) and sets
// `elf_em` before lowering a single node. Everything else (the section table,
// the symbol partition, the layout) is shared, which is the whole point of
// having a machine interface: a second instruction set is not a second writer.
//
// The object is NOT an executable: `os = "linux"` in mc.toml always goes through
// `[linker]` (src/driver.mc). The direct-executable backend is macOS only
// (`macho-exe`, M11).
//
// Depends on arena.mc (buf_*, xalloc, die, write_file), on macho.mc (sections,
// symbols, relocations, sym_order and the R_* / S_* constants), on gen_walk.mc
// (gen_lower/gen_encode_all, ivec_at/set_ivec_at), on machine_x86_64.mc
// (R_X86_PC32/R_X86_PLT32) and on toml.mc (tm_cat). It
// borrows two pure helpers from backend_exe.mc — `exe_up` (round up) and
// `exe_segname` (16 fixed bytes as a string); neither has anything Mach-O in it.

#include "../lib/prelude.mc"

// ---- ELF header ----
#define ELFCLASS64  2
#define ELFDATA2LSB 1
#define EV_CURRENT  1
#define ET_REL      1
#define EM_AARCH64  183
#define EM_X86_64   62
#define EHDR_SIZE   64
#define SHDR_SIZE   64

// ---- section headers ----
#define SHT_NULL     0
#define SHT_PROGBITS 1
#define SHT_SYMTAB   2
#define SHT_STRTAB   3
#define SHT_RELA     4
#define SHT_NOBITS   8

#define SHF_WRITE     1
#define SHF_ALLOC     2
#define SHF_EXECINSTR 4
#define SHF_INFO_LINK 0x40

// ---- symbols ----
#define ELFSYM_SIZE 24
#define SHN_UNDEF   0
#define STB_LOCAL   0
#define STB_GLOBAL  1
#define STT_NOTYPE  0
#define STT_OBJECT  1
#define STT_FUNC    2

// ---- relocations (AArch64 psABI) ----
#define ELFRELA_SIZE                24
#define R_AARCH64_ABS64             257
#define R_AARCH64_ADR_PREL_PG_HI21  275
#define R_AARCH64_ADD_ABS_LO12_NC   277
#define R_AARCH64_LDST8_ABS_LO12_NC 278
#define R_AARCH64_CALL26            283
#define R_AARCH64_LDST16_ABS_LO12_NC 284
#define R_AARCH64_LDST32_ABS_LO12_NC 285
#define R_AARCH64_LDST64_ABS_LO12_NC 286

// ---- relocations (x86-64 psABI) ----
#define R_X86_64_64    1
#define R_X86_64_PC32  2
#define R_X86_64_PLT32 4

#define EK_NULL     0
#define EK_CONTENT  1
#define EK_RELA     2
#define EK_TABLE    3                  // symtab / strtab / shstrtab

// ---- the ELF section table, in the order the headers come out ----
// M23: no ceiling. The count is known exactly before the first append -- the
// null one, one per module section, at most one .rela per module section, and
// the three tables -- so elf_plan allocates 2 * nsections + 4 slots and the
// table never grows.
uptr es_kind;
uptr es_src;                           // module section; -1 when there is none
uptr es_name;
uptr es_nameoff;                       // offset into .shstrtab
uptr es_type;
uptr es_flags;
uptr es_off;
uptr es_size;
uptr es_link;
uptr es_info;
uptr es_align;
uptr es_ent;
i64  nesec = 0;

uptr es_name_at(i64 i)             { return ld64(es_name + i * 8); }
void set_es_name_at(i64 i, uptr v) { st64(es_name + i * 8, v); }

// ---- the three ELF string/symbol tables ----
u8 el_str[BUF_SIZE];                   // .strtab: symbol names
u8 el_shstr[BUF_SIZE];                 // .shstrtab: section names
u8 el_sym[BUF_SIZE];                   // .symtab
i64 el_isymtab = 0;                    // index of .symtab, cited by every .rela
i64 el_istrtab = 0;
i64 el_ishstr  = 0;
i64 elf_em = EM_AARCH64;               // which architecture this object is for

// ---- names ----
// A Mach-O 16-byte name lowercased with its leading underscores dropped:
// `__TEXT` -> `text`, `__hot` -> `hot`. Only the LEADING underscores go, so
// `__my_sect` stays `my_sect` — an ELF section name with an underscore in the
// middle is ordinary.
void elf_put_lower(uptr b, uptr s) {
    i64 i = 0;
    while (ld8(s + i) == '_') { i = i + 1; }
    while (ld8(s + i)) {
        i64 c = ld8(s + i);
        if (c >= 'A' && c <= 'Z') c = c + 32;
        buf_u8(b, c);
        i = i + 1;
    }
}

// `#section SEG SECT` -> `.seg.sect` (`__TEXT,__hot` -> `.text.hot`). The four
// sections the core itself creates do not go through here: they have the names
// Linux expects (.text/.rodata/.data/.bss), decided in elf_sec_name.
uptr elf_custom_name(i64 i) {
    u8 b[BUF_SIZE];
    buf_init(b);
    buf_u8(b, '.');
    elf_put_lower(b, exe_segname(sec_seg(sec_at(i))));
    buf_u8(b, '.');
    elf_put_lower(b, exe_segname(sec_sect(sec_at(i))));
    buf_u8(b, 0);
    return buf_p(b);
}

uptr elf_sec_name(i64 i) {
    if (i == isec_text) return ".text";
    if (i == isec_cstr) return ".rodata";
    if (i == isec_data) return ".data";
    if (i == isec_bss)  return ".bss";
    return elf_custom_name(i);
}

// Mach-O name -> ELF name: the `_` the compiler prefixes goes away and the
// string labels become the assembler's temporaries.
uptr elf_sym_name(uptr n) {
    if (ld8(n) == 'l' && ld8(n + 1) == '_') return tm_cat(".L", n + 2);
    if (ld8(n) == '_')                      return n + 1;
    return n;
}

// ---- section attributes ----
i64 elf_sec_zf(i64 i)   { return (sec_flags(sec_at(i)) & 0xff) == S_ZEROFILL; }
i64 elf_sec_exec(i64 i) { return (sec_flags(sec_at(i)) & S_ATTR_PURE_INSTRUCTIONS) != 0; }

i64 elf_sec_type(i64 i) {
    if (elf_sec_zf(i)) return SHT_NOBITS;
    return SHT_PROGBITS;
}

// AX for instructions, A for the read-only literals, WA for everything else —
// the same three shapes clang emits for .text/.rodata/.data|.bss.
i64 elf_sec_flags(i64 i) {
    if (elf_sec_exec(i)) return SHF_ALLOC | SHF_EXECINSTR;
    if (i == isec_cstr)  return SHF_ALLOC;
    return SHF_ALLOC | SHF_WRITE;
}

i64 elf_sec_size(i64 i) {
    if (elf_sec_zf(i)) return sec_zsize(sec_at(i));
    return buf_len(sec_data(sec_at(i)));
}

// ---- the section table ----
void elf_add_sec(i64 kind, i64 src, uptr name, i64 type, i64 flags, i64 size,
                 i64 align, i64 ent) {
    set_ivec_at(es_kind, nesec, kind);
    set_ivec_at(es_src, nesec, src);
    set_es_name_at(nesec, name);
    set_ivec_at(es_type, nesec, type);
    set_ivec_at(es_flags, nesec, flags);
    set_ivec_at(es_size, nesec, size);
    set_ivec_at(es_align, nesec, align);
    set_ivec_at(es_ent, nesec, ent);
    set_ivec_at(es_link, nesec, 0);
    set_ivec_at(es_info, nesec, 0);
    set_ivec_at(es_off, nesec, 0);
    nesec = nesec + 1;
}

// null, the content sections in creation order (so section header index i + 1
// is exactly the module's 1-based sym_sect), then one .rela per section that
// has relocations, then the three tables.
void elf_plan() {
    nesec = 0;
    i64 cap = nsections * 2 + 4;       // exact upper bound, see the table above
    es_kind = xalloc(8 * cap);
    es_src = xalloc(8 * cap);
    es_name = xalloc(8 * cap);
    es_nameoff = xalloc(8 * cap);
    es_type = xalloc(8 * cap);
    es_flags = xalloc(8 * cap);
    es_off = xalloc(8 * cap);
    es_size = xalloc(8 * cap);
    es_link = xalloc(8 * cap);
    es_info = xalloc(8 * cap);
    es_align = xalloc(8 * cap);
    es_ent = xalloc(8 * cap);
    elf_add_sec(EK_NULL, 0 - 1, "", SHT_NULL, 0, 0, 0, 0);
    i64 i = 0;
    while (i < nsections) {
        elf_add_sec(EK_CONTENT, i, elf_sec_name(i), elf_sec_type(i), elf_sec_flags(i),
                    elf_sec_size(i), 1 << sec_align(sec_at(i)), 0);
        i = i + 1;
    }
    i = 0;
    while (i < nsections) {
        if (sec_nrel(sec_at(i)) > 0) {
            elf_add_sec(EK_RELA, i, tm_cat(".rela", elf_sec_name(i)), SHT_RELA,
                        SHF_INFO_LINK, ELFRELA_SIZE * sec_nrel(sec_at(i)), 8, ELFRELA_SIZE);
            set_ivec_at(es_info, nesec - 1, i + 1);
        }
        i = i + 1;
    }
    el_isymtab = nesec;                          // the three tables are already
    elf_add_sec(EK_TABLE, 0 - 1, ".symtab", SHT_SYMTAB, 0, buf_len(el_sym), 8, ELFSYM_SIZE);
    el_istrtab = nesec;                          // built, so their sizes are known
    elf_add_sec(EK_TABLE, 0 - 1, ".strtab", SHT_STRTAB, 0, buf_len(el_str), 1, 0);
    el_ishstr = nesec;                           // except .shstrtab, which names them
    elf_add_sec(EK_TABLE, 0 - 1, ".shstrtab", SHT_STRTAB, 0, 0, 1, 0);
    i = 0;
    while (i < nesec) {                          // .rela.X cites .symtab and X
        if (ivec_at(es_kind, i) == EK_RELA) set_ivec_at(es_link, i, el_isymtab);
        i = i + 1;
    }
    set_ivec_at(es_link, el_isymtab, el_istrtab);
}

// ---- .shstrtab ----
void elf_build_shstr() {
    buf_init(el_shstr);
    buf_u8(el_shstr, 0);
    i64 i = 0;
    while (i < nesec) {
        uptr n = es_name_at(i);
        if (cstrlen(n) == 0) set_ivec_at(es_nameoff, i, 0);
        else {
            set_ivec_at(es_nameoff, i, buf_len(el_shstr));
            buf_put(el_shstr, n, cstrlen(n) + 1);
        }
        i = i + 1;
    }
    set_ivec_at(es_size, el_ishstr, buf_len(el_shstr));
}

// ---- .strtab and .symtab ----
i64 elf_sym_bind(uptr s) {
    if (sym_sect(s) == 0) return STB_GLOBAL;
    if (sym_global(s))    return STB_GLOBAL;
    return STB_LOCAL;
}

// a symbol in a pure-instructions section is a function; anything else defined
// is data; undefined has no type
i64 elf_sym_type(uptr s) {
    if (sym_sect(s) == 0) return STT_NOTYPE;
    if (elf_sec_exec(sym_sect(s) - 1)) return STT_FUNC;
    return STT_OBJECT;
}

// index 0 is ELF's null symbol, so a module symbol at position k in sym_order
// is ELF symbol k + 1
void elf_build_symtab(uptr order, uptr strx) {
    buf_init(el_sym);
    i64 k = 0;
    while (k < ELFSYM_SIZE) {                    // the null symbol: 24 zeros
        buf_u8(el_sym, 0);
        k = k + 1;
    }
    k = 0;
    while (k < nsymbols) {
        i64 oi = ivec_at(order, k);
        uptr s = sym_at(oi);
        buf_u32(el_sym, ivec_at(strx, oi));
        buf_u8(el_sym, (elf_sym_bind(s) << 4) | elf_sym_type(s));
        buf_u8(el_sym, 0);                       // st_other
        buf_u16(el_sym, sym_sect(s));            // 0 = SHN_UNDEF; else section i + 1
        buf_u64(el_sym, sym_value(s));
        buf_u64(el_sym, 0);                      // st_size: the core does not track it
        k = k + 1;
    }
}

void elf_build_strtab(uptr strx) {
    buf_init(el_str);
    buf_u8(el_str, 0);
    i64 k = 0;
    while (k < nsymbols) {
        uptr n = elf_sym_name(sym_name(sym_at(k)));
        set_ivec_at(strx, k, buf_len(el_str));
        buf_put(el_str, n, cstrlen(n) + 1);
        k = k + 1;
    }
}

// ---- relocations ----
// indices of section `s`'s relocations in ascending offset order. Insertion
// sort: the encoder already produces them in order, so this is one pass in
// practice, and it is stable, which keeps two relocations at the same offset in
// the order they were registered.
uptr elf_rel_order(uptr s) {
    i64 n = sec_nrel(s);
    uptr ord = xalloc(8 * (n + 1));
    i64 i = 0;
    while (i < n) {
        i64 off = rel_off(rel_at(sec_rel(s), i));
        i64 j = i;
        while (j > 0 && rel_off(rel_at(sec_rel(s), ivec_at(ord, j - 1))) > off) {
            set_ivec_at(ord, j, ivec_at(ord, j - 1));
            j = j - 1;
        }
        set_ivec_at(ord, j, i);
        i = i + 1;
    }
    return ord;
}

// PAGEOFF12 is one Mach-O relocation and four ELF ones: the 12-bit immediate of
// an `add` is the offset itself, that of an ldr/str with an unsigned offset is
// scaled by the access width (bits 31:30). Same classification as
// exe_fix_pageoff12 in backend_exe.mc, which does the scaling by hand.
i64 elf_pageoff12(i64 w) {
    if ((w & 0x3b000000) != 0x39000000) return R_AARCH64_ADD_ABS_LO12_NC;
    i64 sc = (w >> 30) & 3;
    if (sc == 0) return R_AARCH64_LDST8_ABS_LO12_NC;
    if (sc == 1) return R_AARCH64_LDST16_ABS_LO12_NC;
    if (sc == 2) return R_AARCH64_LDST32_ABS_LO12_NC;
    return R_AARCH64_LDST64_ABS_LO12_NC;
}

// x86-64 has one relocation per shape and no instruction to inspect: the four
// bytes are always the tail of the instruction, so the addend is -4 for both
// pc-relative kinds and 0 for the 64-bit absolute one in data.
i64 elf_rel_type_x86(uptr r) {
    i64 t = rel_type(r);
    if (t == R_X86_PC32)  return R_X86_64_PC32;
    if (t == R_X86_PLT32) return R_X86_64_PLT32;
    if (t == R_UNSIGNED) {
        if (rel_len(r) != 3) die("UNSIGNED that does not occupy 8 bytes");
        return R_X86_64_64;
    }
    die("relocation not supported in the x86-64 ELF object");
    return 0;
}

i64 elf_rel_addend(uptr r) {
    i64 t = rel_type(r);
    if (t == R_X86_PC32 || t == R_X86_PLT32) return 0 - 4;
    return 0;
}

i64 elf_rel_type(uptr sec, uptr r) {
    i64 t = rel_type(r);
    if (elf_em == EM_X86_64) return elf_rel_type_x86(r);
    if (t == R_BRANCH26) return R_AARCH64_CALL26;
    if (t == R_PAGE21)   return R_AARCH64_ADR_PREL_PG_HI21;
    if (t == R_UNSIGNED) {
        if (rel_len(r) != 3) die("UNSIGNED that does not occupy 8 bytes");
        return R_AARCH64_ABS64;
    }
    if (t != R_PAGEOFF12) die("relocation not supported in the ELF object");
    return elf_pageoff12(ld32(buf_p(sec_data(sec)) + rel_off(r)));
}

// r_offset, r_info = (symbol << 32) | type, r_addend. On aarch64 the addend is
// always 0: the encoder leaves the immediate field of the relocated instruction
// zeroed and writes 8 zero bytes for an UNSIGNED, so there is nothing implicit
// to carry. On x86-64 a rel32 counts from the END of the field, which is four
// bytes past r_offset, so its addend is -4.
void elf_put_relas(uptr o, i64 i, uptr pos) {
    uptr s = sec_at(i);
    uptr ord = elf_rel_order(s);
    i64 j = 0;
    while (j < sec_nrel(s)) {
        uptr r = rel_at(sec_rel(s), ivec_at(ord, j));
        buf_u64(o, rel_off(r));
        buf_u32(o, elf_rel_type(s, r));
        buf_u32(o, ivec_at(pos, rel_sym(r)) + 1);
        buf_u64(o, elf_rel_addend(r));
        j = j + 1;
    }
}

// ---- layout ----
// The header first, then every section's content in table order (NOBITS takes
// no file space but still records where it would start), then the section
// headers, on 8.
i64 elf_layout() {
    i64 cur = EHDR_SIZE;
    i64 i = 1;
    while (i < nesec) {
        i64 al = ivec_at(es_align, i);
        if (al > 1) cur = exe_up(cur, al);
        set_ivec_at(es_off, i, cur);
        if (ivec_at(es_type, i) != SHT_NOBITS) cur = cur + ivec_at(es_size, i);
        i = i + 1;
    }
    return exe_up(cur, 8);
}

void elf_put_shdr(uptr o, i64 i) {
    buf_u32(o, ivec_at(es_nameoff, i));
    buf_u32(o, ivec_at(es_type, i));
    buf_u64(o, ivec_at(es_flags, i));
    buf_u64(o, 0);                               // sh_addr: a relocatable has none
    buf_u64(o, ivec_at(es_off, i));
    buf_u64(o, ivec_at(es_size, i));
    buf_u32(o, ivec_at(es_link, i));
    buf_u32(o, ivec_at(es_info, i));
    buf_u64(o, ivec_at(es_align, i));
    buf_u64(o, ivec_at(es_ent, i));
}

void elf_put_ehdr(uptr o, i64 shoff) {
    buf_u8(o, 0x7f); buf_u8(o, 'E'); buf_u8(o, 'L'); buf_u8(o, 'F');
    buf_u8(o, ELFCLASS64);
    buf_u8(o, ELFDATA2LSB);
    buf_u8(o, EV_CURRENT);
    buf_u8(o, 0);                                // EI_OSABI: System V
    buf_u8(o, 0);                                // EI_ABIVERSION
    i64 i = 0;
    while (i < 7) {                              // EI_PAD
        buf_u8(o, 0);
        i = i + 1;
    }
    buf_u16(o, ET_REL);
    buf_u16(o, elf_em);
    buf_u32(o, EV_CURRENT);
    buf_u64(o, 0);                               // e_entry
    buf_u64(o, 0);                               // e_phoff
    buf_u64(o, shoff);
    buf_u32(o, 0);                               // e_flags
    buf_u16(o, EHDR_SIZE);
    buf_u16(o, 0);                               // e_phentsize
    buf_u16(o, 0);                               // e_phnum
    buf_u16(o, SHDR_SIZE);
    buf_u16(o, nesec);
    buf_u16(o, el_ishstr);                       // e_shstrndx
}

// ---- writing ----
void elf_write(uptr path) {
    uptr order = xalloc(8 * (nsymbols + 1));
    uptr pos   = xalloc(8 * (nsymbols + 1));
    uptr strx  = xalloc(8 * (nsymbols + 1));
    u8   count[24];
    sym_order(order, pos, count);                // local / defined global / undefined
    elf_build_strtab(strx);
    elf_build_symtab(order, strx);

    elf_plan();
    elf_build_shstr();
    set_ivec_at(es_info, el_isymtab, ivec_at(count, 0) + 1);   // first global: null + locals
    i64 shoff = elf_layout();

    u8 o[BUF_SIZE];
    buf_init(o);
    elf_put_ehdr(o, shoff);
    i64 i = 1;
    while (i < nesec) {
        if (ivec_at(es_type, i) != SHT_NOBITS) {
            while (buf_len(o) < ivec_at(es_off, i)) {          // alignment, zeroed
                buf_u8(o, 0);
            }
            i64 k = ivec_at(es_kind, i);
            i64 src = ivec_at(es_src, i);
            if (k == EK_CONTENT)   buf_put(o, buf_p(sec_data(sec_at(src))), buf_len(sec_data(sec_at(src))));
            else if (k == EK_RELA) elf_put_relas(o, src, pos);
            else if (i == el_isymtab) buf_put(o, buf_p(el_sym), buf_len(el_sym));
            else if (i == el_istrtab) buf_put(o, buf_p(el_str), buf_len(el_str));
            else                      buf_put(o, buf_p(el_shstr), buf_len(el_shstr));   // .shstrtab
        }
        i = i + 1;
    }
    while (buf_len(o) < shoff) {
        buf_u8(o, 0);
    }
    i = 0;
    while (i < nesec) {
        elf_put_shdr(o, i);
        i = i + 1;
    }
    write_file(path, o);
}

// the backends themselves: the same lowering and the same two-pass encoder as
// `macho`, driven by the machine each one names, and only the writing differs
void backend_elf(i64 root, uptr out) {
    machine_use("arm64");
    elf_em = EM_AARCH64;
    gen_lower(root);
    gen_encode_all();
    elf_write(out);
}

void backend_elf_x86(i64 root, uptr out) {
    machine_use("x86_64");
    elf_em = EM_X86_64;
    gen_lower(root);
    gen_encode_all();
    elf_write(out);
}
