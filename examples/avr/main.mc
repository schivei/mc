// main.mc — the firmware itself (M40, docs/specs/M40.md § 5: "a blink, a UART
// `ok`, one timer ISR, and exit"; nothing else).
//
// Compiled by examples/avr/mc-avr.mc, run by
//
//     simavr build/avr.elf
//     qemu-system-avr -machine arduino-uno -bios build/avr.elf -nographic
//
// and its whole observable behaviour is five lines:
//
//     boot
//     blink
//     tick
//     sum 352
//     ok
//
// `boot` is the UART working, which means the startup copy out of flash worked
// -- the string is in SRAM only because `_start` put it there. `blink` is
// PORTB5 driven through the taught `sbi`/`cbi`. `tick` comes from a TIMER1
// overflow interrupt (vector 13): the vector table, the ISR frame and `sei` all working,
// and it is printed through a POINTER READ OUT OF A `uptr[]` -- two bytes per
// element, because this compiler declared `uptr` to be two bytes. `sum 352` is
// the 64-bit multiply, divide and remainder that an AVR does not have, done by
// examples/avr/lib/rt_avr.mc. `ok` and exit 0 are simavr's command register.
//
// There is no `#include <prelude>` here and no `while`: this compiler carries
// no bundle at all (examples/avr/mc-avr.mc), so every include is a relative
// path and every loop is the core's own `loop { if (...) break; }`.

#include "sys_avr.mc"                    // the UART, halt, _start, the registers
#include "rt_avr.mc"                     // multiply, divide, remainder
#include "isr.mc"                        // the vector 13 frame

// __DATA,__bss: the ISR writes it, `_start` clears it, and it is the only
// thing the two of them share.
i64 ticks = 0;

// __DATA,__data, and the reason it is here: a global with an initializer is
// what makes the flash-to-SRAM copy observable at all. 100 is what `sum` is
// computed from, so the arithmetic below cannot be folded at compile time.
i64 seed = 100;

// Two POINTERS in an initializer -- four bytes of __DATA on this target and
// thirty-two on every other one. Each element is an R_UNSIGNED relocation of
// two bytes, which only exists because src/gen_walk.mc asks the declared word
// how wide a pointer initializer is (M41 § 4a, C5).
uptr lines[2] = { "tick\n", "ok\n" };

// The handler the ISR frame calls. An ordinary function: it has a frame, it can
// call, and it must not re-enable interrupts (examples/avr/README.md § Limits).
void isr_timer1() {
    ticks = ticks + 1;
}

void amain() {
    uart_init();
    uart_puts("boot\n");

    sbi DDRB, LED;                               // the pin an Uno wires the LED to
    sbi PORTB, LED;                              // on
    cbi PORTB, LED;                              // off: one blink
    uart_puts("blink\n");

    st8(TCCR1B, CS_8);                           // clk/8: an overflow every ~33 ms
    st8(TIMSK1, 1 << TOIE1);
    sei();
    loop {
        if (ticks != 0) break;
    }
    cli();
    uart_puts((uptr) ld16(lines));               // "tick\n", through a 2-byte pointer

    i64 sum = seed * 7 / 2 + seed % 7;           // 350 + 2, none of it foldable
    uart_puts("sum ");
    uart_putn(sum);
    uart_putc('\n');

    uart_puts((uptr) ld16(lines + 2));           // "ok\n"
    halt(0);
}
