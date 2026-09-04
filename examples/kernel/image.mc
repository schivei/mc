// image.mc — the `rv-image` backend: a flat bare-metal image, no linker, no
// container format at all (M39, docs/specs/M39.md § 3).
//
// It is src/backend_exe.mc's idea one architecture over and with the envelope
// removed: read the public object model (docs/reference/objects.md §§ 2, 5-9),
// place the sections at fixed addresses, rebase every symbol, resolve its own
// relocations in place and write the bytes. What `ld` and a linker script would
// have done is done here, from inside the compiler, by a module.
//
// The address map, all of it decided in this file:
//
//     0x80000000  reset stub: `li sp, _stack_top` + `j _start`, synthesized
//     0x80000020  __TEXT,__text        )
//                 __TEXT,__cstring     ) every non-zerofill section, in the
//                 __DATA,__data        ) order gen_sections created them,
//                 (any #section)       ) each rounded up to 1 << sec_align
//     ---------   end of the file
//                 __DATA,__bss         zerofill: addressed, never written
//                 _stack_top           RV_STACK bytes above that
//
// 0x80000000 is where `qemu-system-riscv64 -machine virt -bios none -kernel`
// loads a raw image and starts executing, so the image is position-DEPENDENT by
// construction -- and that is exactly why docs/specs/M39.md D3 chose
// `auipc`+`addi` over `lui`+`addi`: `lui t2, 0x80000` on RV64 sign-extends to
// 0xFFFFFFFF80000000, which is wrong at precisely this base.
//
// The three relocations that can reach here:
//
//   RVK_PCREL_LA   (32)  auipc rd,0 + addi rd,rd,0    the address of a symbol
//   RVK_PCREL_CALL (33)  auipc ra,0 + jalr ra,ra,0    a direct call
//   R_UNSIGNED     (0)   eight bytes in __data        a pointer in an initializer
//
// The first two are examples/kernel/machine_riscv64.mc's private kinds, each
// carried by ONE fused 8-byte Ins, so the walker's "one implicit relocation per
// instruction" rule (M39 § G3) is never bent. Anything else is refused loudly.

#define IMG_BASE   0x80000000
#define IMG_STUB   32                 // the reset stub's fixed size, in bytes
#define RV_STACK   16384              // the bytes _stack_top leaves above .bss

uptr img_addr;                        // absolute address of each section
i64  img_bss_start = 0;
i64  img_bss_end   = 0;
i64  img_data_lma  = 0;
i64  img_data_addr = 0;
i64  img_data_end  = 0;
i64  img_stack_top = 0;
i64  img_file_end  = 0;

i64  img_addr_at(i64 i)          { return ld64(img_addr + i * 8); }
void set_img_addr_at(i64 i, i64 v) { st64(img_addr + i * 8, v); }

i64 img_zerofill(uptr s) { return (sec_flags(s) & 0xff) == S_ZEROFILL; }

i64 img_align_up(i64 v, i64 a) {
    if (v % a == 0) return v;
    return v + a - v % a;
}

// ---- 1. placement ----
// Two passes over the sections in CREATION order: what occupies file bytes
// first, then what only occupies addresses. The reset stub takes the first
// IMG_STUB bytes, which is why every section starts at 0x80000020 or above.
void img_place() {
    img_addr = xalloc(8 * (nsections + 1));
    i64 cur = IMG_BASE + IMG_STUB;
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (!img_zerofill(s)) {
            cur = img_align_up(cur, 1 << sec_align(s));
            set_img_addr_at(i, cur);
            cur = cur + buf_len(sec_data(s));
        }
        i = i + 1;
    }
    img_file_end = cur;
    img_bss_start = cur;
    i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (img_zerofill(s)) {
            cur = img_align_up(cur, 1 << sec_align(s));
            set_img_addr_at(i, cur);
            cur = cur + sec_zsize(s);
        }
        i = i + 1;
    }
    img_bss_end = cur;
    img_stack_top = img_align_up(cur, 16) + RV_STACK;
    // __DATA,__data is where a real flash target would need a startup copy. In
    // this image the load address and the run address are the same -- QEMU puts
    // the whole file at IMG_BASE -- so _data_lma == _data_start and _start's
    // copy loop does nothing. The three symbols exist anyway, because they are
    // what the layer would use on a board where the two differ.
    img_data_addr = img_bss_start;
    img_data_end  = img_bss_start;
    i64 di = sec_find("__DATA", "__data");
    if (di >= 0) {
        img_data_addr = img_addr_at(di);
        img_data_end  = img_data_addr + buf_len(sec_data(sec_at(di)));
    }
    img_data_lma = img_data_addr;
}

// ---- 2. symbols ----
// Every defined symbol's value goes from "offset inside its section" to the
// absolute address it will have at run time, which is what the relocation pass
// and the synthesized symbols below both read.
void img_rebase_syms() {
    i64 i = 0;
    while (i < nsymbols) {
        uptr s = sym_at(i);
        if (sym_sect(s) != 0) sym_set_value(i, img_addr_at(sym_sect(s) - 1) + sym_value(s));
        i = i + 1;
    }
}

// The six the layer may reference. They are declared there as `extern` FUNCTIONS
// and used only through `&name` (mc has no extern variable -- see
// docs/reference/language.md § extern), which is the same idiom C uses for a
// linker-defined symbol. sym_new fills in a name that already exists as
// undefined, so a symbol the layer took the address of gets its value here and
// one nobody mentioned is simply created and never read.
//
// Section 1 is written as the "defined" flag and nothing more: img_rebase_syms
// has already run, so no second rebase can touch these.
void img_define(uptr name, i64 value) { sym_new(name, 1, value, 0); }

void img_synth_syms() {
    img_define("_bss_start",  img_bss_start);
    img_define("_bss_end",    img_bss_end);
    img_define("_data_start", img_data_addr);
    img_define("_data_end",   img_data_end);
    img_define("_data_lma",   img_data_lma);
    img_define("_stack_top",  img_stack_top);
}

// ---- 3. relocations ----
// `auipc rd, hi` + `addi rd, rd, lo` (or `jalr ra, ra, lo`), where the pair
// addresses `target` from the address of the AUIPC. The low twelve bits are
// signed, so the high part is rounded to compensate -- the same +0x800 the
// assembler's %pcrel_hi does.
void img_fix_pcrel(uptr p, i64 at, i64 pc, i64 target) {
    i64 d = target - pc;
    if (d >= 0x7ffff800 || d < 0 - 0x80000000) die("riscv pc-relative pair out of range");
    i64 hi = (d + 0x800) >> 12;
    i64 lo = d - (hi << 12);
    st32(p + at, (ld32(p + at) & 0xfff) | ((hi & 0xfffff) << 12));
    st32(p + at + 4, (ld32(p + at + 4) & 0xfffff) | ((lo & 0xfff) << 20));
}

void img_relocate() {
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (!img_zerofill(s)) {
            uptr p = buf_p(sec_data(s));
            i64 base = img_addr_at(i);
            i64 j = 0;
            while (j < sec_nrel(s)) {
                uptr r = rel_at(sec_rel(s), j);
                uptr sy = sym_at(rel_sym(r));
                if (sym_sect(sy) == 0) die2("undefined symbol", sym_name(sy));
                i64 t = rel_type(r);
                if (t == RVK_PCREL_LA || t == RVK_PCREL_CALL)
                    img_fix_pcrel(p, rel_off(r), base + rel_off(r), sym_value(sy));
                else if (t == R_UNSIGNED)
                    st64(p + rel_off(r), sym_value(sy));
                else
                    die("relocation not supported in a flat image");
                j = j + 1;
            }
        }
        i = i + 1;
    }
}

// ---- 4. the bytes ----
// The reset vector, and the one place this writer synthesizes code rather than
// placing it -- the same licence src/backend_exe.mc takes when it fabricates
// __stubs. It does two things:
//
//   li sp, _stack_top    because a RISC-V hart comes out of reset with every
//                        register zero and the compiler's frame record is
//                        UNCONDITIONAL: `_start`'s own `sd ra, 8(sp)` would
//                        fault on the first instruction of the kernel. Nothing
//                        below the reset vector can set sp, so the writer does
//                        -- it is the one piece of code that knows where the
//                        stack is, because it is what decided.
//   j _start             because functions land in __text in DEFINITION order
//                        and the layer is only one of several files, so
//                        `_start` is not reliably first. `jal`'s range is
//                        +/-1 MiB, the whole of any image this can produce.
//
// The stub is a FIXED IMG_STUB bytes, padded with canonical `nop`s, so that the
// placement above does not depend on how many words `li` happens to need -- a
// stack top above 0x7fffffff costs four (lui, addi, slli, addi) because `lui`
// sign-extends on RV64, which is D3's reason for pc-relative addressing said
// once more.
void img_put_stub(uptr b) {
    i64 si = sym_find("__start");
    if (si < 0) die("the image has no _start");
    u8 t[BUF_SIZE];
    buf_init(t);
    rv_put_li(t, RV_SP, img_stack_top);
    i64 jat = buf_len(t);
    if (jat + 4 > IMG_STUB) die("the reset stub does not fit");
    // the jal sits `jat` bytes into the stub, so it counts from there
    i64 target = sym_value(sym_at(si)) - (IMG_BASE + jat);
    if (target >= 1048576 || target < 0 - 1048576)
        die("_start is more than 1 MiB from the reset vector");
    rv_put_j(t, target, RV_ZERO);
    while (buf_len(t) < IMG_STUB) { buf_u32(t, 0x00000013); }   // nop = addi x0,x0,0
    buf_put(b, buf_p(t), IMG_STUB);
}

void rv_image_write(uptr path) {
    img_place();
    img_rebase_syms();
    img_synth_syms();
    img_relocate();
    u8 b[BUF_SIZE];
    buf_init(b);
    img_put_stub(b);
    i64 i = 0;
    while (i < nsections) {
        uptr s = sec_at(i);
        if (!img_zerofill(s)) {
            buf_pad(b, 1 << sec_align(s));       // IMG_BASE is 64 KiB aligned, so
            buf_put(b, buf_p(sec_data(s)), buf_len(sec_data(s)));   // offset == address
        }
        i = i + 1;
    }
    if (IMG_BASE + buf_len(b) != img_file_end) die("image layout disagrees with the bytes");
    write_file(path, b);
}

// The backend itself. The object backend picks the machine as its first
// statement, the rule settled in M17 step B (docs/reference/machine.md § 1).
void backend_rv_image(i64 root, uptr out) {
    machine_use("riscv64");
    gen_lower(root);
    gen_encode_all();
    rv_image_write(out);
}
