// main.mc — the kernel itself (M39, docs/specs/M39.md § 4).
//
// Compiled by examples/kernel/mc-kernel.mc, run by
//
//     qemu-system-riscv64 -machine virt -bios none -nographic -kernel kernel.bin
//
// and its whole observable behaviour is four lines and an exit code:
//
//     boot
//     trap
//     t0 t1 t0 t1 t0 t1 t0 t1 t0 t1
//     ok
//     (exit 0)
//
// `boot` is the UART working. `trap` is `mtvec`, an `ecall` and an `mret`
// working. The alternating line is the cooperative switch working -- ten
// switches between two stacks. `ok` and exit 0 are the SiFive test device.
// examples/kernel/test.sh asserts all five.

// `while`, `for` and the compound assignments are not core syntax: they are
// six `#rule stmt:` in lib/prelude.mc, which the binary carries in its bundle.
#include <prelude>

#include "sys_bare.mc"                   // UART, halt, the CSRs, _start
#include "trap.mc"                       // mtvec, trap_entry, mret
#include "sched.mc"                      // two tasks, ctx_switch, yield_now

#define ROUNDS 5

// The second task. It never returns: its fabricated frame has a zero where a
// return address would be, so returning would jump to 0. It yields forever and
// the first task is what ends the program.
void task_b() {
    loop {
        uart_puts("t1 ");
        yield;
    }
}

// A local array between RV's signed 12-bit store displacement (2047) and the
// walker's language-wide frame limit (4095): every access to it goes through
// the machine's t2 fallback, which is a code path nothing else in this kernel
// reaches. docs/specs/M39.md § G7 and § Acceptance 6 are why it is here and not
// in a test of its own -- the kernel exercising it is the proof that the
// fallback is not decoration.
i64 big_frame_sum() {
    u8 buf[3000];
    i64 i = 0;
    while (i < 3000) {
        st8(buf + i, i & 0xff);
        i = i + 1;
    }
    i64 sum = 0;
    i = 0;
    while (i < 3000) {
        sum = sum + ld8(buf + i);
        i = i + 1;
    }
    return sum;
}

void kmain() {
    uart_init();
    uart_puts("boot\n");

    // one deliberate ecall: mtvec was set by _start, trap_entry saves the world,
    // trap_handler prints, mepc moves past the ecall and mret comes back here
    trap_now();

    // the frame fallback, checked against the value it must have:
    // 3000 bytes of i & 0xff, which is 11 full 0..255 cycles (2816 bytes,
    // 11 * 32640) plus 0..183 (16836)
    i64 sum = big_frame_sum();
    if (sum != 375876) {
        uart_puts("frame FAIL ");
        uart_putn(sum);
        uart_puts("\n");
        halt(3);
    }

    task_init_b(&task_b);
    i64 n = 0;
    while (n < ROUNDS) {
        uart_puts("t0 ");
        yield;
        n = n + 1;
    }
    uart_puts("\nok\n");
    halt(0);
}
