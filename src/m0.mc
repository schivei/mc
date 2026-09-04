// m0.mc — driver for M6 slices 1-2: exercises src/macho.mc alone, without a
// front end. Each mode builds by hand the SAME object model that build/mc0 builds
// for a test and has macho_write write it out; the criterion is a byte-for-byte `cmp` with
// mc0's .o. It proves the writer (section layout, stable-partition symtab,
// creation-order strtab, descending-order relocations) before a
// lexer/parser/codegen exists in .mc.
//
// usage: m0 MODE OUT.o [--dump-syms]
//   MODE 1 -> the .o of tests/001-return42.mc  (only __TEXT,__text; extern _main)
//   MODE 2 -> the .o of tests/021-strings.mc   (__text + __cstring, local symbol
//             l_str0, undefined _write, 3 BRANCH26 + 2 PAGE21 + 2 PAGEOFF12)
// --dump-syms prints the same text as `mc0 --dump-syms TEST.mc` (also cross-checks
// the symtab's stable partition, not just the file's bytes).
//
// The instruction words are raw data copied from mc0's .o (the codegen in .mc
// is slice 4); each line's comment carries the offset in the section and the
// corresponding line of `mc0 --dump-asm`.

#include "arena.mc"
#include "objmodel.mc"
#include "macho.mc"

void emit_word(i64 sec, i64 w)          { buf_u32(sec_data(sec_at(sec)), w); }
void emit_bytes(i64 sec, uptr p, i64 n) { buf_put(sec_data(sec_at(sec)), p, n); }

// ---- mode 1: tests/001-return42.mc ----
// mc0 --dump-syms: section __TEXT,__text flags=0x80000400 align=2 size=28 nreloc=0
//                  sym 0 extern sect=1 value=0 _main
void obj001() {
    i64 t = sec_new("__TEXT", "__text", TEXT_FLAGS, 2);
    // _main:
    emit_word(t, 0xa9bf7bfd);   // 0000  stp x29, x30, [sp, #-16]!
    emit_word(t, 0x910003fd);   // 0004  mov x29, sp
    emit_word(t, 0xd2800549);   // 0008  movz x9, #42
    emit_word(t, 0xaa0903e0);   // 000c  mov x0, x9
    emit_word(t, 0x14000001);   // 0010  b L1
    // L1:
    emit_word(t, 0xa8c17bfd);   // 0014  ldp x29, x30, [sp], #16
    emit_word(t, 0xd65f03c0);   // 0018  ret
    sym_new("_main", t + 1, 0, 1);
}

// ---- mode 2: tests/021-strings.mc ----
// 484 bytes of __text (121 words), in the order gen_arm64 emits them:
// _strlen (0x000), _puts (0x068), _putnum (0x0c0), _main (0x178).
void text021(i64 t) {
    // _strlen:
    emit_word(t, 0xa9bf7bfd);   // 0000  stp x29, x30, [sp, #-16]!
    emit_word(t, 0x910003fd);   // 0004  mov x29, sp
    emit_word(t, 0xd10043ff);   // 0008  sub sp, sp, #16
    emit_word(t, 0xf90007e0);   // 000c  str x0, [sp, #8]
    emit_word(t, 0xd2800009);   // 0010  movz x9, #0
    emit_word(t, 0xf90003e9);   // 0014  str x9, [sp]
    // L2:
    emit_word(t, 0xf94007e9);   // 0018  ldr x9, [sp, #8]
    emit_word(t, 0xf94003ea);   // 001c  ldr x10, [sp]
    emit_word(t, 0x8b0a0129);   // 0020  add x9, x9, x10
    emit_word(t, 0x39400129);   // 0024  ldrb w9, [x9]
    emit_word(t, 0xd280000a);   // 0028  movz x10, #0
    emit_word(t, 0xeb0a013f);   // 002c  cmp x9, x10
    emit_word(t, 0x9a9f17e9);   // 0030  cset x9, eq
    emit_word(t, 0xb4000049);   // 0034  cbz x9, L4
    emit_word(t, 0x14000006);   // 0038  b L3
    // L4:
    emit_word(t, 0xf94003e9);   // 003c  ldr x9, [sp]
    emit_word(t, 0xd280002a);   // 0040  movz x10, #1
    emit_word(t, 0x8b0a0129);   // 0044  add x9, x9, x10
    emit_word(t, 0xf90003e9);   // 0048  str x9, [sp]
    emit_word(t, 0x17fffff3);   // 004c  b L2
    // L3:
    emit_word(t, 0xf94003e9);   // 0050  ldr x9, [sp]
    emit_word(t, 0xaa0903e0);   // 0054  mov x0, x9
    emit_word(t, 0x14000001);   // 0058  b L1
    // L1:
    emit_word(t, 0x910043ff);   // 005c  add sp, sp, #16
    emit_word(t, 0xa8c17bfd);   // 0060  ldp x29, x30, [sp], #16
    emit_word(t, 0xd65f03c0);   // 0064  ret
    // _puts:
    emit_word(t, 0xa9bf7bfd);   // 0068  stp x29, x30, [sp, #-16]!
    emit_word(t, 0x910003fd);   // 006c  mov x29, sp
    emit_word(t, 0xd10083ff);   // 0070  sub sp, sp, #32
    emit_word(t, 0xf9000fe0);   // 0074  str x0, [sp, #24]
    emit_word(t, 0xd2800029);   // 0078  movz x9, #1
    emit_word(t, 0xf9400fea);   // 007c  ldr x10, [sp, #24]
    emit_word(t, 0xf9400feb);   // 0080  ldr x11, [sp, #24]
    emit_word(t, 0xf9000be9);   // 0084  str x9, [sp, #16]
    emit_word(t, 0xf90007ea);   // 0088  str x10, [sp, #8]
    emit_word(t, 0xaa0b03e0);   // 008c  mov x0, x11
    emit_word(t, 0x94000000);   // 0090  bl _strlen
    emit_word(t, 0xf9400be9);   // 0094  ldr x9, [sp, #16]
    emit_word(t, 0xf94007ea);   // 0098  ldr x10, [sp, #8]
    emit_word(t, 0xaa0003eb);   // 009c  mov x11, x0
    emit_word(t, 0xaa0903e0);   // 00a0  mov x0, x9
    emit_word(t, 0xaa0a03e1);   // 00a4  mov x1, x10
    emit_word(t, 0xaa0b03e2);   // 00a8  mov x2, x11
    emit_word(t, 0x94000000);   // 00ac  bl _write
    emit_word(t, 0xaa0003e9);   // 00b0  mov x9, x0
    // L1:
    emit_word(t, 0x910083ff);   // 00b4  add sp, sp, #32
    emit_word(t, 0xa8c17bfd);   // 00b8  ldp x29, x30, [sp], #16
    emit_word(t, 0xd65f03c0);   // 00bc  ret
    // _putnum:
    emit_word(t, 0xa9bf7bfd);   // 00c0  stp x29, x30, [sp, #-16]!
    emit_word(t, 0x910003fd);   // 00c4  mov x29, sp
    emit_word(t, 0xd100c3ff);   // 00c8  sub sp, sp, #48
    emit_word(t, 0xf90017e0);   // 00cc  str x0, [sp, #40]
    emit_word(t, 0xd2800309);   // 00d0  movz x9, #24
    emit_word(t, 0xf90003e9);   // 00d4  str x9, [sp]
    // L2:
    emit_word(t, 0xf94003e9);   // 00d8  ldr x9, [sp]
    emit_word(t, 0xd280002a);   // 00dc  movz x10, #1
    emit_word(t, 0xcb0a0129);   // 00e0  sub x9, x9, x10
    emit_word(t, 0xf90003e9);   // 00e4  str x9, [sp]
    emit_word(t, 0x910023e9);   // 00e8  add x9, sp, #8
    emit_word(t, 0xf94003ea);   // 00ec  ldr x10, [sp]
    emit_word(t, 0x8b0a0129);   // 00f0  add x9, x9, x10
    emit_word(t, 0xd280060a);   // 00f4  movz x10, #48
    emit_word(t, 0xf94017eb);   // 00f8  ldr x11, [sp, #40]
    emit_word(t, 0xd280014c);   // 00fc  movz x12, #10
    emit_word(t, 0x9acc0d68);   // 0100  sdiv x8, x11, x12
    emit_word(t, 0x9b0cad0b);   // 0104  msub x11, x8, x12, x11
    emit_word(t, 0x8b0b014a);   // 0108  add x10, x10, x11
    emit_word(t, 0x3900012a);   // 010c  strb w10, [x9]
    emit_word(t, 0xf94017e9);   // 0110  ldr x9, [sp, #40]
    emit_word(t, 0xd280014a);   // 0114  movz x10, #10
    emit_word(t, 0x9aca0d29);   // 0118  sdiv x9, x9, x10
    emit_word(t, 0xf90017e9);   // 011c  str x9, [sp, #40]
    emit_word(t, 0xf94017e9);   // 0120  ldr x9, [sp, #40]
    emit_word(t, 0xd280000a);   // 0124  movz x10, #0
    emit_word(t, 0xeb0a013f);   // 0128  cmp x9, x10
    emit_word(t, 0x9a9f17e9);   // 012c  cset x9, eq
    emit_word(t, 0xb4000049);   // 0130  cbz x9, L4
    emit_word(t, 0x14000002);   // 0134  b L3
    // L4:
    emit_word(t, 0x17ffffe8);   // 0138  b L2
    // L3:
    emit_word(t, 0xd2800029);   // 013c  movz x9, #1
    emit_word(t, 0x910023ea);   // 0140  add x10, sp, #8
    emit_word(t, 0xf94003eb);   // 0144  ldr x11, [sp]
    emit_word(t, 0x8b0b014a);   // 0148  add x10, x10, x11
    emit_word(t, 0xd280030b);   // 014c  movz x11, #24
    emit_word(t, 0xf94003ec);   // 0150  ldr x12, [sp]
    emit_word(t, 0xcb0c016b);   // 0154  sub x11, x11, x12
    emit_word(t, 0xaa0903e0);   // 0158  mov x0, x9
    emit_word(t, 0xaa0a03e1);   // 015c  mov x1, x10
    emit_word(t, 0xaa0b03e2);   // 0160  mov x2, x11
    emit_word(t, 0x94000000);   // 0164  bl _write
    emit_word(t, 0xaa0003e9);   // 0168  mov x9, x0
    // L1:
    emit_word(t, 0x9100c3ff);   // 016c  add sp, sp, #48
    emit_word(t, 0xa8c17bfd);   // 0170  ldp x29, x30, [sp], #16
    emit_word(t, 0xd65f03c0);   // 0174  ret
    // _main:
    emit_word(t, 0xa9bf7bfd);   // 0178  stp x29, x30, [sp, #-16]!
    emit_word(t, 0x910003fd);   // 017c  mov x29, sp
    emit_word(t, 0xd10043ff);   // 0180  sub sp, sp, #16
    emit_word(t, 0x90000009);   // 0184  adrp x9, l_str0@PAGE
    emit_word(t, 0x91000129);   // 0188  add x9, x9, l_str0@PAGEOFF
    emit_word(t, 0xf90007e9);   // 018c  str x9, [sp, #8]
    emit_word(t, 0x90000009);   // 0190  adrp x9, l_str0@PAGE
    emit_word(t, 0x91000129);   // 0194  add x9, x9, l_str0@PAGEOFF
    emit_word(t, 0xf90003e9);   // 0198  str x9, [sp]
    emit_word(t, 0xf94007e9);   // 019c  ldr x9, [sp, #8]
    emit_word(t, 0xf94003ea);   // 01a0  ldr x10, [sp]
    emit_word(t, 0xeb0a013f);   // 01a4  cmp x9, x10
    emit_word(t, 0x9a9f07e9);   // 01a8  cset x9, ne
    emit_word(t, 0xb4000089);   // 01ac  cbz x9, L2
    emit_word(t, 0xd2800029);   // 01b0  movz x9, #1
    emit_word(t, 0xaa0903e0);   // 01b4  mov x0, x9
    emit_word(t, 0x14000008);   // 01b8  b L1
    // L2:
    emit_word(t, 0xf94007e9);   // 01bc  ldr x9, [sp, #8]
    emit_word(t, 0xaa0903e0);   // 01c0  mov x0, x9
    emit_word(t, 0x94000000);   // 01c4  bl _puts
    emit_word(t, 0xaa0003e9);   // 01c8  mov x9, x0
    emit_word(t, 0xd2800009);   // 01cc  movz x9, #0
    emit_word(t, 0xaa0903e0);   // 01d0  mov x0, x9
    emit_word(t, 0x14000001);   // 01d4  b L1
    // L1:
    emit_word(t, 0x910043ff);   // 01d8  add sp, sp, #16
    emit_word(t, 0xa8c17bfd);   // 01dc  ldp x29, x30, [sp], #16
    emit_word(t, 0xd65f03c0);   // 01e0  ret
}

// mc0 --dump-syms: section __TEXT,__text    flags=0x80000400 align=2 size=484 nreloc=8
//                  section __TEXT,__cstring flags=0x2        align=0 size=7   nreloc=0
// The symbol CREATION order (the one the strtab preserves) matches the codegen's:
// each function creates the symbols it references before its own.
void obj021() {
    i64 t = sec_new("__TEXT", "__text", TEXT_FLAGS, 2);
    i64 c = sec_new("__TEXT", "__cstring", S_CSTRING_LITERALS, 0);
    text021(t);
    emit_bytes(c, "hello\n", 7);              // 6 bytes + __cstring's NUL

    sym_new("_strlen", t + 1, 0, 1);           // 0: defined in __text
    sym_ref("_write");                         // 1: undefined (libSystem)
    sym_new("_puts",   t + 1, 104, 1);         // 2
    sym_new("_putnum", t + 1, 192, 1);         // 3
    sym_new("l_str0",  c + 1, 0, 0);           // 4: local, in __cstring
    sym_new("_main",   t + 1, 376, 1);         // 5

    // ascending address order; macho_write reverses it when writing
    reloc_add(t, 0x090, 0, R_BRANCH26,  1, 2);   // bl _strlen
    reloc_add(t, 0x0ac, 1, R_BRANCH26,  1, 2);   // bl _write
    reloc_add(t, 0x164, 1, R_BRANCH26,  1, 2);   // bl _write
    reloc_add(t, 0x184, 4, R_PAGE21,    1, 2);   // adrp x9, l_str0@PAGE
    reloc_add(t, 0x188, 4, R_PAGEOFF12, 0, 2);   // add  x9, x9, l_str0@PAGEOFF
    reloc_add(t, 0x190, 4, R_PAGE21,    1, 2);   // adrp x9, l_str0@PAGE
    reloc_add(t, 0x194, 4, R_PAGEOFF12, 0, 2);   // add  x9, x9, l_str0@PAGEOFF
    reloc_add(t, 0x1c4, 2, R_BRANCH26,  1, 2);   // bl _puts
}

i64 main(i64 argc, uptr argv) {
    if (argc < 3) {
        out_str(2, "usage: m0 MODE OUT.o   (MODE = 1 or 2)\n");
        return 1;
    }
    uptr mode = ld64(argv + 8);
    uptr out  = ld64(argv + 16);
    i64  m = 0;
    if (str_eq(mode, "1")) m = 1;
    if (str_eq(mode, "2")) m = 2;
    if (m == 0) {
        out_str(2, "m0: unknown mode (use 1 or 2)\n");
        return 1;
    }
    if (m == 1) obj001();
    if (m == 2) obj021();
    if (argc > 3) {
        if (str_eq(ld64(argv + 24), "--dump-syms")) dump_syms();
    }
    macho_write(out);
    return 0;
}
