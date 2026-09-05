# `examples/avr` — an 8-bit part, and a compiler recreated for it

A bare-metal ATmega328P firmware — a blink, a UART transcript, a timer interrupt
and an exit code — built by a compiler this directory ASSEMBLES: `<mc/core_min>`
plus `<mc/core_build>`, an AVR machine, an ELF32 writer, four taught words, and
`uptr` declared to be **two bytes**. No arm64, no x86-64, no Mach-O, no ELF64,
no COFF, no bundle.

```
../../build/mc1 build examples/avr        # the compiler, then the firmware
simavr examples/avr/build/avr.elf         # boot / blink / tick / sum 352 / ok, exit 0
make check-avr                            # the whole gate
```

`git diff --stat src/ stage0/ lib/ tests/` for this milestone is **empty**. That
is the point: M39 proved an architecture is a module; M40 proves the *word* is
too, and that a compiler can be smaller than `mc` by what it omits.

## What is here

| file | lines | what |
|---|---|---|
| `machine_avr.mc` | 995 | the ATmega328P machine: the same 31 task slots `src/machine_arm64.mc` fills |
| `image_avr.mc` | 556 | `backend("avr-image", ...)`: ELF32 `EM_AVR`, the vector table, the reset stub, `.mmcu` |
| `avr_syntax.mc` | 132 | `sfr`, `sbi`, `cbi`, `bit` — one `syntax`, two `syntax_stmt`, one `syntax_expr` |
| `mc-avr.mc` | 70 | the recreated compiler: the parts it is made of, and the five registrations |
| `lib/sys_avr.mc` | 150 | the UART, `halt`, `_start` and the flash-to-SRAM copy |
| `lib/rt_avr.mc` | 104 | multiply, divide and remainder, written in the language |
| `lib/isr.mc` | 103 | the interrupt frame: `#opcode` only, ending in `reti` |
| `main.mc` | 80 | the firmware |
| `tests/sweep_a.mc`, `tests/sweep_b.mc` | 230 | every task of the machine, checked by the program itself |
| `test.sh` | 633 | the gate: three oracles, two toolchains, ten steps |
| `oracle/simavr-run.sh` | 164 | one run under one simavr, judged; shared with the CI leg |
| `oracle/Dockerfile` | 31 | `ubuntu:latest` + `simavr qemu-system-misc`: the version CI has |

(About half of the `.mc` lines are comment: this directory is also the worked
example `docs/guide/97-a-new-architecture.md` sends people to.)

## The compiler this example builds

```c
#include <mc/host>
#include <mc/core_min>
#include <mc/core_build>
#include "machine_avr.mc"
#include "image_avr.mc"
#include "avr_syntax.mc"

i64 main(i64 argc, uptr argv, uptr envp) {
    host_init(envp);
    mc_build_init();
    return mc_main(argc, argv, envp);
}

void user_init() {
    type_set_width(TY_UPTR, 2);
    machine_avr_init();
    backend("avr-image", &backend_avr_image);
    backend_default("avr-image");
    target("none", "avr", "avr-image", "avr-image");
    avr_syntax_init();
}
```

**339 187 bytes against `mc`'s 776 467** (`build/mc1 --exe src/mc.mc`, the same
backend building both), and the difference is not compression: it is four object
writers, two machines and a 350 KB bundle that this compiler does not contain. `docs/guide/98-recreating-the-compiler.md` is the walkthrough.

**`type_set_width(TY_UPTR, 2)` is the milestone's headline.** M41 built that
registration for exactly this caller (M24 D8 had refused it for having none).
Everything follows from the one line: a `uptr` local occupies two bytes of frame,
`uptr lines[2]` is four bytes of `__DATA` instead of thirty-two, and a string
inside that initializer is a two-byte relocation.

## The ABI

| | |
|---|---|
| `r0`, `r1` | scratch bytes; `r0` also carries `SREG` across the two `out`s that move SP |
| `r8..r15` | TMP: the right-hand operand of a byte chain |
| `r16..r23` | ACC: the accumulator — left operand, result, and the **return value** |
| `r24`, `r25` | byte scratch: a shift counter, the 0/1 of a comparison |
| `r26:r27` (X) | the address scratch a frame access past `ldd`'s six bits borrows |
| `r28:r29` (Y) | the frame pointer, and the value of SP for the whole body |
| `r30:r31` (Z) | the address register of every load and store |
| `r2..r7` | **never written** — `test.sh` asserts zero mentions over the whole firmware |
| arguments | all of them in the CALLER's frame, 8 bytes each, zero-extended, at `[Y+1+8i]` |
| result | `r16..r23`, zero-extended to 8 bytes by the callee |
| clobbered | `r0`, `r1`, `r8..r27`, `r30`, `r31` and `SREG` |
| preserved | `r2..r7`, `Y` and `SP` |

The frame is `[Y+1, Y+total]` and **SP equals Y for the whole body** — nothing is
pushed between the prologue and the epilogue. That is what makes the outgoing
argument area work: it sits at the bottom of the caller's frame, immediately
above SP, so the `call` pushes the return address just below it and the callee
finds argument *i* at `base + 4 + 8i`, where the 4 is the return address plus the
pushed Y. No argument is ever in a register, so `MAXPARAMS 12` costs nothing.

### Three decisions, and what they cost

**A depth is a frame slot, never a register.** An AVR has 32 eight-bit registers;
one 64-bit value already costs eight of them, and Y, Z, X and `r0`/`r1` are spoken
for. So every depth lives in an 8-byte slot and `r16..r23` is the accumulator
every task loads into and stores back from. The win is that a call can never
clobber a live value — `save_live`/`restore_live` do not exist in this machine —
and the cost is size: about 500 bytes of flash for a line like
`check(11, a * 3, 0x0369d0369d0369cd)`. An ATmega328P has 32 KiB, which is why
the sweep is two programs and not one.

**Every slot holds eight valid bytes**, zero-extended (every core type but `i64`
is unsigned). That is what lets a consumer read a depth at a width the producer
did not use: `i64 x = u8v;` stores one byte and reads eight, and both are right.

**Arithmetic happens at the depth's DECLARED width** (M24's `walk_depth_type`,
adopted by `docs/specs/M40.md` D4). `u16 + u16` is two `add`s and not eight. The
divergence that buys is real, declared, and tested:

```c
i64 narrow3(u8 a, u16 b, u32 c) { return a + b + c; }
narrow3(200, 40000, 3000000000)     // 8 here, 3000040200 on arm64
```

`a + b` is typed from its LEFT operand, so it is computed in eight bits here and
in sixty-four there. `tests/sweep_b.mc` check 52 asserts the AVR answer and check
56 the portable one, which is the same expression with `(i64)` casts. It is
stated in `docs/reference/machine.md` § the avr column.

## Harvard, and the startup copy

Code is in flash, data in SRAM, `ld`/`st` reach SRAM only — and mc has one flat
address space. So `image_avr.mc` lays the initialized data **twice**: at its run
address in SRAM (the address every relocation uses) and, byte for byte, at a load
address in flash. `_start` copies one to the other with `lpm8`, an intrinsic the
machine registers with M24's `intrinsic()`, before anything else runs. After that
`ld8(p)` on a string literal works with no address-space discipline anywhere in
the source. The cost is SRAM: a literal occupies both.

```
flash 0x0000  the interrupt vector table, 26 x jmp, synthesized
      0x0068  the reset stub: SP = RAMEND, then jmp _start
      0x0078  __TEXT,__text
              the LOAD image of __TEXT,__cstring and __DATA,__data
              .mmcu, the simavr blob -- last, and in no LOAD segment
sram  0x0100  __TEXT,__cstring, __DATA,__data, __DATA,__bss
      0x08FF  RAMEND: _stack_top
```

The load image of the data comes immediately after the code, with nothing in
between, and that order is not cosmetic: simavr 1.6 builds its flash from the
CONTENTS of `.text` immediately followed by the contents of `.data` and ignores
every address in the file. See § The three oracles.

The reset stub is there for the same reason M39's was: the compiler's frame
record is unconditional, so `_start`'s own `push r29` is the first instruction of
the program and SP has to mean something before it.

## The three oracles

| | simavr master | simavr 1.6 | qemu-system-avr |
|---|---|---|---|
| where | Homebrew, or a source build | Debian/Ubuntu `apt`, and therefore CI | Homebrew, `apt`, CI |
| how it loads | the `PT_LOAD` program headers | the CONTENTS of `.text`, then `.data`; addresses ignored | the program headers |
| transcript | **stdout**, `ESC[32m` per line | **stderr**, `ESC[32m` per line, the `\n` drawn as a trailing `.` | stdout, plain |
| exit | the `.mmcu` command register: 4 exits 0, 5 exits 1 | the register has no handler: always 0 | none — the run is ended by the watchdog |

**There are two simavrs and they are not interchangeable.** 1.6 is the one CI
has, and it was 1.6 that caught an ALLOC `.mmcu` sitting between the code and the
load image of the data: it copies `.text` and then `.data` by name, so the data
landed 78 bytes low, every pointer in `__data` came out `0xffff`, and the
firmware died on its first string — as a fifteen-minute hang, because 1.6
answers a bad access by starting a GDB stub and waiting. The layout above
satisfies both loaders, `.mmcu` sits at 0x910000 with no flags and in no segment
(which is also what stops master warning `ELF .mmcu section at 0 may be loaded`),
and the whole story is `docs/specs/M40.md` finding 11.

Because the two versions disagree about the stream, about the line ending and
about whether the exit code can carry anything at all, no caller compares raw
output. Every run goes through **`oracle/simavr-run.sh`**, which is called by
`test.sh` and by the `baremetal-avr` CI leg and by nothing else: it separates the
firmware's bytes from the simulator's log by the ANSI colour (neither version
colours its own lines), reads the verdict off the `.mmcu` command register at
`-v -v -v` (`0x04` for `halt(0)`, `0x05` for `halt(1)`, logged by BOTH versions)
and additionally requires the process status to match on the version that
implements it — detected from the `has no handler` line, never assumed from a
version string. It also fails on any `Invalid read`, `Invalid write` or
`avr_sadly_crashed` line, and carries a 60-second watchdog, so what used to be a
CI hang is now a ten-second failure with the crash line quoted.

**Running 1.6 on macOS**: `oracle/Dockerfile` is `ubuntu:latest` plus
`simavr qemu-system-misc`. `test.sh` builds it on demand
(`docker build --platform linux/amd64 -t mc-avr-oracle examples/avr/oracle`),
caches it by tag, runs the four images under it, and prints `SKIP` with a reason
when there is no Docker.

**One image and one transcript channel, no `#define`.** `docs/specs/M40.md` § 4
expected the two simulators to disagree about stdout and priced a `#define`
between the console register and `UDR0`. Measured here, they do not: this simavr
prints UART0 as well (in green), so the firmware writes `UDR0` only and both
oracles read the same register. What the `.mmcu` section is still for is the exit
code, which is the one thing QEMU cannot give: `AVR_MMCU_TAG_SIMAVR_COMMAND` at
`GPIOR1`, plus the part's name and frequency. `SIMAVR_CMD_EXIT_CODE_0` and `_1`
were measured before `test.sh` was allowed to depend on them.

**TIMER1 and not TIMER0**, and that too is an oracle: QEMU models the 16-bit timer
of an ATmega328P and not the two 8-bit ones, so a TIMER0 overflow never arrives
there. simavr models both. The interrupt is TIMER1_OVF, vector 13.

## The interrupt frame

An ISR is not a function: it must save `SREG` and every register a called
function can clobber, and it must end in `reti`. Neither is expressible, so
`lib/isr.mc` is an `#opcode`-only leaf — 25 pushes, a hand-written `call` through
`reloc(BRANCH26, ...)`, 25 pops and a bare `reti`. The walker's own epilogue is
emitted behind that `reti` and is dead code.

The walker's PROLOGUE in front of it is harmless, and not by accident: the
function has no parameter, no local and no call the walker can see, so its frame
is zero bytes — and with a zero frame the machine emits `push YH; push YL; in
YL,SPL; in YH,SPH` and nothing else. It saves Y, writes no other register and
touches no flag. The two `pop`s at the bottom of the body undo it.

## Limits, written down

* **A single function's jumps reach ±4 KiB of code.** `rjmp` is a signed 12-bit
  word displacement and there is no `jmp` fallback available: `jmp` takes an
  absolute word address, and at encode time a label is a byte offset inside the
  function — where the section lands in flash is the image writer's decision, and
  a relocation names a symbol, not a local label. Past it the machine says
  `avr rjmp out of range` instead of wrapping the field.
* **A frame is capped at 1024 bytes** and an image at 32 KiB of flash; both are
  the part's numbers, and both are diagnostics rather than a silent overrun.
* **`avr_rem` is a global**, so `%` costs no second division and is not
  reentrant. An interrupt handler that divides while `main` is dividing would see
  it change under itself. The handler here does not.
* **An ISR must not re-enable interrupts** before it returns.
* **No `i32`, and it says so.** This machine's slot invariant is that the bytes
  above a value's width are ZEROED — "extend" always means zero here — which is
  false for a signed narrow integer. Rather than be silently wrong, `mc-avr.mc`
  calls `type_disable(ty_i32)`, so a source that writes `i32` is refused with
  `i32: removed by this compiler` at the token (M45; the contract obligation is
  `docs/reference/machine.md`, version 4). Sign-fill on AVR is a later ask.
* **No `lpm`-based flash strings.** Every literal is copied into SRAM at startup;
  a program that wants to keep them in flash uses `lpm8` directly and tracks two
  address spaces, which is the SRAM-saving follow-up `docs/specs/M40.md` D7 names.
* **The generated code is large.** A memory-to-memory 64-bit machine on an 8-bit
  part is what the three decisions above buy, and about 500 bytes of flash per
  non-trivial statement is what it costs. The firmware is 13.5 KiB of the part's
  32 KiB; `tests/sweep_a.mc` and `tests/sweep_b.mc` are 22 and 25 KiB, which is
  why they are two files.

## The gate

`make check-avr` (inside `make check`) runs `test.sh`: `mc build` and the
single-file CLI agreeing byte for byte, the transcript and the verdict under
simavr and again under simavr 1.6 in Docker, the same transcript under QEMU, the
two sweeps run under all three, two builds byte-identical, the default compiler
refusing all three halves, the ABI asserted over `--dump-asm --machine=avr`, the
four things the machine refuses rather than truncates, the **1979 distinct
instructions** of the three images re-assembled byte for byte under
`llvm-mc -triple=avr` with every relative and absolute target recomputed, the ELF
compared field by field against the same program built by `avr-gcc` (header, the
three LOAD segments, the three sections both toolchains emit, `.mmcu`'s placement
and the vector table), and `mc limits` cold and remembered.

Every external tool is optional: without simavr, Docker, QEMU, `llvm-mc` or
avr-binutils the corresponding step prints `SKIP` and the rest still runs.
