// sys_bare.mc — the system layer with no system: a 16550A UART, the SiFive
// test device, the machine-mode CSRs and the entry point, on a QEMU `virt`
// board with no firmware under it (M39, docs/specs/M39.md § 4).
//
// It is lib/sys_svc.mc and lib/sys_linux.mc's sibling one step further down:
// there is no kernel to call at all. The UART and the test device are ordinary
// `st8`/`st32` through a `mmio` name; only the four instructions that have no
// expression form -- csrrw, csrrs, mret, wfi -- need `#opcode`, and each one
// rests on the same guarantee the other two files rest on: the prologue writes
// the parameters to the frame WITHOUT touching a0..a7, and the epilogue leaves
// a0 alone (examples/kernel/README.md § The ABI).
//
// Compiled only by examples/kernel/mc-kernel.mc: `mmio` and `csrw` are that
// compiler's words, not the language's.

mmio UART_BASE 0x10000000;               // NS16550A, QEMU `virt`
mmio TEST_BASE 0x00100000;               // SiFive test finisher

#define UART_THR 0                       // transmit holding register
#define UART_IER 1
#define UART_FCR 2
#define UART_LCR 3
#define UART_LSR 5
#define LSR_THRE 0x20                    // the transmitter is ready

#define TEST_PASS 0x5555                 // exit 0
#define TEST_FAIL 0x3333                 // (code << 16) | this  -> exit code

#define CSR_MSTATUS 0x300
#define CSR_MTVEC   0x305
#define CSR_MEPC    0x341
#define CSR_MCAUSE  0x342

#define RVA0 10                          // a0, the register the ABI hands over

// ---- the four instructions with no expression form ----
// csrrw x0, csr, rs   /   csrrs rd, csr, x0   /   mret   /   wfi   /   ecall
#opcode op_csrw(csr, rs) 0x00001073 | (csr << 20) | (rs << 15)
#opcode op_csrr(rd, csr) 0x00002073 | (csr << 20) | (rd << 7)
#opcode op_mret()        0x30200073
#opcode op_wfi()         0x10500073
#opcode op_ecall()       0x00000073

// The CSR wrappers examples/kernel/kernel_syntax.mc's `csrw`/`csrr` expand to.
// Each is the shape lib/sys_svc.mc's syscalls have: the value is already in a0
// when the body starts, and a0 is still there when the epilogue ends.
void csrw_mstatus(uptr v) { op_csrw(CSR_MSTATUS, RVA0); }
void csrw_mtvec(uptr v)   { op_csrw(CSR_MTVEC, RVA0); }
void csrw_mepc(uptr v)    { op_csrw(CSR_MEPC, RVA0); }
void csrw_mcause(uptr v)  { op_csrw(CSR_MCAUSE, RVA0); }

uptr csrr_mstatus() { op_csrr(RVA0, CSR_MSTATUS); }
uptr csrr_mtvec()   { op_csrr(RVA0, CSR_MTVEC); }
uptr csrr_mepc()    { op_csrr(RVA0, CSR_MEPC); }
uptr csrr_mcause()  { op_csrr(RVA0, CSR_MCAUSE); }

void trap_now() { op_ecall(); }                  // the deliberate ecall
void idle()     { op_wfi(); }

// ---- the UART ----
void uart_init() {
    st8(UART_BASE + UART_LCR, 0x03);             // 8 bits, no parity, one stop
    st8(UART_BASE + UART_FCR, 0x01);             // FIFO on
    st8(UART_BASE + UART_IER, 0x00);             // polled, never interrupt
}

void uart_putc(i64 c) {
    loop {
        if (ld8(UART_BASE + UART_LSR) & LSR_THRE) break;
    }
    st8(UART_BASE + UART_THR, c);
}

void uart_puts(uptr s) {
    i64 i = 0;
    while (ld8(s + i) != 0) {
        uart_putc(ld8(s + i));
        i = i + 1;
    }
}

// unsigned decimal, smallest useful form: the digits come out backwards into a
// local array and go out forwards
void uart_putn(i64 v) {
    u8 tmp[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    while (i < 24) {
        uart_putc(ld8(tmp + i));
        i = i + 1;
    }
}

// ---- the way out ----
// The SiFive test finisher turns the value written at TEST_BASE into QEMU's own
// process status: 0x5555 exits 0 and (code << 16) | 0x3333 exits with `code`.
// Measured on QEMU 11.0.1 and 8.2.2 -- docs/specs/M39.md § Acceptance 2 and
// examples/kernel/test.sh assert both halves.
void halt(i64 code) {
    if (code == 0) st32(TEST_BASE, TEST_PASS);
    else           st32(TEST_BASE, (code << 16) | TEST_FAIL);
    loop { idle(); }                             // unreachable on a live board
}

// ---- the entry point ----
// The image writer defines these; mc has no extern VARIABLE
// (docs/reference/language.md § extern), so they are declared as extern
// functions and used only through `&name` -- the idiom C uses for a
// linker-defined symbol, with `ld`'s job done by examples/kernel/image.mc.
extern void bss_start();
extern void bss_end();
extern void data_start();
extern void data_end();
extern void data_lma();

// `_start` is where the reset stub jumps. sp is already set when it arrives:
// the stub does that, because the compiler's frame record is unconditional and
// a RISC-V hart comes out of reset with every register zero -- the prologue's
// `sd ra, 8(sp)` would fault on the first instruction of the kernel otherwise
// (examples/kernel/image.mc § the reset stub).
void _start() {
    uptr p = &bss_start;
    uptr e = &bss_end;
    while (p < e) {
        st8(p, 0);
        p = p + 1;
    }
    // On this board the load address and the run address are the same -- QEMU
    // puts the whole file at 0x80000000 -- so this loop copies .data onto
    // itself. It is here because it is what a flash target needs, and because
    // _data_lma is a symbol the image writer already has to compute.
    uptr d = &data_start;
    uptr de = &data_end;
    uptr s = &data_lma;
    while (d < de) {
        st8(d, ld8(s));
        d = d + 1;
        s = s + 1;
    }
    csrw mtvec, &trap_entry;                     // direct mode: the address is 4-aligned
    kmain();
    loop { idle(); }
}
