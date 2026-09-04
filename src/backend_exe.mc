// backend_exe.mc — backend `macho-exe`: writes an arm64 MH_EXECUTE directly, without
// `ld`. `--exe` in the driver is an alias for `--backend=macho-exe`.
//
// The common path up to here is the same as the `macho` backend: gen_lower lowers the
// AST and gen_encode_all encodes the words and registers the relocations in the
// sections. The difference starts after that: instead of writing an MH_OBJECT with
// the relocation table for `ld` to resolve, this backend
//
//   1. picks the final addresses (one LC_SEGMENT_64 per distinct segment name, each
//      aligned to 16 KiB, which is the arm64 vm_page_size);
//   2. resolves every relocation itself (BRANCH26, PAGE21, PAGEOFF12, UNSIGNED);
//   3. for each undefined symbol creates a stub in __TEXT,__stubs and a slot in
//      __DATA,__got, and has dyld fill the slot in via bind opcodes;
//   4. UNSIGNED in a writable section becomes an absolute pointer + a rebase entry (the
//      binary is PIE: without rebase, ASLR would break the pointer);
//   5. signs ad-hoc (CS_SuperBlob + CS_CodeDirectory v0x20400, SHA-256 per
//      4 KiB page) — without a signature the kernel kills the process.
//
// The address layout follows the same rule as `ld` (checked against `otool -l`
// on a reference executable, see docs/macho-notes.md): __PAGEZERO occupies the
// first 4 GiB, __TEXT starts at 0x100000000 with the header and the load commands
// inside it, and each following segment starts at the next 16 KiB page both
// in VM and in the file (VM and file advance separately because zerofill occupies VM
// but not the file).
//
// Depends on arena.mc (buf_*, xalloc, die, io_write), on macho.mc (sections,
// symbols, relocations, sym_order), on gen_arm64.mc (gen_lower/gen_encode_all and
// ivec_at/set_ivec_at) and on sha256.mc.

#include "../lib/prelude.mc"

// changes the mode of a file that already exists: `creat` only applies the mode
// when it creates it, so rewriting an existing -o would keep the old permission
extern i64 chmod(uptr path, i64 mode);

#define MODE_755 493                       // 0755 in decimal: there is no octal literal

// ---- Mach-O constants that MH_OBJECT does not use ----
#define MH_EXECUTE   2
#define MH_NOUNDEFS  0x1
#define MH_DYLDLINK  0x4
#define MH_TWOLEVEL  0x80
#define MH_PIE       0x200000
#define EXE_FLAGS (MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE)

#define LC_REQ_DYLD       0x80000000
#define LC_DYLD_INFO_ONLY 0x80000022
#define LC_LOAD_DYLINKER  0xe
#define LC_UUID           0x1b
#define LC_MAIN           0x80000028
#define LC_LOAD_DYLIB     0xc
#define LC_CODE_SIGNATURE 0x1d

#define S_NON_LAZY_SYMBOL_POINTERS 6
#define S_SYMBOL_STUBS             8
#define STUB_FLAGS (S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)

#define EXE_BASE  0x100000000              // top of __PAGEZERO
#define EXE_PAGE  16384                    // arm64 vm_page_size
#define CS_PAGE   4096                     // signature hash page
#define STUB_SIZE 12                        // adrp + ldr + br

#define N_DESC_ORD1 0x100                  // ordinal 1 (libSystem) in n_desc
#define DYLIB_HDR   24                     // LC_LOAD_DYLIB bytes before the name

// rebase/bind opcodes (mach-o/loader.h)
#define REBASE_SET_TYPE_IMM      0x10
#define REBASE_SET_SEG_ULEB      0x20
#define REBASE_DO_IMM_TIMES      0x50
#define BIND_SET_DYLIB_ORD_IMM   0x10
#define BIND_SET_SYMBOL_FLAGS    0x40
#define BIND_SET_TYPE_IMM        0x50
#define BIND_SET_SEG_ULEB        0x70
#define BIND_DO_BIND             0x90
#define TYPE_POINTER             1

// ---- ad-hoc signature ----
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_CODEDIRECTORY      0xfade0c02
#define CS_ADHOC                   0x2
#define CS_EXECSEG_MAIN_BINARY     0x1
#define CD_VERSION                 0x20400
#define CD_HEADER                  88       // bytes before the identifier
#define CD_HASHTYPE_SHA256         2
#define CD_HASHSIZE                32

// M23: the section, segment and import tables are arena blocks that double on
// demand (arena.mc grow()); sec2x is sized exactly by the module's sections.

// ---- table of executable sections (final order = order in the file) ----
uptr xs_src;                               // index in sections[]; -1 if synthetic
uptr xs_kind;                              // 0 = from the module, 1 = __stubs, 2 = __got
uptr xs_addr;
uptr xs_off;
uptr xs_size;
uptr xs_seg;
i64 xseccap = 0;
i64 nxsec = 0;
uptr sec2x;                                // module section -> index in xs_*

// ---- segment table ----
uptr xg_name;
uptr xg_addr;
uptr xg_vmsize;
uptr xg_off;
uptr xg_fsize;
i64  xsegcap = 0;
i64  nxseg = 0;

uptr xg_name_at(i64 i)            { return ld64(xg_name + i * 8); }
void set_xg_name_at(i64 i, uptr v) { st64(xg_name + i * 8, v); }

// ---- imported symbols, in creation order ----
uptr undef_sym;
i64 undefcap = 0;
i64 nundef = 0;

// ---- __LINKEDIT ----
u8  lk_rebase[BUF_SIZE];
u8  lk_bind[BUF_SIZE];
u8  lk_str[BUF_SIZE];
i64 rb_open = 0;                           // has the rebase SET_TYPE already been emitted?
i64 bd_open = 0;                           // have the bind ordinal and type already been emitted?
i64 bd_ord = 0;                            // dylib ordinal currently in effect for binds
i64 lk_off = 0;
i64 lk_addr = 0;
i64 stubs_addr = 0;
i64 got_addr = 0;
i64 got_seg = 0;

// ---- utilities ----
i64 exe_up(i64 v, i64 a) { return (v + a - 1) & ~(a - 1); }

// 16 zero-filled bytes of a segment/section name
void exe_put_name(uptr o, uptr s) {
    i64 i = 0;
    while (i < 16) {
        if (i < cstrlen(s)) buf_u8(o, ld8(s + i));
        else                buf_u8(o, 0);
        i++;
    }
}

// the signature fields are big-endian, unlike the rest of Mach-O
void buf_be32(uptr b, i64 v) {
    buf_u8(b, (v >> 24) & 0xff);
    buf_u8(b, (v >> 16) & 0xff);
    buf_u8(b, (v >> 8) & 0xff);
    buf_u8(b, v & 0xff);
}

void buf_be64(uptr b, i64 v) {
    buf_be32(b, (v >> 32) & 0xffffffff);
    buf_be32(b, v & 0xffffffff);
}

// little-endian variable-length integer, 7 bits per byte (the dyld opcode format)
void exe_uleb(uptr b, i64 v) {
    loop {
        i64 c = v & 0x7f;
        v = v >> 7;
        if (v == 0) {
            buf_u8(b, c);
            break;
        }
        buf_u8(b, c | 0x80);
    }
}

// the 16 segname bytes of a Section as a NUL-terminated string
uptr exe_segname(uptr p16) {
    uptr s = xalloc(17);
    i64 i = 0;
    while (i < 16) {
        st8(s + i, ld8(p16 + i));
        i++;
    }
    st8(s + 16, 0);
    return s;
}

// ---- imported symbols ----
void exe_collect_undef() {
    nundef = 0;
    i64 i = 0;
    while (i < nsymbols) {
        if (sym_sect(sym_at(i)) == 0) {
            undef_sym = grow(T_UNDEF, undef_sym, nundef, &undefcap, 8);
            set_ivec_at(undef_sym, nundef, i);
            nundef = nundef + 1;
        }
        i++;
    }
}

i64 exe_undef_index(i64 sym) {
    i64 i = 0;
    while (i < nundef) {
        if (ivec_at(undef_sym, i) == sym) return i;
        i++;
    }
    return -1;
}

// ---- segments and sections ----
i64 exe_seg_find(uptr nm) {
    i64 i = 0;
    while (i < nxseg) {
        if (str_eq(xg_name_at(i), nm)) return i;
        i++;
    }
    return -1;
}

void exe_seg_add(uptr nm) {
    i64 oc = xsegcap;
    xg_name = grow(T_XSEGS, xg_name, nxseg, &xsegcap, 8);
    if (xsegcap != oc) {
        xg_addr   = grow_to(xg_addr,   nxseg, xsegcap, 8);
        xg_vmsize = grow_to(xg_vmsize, nxseg, xsegcap, 8);
        xg_off    = grow_to(xg_off,    nxseg, xsegcap, 8);
        xg_fsize  = grow_to(xg_fsize,  nxseg, xsegcap, 8);
    }
    set_xg_name_at(nxseg, nm);
    nxseg = nxseg + 1;
}

void exe_add_sec(i64 src, i64 kind, i64 seg) {
    i64 oc = xseccap;
    xs_src = grow(T_XSECS, xs_src, nxsec, &xseccap, 8);
    if (xseccap != oc) {
        xs_kind = grow_to(xs_kind, nxsec, xseccap, 8);
        xs_addr = grow_to(xs_addr, nxsec, xseccap, 8);
        xs_off  = grow_to(xs_off,  nxsec, xseccap, 8);
        xs_size = grow_to(xs_size, nxsec, xseccap, 8);
        xs_seg  = grow_to(xs_seg,  nxsec, xseccap, 8);
    }
    set_ivec_at(xs_src, nxsec, src);
    set_ivec_at(xs_kind, nxsec, kind);
    set_ivec_at(xs_seg, nxsec, seg);
    if (src >= 0) set_ivec_at(sec2x, src, nxsec);
    nxsec = nxsec + 1;
}

i64 exe_sec_zf(i64 x) {
    i64 src = ivec_at(xs_src, x);
    if (src < 0) return 0;                        // synthetic sections are always regular
    return (sec_flags(sec_at(src)) & 0xff) == S_ZEROFILL;
}

i64 exe_sec_align(i64 x) {
    i64 k = ivec_at(xs_kind, x);
    if (k == 1) return 2;                         // instructions
    if (k == 2) return 3;                         // 8-byte pointers
    return sec_align(sec_at(ivec_at(xs_src, x)));
}

i64 exe_sec_size(i64 x) {
    i64 k = ivec_at(xs_kind, x);
    if (k == 1) return STUB_SIZE * nundef;
    if (k == 2) return 8 * nundef;
    uptr s = sec_at(ivec_at(xs_src, x));
    if ((sec_flags(s) & 0xff) == S_ZEROFILL) return sec_zsize(s);
    return buf_len(sec_data(s));
}

i64 exe_sec_flags(i64 x) {
    i64 k = ivec_at(xs_kind, x);
    if (k == 1) return STUB_FLAGS;
    if (k == 2) return S_NON_LAZY_SYMBOL_POINTERS;
    return sec_flags(sec_at(ivec_at(xs_src, x)));
}

i64 exe_seg_nsec(i64 g) {
    i64 n = 0;
    i64 x = 0;
    while (x < nxsec) {
        if (ivec_at(xs_seg, x) == g) n = n + 1;
        x++;
    }
    return n;
}

// One segment per distinct segment name, in order of first appearance — since
// __TEXT,__text is always the first section created by gen_sections, __TEXT always
// comes out at index 0, which is what the header requires. Within each segment the
// regular sections come in creation order and the zerofill ones at the end, the same
// rule as macho_write. The two synthetic ones go at the end of their segment's regular sections.
void exe_plan_sections() {
    nxseg = 0;
    nxsec = 0;
    sec2x = xalloc(8 * (nsections + 1));   // one slot per module section, exactly
    i64 i = 0;
    while (i < nsections) {
        uptr nm = exe_segname(sec_seg(sec_at(i)));
        if (exe_seg_find(nm) < 0) exe_seg_add(nm);
        i++;
    }
    if (nundef > 0 && exe_seg_find("__DATA") < 0) exe_seg_add("__DATA");
    i64 g = 0;
    while (g < nxseg) {
        uptr nm = xg_name_at(g);
        i64 pass = 0;
        while (pass < 2) {
            i = 0;
            while (i < nsections) {
                uptr s = sec_at(i);
                i64 zf = (sec_flags(s) & 0xff) == S_ZEROFILL;
                if (zf == pass && str_eq(exe_segname(sec_seg(s)), nm)) exe_add_sec(i, 0, g);
                i++;
            }
            if (pass == 0 && nundef > 0) {
                if (str_eq(nm, "__TEXT")) exe_add_sec(0 - 1, 1, g);
                if (str_eq(nm, "__DATA")) exe_add_sec(0 - 1, 2, g);
            }
            pass++;
        }
        g++;
    }
}

// LC_LOAD_DYLIB: fixed header + NUL-terminated path, rounded up to 8
i64 exe_dylib_size(uptr path) { return exe_up(DYLIB_HDR + cstrlen(path) + 1, 8); }

// size of all the load commands: known before the layout because it only depends on
// the number of segments, sections and dylibs
i64 exe_sizeofcmds() {
    i64 n = 72;                                   // __PAGEZERO
    i64 g = 0;
    while (g < nxseg) {
        n = n + 72 + 80 * exe_seg_nsec(g);
        g++;
    }
    n = n + 72;                                   // __LINKEDIT
    n = n + 48;                                   // LC_DYLD_INFO_ONLY
    n = n + 24;                                   // LC_SYMTAB
    n = n + 80;                                   // LC_DYSYMTAB
    n = n + 32;                                   // LC_LOAD_DYLINKER
    n = n + 24;                                   // LC_UUID
    n = n + 24;                                   // LC_BUILD_VERSION
    n = n + 24;                                   // LC_MAIN
    n = n + exe_dylib_size("/usr/lib/libSystem.B.dylib");
    i64 dl = 0;                                   // one LC_LOAD_DYLIB per #dylib
    while (dl < dylib_count()) {
        n = n + exe_dylib_size(dylib_path(dl));
        dl++;
    }
    n = n + 16;                                   // LC_CODE_SIGNATURE
    return n;
}

// final addresses: each segment starts on a 16 KiB page, in VM and in the
// file; within it the cursor is the same for both (which is why a section's
// offset is always segoff + (addr - segvm)).
void exe_layout(i64 sizeofcmds) {
    i64 vm = EXE_BASE;
    i64 fo = 0;
    i64 g = 0;
    while (g < nxseg) {
        i64 segvm = vm;
        i64 segoff = fo;
        i64 cur = 0;
        if (g == 0) cur = 32 + sizeofcmds;        // the header lives inside __TEXT
        i64 fsz = 0;
        i64 pass = 0;
        while (pass < 2) {
            i64 x = 0;
            while (x < nxsec) {
                if (ivec_at(xs_seg, x) == g && exe_sec_zf(x) == pass) {
                    cur = exe_up(cur, 1 << exe_sec_align(x));
                    set_ivec_at(xs_addr, x, segvm + cur);
                    if (pass) set_ivec_at(xs_off, x, 0);
                    else      set_ivec_at(xs_off, x, segoff + cur);
                    set_ivec_at(xs_size, x, exe_sec_size(x));
                    cur = cur + exe_sec_size(x);
                }
                x++;
            }
            if (pass == 0) fsz = cur;
            pass++;
        }
        set_ivec_at(xg_addr, g, segvm);
        set_ivec_at(xg_off, g, segoff);
        set_ivec_at(xg_fsize, g, exe_up(fsz, EXE_PAGE));
        set_ivec_at(xg_vmsize, g, exe_up(cur, EXE_PAGE));
        vm = segvm + exe_up(cur, EXE_PAGE);
        fo = segoff + exe_up(fsz, EXE_PAGE);
        g++;
    }
    lk_off = fo;
    lk_addr = vm;
    stubs_addr = 0;
    got_addr = 0;
    i64 x = 0;
    while (x < nxsec) {
        if (ivec_at(xs_kind, x) == 1) stubs_addr = ivec_at(xs_addr, x);
        if (ivec_at(xs_kind, x) == 2) {
            got_addr = ivec_at(xs_addr, x);
            got_seg  = ivec_at(xs_seg, x);
        }
        x++;
    }
}

// ---- rebase and bind ----
void exe_rebase_add(i64 seg, i64 off) {
    if (seg > 15) die("too many segments for the rebase opcode");
    if (!rb_open) {
        buf_u8(lk_rebase, REBASE_SET_TYPE_IMM | TYPE_POINTER);
        rb_open = 1;
    }
    buf_u8(lk_rebase, REBASE_SET_SEG_ULEB | seg);
    exe_uleb(lk_rebase, off);
    buf_u8(lk_rebase, REBASE_DO_IMM_TIMES | 1);
}

// dylib ordinal of an imported symbol: the symbol name has the `_` that the
// compiler adds, the #dylib table is indexed by the source name
i64 exe_sym_ord(uptr symname) { return extern_lib_find(symname + 1); }

void exe_bind_add(i64 seg, i64 off, uptr name, i64 ord) {
    if (seg > 15) die("too many segments for the bind opcode");
    if (ord > 15) die("too many dylibs for the bind opcode");
    if (!bd_open) {
        buf_u8(lk_bind, BIND_SET_DYLIB_ORD_IMM | ord);
        buf_u8(lk_bind, BIND_SET_TYPE_IMM | TYPE_POINTER);
        bd_open = 1;
        bd_ord = ord;
    } else if (ord != bd_ord) {
        buf_u8(lk_bind, BIND_SET_DYLIB_ORD_IMM | ord);    // switched dylib
        bd_ord = ord;
    }
    buf_u8(lk_bind, BIND_SET_SYMBOL_FLAGS);
    buf_put(lk_bind, name, cstrlen(name) + 1);
    buf_u8(lk_bind, BIND_SET_SEG_ULEB | seg);
    exe_uleb(lk_bind, off);
    buf_u8(lk_bind, BIND_DO_BIND);
}

// ---- relocations ----
// final address of a symbol; an imported one has no address of its own, so its
// stub's address is used — that is how `&write` ends up working in the direct executable
i64 exe_sym_addr(i64 sym) {
    uptr s = sym_at(sym);
    if (sym_sect(s) == 0) return stubs_addr + exe_undef_index(sym) * STUB_SIZE;
    return ivec_at(xs_addr, ivec_at(sec2x, sym_sect(s) - 1)) + sym_value(s);
}

void exe_fix_branch26(uptr p, i64 at, i64 pc, i64 target) {
    i64 d = target - pc;
    if (d % 4 != 0) die("misaligned bl target");
    if (d >= 128 * 1024 * 1024 || d < 0 - 128 * 1024 * 1024) die("bl too far");
    st32(p + at, (ld32(p + at) & ~0x3ffffff) | ((d / 4) & 0x3ffffff));
}

void exe_fix_page21(uptr p, i64 at, i64 pc, i64 target) {
    i64 im = ((target & ~4095) - (pc & ~4095)) / 4096;
    i64 w = ld32(p + at) & ~((3 << 29) | (0x7ffff << 5));
    st32(p + at, w | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5));
}

// the 12-bit immediate of `add` is the offset itself; that of an ldr/str with
// an unsigned offset is scaled by the access width (bits 31:30)
void exe_fix_pageoff12(uptr p, i64 at, i64 target) {
    i64 w = ld32(p + at);
    i64 sc = 0;
    if ((w & 0x3b000000) == 0x39000000) sc = (w >> 30) & 3;
    i64 lo = target & 4095;
    if (lo % (1 << sc) != 0) die("pageoff12 misaligned for the access width");
    st32(p + at, (w & ~(0xfff << 10)) | (((lo >> sc) & 0xfff) << 10));
}

void exe_fix_unsigned(i64 x, uptr p, uptr r) {
    i64 seg = ivec_at(xs_seg, x);
    i64 at = rel_off(r);
    i64 off = ivec_at(xs_addr, x) - ivec_at(xg_addr, seg) + at;
    i64 sym = rel_sym(r);
    if (rel_len(r) != 3) die("UNSIGNED that does not occupy 8 bytes");
    if (str_eq(xg_name_at(seg), "__TEXT"))
        die("relocated pointer in __TEXT: the segment is r-x and dyld will not rebase it");
    if (sym_sect(sym_at(sym)) == 0) {
        st64(p + at, 0);                            // dyld writes the imported address
        uptr nm = sym_name(sym_at(sym));
        exe_bind_add(seg + 1, off, nm, exe_sym_ord(nm));
    } else {
        st64(p + at, exe_sym_addr(sym));            // address without the ASLR slide
        exe_rebase_add(seg + 1, off);               // ... which dyld adds during rebase
    }
}

void exe_patch_relocs() {
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if ((sec_flags(s) & 0xff) != S_ZEROFILL) {
            i64 x = ivec_at(sec2x, i);
            uptr p = buf_p(sec_data(s));
            i64 j = 0;
            while (j < sec_nrel(s)) {
                uptr r = rel_at(sec_rel(s), j);
                i64 t = rel_type(r);
                i64 pc = ivec_at(xs_addr, x) + rel_off(r);
                if (t == R_BRANCH26)        exe_fix_branch26(p, rel_off(r), pc, exe_sym_addr(rel_sym(r)));
                else if (t == R_PAGE21)     exe_fix_page21(p, rel_off(r), pc, exe_sym_addr(rel_sym(r)));
                else if (t == R_PAGEOFF12)  exe_fix_pageoff12(p, rel_off(r), exe_sym_addr(rel_sym(r)));
                else if (t == R_UNSIGNED)   exe_fix_unsigned(x, p, r);
                else die("relocation not supported in the direct executable");
                j++;
            }
        }
        i++;
    }
}

// ---- synthetic content ----
// stub k: adrp x16, slot page; ldr x16, [x16, #off]; br x16
void exe_put_stubs(uptr o) {
    i64 k = 0;
    while (k < nundef) {
        i64 pc = stubs_addr + k * STUB_SIZE;
        i64 slot = got_addr + k * 8;
        i64 im = ((slot & ~4095) - (pc & ~4095)) / 4096;
        buf_u32(o, 0x90000010 | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5));
        buf_u32(o, 0xF9400210 | (((slot & 4095) / 8) << 10));
        buf_u32(o, 0xD61F0200);
        k++;
    }
}

// the __got slots come out zeroed: dyld fills them in via bind opcodes
void exe_put_got(uptr o) {
    i64 k = 0;
    while (k < nundef) {
        buf_u64(o, 0);
        k++;
    }
}

// one bind per __got slot, in the order of the imported symbols
void exe_bind_got() {
    i64 k = 0;
    while (k < nundef) {
        i64 off = got_addr + k * 8 - ivec_at(xg_addr, got_seg);
        uptr nm = sym_name(sym_at(ivec_at(undef_sym, k)));
        exe_bind_add(got_seg + 1, off, nm, exe_sym_ord(nm));
        k++;
    }
}

// ---- load commands ----
void exe_seg_cmd(uptr o, uptr nm, i64 vmaddr, i64 vmsize, i64 fileoff, i64 filesize,
                 i64 prot, i64 nsects) {
    buf_u32(o, LC_SEGMENT_64);
    buf_u32(o, 72 + 80 * nsects);
    exe_put_name(o, nm);
    buf_u64(o, vmaddr);
    buf_u64(o, vmsize);
    buf_u64(o, fileoff);
    buf_u64(o, filesize);
    buf_u32(o, prot);
    buf_u32(o, prot);
    buf_u32(o, nsects);
    buf_u32(o, 0);
}

void exe_sec_hdr(uptr o, i64 x) {
    i64 src = ivec_at(xs_src, x);
    i64 kind = ivec_at(xs_kind, x);
    if (src >= 0) {
        buf_put(o, sec_sect(sec_at(src)), 16);
        buf_put(o, sec_seg(sec_at(src)), 16);
    } else if (kind == 1) {
        exe_put_name(o, "__stubs");
        exe_put_name(o, "__TEXT");
    } else {
        exe_put_name(o, "__got");
        exe_put_name(o, "__DATA");
    }
    buf_u64(o, ivec_at(xs_addr, x));
    buf_u64(o, ivec_at(xs_size, x));
    buf_u32(o, ivec_at(xs_off, x));
    buf_u32(o, exe_sec_align(x));
    buf_u32(o, 0);                                  // reloff: none, already resolved
    buf_u32(o, 0);                                  // nreloc
    buf_u32(o, exe_sec_flags(x));
    // reserved1 is the index into the indirect symbol table; reserved2 the stub
    // size. The table holds the imported symbols twice: first for __stubs,
    // then for __got, in the same order they appear in the file.
    if (kind == 1)      { buf_u32(o, 0);      buf_u32(o, STUB_SIZE); }
    else if (kind == 2) { buf_u32(o, nundef); buf_u32(o, 0); }
    else                { buf_u32(o, 0);      buf_u32(o, 0); }
    buf_u32(o, 0);
}

void exe_dylinker(uptr o) {
    buf_u32(o, LC_LOAD_DYLINKER);
    buf_u32(o, 32);
    buf_u32(o, 12);                                 // name offset
    buf_put(o, "/usr/lib/dyld", 14);
    buf_pad(o, 8);
}

void exe_dylib_one(uptr o, uptr path) {
    buf_u32(o, LC_LOAD_DYLIB);
    buf_u32(o, exe_dylib_size(path));
    buf_u32(o, DYLIB_HDR);                          // name offset
    buf_u32(o, 2);                                  // fixed timestamp (determinism)
    buf_u32(o, 0x054C0000);                         // current 1356.0.0
    buf_u32(o, 0x00010000);                         // compatibility 1.0.0
    buf_put(o, path, cstrlen(path) + 1);
    buf_pad(o, 8);
}

// libSystem is always first (ordinal 1); then the #dylib ones, in registration
// order — that order defines the ordinal that n_desc and the binds cite
void exe_dylib(uptr o) {
    exe_dylib_one(o, "/usr/lib/libSystem.B.dylib");
    i64 i = 0;
    while (i < dylib_count()) {
        exe_dylib_one(o, dylib_path(i));
        i++;
    }
}

// ---- symtab ----
// section number (1-based in the final order) and absolute address of a symbol
void exe_symtab(uptr o, uptr order, uptr strx) {
    i64 k = 0;
    while (k < nsymbols) {
        i64 oi = ivec_at(order, k);
        uptr s = sym_at(oi);
        buf_u32(o, ivec_at(strx, oi));
        if (sym_sect(s) == 0) {
            buf_u8(o, N_UNDF | N_EXT);
            buf_u8(o, 0);
            buf_u16(o, N_DESC_ORD1 * exe_sym_ord(sym_name(s)));  // two-level: ordinal
            buf_u64(o, 0);
        } else {
            i64 x = ivec_at(sec2x, sym_sect(s) - 1);
            if (sym_global(s)) buf_u8(o, N_SECT | N_EXT);
            else               buf_u8(o, N_SECT);
            buf_u8(o, x + 1);
            buf_u16(o, 0);
            buf_u64(o, ivec_at(xs_addr, x) + sym_value(s));
        }
        k++;
    }
}

void exe_indirect(uptr o, uptr pos) {
    i64 pass = 0;
    while (pass < 2) {                              // __stubs then __got
        i64 k = 0;
        while (k < nundef) {
            buf_u32(o, ivec_at(pos, ivec_at(undef_sym, k)));
            k++;
        }
        pass++;
    }
}

// ---- ad-hoc signature ----
// output file name without the directory: it is the identifier that `codesign -dvvv`
// shows and the signature's only free-form text
uptr exe_ident(uptr path) {
    i64 last = 0;
    i64 i = 0;
    while (ld8(path + i)) {
        if (ld8(path + i) == '/') last = i + 1;
        i++;
    }
    return path + last;
}

// CS_SuperBlob with a single CS_CodeDirectory; everything big-endian
void exe_sig(uptr o, uptr ident, i64 codelimit, i64 nslots, i64 texts, i64 textlim, uptr hashes) {
    i64 idlen = cstrlen(ident) + 1;
    i64 cdlen = CD_HEADER + idlen + CD_HASHSIZE * nslots;
    buf_be32(o, CSMAGIC_EMBEDDED_SIGNATURE);
    buf_be32(o, 20 + cdlen);
    buf_be32(o, 1);                                 // one blob
    buf_be32(o, 0);                                 // CSSLOT_CODEDIRECTORY
    buf_be32(o, 20);                                // blob offset
    buf_be32(o, CSMAGIC_CODEDIRECTORY);
    buf_be32(o, cdlen);
    buf_be32(o, CD_VERSION);
    buf_be32(o, CS_ADHOC);
    buf_be32(o, CD_HEADER + idlen);                 // hashOffset
    buf_be32(o, CD_HEADER);                         // identOffset
    buf_be32(o, 0);                                 // nSpecialSlots
    buf_be32(o, nslots);
    buf_be32(o, codelimit);
    buf_u8(o, CD_HASHSIZE);
    buf_u8(o, CD_HASHTYPE_SHA256);
    buf_u8(o, 0);                                   // platform
    buf_u8(o, 12);                                  // pageSize: 1 << 12 = 4 KiB
    buf_be32(o, 0);                                 // spare2
    buf_be32(o, 0);                                 // scatterOffset
    buf_be32(o, 0);                                 // teamOffset
    buf_be32(o, 0);                                 // spare3
    buf_be64(o, 0);                                 // codeLimit64
    buf_be64(o, texts);                             // execSegBase
    buf_be64(o, textlim);                           // execSegLimit
    buf_be64(o, CS_EXECSEG_MAIN_BINARY);            // execSegFlags
    buf_put(o, ident, idlen);
    buf_put(o, hashes, CD_HASHSIZE * nslots);
}

// ---- writing ----
void exe_write_file(uptr path, uptr b) {
    i64 fd = creat(path, MODE_755);
    if (fd < 0) die2("cannot create", path);
    io_write(fd, buf_p(b), buf_len(b));
    close(fd);
    chmod(path, MODE_755);                          // creat only applies the mode on creation
}

void exe_write(uptr path) {
    exe_collect_undef();
    exe_plan_sections();
    i64 sizeofcmds = exe_sizeofcmds();
    exe_layout(sizeofcmds);

    buf_init(lk_rebase);
    buf_init(lk_bind);
    buf_init(lk_str);
    rb_open = 0;
    bd_open = 0;
    exe_bind_got();
    exe_patch_relocs();
    if (rb_open) buf_u8(lk_rebase, 0);              // REBASE_OPCODE_DONE
    if (bd_open) buf_u8(lk_bind, 0);                // BIND_OPCODE_DONE

    uptr order = xalloc(8 * (nsymbols + 1));
    uptr pos   = xalloc(8 * (nsymbols + 1));
    u8   count[24];
    sym_order(order, pos, count);
    uptr strx = xalloc(8 * (nsymbols + 1));
    buf_u8(lk_str, 0);
    i64 k = 0;
    while (k < nsymbols) {
        set_ivec_at(strx, k, buf_len(lk_str));
        buf_put(lk_str, sym_name(sym_at(k)), cstrlen(sym_name(sym_at(k))) + 1);
        k++;
    }
    buf_pad(lk_str, 8);

    i64 rebase_off = lk_off;
    i64 bind_off   = exe_up(rebase_off + buf_len(lk_rebase), 8);
    i64 symoff     = exe_up(bind_off + buf_len(lk_bind), 8);
    i64 indoff     = symoff + 16 * nsymbols;
    i64 stroff     = indoff + 4 * 2 * nundef;
    i64 sigoff     = exe_up(stroff + buf_len(lk_str), 16);
    i64 nslots     = (sigoff + CS_PAGE - 1) / CS_PAGE;
    uptr ident     = exe_ident(path);
    i64 siglen     = 20 + CD_HEADER + cstrlen(ident) + 1 + CD_HASHSIZE * nslots;

    i64 msym = sym_find("_main");
    if (msym < 0 || sym_sect(sym_at(msym)) == 0) die("no _main: cannot generate an executable");

    u8 o[BUF_SIZE];
    buf_init(o);
    buf_u32(o, MH_MAGIC_64);
    buf_u32(o, CPU_TYPE_ARM64);
    buf_u32(o, 0);
    buf_u32(o, MH_EXECUTE);
    buf_u32(o, nxseg + 11 + dylib_count());
    buf_u32(o, sizeofcmds);
    buf_u32(o, EXE_FLAGS);
    buf_u32(o, 0);

    exe_seg_cmd(o, "__PAGEZERO", 0, EXE_BASE, 0, 0, 0, 0);
    i64 g = 0;
    while (g < nxseg) {
        i64 prot = 3;                               // rw-
        if (str_eq(xg_name_at(g), "__TEXT")) prot = 5;
        exe_seg_cmd(o, xg_name_at(g), ivec_at(xg_addr, g), ivec_at(xg_vmsize, g),
                    ivec_at(xg_off, g), ivec_at(xg_fsize, g), prot, exe_seg_nsec(g));
        i64 x = 0;
        while (x < nxsec) {
            if (ivec_at(xs_seg, x) == g) exe_sec_hdr(o, x);
            x++;
        }
        g++;
    }
    exe_seg_cmd(o, "__LINKEDIT", lk_addr, exe_up(sigoff + siglen - lk_off, EXE_PAGE),
                lk_off, sigoff + siglen - lk_off, 1, 0);

    buf_u32(o, LC_DYLD_INFO_ONLY);
    buf_u32(o, 48);
    buf_u32(o, rebase_off);
    buf_u32(o, buf_len(lk_rebase));
    buf_u32(o, bind_off);
    buf_u32(o, buf_len(lk_bind));
    buf_u32(o, 0); buf_u32(o, 0);                   // weak bind
    buf_u32(o, 0); buf_u32(o, 0);                   // lazy bind: everything is immediate bind
    buf_u32(o, 0); buf_u32(o, 0);                   // export trie: the executable exports nothing

    buf_u32(o, LC_SYMTAB);
    buf_u32(o, 24);
    buf_u32(o, symoff);
    buf_u32(o, nsymbols);
    buf_u32(o, stroff);
    buf_u32(o, buf_len(lk_str));

    buf_u32(o, LC_DYSYMTAB);
    buf_u32(o, 80);
    buf_u32(o, 0);                buf_u32(o, ivec_at(count, 0));
    buf_u32(o, ivec_at(count, 0)); buf_u32(o, ivec_at(count, 1));
    buf_u32(o, ivec_at(count, 0) + ivec_at(count, 1)); buf_u32(o, ivec_at(count, 2));
    buf_u32(o, 0); buf_u32(o, 0);                   // toc
    buf_u32(o, 0); buf_u32(o, 0);                   // modtab
    buf_u32(o, 0); buf_u32(o, 0);                   // extrefsyms
    buf_u32(o, indoff); buf_u32(o, 2 * nundef);
    buf_u32(o, 0); buf_u32(o, 0);                   // extrel
    buf_u32(o, 0); buf_u32(o, 0);                   // locrel

    exe_dylinker(o);
    buf_u32(o, LC_UUID);
    buf_u32(o, 24);
    i64 uuid_off = buf_len(o);                      // filled in later: it is a hash of the file
    i64 i = 0;
    while (i < 16) {
        buf_u8(o, 0);
        i++;
    }
    buf_u32(o, LC_BUILD_VERSION);
    buf_u32(o, 24);
    buf_u32(o, 1);                                  // platform macOS
    buf_u32(o, 0x000D0000);                         // minos 13.0.0
    buf_u32(o, 0x000D0000);                         // sdk 13.0.0
    buf_u32(o, 0);                                  // ntools
    buf_u32(o, LC_MAIN);
    buf_u32(o, 24);
    buf_u64(o, exe_sym_addr(msym) - EXE_BASE);      // entryoff: dyld calls _main
    buf_u64(o, 0);                                  // stacksize: default
    exe_dylib(o);
    buf_u32(o, LC_CODE_SIGNATURE);
    buf_u32(o, 16);
    buf_u32(o, sigoff);
    buf_u32(o, siglen);

    i64 x = 0;                                      // section data
    while (x < nxsec) {
        if (!exe_sec_zf(x)) {
            while (buf_len(o) < ivec_at(xs_off, x)) {
                buf_u8(o, 0);
            }
            i64 kind = ivec_at(xs_kind, x);
            if (kind == 1)      exe_put_stubs(o);
            else if (kind == 2) exe_put_got(o);
            else {
                uptr s = sec_at(ivec_at(xs_src, x));
                buf_put(o, buf_p(sec_data(s)), buf_len(sec_data(s)));
            }
        }
        x++;
    }
    while (buf_len(o) < rebase_off) {
        buf_u8(o, 0);
    }
    buf_put(o, buf_p(lk_rebase), buf_len(lk_rebase));
    while (buf_len(o) < bind_off) {
        buf_u8(o, 0);
    }
    buf_put(o, buf_p(lk_bind), buf_len(lk_bind));
    while (buf_len(o) < symoff) {
        buf_u8(o, 0);
    }
    exe_symtab(o, order, strx);
    exe_indirect(o, pos);
    buf_put(o, buf_p(lk_str), buf_len(lk_str));
    while (buf_len(o) < sigoff) {
        buf_u8(o, 0);
    }

    // the UUID is the SHA-256 of the whole file without it: deterministic and dateless
    u8 dig[32];
    sha256(buf_p(o), sigoff, dig);
    i = 0;
    while (i < 16) {
        st8(buf_p(o) + uuid_off + i, ld8(dig + i));
        i++;
    }
    st8(buf_p(o) + uuid_off + 6, (ld8(dig + 6) & 0x0f) | 0x50);   // version 5
    st8(buf_p(o) + uuid_off + 8, (ld8(dig + 8) & 0x3f) | 0x80);   // RFC 4122 variant

    // hashes of every page before writing a single byte of the signature:
    // buf_put may reallocate the buffer and move buf_p(o)
    uptr hashes = xalloc(CD_HASHSIZE * nslots + CD_HASHSIZE);
    i = 0;
    while (i < nslots) {
        i64 n = CS_PAGE;
        if (i * CS_PAGE + n > sigoff) n = sigoff - i * CS_PAGE;
        sha256(buf_p(o) + i * CS_PAGE, n, hashes + i * CD_HASHSIZE);
        i++;
    }
    exe_sig(o, ident, sigoff, nslots, ivec_at(xg_off, 0), ivec_at(xg_fsize, 0), hashes);
    exe_write_file(path, o);
}

// the backend itself: the same lowering and the same encoder as the `macho`
// backend, only the writing differs. M37: it names its machine first, like
// every backend since M17 -- a Mach-O executable is arm64, whatever machine the
// host that is running the compiler uses by default.
void backend_exe(i64 root, uptr out) {
    machine_use("arm64");
    gen_lower(root);
    gen_encode_all();
    exe_write(out);
}
