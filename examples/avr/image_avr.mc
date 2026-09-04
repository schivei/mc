// image_avr.mc — the `avr-image` backend: an ELF32 `EM_AVR` firmware image for
// an ATmega328P, written by a module (M40, docs/specs/M40.md § 4, D5).
//
// It is examples/kernel/image.mc one architecture over, with a container back
// on: a bare RISC-V board takes a flat blob, and both AVR oracles take ELF --
// and only ELF carries the `.mmcu` section, which is simavr's exit channel.
// src/backend_elf.mc cannot be reused for one reason that is not negotiable:
// it is ELFCLASS64 throughout (`EHDR_SIZE 64`, 64-bit fields), and this is a
// 32-bit ELF for an 8-bit machine.
//
// What is Harvard about it (docs/specs/M40.md D7). Code lives in flash and data
// in SRAM, `ld`/`st` reach SRAM only, and the language has one flat address
// space. So the writer lays the initialized data TWICE: at its run address in
// SRAM (the VMA every relocation uses) and, byte for byte, at a LOAD address in
// flash -- and examples/avr/lib/sys_avr.mc's `_start` copies one to the other
// with the `lpm8` intrinsic before anything else runs. Every `ld8(p)` in the
// language then works with no address-space discipline in the source.
//
//     flash 0x0000  the interrupt vector table, 26 x `jmp`, SYNTHESIZED here
//     flash 0x0068  __TEXT,__text and every other instruction section
//                   .mmcu, the simavr blob
//                   the LOAD image of __TEXT,__cstring and __DATA,__data
//     sram  0x0100  __TEXT,__cstring )  the RUN addresses: what a pointer
//                   __DATA,__data    )  in the program actually holds
//                   __DATA,__bss     )  zeroed by _start
//     sram  0x08FF  RAMEND: _stack_top, and SP before the first push
//
// The three relocations that can reach here:
//
//   AVRK_ADDR16 (34)  two `ldi` halves      lo8/hi8 of a symbol's address
//   AVRK_CALL22 (35)  a 4-byte jmp/call     the symbol's WORD address
//   R_BRANCH26  (2)   the same, from reloc() in the source -- the only kind
//                     the surface can spell (docs/specs/M39.md § G2)
//   R_UNSIGNED  (0)   two bytes in __data   a pointer in an initializer, two
//                     bytes because the compiler declared uptr as two
//
// Depends on objmodel.mc (sections, symbols, relocations), gen_walk.mc
// (gen_lower / gen_encode_all) and arena.mc (buf_*, write_file, die).

#include "../../lib/prelude.mc"

#define AVR_NVEC     26               // ATmega328P: RESET plus 25 interrupts
#define AVR_VECSIZE   4               // each entry is one `jmp`
#define AVR_STUB     16               // the reset stub's fixed size, in bytes
#define AVR_SRAM  0x0100              // the first byte of SRAM on this part
#define AVR_RAMEND 0x08ff             // the last one: SP starts here
#define AVR_FLASH  0x8000             // 32 KiB, the whole program memory
#define AVR_DATA_SEG 0x800000         // the AVR ELF convention for data space
#define AVR_FREQ  16000000

// the simavr .mmcu tags this image uses (avr_mcu_section.h, verified against a
// reference ELF built by avr-gcc -- docs/specs/M40.md risk 4)
#define MMCU_NAME      1              // {u8 tag, u8 len=64, char[64]}
#define MMCU_FREQ      2              // {u8 tag, u8 len=4,  u32}
#define MMCU_COMMAND  10              // {u8 tag, u8 len=2,  u16 data address}
#define SIMAVR_GPIOR1 0x4a            // the command register the program writes

uptr img_addr;                        // absolute address of each module section
i64  img_text_end  = 0;               // end of the code half, in flash
i64  img_mmcu      = 0;               // flash address of .mmcu
i64  img_lma       = 0;               // flash address of the data image
i64  img_data      = 0;               // SRAM address of the data image
i64  img_data_end  = 0;
i64  img_bss_start = 0;
i64  img_bss_end   = 0;

i64  img_addr_at(i64 i)            { return ld64(img_addr + i * 8); }
void set_img_addr_at(i64 i, i64 v) { st64(img_addr + i * 8, v); }

i64 img_zerofill(uptr s) { return (sec_flags(s) & 0xff) == S_ZEROFILL; }
i64 img_code(uptr s)     { return (sec_flags(s) & S_ATTR_PURE_INSTRUCTIONS) != 0; }

i64 img_align_up(i64 v, i64 a) {
    if (v % a == 0) return v;
    return v + a - v % a;
}

// ---- 1. placement ----
// Three passes over the sections in CREATION order: what executes, what is
// initialized, what is only addressed. The vector table takes the first
// AVR_NVEC * 4 bytes of flash, which is why no code can start below 0x68.
void img_place() {
    img_addr = xalloc(8 * (nsections + 1));
    i64 cur = AVR_NVEC * AVR_VECSIZE + AVR_STUB;
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (img_code(s) && !img_zerofill(s)) {
            cur = img_align_up(cur, 2);
            set_img_addr_at(i, cur);
            cur = cur + buf_len(sec_data(s));
        }
        i = i + 1;
    }
    img_text_end = img_align_up(cur, 2);
    img_mmcu = img_text_end;
    img_lma = img_mmcu + img_mmcu_size();
    // the initialized data: one contiguous run, at its RUN address in SRAM and
    // at img_lma in flash, in the same order and with the same padding
    i64 lma = img_lma;
    i64 ram = AVR_SRAM;
    img_data = ram;
    i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (!img_code(s) && !img_zerofill(s)) {
            i64 a = 1 << sec_align(s);
            if (a > 2) a = 2;                    // an 8-bit part aligns to bytes
            ram = img_align_up(ram, a);
            lma = img_lma + (ram - img_data);
            set_img_addr_at(i, ram);
            ram = ram + buf_len(sec_data(s));
        }
        i = i + 1;
    }
    img_data_end = ram;
    img_bss_start = ram;
    i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (img_zerofill(s)) {
            i64 a = 1 << sec_align(s);
            if (a > 2) a = 2;
            ram = img_align_up(ram, a);
            set_img_addr_at(i, ram);
            ram = ram + sec_zsize(s);
        }
        i = i + 1;
    }
    img_bss_end = ram;
    if (img_bss_end > AVR_RAMEND - 64)
        die("avr: the image does not fit in 2 KiB of SRAM");
}

// ---- 2. symbols ----
void img_rebase_syms() {
    i64 i = 0;
    while (i < nsymbols) {
        uptr s = sym_at(i);
        if (sym_sect(s) != 0) sym_set_value(i, img_addr_at(sym_sect(s) - 1) + sym_value(s));
        i = i + 1;
    }
}

// The six the system layer may reference. They are declared there as extern
// FUNCTIONS and used only through `&name` -- mc has no extern variable -- which
// is the idiom C uses for a linker-defined symbol, with `ld`'s job done here.
void img_define(uptr name, i64 value) { sym_new(name, 1, value, 0); }

void img_synth_syms() {
    img_define("_data_start", img_data);
    img_define("_data_end",   img_data_end);
    img_define("_data_lma",   img_lma);
    img_define("_bss_start",  img_bss_start);
    img_define("_bss_end",    img_bss_end);
    img_define("_stack_top",  AVR_RAMEND);
}

// ---- 3. relocations ----
// `ldi Rd, K` carries K in two nibbles, bits 11:8 and 3:0, so a byte is written
// into an instruction word rather than into memory.
void img_put_ldi(uptr p, i64 at, i64 k) {
    i64 w = ld16(p + at);
    st16(p + at, (w & 0xf0f0) | ((k & 0xf0) << 4) | (k & 0x0f));
}

// `jmp`/`call` address a WORD, and the 22 bits are split: k21..k17 in the first
// word's bits 8:4, k16 in its bit 0, k15..k0 in the second word.
void img_put_call(uptr p, i64 at, i64 target) {
    if (target % 2 != 0) die("avr: a call target is not word aligned");
    i64 k = target / 2;
    if (k > 0x3fffff) die("avr: a call target is past the 22-bit field");
    st16(p + at, (ld16(p + at) & 0xfe0e) | (((k >> 17) & 0x1f) << 4) | ((k >> 16) & 1));
    st16(p + at + 2, k & 0xffff);
}

void img_relocate() {
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (!img_zerofill(s)) {
            uptr p = buf_p(sec_data(s));
            i64 j = 0;
            while (j < sec_nrel(s)) {
                uptr r = rel_at(sec_rel(s), j);
                uptr sy = sym_at(rel_sym(r));
                if (sym_sect(sy) == 0) die2("undefined symbol", sym_name(sy));
                i64 t = rel_type(r);
                i64 v = sym_value(sy);
                if (t == AVRK_ADDR16) {
                    img_put_ldi(p, rel_off(r), v & 0xff);
                    img_put_ldi(p, rel_off(r) + 2, (v >> 8) & 0xff);
                } else if (t == AVRK_CALL22 || t == R_BRANCH26) {
                    img_put_call(p, rel_off(r), v);
                } else if (t == R_UNSIGNED) {
                    st16(p + rel_off(r), v & 0xffff);
                } else {
                    die("relocation not supported in an avr image");
                }
                j = j + 1;
            }
        }
        i = i + 1;
    }
}

// ---- 4. the vector table ----
// The one place this writer synthesizes code rather than placing it, the same
// licence examples/kernel/image.mc takes with its reset stub and
// src/backend_exe.mc with __stubs. Entry 0 is the reset vector and has to be a
// `jmp` to `_start`, because a function lands in __text in DEFINITION order and
// nothing makes the system layer first. Every other entry goes to the handler
// the program defined as `vector_<N>`, or back to 0 -- which is what avr-gcc's
// own `__bad_interrupt` does.
void img_put_vector(uptr b, i64 target) {
    i64 k = target / 2;
    buf_u16(b, 0x940c | (((k >> 17) & 0x1f) << 4) | ((k >> 16) & 1));
    buf_u16(b, k & 0xffff);
}

uptr img_vec_name(i64 n) {
    uptr s = xalloc(16);
    st8(s, '_');
    st8(s + 1, 'v');
    st8(s + 2, 'e');
    st8(s + 3, 'c');
    st8(s + 4, 't');
    st8(s + 5, 'o');
    st8(s + 6, 'r');
    st8(s + 7, '_');
    i64 k = 8;
    if (n >= 10) {
        st8(s + k, '0' + n / 10);
        k = k + 1;
    }
    st8(s + k, '0' + n % 10);
    st8(s + k + 1, 0);
    return s;
}

void img_put_vectors(uptr b) {
    img_put_vector(b, AVR_NVEC * AVR_VECSIZE);   // reset: the stub below
    i64 n = 1;
    while (n < AVR_NVEC) {
        i64 k = sym_find(img_vec_name(n));
        i64 target = 0;
        if (k >= 0 && sym_sect(sym_at(k)) != 0) target = sym_value(sym_at(k));
        img_put_vector(b, target);
        n = n + 1;
    }
}

// The reset stub, and the second place this writer synthesizes code. An AVR
// comes out of reset with SP at whatever the part's reset value is, and the
// compiler's frame record is UNCONDITIONAL -- `_start`'s own `push r29` is the
// first instruction of the program and it has to go somewhere real. Nothing
// below the vector table can set SP, so the writer does: it is what decided
// where the stack is. Then a `jmp` to `_start`, because functions land in
// __text in DEFINITION order and the system layer is only one file of several.
//
// Fixed AVR_STUB bytes, padded with `nop`, so the placement above does not
// depend on how this happens to be spelled.
void img_put_stub(uptr b) {
    i64 si = sym_find("__start");
    if (si < 0) die("the image has no _start");
    i64 at = buf_len(b);
    buf_u16(b, avr_ldi_w(AR_Y, AVR_RAMEND & 0xff));
    buf_u16(b, avr_ldi_w(AR_Y + 1, (AVR_RAMEND >> 8) & 0xff));
    buf_u16(b, avr_out_w(IO_SPH, AR_Y + 1));
    buf_u16(b, avr_out_w(IO_SPL, AR_Y));
    img_put_vector(b, sym_value(sym_at(si)));    // `jmp _start`, the same words
    while (buf_len(b) - at < AVR_STUB) { buf_u16(b, 0); }
    if (buf_len(b) - at != AVR_STUB) die("avr: the reset stub does not fit");
}

// ---- 5. the .mmcu section ----
// A byte-exact blob simavr reads out of the ELF: without it the simulator does
// not know which part this is, and there is no way to end the run with a
// verdict. The layout is avr_mcu_section.h's three packed records, checked
// against `avr-objdump -s -j .mmcu` of a reference ELF.
i64 img_mmcu_size() { return 4 + 6 + 66 + 2; }

void img_put_mmcu(uptr b) {
    buf_u8(b, MMCU_COMMAND);                     // {tag, len, u16}
    buf_u8(b, 2);
    buf_u16(b, SIMAVR_GPIOR1);
    buf_u8(b, MMCU_FREQ);                        // {tag, len, u32}
    buf_u8(b, 4);
    buf_u32(b, AVR_FREQ);
    buf_u8(b, MMCU_NAME);                        // {tag, len, char[64]}
    buf_u8(b, 64);
    buf_put(b, "atmega328p", 10);
    i64 i = 10;
    while (i < 64) {
        buf_u8(b, 0);
        i = i + 1;
    }
    buf_u8(b, 0);                                // the terminating tag
    buf_u8(b, 0);
}

// ---- 6. the ELF32 container ----
#define EHDR_SIZE 52
#define PHDR_SIZE 32
#define SHDR_SIZE 40
#define SYM_ELF_SIZE 16
#define EM_AVR 83
#define EF_AVR5 5

uptr img_shstr;                       // the section name table, built once
uptr img_strtab;                      // the symbol name table
uptr img_symtab;                      // the symbol records
i64  img_nsym = 0;
i64  img_shname[8];                   // sh_name offset of each section header

i64  img_shname_at(i64 i)            { return ld64(img_shname + i * 8); }
void set_img_shname_at(i64 i, i64 v) { st64(img_shname + i * 8, v); }

i64 img_str_add(uptr t, uptr s) {
    i64 off = buf_len(t);
    buf_put(t, s, cstrlen(s));
    buf_u8(t, 0);
    return off;
}

// The ELF symbol name of a module symbol: the compiler's leading `_` goes (so
// `_main` is `main`, exactly as src/backend_elf.mc does it) and a string label
// becomes an assembler temporary.
uptr img_sym_name(uptr n) {
    if (ld8(n) == '_') return n + 1;
    return n;
}

// which ELF section a module section belongs to: 1 .text, 3 .data, 4 .bss
i64 img_shndx(i64 sect) {
    if (sect == 0) return 0;
    uptr s = sec_at(sect - 1);
    if (img_zerofill(s)) return 4;
    if (img_code(s)) return 1;
    return 3;
}

void img_put_sym(uptr t, i64 name, i64 value, i64 info, i64 shndx) {
    buf_u32(t, name);
    buf_u32(t, value);
    buf_u32(t, 0);                               // st_size: not tracked
    buf_u8(t, info);
    buf_u8(t, 0);
    buf_u16(t, shndx);
    img_nsym = img_nsym + 1;
}

// Locals first, then globals: ELF requires it and sh_info is the boundary.
// The module's own stable partition (sym_order, src/objmodel.mc) is what the
// Mach-O, ELF64 and COFF writers use for exactly the same reason.
i64 img_build_symtab() {
    img_strtab = xalloc(BUF_SIZE);
    buf_init(img_strtab);
    img_symtab = xalloc(BUF_SIZE);
    buf_init(img_symtab);
    buf_u8(img_strtab, 0);
    img_put_sym(img_symtab, 0, 0, 0, 0);         // the mandatory null symbol
    i64 nlocal = 1;
    i64 pass = 0;
    while (pass < 2) {
        i64 i = 0;
        while (i < nsymbols) {
            uptr s = sym_at(i);
            i64 g = sym_global(s);
            if (sym_sect(s) == 0) g = 1;
            if (g == pass) {
                i64 info = 1;                    // OBJECT
                if (img_shndx(sym_sect(s)) == 1) info = 2;   // FUNC
                if (sym_sect(s) == 0) info = 0;              // NOTYPE
                if (pass == 1) info = info + 16;             // GLOBAL binding
                img_put_sym(img_symtab, img_str_add(img_strtab, img_sym_name(sym_name(s))),
                            sym_value(s), info, img_shndx(sym_sect(s)));
                if (pass == 0) nlocal = nlocal + 1;
            }
            i = i + 1;
        }
        pass = pass + 1;
    }
    return nlocal;
}

void img_shdr(uptr b, i64 name, i64 type, i64 flags, i64 addr, i64 off,
              i64 size, i64 link, i64 info, i64 align, i64 entsize) {
    buf_u32(b, name);
    buf_u32(b, type);
    buf_u32(b, flags);
    buf_u32(b, addr);
    buf_u32(b, off);
    buf_u32(b, size);
    buf_u32(b, link);
    buf_u32(b, info);
    buf_u32(b, align);
    buf_u32(b, entsize);
}

void img_phdr(uptr b, i64 type, i64 off, i64 vaddr, i64 paddr,
              i64 filesz, i64 memsz, i64 flags, i64 align) {
    buf_u32(b, type);
    buf_u32(b, off);
    buf_u32(b, vaddr);
    buf_u32(b, paddr);
    buf_u32(b, filesz);
    buf_u32(b, memsz);
    buf_u32(b, flags);
    buf_u32(b, align);
}

void avr_image_write(uptr path) {
    img_place();
    img_rebase_syms();
    img_synth_syms();
    img_relocate();

    // the flash image: vectors, code, .mmcu, then the LOAD copy of the data
    uptr flash = xalloc(BUF_SIZE);
    buf_init(flash);
    img_put_vectors(flash);
    img_put_stub(flash);
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (img_code(s) && !img_zerofill(s)) {
            buf_pad(flash, 2);
            buf_put(flash, buf_p(sec_data(s)), buf_len(sec_data(s)));
        }
        i = i + 1;
    }
    buf_pad(flash, 2);
    if (buf_len(flash) != img_mmcu) die("avr: the code layout disagrees with the bytes");
    img_put_mmcu(flash);
    if (buf_len(flash) != img_lma) die("avr: the .mmcu layout disagrees with the bytes");
    i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (!img_code(s) && !img_zerofill(s)) {
            // flash byte L holds SRAM address img_data + (L - img_lma), so a
            // gap the SRAM placement left is a gap here too
            while (img_data + buf_len(flash) - img_lma < img_addr_at(i)) { buf_u8(flash, 0); }
            buf_put(flash, buf_p(sec_data(s)), buf_len(sec_data(s)));
        }
        i = i + 1;
    }
    i64 datasz = img_data_end - img_data;
    i64 flashsz = buf_len(flash);
    // The other half of the part's size, and the one a linker script would
    // have carried: 32 KiB of program memory, vector table, code, .mmcu and the
    // load image of the data all together.
    if (flashsz > AVR_FLASH) die("avr: the image does not fit in 32 KiB of flash");

    i64 nlocal = img_build_symtab();
    img_shstr = xalloc(BUF_SIZE);
    buf_init(img_shstr);
    buf_u8(img_shstr, 0);
    set_img_shname_at(1, img_str_add(img_shstr, ".text"));
    set_img_shname_at(2, img_str_add(img_shstr, ".mmcu"));
    set_img_shname_at(3, img_str_add(img_shstr, ".data"));
    set_img_shname_at(4, img_str_add(img_shstr, ".bss"));
    set_img_shname_at(5, img_str_add(img_shstr, ".symtab"));
    set_img_shname_at(6, img_str_add(img_shstr, ".strtab"));
    set_img_shname_at(7, img_str_add(img_shstr, ".shstrtab"));

    i64 nph = 3;
    i64 off_flash = EHDR_SIZE + nph * PHDR_SIZE;
    i64 off_sym = off_flash + flashsz;
    i64 off_str = off_sym + buf_len(img_symtab);
    i64 off_shstr = off_str + buf_len(img_strtab);
    i64 off_sh = off_shstr + buf_len(img_shstr);

    uptr b = xalloc(BUF_SIZE);
    buf_init(b);
    buf_u8(b, 0x7f);
    buf_u8(b, 'E');
    buf_u8(b, 'L');
    buf_u8(b, 'F');
    buf_u8(b, 1);                                // ELFCLASS32
    buf_u8(b, 1);                                // ELFDATA2LSB
    buf_u8(b, 1);                                // EV_CURRENT
    i = 7;
    while (i < 16) {
        buf_u8(b, 0);
        i = i + 1;
    }
    buf_u16(b, 2);                               // ET_EXEC
    buf_u16(b, EM_AVR);
    buf_u32(b, 1);
    buf_u32(b, 0);                               // e_entry: the reset vector
    buf_u32(b, EHDR_SIZE);
    buf_u32(b, off_sh);
    buf_u32(b, EF_AVR5);
    buf_u16(b, EHDR_SIZE);
    buf_u16(b, PHDR_SIZE);
    buf_u16(b, nph);
    buf_u16(b, SHDR_SIZE);
    buf_u16(b, 8);
    buf_u16(b, 7);

    // flash, then the data at its run address with the flash copy as p_paddr,
    // then bss as an address-only segment -- the same three avr-gcc emits
    img_phdr(b, 1, off_flash, 0, 0, img_lma, img_lma, 5, 2);
    img_phdr(b, 1, off_flash + img_lma, AVR_DATA_SEG + img_data, img_lma,
             datasz, datasz, 6, 1);
    img_phdr(b, 1, 0, AVR_DATA_SEG + img_bss_start, AVR_DATA_SEG + img_bss_start,
             0, img_bss_end - img_bss_start, 6, 1);

    buf_put(b, buf_p(flash), flashsz);
    buf_put(b, buf_p(img_symtab), buf_len(img_symtab));
    buf_put(b, buf_p(img_strtab), buf_len(img_strtab));
    buf_put(b, buf_p(img_shstr), buf_len(img_shstr));

    img_shdr(b, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    img_shdr(b, img_shname_at(1), 1, 6, 0, off_flash, img_mmcu, 0, 0, 2, 0);
    img_shdr(b, img_shname_at(2), 1, 2, img_mmcu, off_flash + img_mmcu,
             img_mmcu_size(), 0, 0, 1, 0);
    img_shdr(b, img_shname_at(3), 1, 3, AVR_DATA_SEG + img_data,
             off_flash + img_lma, datasz, 0, 0, 1, 0);
    img_shdr(b, img_shname_at(4), 8, 3, AVR_DATA_SEG + img_bss_start,
             off_flash + flashsz, img_bss_end - img_bss_start, 0, 0, 1, 0);
    img_shdr(b, img_shname_at(5), 2, 0, 0, off_sym, buf_len(img_symtab),
             6, nlocal, 4, SYM_ELF_SIZE);
    img_shdr(b, img_shname_at(6), 3, 0, 0, off_str, buf_len(img_strtab), 0, 0, 1, 0);
    img_shdr(b, img_shname_at(7), 3, 0, 0, off_shstr, buf_len(img_shstr), 0, 0, 1, 0);

    write_file(path, b);
}

// The backend itself. It names the machine as its first statement, the rule
// settled in M17 step B (docs/reference/machine.md § 1) -- the format already
// records the architecture, so the writer is what picks it.
void backend_avr_image(i64 root, uptr out) {
    machine_use("avr");
    gen_lower(root);
    gen_encode_all();
    avr_image_write(out);
}
