// macho.mc — transliteration of stage0/macho.c: object model (sections,
// symbols, relocations) and writing of an arm64 MH_OBJECT. Same functions, same
// order, same I/O shape. Every field of the file is written byte by byte in
// little-endian by arena.mc's buf_u8/u16/u32/u64; no "writing the struct".
//
// No struct: each C record becomes a flat block in the arena with #define
// offsets + accessors. The layouts below are derived from stage0/mc.h (the C's
// current version; the table in docs/specs/M6-M7.md is out of date). Rule: every
// field occupies 8 bytes, except Section's two inline 16-byte names.
//
//   C: typedef struct { u8 *p; size_t len, cap; } Buf;                 (arena.mc)
//      BUF_P 0  BUF_LEN 8  BUF_CAP 16                       -> BUF_SIZE 24
//
//   C: typedef struct {
//          char seg[16], sect[16];
//          u32  flags, align;          // align in log2
//          Buf  data;                  // inline, not a pointer
//          u64  zsize;                 // size if S_ZEROFILL
//          Reloc *rel; int nrel, relcap;
//      } Section;
//      SEC_SEG 0 (16 B inline)  SEC_SECT 16 (16 B inline)
//      SEC_FLAGS 32  SEC_ALIGN 40
//      SEC_DATA 48 (Buf inline: p at 48, len at 56, cap at 64)
//      SEC_ZSIZE 72  SEC_REL 80  SEC_NREL 88  SEC_RELCAP 96 -> SEC_SIZE 104
//
//   C: typedef struct { const char *name; int sect; u64 value; bool global; } Symbol;
//      SYM_NAME 0  SYM_SECT 8  SYM_VALUE 16  SYM_GLOBAL 24  -> SYM_SIZE 32
//      (sect 0 = undefined)
//
//   C: typedef struct { u32 off; int sym; u8 type, pcrel, len; } Reloc;
//      REL_OFF 0  REL_SYM 8  REL_TYPE 16  REL_PCREL 24  REL_LEN 32 -> REL_SIZE 40
//
// Record arrays = base + index * SIZE. C strings = uptr to NUL-terminated
// bytes in the arena. Depends on arena.mc (xalloc, mem_copy, mem_zero,
// str_eq, cstrlen, buf_*, out_*, die2, write_file).
//
// M9: this is the leaf module migrated to the prelude. Every C `for`/`while`
// became lib/prelude.mc's `for`/`while` — which are #rule over the core's
// `loop {}`, not built-in syntax — and every C `x += e` became `+=`. Where the C
// uses `for` with no initializer (`for (; cond; incr)`) it becomes a `while`:
// the prelude's `for` pattern requires a `stmt $init`, and the core has no empty
// statement. The step is `i = i + 1` and not `i++` for the same reason: the
// pattern's step is `ident $x = expr $step`.

#include "../lib/prelude.mc"

// ---- Section ----
#define SEC_SEG    0
#define SEC_SECT   16
#define SEC_FLAGS  32
#define SEC_ALIGN  40
#define SEC_DATA   48
#define SEC_ZSIZE  72
#define SEC_REL    80
#define SEC_NREL   88
#define SEC_RELCAP 96
#define SEC_SIZE   104

// ---- Symbol ----
#define SYM_NAME   0
#define SYM_SECT   8
#define SYM_VALUE  16
#define SYM_GLOBAL 24
#define SYM_SIZE   32

// ---- Reloc ----
#define REL_OFF   0
#define REL_SYM   8
#define REL_TYPE  16
#define REL_PCREL 24
#define REL_LEN   32
#define REL_SIZE  40

// ---- relocation types (mc.h enum) ----
#define R_UNSIGNED   0
#define R_SUBTRACTOR 1
#define R_BRANCH26   2
#define R_PAGE21     3
#define R_PAGEOFF12  4
#define R_ADDEND     10

// ---- section flags (mc.h) ----
#define S_REGULAR                0
#define S_ZEROFILL               1
#define S_CSTRING_LITERALS       2
#define S_ATTR_PURE_INSTRUCTIONS 0x80000000
#define S_ATTR_SOME_INSTRUCTIONS 0x400
#define TEXT_FLAGS (S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)

uptr sections;
i64  nsections = 0;
i64  seccap = 0;
uptr symbols;
i64  nsymbols = 0;
i64  symcap = 0;

// ---- Section accessors ----
uptr sec_at(i64 i)      { return sections + i * SEC_SIZE; }
uptr sec_seg(uptr s)    { return s + SEC_SEG; }        // 16 bytes inline
uptr sec_sect(uptr s)   { return s + SEC_SECT; }       // 16 bytes inline
uptr sec_data(uptr s)   { return s + SEC_DATA; }       // Buf inline
i64  sec_flags(uptr s)  { return ld64(s + SEC_FLAGS); }
i64  sec_align(uptr s)  { return ld64(s + SEC_ALIGN); }
i64  sec_zsize(uptr s)  { return ld64(s + SEC_ZSIZE); }
uptr sec_rel(uptr s)    { return ld64(s + SEC_REL); }
i64  sec_nrel(uptr s)   { return ld64(s + SEC_NREL); }
i64  sec_relcap(uptr s) { return ld64(s + SEC_RELCAP); }
void set_sec_flags(uptr s, i64 v)  { st64(s + SEC_FLAGS, v); }
void set_sec_align(uptr s, i64 v)  { st64(s + SEC_ALIGN, v); }
void set_sec_zsize(uptr s, i64 v)  { st64(s + SEC_ZSIZE, v); }
void set_sec_rel(uptr s, uptr v)   { st64(s + SEC_REL, v); }
void set_sec_nrel(uptr s, i64 v)   { st64(s + SEC_NREL, v); }
void set_sec_relcap(uptr s, i64 v) { st64(s + SEC_RELCAP, v); }

// ---- Symbol accessors ----
uptr sym_at(i64 i)      { return symbols + i * SYM_SIZE; }
uptr sym_name(uptr s)   { return ld64(s + SYM_NAME); }
i64  sym_sect(uptr s)   { return ld64(s + SYM_SECT); }
i64  sym_value(uptr s)  { return ld64(s + SYM_VALUE); }
i64  sym_global(uptr s) { return ld64(s + SYM_GLOBAL); }
void set_sym_name(uptr s, uptr v)   { st64(s + SYM_NAME, v); }
void set_sym_sect(uptr s, i64 v)    { st64(s + SYM_SECT, v); }
void set_sym_value(uptr s, i64 v)   { st64(s + SYM_VALUE, v); }
void set_sym_global(uptr s, i64 v)  { st64(s + SYM_GLOBAL, v); }

// ---- Reloc accessors ----
uptr rel_at(uptr base, i64 k) { return base + k * REL_SIZE; }
i64  rel_off(uptr r)   { return ld64(r + REL_OFF); }
i64  rel_sym(uptr r)   { return ld64(r + REL_SYM); }
i64  rel_type(uptr r)  { return ld64(r + REL_TYPE); }
i64  rel_pcrel(uptr r) { return ld64(r + REL_PCREL); }
i64  rel_len(uptr r)   { return ld64(r + REL_LEN); }
void set_rel_off(uptr r, i64 v)   { st64(r + REL_OFF, v); }
void set_rel_sym(uptr r, i64 v)   { st64(r + REL_SYM, v); }
void set_rel_type(uptr r, i64 v)  { st64(r + REL_TYPE, v); }
void set_rel_pcrel(uptr r, i64 v) { st64(r + REL_PCREL, v); }
void set_rel_len(uptr r, i64 v)   { st64(r + REL_LEN, v); }

// copies s into dst in 16 bytes, filling the rest with zero (may have no NUL)
void name16(uptr dst, uptr s) {
    i64 i = 0;
    while (i < 16 && ld8(s + i)) {
        st8(dst + i, ld8(s + i));
        i++;
    }
    while (i < 16) {
        st8(dst + i, 0);
        i++;
    }
}

i64 sec_new(uptr seg, uptr sect, i64 flags, i64 align) {
    i64 i = sec_find(seg, sect);
    if (i >= 0) return i;
    sections = grow(T_MSECS, sections, nsections, &seccap, SEC_SIZE);
    uptr s = sec_at(nsections);
    mem_zero(s, SEC_SIZE);
    name16(sec_seg(s), seg);
    name16(sec_sect(s), sect);
    set_sec_flags(s, flags);
    set_sec_align(s, align);
    nsections = nsections + 1;
    return nsections - 1;
}

i64 sec_find(uptr seg, uptr sect) {
    u8 a[16];
    u8 b[16];
    name16(a, seg);
    name16(b, sect);
    for (i64 i = 0; i < nsections; i = i + 1) {
        uptr s = sec_at(i);
        i64 eq = 1;
        for (i64 k = 0; k < 16; k = k + 1) {
            if (ld8(sec_seg(s) + k) != ld8(a + k))   { eq = 0; break; }
            if (ld8(sec_sect(s) + k) != ld8(b + k))  { eq = 0; break; }
        }
        if (eq) return i;
    }
    return 0 - 1;
}

i64 sym_find(uptr name) {
    for (i64 i = 0; i < nsymbols; i = i + 1) {
        if (str_eq(sym_name(sym_at(i)), name)) return i;
    }
    return 0 - 1;
}

i64 sym_new(uptr name, i64 sect, i64 value, i64 global) {
    i64 i = sym_find(name);
    if (i >= 0) {
        uptr old = sym_at(i);
        if (sym_sect(old) != 0 && sect != 0) die2("duplicate symbol", name);
        if (sect != 0) {
            set_sym_sect(old, sect);
            set_sym_value(old, value);
            set_sym_global(old, global);
        }
        return i;
    }
    symbols = grow(T_SYMBOLS, symbols, nsymbols, &symcap, SYM_SIZE);
    uptr e = sym_at(nsymbols);
    set_sym_name(e, name);
    set_sym_sect(e, sect);
    set_sym_value(e, value);
    set_sym_global(e, global);
    nsymbols = nsymbols + 1;
    return nsymbols - 1;
}

// finds or creates undefined
i64 sym_ref(uptr name) {
    i64 i = sym_find(name);
    if (i >= 0) return i;
    return sym_new(name, 0, 0, 1);
}

// a function's address only exists after encoding: gen_lower creates the
// symbol (fixing the symtab order) and gen_encode_all fills in the value
void sym_set_value(i64 sym, i64 value) { set_sym_value(sym_at(sym), value); }

void reloc_add(i64 sec, i64 off, i64 sym, i64 type, i64 pcrel, i64 len) {
    uptr s = sec_at(sec);
    if (sec_nrel(s) == sec_relcap(s)) {
        i64 cap = sec_relcap(s);
        if (cap == 0) cap = 16;
        else          cap = cap * 2;
        set_sec_relcap(s, cap);
        uptr n = xalloc(REL_SIZE * cap);
        for (i64 k = 0; k < sec_nrel(s); k = k + 1) {
            mem_copy(rel_at(n, k), rel_at(sec_rel(s), k), REL_SIZE);
        }
        set_sec_rel(s, n);
    }
    uptr r = rel_at(sec_rel(s), sec_nrel(s));
    set_rel_off(r, off);
    set_rel_sym(r, sym);
    set_rel_type(r, type);
    set_rel_pcrel(r, pcrel);
    set_rel_len(r, len);
    set_sec_nrel(s, sec_nrel(s) + 1);
}

// ---- writing ----
#define MH_MAGIC_64                0xfeedfacf
#define CPU_TYPE_ARM64             0x0100000C
#define MH_OBJECT                  1
#define MH_SUBSECTIONS_VIA_SYMBOLS 0x2000
#define LC_SEGMENT_64              0x19
#define LC_SYMTAB                  0x2
#define LC_DYSYMTAB                0xb
#define LC_BUILD_VERSION           0x32
#define N_EXT                      0x01
#define N_UNDF                     0x00
#define N_SECT                     0x0e

i64 sym_class(uptr s) {
    if (sym_sect(s) == 0) return 2;
    if (sym_global(s)) return 1;
    return 0;
}

// final symtab order: locals, defined externs, undefined (stable partition)
void sym_order(uptr order, uptr pos, uptr count) {
    i64 n = 0;
    st64(count, 0);
    st64(count + 8, 0);
    st64(count + 16, 0);
    for (i64 c = 0; c < 3; c = c + 1) {
        for (i64 i = 0; i < nsymbols; i = i + 1) {
            if (sym_class(sym_at(i)) == c) {
                st64(pos + i * 8, n);
                st64(order + n * 8, i);
                n++;
                st64(count + c * 8, ld64(count + c * 8) + 1);
            }
        }
    }
}

// seg/sect names occupy 16 zero-padded bytes and may have no NUL
void out_name16(uptr p) {
    i64 n = 0;
    while (n < 16 && ld8(p + n)) {
        n++;
    }
    out_bytes(1, p, n);
}

// --dump-syms: sections in creation order and symbols in the final symtab order
void dump_syms() {
    for (i64 i = 0; i < nsections; i = i + 1) {
        uptr s = sec_at(i);
        i64 zf = (sec_flags(s) & 0xff) == S_ZEROFILL;
        out_str(1, "section "); out_name16(sec_seg(s));
        out_str(1, ",");        out_name16(sec_sect(s));
        out_str(1, " flags="); out_hex(1, sec_flags(s));
        out_str(1, " align="); out_num(1, sec_align(s));
        out_str(1, " size=");
        if (zf) out_num(1, sec_zsize(s));
        else    out_num(1, buf_len(sec_data(s)));
        out_str(1, " nreloc="); out_num(1, sec_nrel(s));
        out_str(1, "\n");
    }
    uptr order = xalloc(8 * (nsymbols + 1));
    uptr pos   = xalloc(8 * (nsymbols + 1));
    u8   count[24];
    sym_order(order, pos, count);
    for (i64 k = 0; k < nsymbols; k = k + 1) {
        uptr s = sym_at(ld64(order + k * 8));
        out_str(1, "sym "); out_num(1, k); out_str(1, " ");
        if (sym_sect(s) == 0)   out_str(1, "undef");
        else {
            if (sym_global(s))  out_str(1, "extern");
            else                out_str(1, "local");
        }
        out_str(1, " sect=");  out_num(1, sym_sect(s));
        out_str(1, " value="); out_num(1, sym_value(s));
        out_str(1, " ");       out_str(1, sym_name(s));
        out_str(1, "\n");
    }
}

void macho_write(uptr path) {
    uptr order = xalloc(8 * (nsymbols + 1));
    uptr pos   = xalloc(8 * (nsymbols + 1));
    u8   count[24];
    sym_order(order, pos, count);

    // address layout: regular sections first, zerofill last
    uptr addr = xalloc(8 * (nsections + 1));
    i64 vm = 0;
    i64 filesz = 0;
    for (i64 pass = 0; pass < 2; pass = pass + 1) {
        for (i64 i = 0; i < nsections; i = i + 1) {
            uptr s = sec_at(i);
            i64 zf = (sec_flags(s) & 0xff) == S_ZEROFILL;
            i64 want = 0;
            if (pass == 1) want = 1;
            if (zf == want) {
                i64 al = 1 << sec_align(s);
                vm = (vm + al - 1) & ~(al - 1);
                st64(addr + i * 8, vm);
                if (zf) vm += sec_zsize(s);
                else    vm += buf_len(sec_data(s));
                if (!zf) filesz = vm;
            }
        }
    }

    i64 ncmds = 4;
    i64 sizeofcmds = 72 + 80 * nsections + 24 + 24 + 80;
    i64 dataoff = 32 + sizeofcmds;
    i64 reloff = dataoff + filesz;
    reloff = (reloff + 7) & ~7;
    i64 nreloc_total = 0;
    i64 i = 0;
    for (i = 0; i < nsections; i = i + 1) {
        nreloc_total += sec_nrel(sec_at(i));
    }
    i64 symoff = reloff + 8 * nreloc_total;
    i64 stroff = symoff + 16 * nsymbols;

    // string table, in symbol creation order
    u8 str[BUF_SIZE];
    buf_init(str);
    buf_u8(str, 0);
    uptr strx = xalloc(8 * (nsymbols + 1));
    i64 k = 0;
    for (k = 0; k < nsymbols; k = k + 1) {
        st64(strx + k * 8, buf_len(str));
        buf_put(str, sym_name(sym_at(k)), cstrlen(sym_name(sym_at(k))) + 1);
    }
    buf_pad(str, 8);

    u8 o[BUF_SIZE];
    buf_init(o);
    buf_u32(o, MH_MAGIC_64); buf_u32(o, CPU_TYPE_ARM64); buf_u32(o, 0);
    buf_u32(o, MH_OBJECT); buf_u32(o, ncmds); buf_u32(o, sizeofcmds);
    buf_u32(o, MH_SUBSECTIONS_VIA_SYMBOLS); buf_u32(o, 0);

    buf_u32(o, LC_SEGMENT_64); buf_u32(o, 72 + 80 * nsections);
    for (i = 0; i < 16; i = i + 1) {            // empty segname: 16 zeroed bytes
        buf_u8(o, 0);
    }
    buf_u64(o, 0); buf_u64(o, vm); buf_u64(o, dataoff); buf_u64(o, filesz);
    buf_u32(o, 7); buf_u32(o, 7); buf_u32(o, nsections); buf_u32(o, 0);
    i64 roff = reloff;
    for (i = 0; i < nsections; i = i + 1) {
        uptr s = sec_at(i);
        i64 zf = (sec_flags(s) & 0xff) == S_ZEROFILL;
        buf_put(o, sec_sect(s), 16);
        buf_put(o, sec_seg(s), 16);
        buf_u64(o, ld64(addr + i * 8));
        if (zf) buf_u64(o, sec_zsize(s));
        else    buf_u64(o, buf_len(sec_data(s)));
        if (zf) buf_u32(o, 0);
        else    buf_u32(o, dataoff + ld64(addr + i * 8));
        buf_u32(o, sec_align(s));
        if (sec_nrel(s) != 0) buf_u32(o, roff);
        else                  buf_u32(o, 0);
        buf_u32(o, sec_nrel(s)); buf_u32(o, sec_flags(s));
        buf_u32(o, 0); buf_u32(o, 0); buf_u32(o, 0);
        roff += 8 * sec_nrel(s);
    }
    buf_u32(o, LC_BUILD_VERSION); buf_u32(o, 24);
    buf_u32(o, 1); buf_u32(o, 0x000D0000); buf_u32(o, 0x000D0000); buf_u32(o, 0);
    buf_u32(o, LC_SYMTAB); buf_u32(o, 24);
    buf_u32(o, symoff); buf_u32(o, nsymbols); buf_u32(o, stroff); buf_u32(o, buf_len(str));
    buf_u32(o, LC_DYSYMTAB); buf_u32(o, 80);
    buf_u32(o, 0); buf_u32(o, ld64(count));
    buf_u32(o, ld64(count)); buf_u32(o, ld64(count + 8));
    buf_u32(o, ld64(count) + ld64(count + 8)); buf_u32(o, ld64(count + 16));
    for (k = 0; k < 12; k = k + 1) {
        buf_u32(o, 0);
    }

    // section data
    for (i = 0; i < nsections; i = i + 1) {
        uptr s = sec_at(i);
        if ((sec_flags(s) & 0xff) != S_ZEROFILL) {
            while (buf_len(o) < dataoff + ld64(addr + i * 8)) {
                buf_u8(o, 0);
            }
            buf_put(o, buf_p(sec_data(s)), buf_len(sec_data(s)));
        }
    }
    while (buf_len(o) < reloff) {
        buf_u8(o, 0);
    }

    // relocations: descending address order, as clang does
    for (i = 0; i < nsections; i = i + 1) {
        uptr s = sec_at(i);
        for (i64 j = sec_nrel(s) - 1; j >= 0; j = j - 1) {
            uptr r = rel_at(sec_rel(s), j);
            i64 symnum = rel_sym(r);
            i64 ext = 0;
            if (rel_type(r) != R_ADDEND) {
                symnum = ld64(pos + rel_sym(r) * 8);
                ext = 1;
            }
            buf_u32(o, rel_off(r));
            buf_u32(o, (symnum & 0xffffff) | (rel_pcrel(r) << 24) | (rel_len(r) << 25)
                       | (ext << 27) | (rel_type(r) << 28));
        }
    }

    // symtab
    for (k = 0; k < nsymbols; k = k + 1) {
        i64 oi = ld64(order + k * 8);
        uptr s = sym_at(oi);
        buf_u32(o, ld64(strx + oi * 8));
        if (sym_sect(s) == 0) buf_u8(o, N_UNDF | N_EXT);
        else {
            if (sym_global(s)) buf_u8(o, N_SECT | N_EXT);
            else               buf_u8(o, N_SECT);
        }
        buf_u8(o, sym_sect(s));
        buf_u16(o, 0);
        if (sym_sect(s) == 0) buf_u64(o, 0);
        else buf_u64(o, ld64(addr + (sym_sect(s) - 1) * 8) + sym_value(s));
    }
    buf_put(o, buf_p(str), buf_len(str));
    write_file(path, o);
}
