// macho.mc — the Mach-O writer: an arm64 MH_OBJECT, and the `macho` backend
// that drives it. M41 moved the object model (sections, symbols, relocations,
// sym_order, dump_syms) out to src/objmodel.mc and left this file with the
// format alone, so that a compiler that targets neither macOS nor Mach-O can
// leave it out (docs/reference/bundle.md § The parts).
//
// Transliteration of the writer half of stage0/macho.c: same fields, same
// order, same I/O shape. Every field of the file is written byte by byte in
// little-endian by arena.mc's buf_u8/u16/u32/u64; no "writing the struct".
//
// Depends on objmodel.mc (the model and sym_order), on arena.mc (xalloc, buf_*,
// write_file) and, for backend_macho, on gen_walk.mc (gen_lower,
// gen_encode_all) and hooks.mc (machine_use).

#include "../lib/prelude.mc"

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
