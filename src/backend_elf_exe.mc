// backend_elf_exe.mc — backends `elf-exe` and `elf-exe-x86_64`: a DYNAMIC ELF64
// `ET_EXEC`, written without a linker and without a sysroot (M42,
// docs/specs/M42.md).
//
// It is to src/backend_elf.mc what src/backend_exe.mc is to src/macho.mc: the
// same `gen_lower` + `gen_encode_all` in front of it, the same sections,
// symbols and relocations behind it, and then instead of handing the
// relocations to `ld.lld` it
//
//   1. picks the final addresses (one PT_LOAD per distinct Mach-O segment name,
//      each on a page: 64 KiB on aarch64, 4 KiB on x86-64);
//   2. resolves every relocation itself, in place, with backend_exe.mc's four
//      patchers -- they encode instructions, and an instruction has no format;
//   3. gives each imported symbol a PLT stub and exactly one 8-byte GOT slot,
//      and asks the loader to fill the slot before the entry point runs
//      (`DT_BIND_NOW` / `DF_1_NOW`, so the stub is a plain indirect jump and
//      there is no resolver, no PLT0 and no lazy binding);
//   4. brings its own entry point: the kernel enters `_start`, not `main`, and
//      there is no crt1.o here. A program that defines `_start` itself
//      (`#include <sys_linux>`) keeps it; anything else gets the 7-instruction
//      stub this file synthesizes.
//
// THE STATIC CASE IS THE DEGENERATE CASE, decided by counting imports and never
// by a flag: with no undefined symbol there is no `PT_INTERP`, no `PT_DYNAMIC`,
// no `.dynsym`/`.dynstr`/`.hash`/`.rela.plt`, no PLT and no GOT, and what comes
// out is a static executable the kernel runs with no loader at all.
//
// Two simplifications, both with M11's precedent of refusing the optional half
// of a format (docs/specs/M42.md § 2):
//
//   ET_EXEC at 0x400000, not ET_DYN. A PIE would need an `R_*_RELATIVE` for
//   every absolute address in the image; a fixed base needs none, because the
//   writer knows every address when it places the segments. The cost is no
//   ASLR, named in docs/reference/objects.md.
//
//   DT_BIND_NOW. Every `JUMP_SLOT` is resolved before `_start` runs, so an
//   import that does not exist fails at load time and not at the first call.
//
// The layout was validated before this file existed: docs/specs/M42.md § 0 is a
// hand-laid-out probe (scratchpad/m42probe/mkprobe.py) run under musl and glibc
// on both architectures. This writer emits the same shape.
//
// Depends on arena.mc (buf_*, xalloc, die, die2), on objmodel.mc (sections,
// symbols, relocations, sym_order, dyn_interp/dyn_libc), on gen_walk.mc
// (gen_lower/gen_encode_all, ivec_at/set_ivec_at), on parse.mc (dylib_count/
// dylib_path) and on two files of its own part: backend_elf.mc (the ELF
// constants and the section naming/typing this shares with the object writer)
// and backend_exe.mc (exe_up, exe_segname, exe_collect_undef, the four
// relocation patchers and exe_write_file -- none of which has Mach-O in it).

#include "../lib/prelude.mc"

// ---- program headers ----
#define ET_EXEC      2
#define PHDR_SIZE    56
#define PT_LOAD      1
#define PT_DYNAMIC   2
#define PT_INTERP    3
#define PT_PHDR      6
#define PT_GNU_STACK 0x6474e551
#define PF_X 1
#define PF_W 2
#define PF_R 4

// ---- sections a relocatable never has ----
#define SHT_HASH    5
#define SHT_DYNAMIC 6
#define SHT_DYNSYM  11

// ---- the .dynamic vector ----
#define DT_NULL     0
#define DT_NEEDED   1
#define DT_PLTRELSZ 2
#define DT_PLTGOT   3
#define DT_HASH     4
#define DT_STRTAB   5
#define DT_SYMTAB   6
#define DT_RELA     7
#define DT_STRSZ    10
#define DT_SYMENT   11
#define DT_PLTREL   20
#define DT_JMPREL   23
#define DT_FLAGS    30
#define DT_FLAGS_1  0x6ffffffb
#define DF_BIND_NOW 8
#define DF_1_NOW    1

#define R_AARCH64_JUMP_SLOT 1026
#define R_X86_64_JUMP_SLOT  7

// The image base. 0x400000 is the traditional ET_EXEC base on both
// architectures and is a multiple of 64 KiB, so the same number serves both
// page sizes.
#define EE_BASE 0x400000

// p_align. On aarch64 a kernel may be configured with 64 KiB pages and would
// refuse a 4 KiB-aligned image; the M42 § 0 probe measured that a 64 KiB align
// loads and runs unchanged on the 4 KiB kernels available, so aarch64 pays the
// larger alignment and x86-64, which has no such configuration, does not.
#define EE_PAGE_A64 65536
#define EE_PAGE_X86 4096

// One PLT stub per import. aarch64: adrp x16 / ldr x17 / br x17 / nop, padded
// to 16 so the stub table is one aligned block. x86-64: jmp *[rip+got] plus two
// int3, which is 8.
#define EE_PLT_A64 16
#define EE_PLT_X86 8

// The synthesized entry point, in bytes. Fixed per architecture: it takes no
// argument and its only variable is the `bl`/`call` displacement.
#define EE_START_A64 28
#define EE_START_X86 34

// ---- kinds of section in the executable's own table ----
#define EEK_NULL     0
#define EEK_MOD      1                 // one of the module's sections
#define EEK_INTERP   2
#define EEK_DYNSYM   3
#define EEK_DYNSTR   4
#define EEK_HASH     5
#define EEK_RELAPLT  6
#define EEK_PLT      7
#define EEK_START    8                 // the synthesized _start
#define EEK_GOT      9
#define EEK_DYNAMIC  10
#define EEK_SYMTAB   11
#define EEK_STRTAB   12
#define EEK_SHSTRTAB 13

// ---- state ----
i64 ee_em      = EM_AARCH64;           // which architecture this executable is for
i64 ee_page    = EE_PAGE_A64;          // p_align of every PT_LOAD
i64 ee_pltent  = EE_PLT_A64;           // bytes per PLT stub
i64 ee_startsz = EE_START_A64;         // bytes of the synthesized entry point

i64 ee_dynamic = 0;                    // 1 when the program imports anything
i64 ee_nlib    = 1;                    // DT_NEEDED count: the default + #dylib
i64 ee_entry   = 0;                    // e_entry
i64 ee_synth   = 0;                    // 1 when this file writes _start itself
i64 ee_mainsym = 0;                    // index of _main, when it does

i64 ee_plt_addr = 0;
i64 ee_got_addr = 0;
i64 ee_shoff    = 0;
i64 ee_filelen  = 0;                   // end of the last loaded segment

// ---- the section table, in file order ----
uptr ee_kind;
uptr ee_src;                           // module section, or -1
uptr ee_name;
uptr ee_nameoff;
uptr ee_type;
uptr ee_flags;
uptr ee_addr;
uptr ee_off;
uptr ee_size;
uptr ee_align;
uptr ee_ent;
uptr ee_link;
uptr ee_info;
uptr ee_seg;                           // index in the segment table, or -1
i64  nee = 0;
i64  ee_g = 0 - 1;                     // segment ee_add puts the next section in
uptr ee_of_sec;                        // module section -> index in the table

uptr ee_name_at(i64 i)             { return ld64(ee_name + i * 8); }
void set_ee_name_at(i64 i, uptr v) { st64(ee_name + i * 8, v); }

// ---- the segment table (one PT_LOAD each) ----
uptr eg_name;
uptr eg_addr;
uptr eg_off;
uptr eg_fsize;
uptr eg_msize;
i64  neseg = 0;

uptr eg_name_at(i64 i)             { return ld64(eg_name + i * 8); }
void set_eg_name_at(i64 i, uptr v) { st64(eg_name + i * 8, v); }

// ---- content built before it is placed ----
u8 ee_dynstr[BUF_SIZE];
u8 ee_dynsym[BUF_SIZE];
u8 ee_hashb[BUF_SIZE];
u8 ee_relab[BUF_SIZE];
u8 ee_dynb[BUF_SIZE];
u8 ee_symb[BUF_SIZE];
u8 ee_strb[BUF_SIZE];
u8 ee_shstrb[BUF_SIZE];
uptr ee_liboff;                        // dynstr offset of each DT_NEEDED name
uptr ee_impoff;                        // dynstr offset of each import's name

// ---- the two per-libc names ----
// Both come from [target] in mc.toml (src/driver.mc) and fall back to musl,
// which is the libc the whole Linux half of this repository is tested against.
// glibc is `interp = "/lib/ld-linux-aarch64.so.1"` (or
// "/lib64/ld-linux-x86-64.so.2") plus `libc = "libc.so.6"`; both were measured
// in docs/specs/M42.md § 0.
uptr ee_interp_path() {
    if (dyn_interp) return dyn_interp;
    if (ee_em == EM_X86_64) return "/lib/ld-musl-x86_64.so.1";
    return "/lib/ld-musl-aarch64.so.1";
}

// the library ordinal 1 refers to -- libSystem's counterpart. Mach-O always
// loads libSystem and ELF always names this one, for the same reason: every
// import that no #dylib and no [externs] pattern claims comes from it.
uptr ee_libc_name() {
    if (dyn_libc) return dyn_libc;
    return "libc.so";
}

// ---- the SysV hash, straight from the gABI ----
// DT_HASH and not DT_GNU_HASH: this is nine lines and every loader accepts it,
// while DT_GNU_HASH is a bloom filter plus sorted buckets for a lookup speed
// that does not matter at our symbol counts (docs/specs/M42.md § 3).
i64 ee_sysv_hash(uptr name) {
    i64 h = 0;
    i64 i = 0;
    while (ld8(name + i)) {
        h = ((h << 4) + ld8(name + i)) & 0xffffffff;
        i64 g = h & 0xf0000000;
        if (g) h = h ^ (g >> 24);
        h = h & ~g & 0xffffffff;
        i = i + 1;
    }
    return h;
}

// ---- imports ----
// The ELF name of import k: the compiler's leading `_` dropped, exactly as the
// object writer drops it (elf_sym_name).
uptr ee_imp_name(i64 k) { return elf_sym_name(sym_name(sym_at(ivec_at(undef_sym, k)))); }

// ---- .dynstr, .dynsym, .hash ----
// One string table for the DT_NEEDED names and the import names, in that order.
void ee_build_dynstr() {
    buf_init(ee_dynstr);
    buf_u8(ee_dynstr, 0);
    ee_liboff = xalloc(8 * (ee_nlib + 1));
    set_ivec_at(ee_liboff, 0, buf_len(ee_dynstr));
    buf_put(ee_dynstr, ee_libc_name(), cstrlen(ee_libc_name()) + 1);
    i64 i = 0;
    while (i < dylib_count()) {
        set_ivec_at(ee_liboff, i + 1, buf_len(ee_dynstr));
        buf_put(ee_dynstr, dylib_path(i), cstrlen(dylib_path(i)) + 1);
        i = i + 1;
    }
    ee_impoff = xalloc(8 * (nundef + 1));
    i = 0;
    while (i < nundef) {
        set_ivec_at(ee_impoff, i, buf_len(ee_dynstr));
        buf_put(ee_dynstr, ee_imp_name(i), cstrlen(ee_imp_name(i)) + 1);
        i = i + 1;
    }
}

// index 0 is the null symbol; import k is .dynsym index k + 1, which is what
// the JUMP_SLOT relocations and the hash chains cite. Every one is an undefined
// global function: nothing else can be imported here.
void ee_build_dynsym() {
    buf_init(ee_dynsym);
    i64 i = 0;
    while (i < ELFSYM_SIZE) {
        buf_u8(ee_dynsym, 0);
        i = i + 1;
    }
    i = 0;
    while (i < nundef) {
        buf_u32(ee_dynsym, ivec_at(ee_impoff, i));
        buf_u8(ee_dynsym, (STB_GLOBAL << 4) | STT_FUNC);
        buf_u8(ee_dynsym, 0);                      // st_other
        buf_u16(ee_dynsym, SHN_UNDEF);
        buf_u64(ee_dynsym, 0);                     // st_value
        buf_u64(ee_dynsym, 0);                     // st_size
        i = i + 1;
    }
}

// nbucket = nchain = the symbol count: a real table, not the legal single
// bucket. A chain is built by prepending, so the buckets come out independent
// of anything but the names -- there is no pointer and no address in here.
void ee_build_hash() {
    i64 n = nundef + 1;
    uptr buckets = xalloc(8 * (n + 1));
    uptr chains  = xalloc(8 * (n + 1));
    i64 i = 0;
    while (i < n) {
        set_ivec_at(buckets, i, 0);
        set_ivec_at(chains, i, 0);
        i = i + 1;
    }
    i = 0;
    while (i < nundef) {
        i64 b = ee_sysv_hash(ee_imp_name(i)) % n;
        set_ivec_at(chains, i + 1, ivec_at(buckets, b));
        set_ivec_at(buckets, b, i + 1);
        i = i + 1;
    }
    buf_init(ee_hashb);
    buf_u32(ee_hashb, n);
    buf_u32(ee_hashb, n);
    i = 0;
    while (i < n) {
        buf_u32(ee_hashb, ivec_at(buckets, i));
        i = i + 1;
    }
    i = 0;
    while (i < n) {
        buf_u32(ee_hashb, ivec_at(chains, i));
        i = i + 1;
    }
}

// ---- the section table ----
// The segment is ee_g and not a ninth parameter: MAXPARAMS is 8 in the frozen
// C seed (src/arena.mc, docs/reference/language.md), and the seed is what
// compiles this file into build/mc1.
void ee_add(i64 kind, i64 src, uptr name, i64 type, i64 flags, i64 size,
            i64 align, i64 ent) {
    set_ivec_at(ee_kind, nee, kind);
    set_ivec_at(ee_src, nee, src);
    set_ee_name_at(nee, name);
    set_ivec_at(ee_type, nee, type);
    set_ivec_at(ee_flags, nee, flags);
    set_ivec_at(ee_size, nee, size);
    set_ivec_at(ee_align, nee, align);
    set_ivec_at(ee_ent, nee, ent);
    set_ivec_at(ee_seg, nee, ee_g);
    set_ivec_at(ee_link, nee, 0);
    set_ivec_at(ee_info, nee, 0);
    set_ivec_at(ee_addr, nee, 0);
    set_ivec_at(ee_off, nee, 0);
    set_ivec_at(ee_nameoff, nee, 0);
    if (src >= 0) set_ivec_at(ee_of_sec, src, nee);
    nee = nee + 1;
}

i64 ee_find_kind(i64 kind) {
    i64 i = 0;
    while (i < nee) {
        if (ivec_at(ee_kind, i) == kind) return i;
        i = i + 1;
    }
    return 0 - 1;
}

i64 ee_seg_find(uptr nm) {
    i64 i = 0;
    while (i < neseg) {
        if (str_eq(eg_name_at(i), nm)) return i;
        i = i + 1;
    }
    return 0 - 1;
}

// One segment per distinct Mach-O segment name, in order of first appearance.
// gen_sections always makes __TEXT,__text first, so segment 0 is __TEXT and is
// the r-x one -- which is what has to hold the ELF header, the program headers
// and every read-only table the loader reads before it maps anything else.
void ee_plan_segments() {
    neseg = 0;
    i64 cap = nsections + 2;
    eg_name  = xalloc(8 * cap);
    eg_addr  = xalloc(8 * cap);
    eg_off   = xalloc(8 * cap);
    eg_fsize = xalloc(8 * cap);
    eg_msize = xalloc(8 * cap);
    i64 i = 0;
    while (i < nsections) {
        uptr nm = exe_segname(sec_seg(sec_at(i)));
        if (ee_seg_find(nm) < 0) {
            set_eg_name_at(neseg, nm);
            neseg = neseg + 1;
        }
        i = i + 1;
    }
    // the GOT and the .dynamic vector have to be writable; if the program has
    // no writable section of its own, the segment that will hold them still
    // has to exist
    if (ee_dynamic && ee_seg_find("__DATA") < 0) {
        set_eg_name_at(neseg, "__DATA");
        neseg = neseg + 1;
    }
}

// The whole file, in order: the null section, then for each segment its regular
// sections and then its zerofill ones, with the synthetic tables placed where
// the loader needs them -- the dynamic-linking tables at the front of segment 0
// (before any code), the PLT and the entry stub at its end, the GOT and
// .dynamic at the end of the writable segment's regular part. The three
// non-allocated tables come last and belong to no segment.
void ee_plan_sections() {
    nee = 0;
    i64 cap = nsections + 14;
    ee_kind    = xalloc(8 * cap);
    ee_src     = xalloc(8 * cap);
    ee_name    = xalloc(8 * cap);
    ee_nameoff = xalloc(8 * cap);
    ee_type    = xalloc(8 * cap);
    ee_flags   = xalloc(8 * cap);
    ee_addr    = xalloc(8 * cap);
    ee_off     = xalloc(8 * cap);
    ee_size    = xalloc(8 * cap);
    ee_align   = xalloc(8 * cap);
    ee_ent     = xalloc(8 * cap);
    ee_link    = xalloc(8 * cap);
    ee_info    = xalloc(8 * cap);
    ee_seg     = xalloc(8 * cap);
    ee_of_sec  = xalloc(8 * (nsections + 1));
    ee_g = 0 - 1;
    ee_add(EEK_NULL, 0 - 1, "", SHT_NULL, 0, 0, 0, 0);
    i64 datag = ee_seg_find("__DATA");
    i64 g = 0;
    while (g < neseg) {
        uptr nm = eg_name_at(g);
        ee_g = g;
        if (g == 0 && ee_dynamic) {
            ee_add(EEK_INTERP, 0 - 1, ".interp", SHT_PROGBITS, SHF_ALLOC,
                   cstrlen(ee_interp_path()) + 1, 1, 0);
            ee_add(EEK_DYNSYM, 0 - 1, ".dynsym", SHT_DYNSYM, SHF_ALLOC,
                   buf_len(ee_dynsym), 8, ELFSYM_SIZE);
            ee_add(EEK_DYNSTR, 0 - 1, ".dynstr", SHT_STRTAB, SHF_ALLOC,
                   buf_len(ee_dynstr), 1, 0);
            ee_add(EEK_HASH, 0 - 1, ".hash", SHT_HASH, SHF_ALLOC,
                   buf_len(ee_hashb), 8, 4);
            ee_add(EEK_RELAPLT, 0 - 1, ".rela.plt", SHT_RELA, SHF_ALLOC | SHF_INFO_LINK,
                   ELFRELA_SIZE * nundef, 8, ELFRELA_SIZE);
        }
        i64 i = 0;                                  // the segment's own sections
        while (i < nsections) {
            uptr s = sec_at(i);
            if (!elf_sec_zf(i) && str_eq(exe_segname(sec_seg(s)), nm))
                ee_add(EEK_MOD, i, elf_sec_name(i), elf_sec_type(i), elf_sec_flags(i),
                       elf_sec_size(i), 1 << sec_align(s), 0);
            i = i + 1;
        }
        if (g == 0) {
            if (ee_dynamic)
                ee_add(EEK_PLT, 0 - 1, ".plt", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR,
                       ee_pltent * nundef, 16, 0);
            if (ee_synth)
                ee_add(EEK_START, 0 - 1, ".text.mcstart", SHT_PROGBITS,
                       SHF_ALLOC | SHF_EXECINSTR, ee_startsz, 16, 0);
        }
        if (g == datag && ee_dynamic) {
            ee_add(EEK_GOT, 0 - 1, ".got", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE,
                   8 * nundef, 8, 8);
            ee_add(EEK_DYNAMIC, 0 - 1, ".dynamic", SHT_DYNAMIC, SHF_ALLOC | SHF_WRITE,
                   16 * (ee_nlib + 12), 8, 16);
        }
        i = 0;                                      // zerofill last: it is the
        while (i < nsections) {                     // gap between filesz and memsz
            uptr s = sec_at(i);
            if (elf_sec_zf(i) && str_eq(exe_segname(sec_seg(s)), nm))
                ee_add(EEK_MOD, i, elf_sec_name(i), elf_sec_type(i), elf_sec_flags(i),
                       elf_sec_size(i), 1 << sec_align(s), 0);
            i = i + 1;
        }
        g = g + 1;
    }
    ee_g = 0 - 1;                                   // the unloaded tables
    ee_add(EEK_SYMTAB, 0 - 1, ".symtab", SHT_SYMTAB, 0, 0, 8, ELFSYM_SIZE);
    ee_add(EEK_STRTAB, 0 - 1, ".strtab", SHT_STRTAB, 0, 0, 1, 0);
    ee_add(EEK_SHSTRTAB, 0 - 1, ".shstrtab", SHT_STRTAB, 0, 0, 1, 0);
    // .dynsym cites .dynstr, .hash and .rela.plt cite .dynsym, .rela.plt's
    // sh_info is the section its relocations act on, and .dynamic cites .dynstr
    if (ee_dynamic) {
        set_ivec_at(ee_link, ee_find_kind(EEK_DYNSYM), ee_find_kind(EEK_DYNSTR));
        set_ivec_at(ee_info, ee_find_kind(EEK_DYNSYM), 1);
        set_ivec_at(ee_link, ee_find_kind(EEK_HASH), ee_find_kind(EEK_DYNSYM));
        set_ivec_at(ee_link, ee_find_kind(EEK_RELAPLT), ee_find_kind(EEK_DYNSYM));
        set_ivec_at(ee_info, ee_find_kind(EEK_RELAPLT), ee_find_kind(EEK_PLT));
        set_ivec_at(ee_link, ee_find_kind(EEK_DYNAMIC), ee_find_kind(EEK_DYNSTR));
    }
    set_ivec_at(ee_link, ee_find_kind(EEK_SYMTAB), ee_find_kind(EEK_STRTAB));
}

// ---- addresses ----
// Every PT_LOAD starts on a page, in VM and in the file, so a section's file
// offset is always segoff + (addr - segvm) and the ELF congruence
// p_offset == p_vaddr (mod p_align) holds by construction. The header and the
// program headers live at the very start of segment 0, which is why the loop
// starts its cursor past them.
i64 ee_phnum() {
    i64 n = 1 + neseg + 1;                          // PT_PHDR, the loads, GNU_STACK
    if (ee_dynamic) n = n + 2;                      // PT_INTERP, PT_DYNAMIC
    return n;
}

void ee_layout() {
    i64 vm = EE_BASE;
    i64 fo = 0;
    i64 g = 0;
    while (g < neseg) {
        i64 segvm = vm;
        i64 segoff = fo;
        i64 cur = 0;
        if (g == 0) cur = EHDR_SIZE + PHDR_SIZE * ee_phnum();
        i64 fsz = 0;
        i64 i = 0;
        while (i < nee) {
            if (ivec_at(ee_seg, i) == g) {
                cur = exe_up(cur, ivec_at(ee_align, i));
                set_ivec_at(ee_addr, i, segvm + cur);
                if (ivec_at(ee_type, i) == SHT_NOBITS) set_ivec_at(ee_off, i, segoff + cur);
                else {
                    set_ivec_at(ee_off, i, segoff + cur);
                    fsz = cur + ivec_at(ee_size, i);
                }
                cur = cur + ivec_at(ee_size, i);
            }
            i = i + 1;
        }
        set_ivec_at(eg_addr, g, segvm);
        set_ivec_at(eg_off, g, segoff);
        set_ivec_at(eg_fsize, g, fsz);
        set_ivec_at(eg_msize, g, cur);
        vm = exe_up(segvm + cur, ee_page);
        fo = exe_up(segoff + fsz, ee_page);
        ee_filelen = segoff + fsz;
        g = g + 1;
    }
    i64 i = ee_find_kind(EEK_PLT);
    if (i >= 0) ee_plt_addr = ivec_at(ee_addr, i);
    i = ee_find_kind(EEK_GOT);
    if (i >= 0) ee_got_addr = ivec_at(ee_addr, i);
}

// ---- symbol addresses ----
// An import has no address of its own, so its PLT stub is what every reference
// to it resolves to -- a call, and equally `&write`, which is exactly the
// canonical address a linker gives a function in a non-PIE executable.
i64 ee_sym_addr(i64 sym) {
    uptr s = sym_at(sym);
    if (sym_sect(s) == 0) return ee_plt_addr + exe_undef_index(sym) * ee_pltent;
    return ivec_at(ee_addr, ivec_at(ee_of_sec, sym_sect(s) - 1)) + sym_value(s);
}

// ---- relocations, resolved in place ----
// A rel32 is measured from the byte after its own four, which is what makes the
// object writer's -4 addend unnecessary here: the displacement is computed
// against the end of the field.
void ee_fix_x86_pc32(uptr p, i64 at, i64 pc, i64 target) {
    i64 d = target - (pc + 4);
    if (d >= 2147483648 || d < 0 - 2147483648) die("pc-relative displacement out of range");
    st32(p + at, d & 0xffffffff);
}

void ee_patch_relocs() {
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (!elf_sec_zf(i)) {
            uptr p = buf_p(sec_data(s));
            i64 base = ivec_at(ee_addr, ivec_at(ee_of_sec, i));
            i64 j = 0;
            while (j < sec_nrel(s)) {
                uptr r = rel_at(sec_rel(s), j);
                i64 t = rel_type(r);
                i64 pc = base + rel_off(r);
                i64 tg = ee_sym_addr(rel_sym(r));
                if (t == R_BRANCH26)       exe_fix_branch26(p, rel_off(r), pc, tg);
                else if (t == R_PAGE21)    exe_fix_page21(p, rel_off(r), pc, tg);
                else if (t == R_PAGEOFF12) exe_fix_pageoff12(p, rel_off(r), tg);
                else if (t == R_X86_PC32)  ee_fix_x86_pc32(p, rel_off(r), pc, tg);
                else if (t == R_X86_PLT32) ee_fix_x86_pc32(p, rel_off(r), pc, tg);
                else if (t == R_UNSIGNED) {
                    if (rel_len(r) != 3) die("UNSIGNED that does not occupy 8 bytes");
                    st64(p + rel_off(r), tg);
                } else die("relocation not supported in the ELF executable");
                j = j + 1;
            }
        }
        i = i + 1;
    }
}

// ---- .rela.plt ----
// One R_*_JUMP_SLOT per import, against its .dynsym index, pointing at its GOT
// slot. The addend is 0 and the slot is written zero: DT_BIND_NOW makes the
// loader fill every one of them before the entry point runs.
void ee_build_rela() {
    buf_init(ee_relab);
    i64 rt = R_AARCH64_JUMP_SLOT;
    if (ee_em == EM_X86_64) rt = R_X86_64_JUMP_SLOT;
    i64 i = 0;
    while (i < nundef) {
        buf_u64(ee_relab, ee_got_addr + i * 8);
        buf_u32(ee_relab, rt);
        buf_u32(ee_relab, i + 1);                   // .dynsym index
        buf_u64(ee_relab, 0);
        i = i + 1;
    }
}

// ---- .dynamic ----
void ee_dt(i64 tag, i64 val) {
    buf_u64(ee_dynb, tag);
    buf_u64(ee_dynb, val);
}

i64 ee_addr_of(i64 kind) { return ivec_at(ee_addr, ee_find_kind(kind)); }

void ee_build_dynamic() {
    buf_init(ee_dynb);
    i64 i = 0;
    while (i < ee_nlib) {                           // the default first, then #dylib
        ee_dt(DT_NEEDED, ivec_at(ee_liboff, i));
        i = i + 1;
    }
    ee_dt(DT_STRTAB, ee_addr_of(EEK_DYNSTR));
    ee_dt(DT_SYMTAB, ee_addr_of(EEK_DYNSYM));
    ee_dt(DT_STRSZ, buf_len(ee_dynstr));
    ee_dt(DT_SYMENT, ELFSYM_SIZE);
    ee_dt(DT_HASH, ee_addr_of(EEK_HASH));
    ee_dt(DT_PLTGOT, ee_got_addr);
    ee_dt(DT_JMPREL, ee_addr_of(EEK_RELAPLT));
    ee_dt(DT_PLTRELSZ, ELFRELA_SIZE * nundef);
    ee_dt(DT_PLTREL, DT_RELA);
    ee_dt(DT_FLAGS, DF_BIND_NOW);
    ee_dt(DT_FLAGS_1, DF_1_NOW);
    ee_dt(DT_NULL, 0);
}

// ---- .symtab and .strtab ----
// The executable keeps a full symbol table -- the same one the object has, with
// final addresses -- because it costs a few kilobytes and it is what makes
// `llvm-nm`, `llvm-objdump -d` and a debugger's backtrace read an mc binary.
// It is not loaded: no segment covers it.
void ee_build_symtab(uptr order, uptr strx) {
    buf_init(ee_symb);
    i64 i = 0;
    while (i < ELFSYM_SIZE) {
        buf_u8(ee_symb, 0);
        i = i + 1;
    }
    i64 k = 0;
    while (k < nsymbols) {
        i64 oi = ivec_at(order, k);
        uptr s = sym_at(oi);
        buf_u32(ee_symb, ivec_at(strx, oi));
        buf_u8(ee_symb, (elf_sym_bind(s) << 4) | elf_sym_type(s));
        buf_u8(ee_symb, 0);
        if (sym_sect(s) == 0) {
            buf_u16(ee_symb, SHN_UNDEF);
            buf_u64(ee_symb, 0);
        } else {
            buf_u16(ee_symb, ivec_at(ee_of_sec, sym_sect(s) - 1));
            buf_u64(ee_symb, ee_sym_addr(oi));
        }
        buf_u64(ee_symb, 0);                        // st_size: the core has none
        k = k + 1;
    }
}

void ee_build_strtab(uptr strx) {
    buf_init(ee_strb);
    buf_u8(ee_strb, 0);
    i64 k = 0;
    while (k < nsymbols) {
        uptr n = elf_sym_name(sym_name(sym_at(k)));
        set_ivec_at(strx, k, buf_len(ee_strb));
        buf_put(ee_strb, n, cstrlen(n) + 1);
        k = k + 1;
    }
}

void ee_build_shstr() {
    buf_init(ee_shstrb);
    buf_u8(ee_shstrb, 0);
    i64 i = 0;
    while (i < nee) {
        uptr n = ee_name_at(i);
        if (cstrlen(n) == 0) set_ivec_at(ee_nameoff, i, 0);
        else {
            set_ivec_at(ee_nameoff, i, buf_len(ee_shstrb));
            buf_put(ee_shstrb, n, cstrlen(n) + 1);
        }
        i = i + 1;
    }
}

// ---- synthetic content ----
// PLT stub k, aarch64: adrp x16, slot page ; ldr x17, [x16, #lo12] ; br x17.
// x86-64: jmp qword ptr [rip + slot] ; int3 ; int3. Nothing else: BIND_NOW
// means the slot already holds the callee when the stub first runs.
void ee_put_plt(uptr o) {
    i64 k = 0;
    while (k < nundef) {
        i64 pc = ee_plt_addr + k * ee_pltent;
        i64 slot = ee_got_addr + k * 8;
        if (ee_em == EM_X86_64) {
            buf_u8(o, 0xff);
            buf_u8(o, 0x25);
            buf_u32(o, (slot - (pc + 6)) & 0xffffffff);
            buf_u8(o, 0xcc);
            buf_u8(o, 0xcc);
        } else {
            i64 im = ((slot & ~4095) - (pc & ~4095)) / 4096;
            buf_u32(o, 0x90000010 | ((im & 3) << 29) | (((im >> 2) & 0x7ffff) << 5));
            buf_u32(o, 0xf9400211 | (((slot & 4095) / 8) << 10));
            buf_u32(o, 0xd61f0220);                 // br x17
            buf_u32(o, 0xd503201f);                 // nop, to a 16-byte stub
        }
        k = k + 1;
    }
}

// The entry point, when the program does not bring its own. The kernel enters
// with sp pointing at the entry stack -- argc, then argv[0..argc-1], then a
// NULL, then envp -- and every other register undefined, so argc, argv and envp
// are three loads from sp and `main` is called like any other function.
// The exit is exit_group by raw syscall, which is what lets this stub work
// with no import and therefore in the static case too.
void ee_put_start(uptr o, i64 pc) {
    i64 target = ee_sym_addr(ee_mainsym);
    if (ee_em == EM_X86_64) {
        buf_u8(o, 0x31); buf_u8(o, 0xed);                       // xor ebp, ebp
        buf_u8(o, 0x48); buf_u8(o, 0x8b); buf_u8(o, 0x3c); buf_u8(o, 0x24);
        buf_u8(o, 0x48); buf_u8(o, 0x8d); buf_u8(o, 0x74); buf_u8(o, 0x24); buf_u8(o, 0x08);
        buf_u8(o, 0x48); buf_u8(o, 0x8d); buf_u8(o, 0x54); buf_u8(o, 0x24); buf_u8(o, 0x10);
        buf_u8(o, 0x48); buf_u8(o, 0x8d); buf_u8(o, 0x14); buf_u8(o, 0xfa);
        i64 d = target - (pc + 25);
        if (d >= 2147483648 || d < 0 - 2147483648) die("main is out of call range");
        buf_u8(o, 0xe8);
        buf_u32(o, d & 0xffffffff);
        buf_u8(o, 0x89); buf_u8(o, 0xc7);                       // mov edi, eax
        buf_u8(o, 0xb8); buf_u32(o, 231);                       // mov eax, exit_group
        buf_u8(o, 0x0f); buf_u8(o, 0x05);                       // syscall
    } else {
        buf_u32(o, 0xf94003e0);                                 // ldr x0, [sp]
        buf_u32(o, 0x910023e1);                                 // add x1, sp, #8
        buf_u32(o, 0x910043e2);                                 // add x2, sp, #16
        buf_u32(o, 0x8b000c42);                                 // add x2, x2, x0, lsl #3
        i64 d = target - (pc + 16);
        if (d % 4 != 0) die("misaligned main");
        if (d >= 128 * 1024 * 1024 || d < 0 - 128 * 1024 * 1024) die("main is out of bl range");
        buf_u32(o, 0x94000000 | ((d / 4) & 0x3ffffff));
        buf_u32(o, 0xd2800bc8);                                 // movz x8, #94
        buf_u32(o, 0xd4000001);                                 // svc #0
    }
}

// ---- program headers ----
void ee_ph(uptr o, i64 type, i64 flags, i64 off, i64 vaddr, i64 fsz, i64 msz, i64 align) {
    buf_u32(o, type);
    buf_u32(o, flags);
    buf_u64(o, off);
    buf_u64(o, vaddr);
    buf_u64(o, vaddr);                              // p_paddr: the same
    buf_u64(o, fsz);
    buf_u64(o, msz);
    buf_u64(o, align);
}

// PT_PHDR, PT_INTERP, one PT_LOAD per segment, PT_DYNAMIC, PT_GNU_STACK. The
// stack header is RW and never X, which is the executable-side counterpart of
// the `.note.GNU-stack` an object carries: without it a loader may fall back to
// an executable stack.
void ee_put_phdrs(uptr o) {
    ee_ph(o, PT_PHDR, PF_R, EHDR_SIZE, EE_BASE + EHDR_SIZE,
          PHDR_SIZE * ee_phnum(), PHDR_SIZE * ee_phnum(), 8);
    if (ee_dynamic) {
        i64 i = ee_find_kind(EEK_INTERP);
        ee_ph(o, PT_INTERP, PF_R, ivec_at(ee_off, i), ivec_at(ee_addr, i),
              ivec_at(ee_size, i), ivec_at(ee_size, i), 1);
    }
    i64 g = 0;
    while (g < neseg) {
        i64 fl = PF_R | PF_W;
        if (str_eq(eg_name_at(g), "__TEXT")) fl = PF_R | PF_X;
        ee_ph(o, PT_LOAD, fl, ivec_at(eg_off, g), ivec_at(eg_addr, g),
              ivec_at(eg_fsize, g), ivec_at(eg_msize, g), ee_page);
        g = g + 1;
    }
    if (ee_dynamic) {
        i64 i = ee_find_kind(EEK_DYNAMIC);
        ee_ph(o, PT_DYNAMIC, PF_R | PF_W, ivec_at(ee_off, i), ivec_at(ee_addr, i),
              ivec_at(ee_size, i), ivec_at(ee_size, i), 8);
    }
    ee_ph(o, PT_GNU_STACK, PF_R | PF_W, 0, 0, 0, 0, 16);
}

// ---- headers ----
void ee_put_ehdr(uptr o) {
    buf_u8(o, 0x7f); buf_u8(o, 'E'); buf_u8(o, 'L'); buf_u8(o, 'F');
    buf_u8(o, ELFCLASS64);
    buf_u8(o, ELFDATA2LSB);
    buf_u8(o, EV_CURRENT);
    buf_u8(o, 0);                                   // EI_OSABI: System V
    buf_u8(o, 0);                                   // EI_ABIVERSION
    i64 i = 0;
    while (i < 7) {
        buf_u8(o, 0);
        i = i + 1;
    }
    buf_u16(o, ET_EXEC);
    buf_u16(o, ee_em);
    buf_u32(o, EV_CURRENT);
    buf_u64(o, ee_entry);
    buf_u64(o, EHDR_SIZE);                          // e_phoff
    buf_u64(o, ee_shoff);
    buf_u32(o, 0);                                  // e_flags
    buf_u16(o, EHDR_SIZE);
    buf_u16(o, PHDR_SIZE);
    buf_u16(o, ee_phnum());
    buf_u16(o, SHDR_SIZE);
    buf_u16(o, nee);
    buf_u16(o, ee_find_kind(EEK_SHSTRTAB));
}

void ee_put_shdr(uptr o, i64 i) {
    buf_u32(o, ivec_at(ee_nameoff, i));
    buf_u32(o, ivec_at(ee_type, i));
    buf_u64(o, ivec_at(ee_flags, i));
    buf_u64(o, ivec_at(ee_addr, i));
    buf_u64(o, ivec_at(ee_off, i));
    buf_u64(o, ivec_at(ee_size, i));
    buf_u32(o, ivec_at(ee_link, i));
    buf_u32(o, ivec_at(ee_info, i));
    buf_u64(o, ivec_at(ee_align, i));
    buf_u64(o, ivec_at(ee_ent, i));
}

// ---- writing ----
// the content of one section, at the offset the layout gave it
void ee_put_section(uptr o, i64 i) {
    i64 k = ivec_at(ee_kind, i);
    if (k == EEK_MOD) {
        uptr s = sec_at(ivec_at(ee_src, i));
        buf_put(o, buf_p(sec_data(s)), buf_len(sec_data(s)));
    }
    else if (k == EEK_INTERP)  buf_put(o, ee_interp_path(), cstrlen(ee_interp_path()) + 1);
    else if (k == EEK_DYNSYM)  buf_put(o, buf_p(ee_dynsym), buf_len(ee_dynsym));
    else if (k == EEK_DYNSTR)  buf_put(o, buf_p(ee_dynstr), buf_len(ee_dynstr));
    else if (k == EEK_HASH)    buf_put(o, buf_p(ee_hashb), buf_len(ee_hashb));
    else if (k == EEK_RELAPLT) buf_put(o, buf_p(ee_relab), buf_len(ee_relab));
    else if (k == EEK_PLT)     ee_put_plt(o);
    else if (k == EEK_START)   ee_put_start(o, ivec_at(ee_addr, i));
    else if (k == EEK_GOT) {
        i64 j = 0;
        while (j < nundef) {                        // zero: the loader fills them
            buf_u64(o, 0);
            j = j + 1;
        }
    }
    else if (k == EEK_DYNAMIC)  buf_put(o, buf_p(ee_dynb), buf_len(ee_dynb));
    else if (k == EEK_SYMTAB)   buf_put(o, buf_p(ee_symb), buf_len(ee_symb));
    else if (k == EEK_STRTAB)   buf_put(o, buf_p(ee_strb), buf_len(ee_strb));
    else if (k == EEK_SHSTRTAB) buf_put(o, buf_p(ee_shstrb), buf_len(ee_shstrb));
}

// The entry point. A program that brings its own `_start` (lib/sys_linux.mc,
// which the compiler compiles for the no-libc case) keeps it and no stub is
// written; anything else is entered through the stub above, which needs `main`.
void ee_pick_entry() {
    ee_synth = 0;
    i64 s = sym_find("__start");                    // the compiler prefixes `_`
    if (s >= 0 && sym_sect(sym_at(s)) != 0) return;
    ee_mainsym = sym_find("_main");
    if (ee_mainsym < 0 || sym_sect(sym_at(ee_mainsym)) == 0)
        die("no main and no _start: cannot generate an executable");
    ee_synth = 1;
}

void ee_write(uptr path) {
    exe_collect_undef();
    ee_dynamic = nundef > 0;
    ee_nlib = 1 + dylib_count();
    ee_pick_entry();

    ee_build_dynstr();
    ee_build_dynsym();
    ee_build_hash();

    ee_plan_segments();
    ee_plan_sections();
    ee_layout();

    if (ee_synth) ee_entry = ivec_at(ee_addr, ee_find_kind(EEK_START));
    else          ee_entry = ee_sym_addr(sym_find("__start"));

    ee_patch_relocs();
    ee_build_rela();
    if (ee_dynamic) ee_build_dynamic();

    uptr order = xalloc(8 * (nsymbols + 1));
    uptr pos   = xalloc(8 * (nsymbols + 1));
    uptr strx  = xalloc(8 * (nsymbols + 1));
    u8   count[24];
    sym_order(order, pos, count);
    ee_build_strtab(strx);
    ee_build_symtab(order, strx);

    // the three unloaded tables go after the last loaded byte, on 8, and the
    // section headers after them
    i64 cur = exe_up(ee_filelen, 8);
    i64 i = ee_find_kind(EEK_SYMTAB);
    set_ivec_at(ee_size, i, buf_len(ee_symb));
    set_ivec_at(ee_off, i, cur);
    set_ivec_at(ee_info, i, ivec_at(count, 0) + 1); // null + the locals
    cur = cur + buf_len(ee_symb);
    i = ee_find_kind(EEK_STRTAB);
    set_ivec_at(ee_size, i, buf_len(ee_strb));
    set_ivec_at(ee_off, i, cur);
    cur = cur + buf_len(ee_strb);
    ee_build_shstr();
    i = ee_find_kind(EEK_SHSTRTAB);
    set_ivec_at(ee_size, i, buf_len(ee_shstrb));
    set_ivec_at(ee_off, i, cur);
    cur = cur + buf_len(ee_shstrb);
    ee_shoff = exe_up(cur, 8);

    u8 o[BUF_SIZE];
    buf_init(o);
    ee_put_ehdr(o);
    ee_put_phdrs(o);
    i = 1;
    while (i < nee) {
        if (ivec_at(ee_type, i) != SHT_NOBITS) {
            while (buf_len(o) < ivec_at(ee_off, i)) {
                buf_u8(o, 0);
            }
            ee_put_section(o, i);
        }
        i = i + 1;
    }
    while (buf_len(o) < ee_shoff) {
        buf_u8(o, 0);
    }
    i = 0;
    while (i < nee) {
        ee_put_shdr(o, i);
        i = i + 1;
    }
    exe_write_file(path, o);
}

// the backends themselves. Like every writer since M17 step B, each one names
// its machine first: the file format records the architecture, so the backend
// is what knows which instruction set this executable is made of.
void backend_elf_exe(i64 root, uptr out) {
    machine_use("arm64");
    ee_em = EM_AARCH64;
    ee_page = EE_PAGE_A64;
    ee_pltent = EE_PLT_A64;
    ee_startsz = EE_START_A64;
    gen_lower(root);
    gen_encode_all();
    ee_write(out);
}

void backend_elf_exe_x86(i64 root, uptr out) {
    machine_use("x86_64");
    ee_em = EM_X86_64;
    ee_page = EE_PAGE_X86;
    ee_pltent = EE_PLT_X86;
    ee_startsz = EE_START_X86;
    gen_lower(root);
    gen_encode_all();
    ee_write(out);
}
