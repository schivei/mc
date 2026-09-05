// sys_avr.mc — the system layer with no system, one part down from
// examples/kernel/lib/sys_bare.mc: an ATmega328P with no operating system, no
// bootloader and no C runtime (M40, docs/specs/M40.md § 3).
//
// Everything a device needs here is an ordinary `ld8`/`st8` at a named address,
// because on an AVR every peripheral register IS a data address -- `sfr`
// (examples/avr/avr_syntax.mc) is what names them. Only four instructions have
// no expression form at all, and each is one `#opcode` word in the fixed-
// register style lib/sys_svc.mc and lib/sys_linux.mc already use.
//
// Compiled only by examples/avr/mc-avr.mc: `sfr`, `sbi`, `cbi` and `bit` are
// that compiler's words, not the language's.

// ---- the registers this program touches, by DATA address ----
sfr DDRB    0x24;
sfr PORTB   0x25;
sfr GPIOR1  0x4a;                        // simavr's command register (.mmcu)
sfr TCCR1A  0x80;
sfr TCCR1B  0x81;
sfr TCNT1L  0x84;
sfr TIMSK1  0x6f;
sfr UCSR0A  0xc0;
sfr UCSR0B  0xc1;
sfr UCSR0C  0xc2;
sfr UBRR0L  0xc4;
sfr UBRR0H  0xc5;
sfr UDR0    0xc6;

#define UDRE0     5                      // UCSR0A: the transmit buffer is empty
#define TXEN0     3                      // UCSR0B: enable the transmitter
#define UCSZ00    1                      // UCSR0C: 8 data bits is (3 << UCSZ00)
#define TOIE1     0                      // TIMSK1: timer 1 overflow interrupt
#define CS_8      2                      // TCCR1B: clk/8, ~33 ms per overflow
#define LED       5                      // PORTB5, the pin an Uno wires an LED to

#define SIMAVR_EXIT_0 4                  // SIMAVR_CMD_EXIT_CODE_0
#define SIMAVR_EXIT_1 5                  // ...and _1: measured, exit 0 and exit 1

// ---- the four instructions with no expression form ----
#opcode op_sei()   0x9478
#opcode op_cli()   0x94f8
#opcode op_sleep() 0x9588
#opcode op_nop()   0x0000

void sei() { op_sei(); }
void cli() { op_cli(); }

// ---- the UART ----
// 115200 8N1 at 16 MHz: UBRR = 16e6 / 16 / 115200 - 1, rounded. Both oracles
// read this one register -- QEMU wires UART0 to the serial console and simavr
// prints it too -- which is why this example has ONE transcript channel and no
// #define to choose between them (docs/specs/M40.md risk 5, resolved by
// measurement: see examples/avr/README.md § The two oracles).
void uart_init() {
    st8(UBRR0H, 0);
    st8(UBRR0L, 8);
    st8(UCSR0B, 1 << TXEN0);
    st8(UCSR0C, 3 << UCSZ00);
}

void uart_putc(i64 c) {
    loop {
        if (bit(UCSR0A, UDRE0)) break;
    }
    st8(UDR0, c);
}

void uart_puts(uptr s) {
    i64 i = 0;
    loop {
        if (ld8(s + i) == 0) break;
        uart_putc(ld8(s + i));
        i = i + 1;
    }
}

// unsigned decimal: the digits come out backwards into a local array and go out
// forwards. Every `/` and `%` here is a call into examples/avr/lib/rt_avr.mc --
// an AVR has an 8x8 multiply and no divide at all.
void uart_putn(i64 v) {
    u8 tmp[24];
    i64 i = 24;
    loop {
        i = i - 1;
        st8(tmp + i, '0' + v % 10);
        v = v / 10;
        if (v == 0) break;
    }
    loop {
        if (i >= 24) break;
        uart_putc(ld8(tmp + i));
        i = i + 1;
    }
}

// ---- the way out ----
// simavr turns a write to the .mmcu command register into a process status:
// 4 exits 0 and 5 exits 1, both measured on this host before test.sh was
// written (docs/specs/M40.md, the architect's addition (b)). QEMU has no exit
// device at all, so the `sleep` below is what a real board would do and what
// the watchdog in test.sh reports as the expected end of the QEMU leg.
void halt(i64 code) {
    if (code == 0) st8(GPIOR1, SIMAVR_EXIT_0);
    else           st8(GPIOR1, SIMAVR_EXIT_1);
    cli();
    loop { op_sleep(); }
}

// ---- the entry point ----
// The image writer defines these; mc has no extern VARIABLE
// (docs/reference/language.md § extern), so they are declared as extern
// functions and used only through `&name` -- the idiom C uses for a
// linker-defined symbol, with `ld`'s job done by examples/avr/image_avr.mc.
extern void data_start();
extern void data_end();
extern void data_lma();
extern void bss_start();
extern void bss_end();

// `_start` is where the reset stub jumps, and SP is already RAMEND when it
// arrives -- the stub does that, because the compiler's frame record is
// unconditional and this function's own `push r29` would otherwise write
// wherever the reset value of SP happens to point (examples/avr/image_avr.mc,
// the reset stub).
//
// Then the two loops that make Harvard invisible to everything above: the
// initialized data is copied out of FLASH (`lpm8`, the machine's own intrinsic)
// into SRAM at the addresses every pointer in the program already holds, and
// the zerofill is cleared. After them `ld8(p)` on a string literal works with
// no address-space discipline anywhere in the source.
void _start() {
    uptr d = &data_start;
    uptr e = &data_end;
    uptr s = &data_lma;
    loop {
        if (d >= e) break;
        st8(d, lpm8(s));
        d = d + 1;
        s = s + 1;
    }
    uptr b = &bss_start;
    uptr be = &bss_end;
    loop {
        if (b >= be) break;
        st8(b, 0);
        b = b + 1;
    }
    amain();
    loop { op_sleep(); }
}
