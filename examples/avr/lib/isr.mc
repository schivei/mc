// isr.mc — the interrupt frame, and the one thing on this target that the
// walker cannot emit (M40, docs/specs/M40.md § 3 and risk 6).
//
// An ISR is not a function. It must save SREG and every register its body can
// touch -- including the ones a called function clobbers -- and it must end in
// `reti` and not in `ret`. Neither is expressible in the language, so
// `vector_16` below is an `#opcode`-only leaf: it pushes the save set, calls an
// ORDINARY mc function through a hand-written `call`, pops, and executes a bare
// `reti`. The walker's own epilogue is emitted behind that `reti` and is dead
// code, which is exactly the shape examples/kernel/lib/trap.mc has.
//
// Why the walker's PROLOGUE in front of it is harmless, and why that is not an
// accident: this function has no parameter, no local and no call the walker can
// see, so its frame is zero bytes -- and with a zero frame
// examples/avr/machine_avr.mc emits `push YH; push YL; in YL,SPL; in YH,SPH`
// and nothing else. It saves Y (which is what an interrupted function has in
// it), it writes no other register, and it touches no flag. The two `pop`s at
// the bottom of the body are what undo it before the `reti`.
//
// THE SAVE SET IS HERE AND NOWHERE ELSE. It is the ABI's "clobbered" line read
// backwards -- r0, r1, r8..r27, r30, r31 and SREG -- and examples/avr/test.sh
// asserts that no other file in this example mentions a register at all.

#opcode push_r(n)   0x920f | (n << 4)
#opcode pop_r(n)    0x900f | (n << 4)
#opcode in_sreg(n)  0xb60f | (n << 4)    // in Rn, 0x3f
#opcode out_sreg(n) 0xbe0f | (n << 4)    // out 0x3f, Rn
#opcode op_reti()   0x9518

// Vector 13 on an ATmega328P is TIMER1_OVF -- the number comes from the
// datasheet and is checked against `avr-objdump -d` of an avr-gcc reference in
// examples/avr/test.sh, not taken on trust. The image writer looks the symbol
// up by name (`_vector_13`) and puts a `jmp` to it at flash address 52.
//
// TIMER1 and not TIMER0, and the reason is an oracle: qemu-system-avr models
// the 16-bit timer of an ATmega328P and not the two 8-bit ones, so a TIMER0
// overflow never arrives there and the firmware would wait for it forever.
// simavr models both. examples/avr/README.md § The two oracles.
void vector_13() {
    push_r(0);
    in_sreg(0);
    push_r(0);                                   // SREG, through r0
    push_r(1);
    push_r(8);
    push_r(9);
    push_r(10);
    push_r(11);
    push_r(12);
    push_r(13);
    push_r(14);
    push_r(15);
    push_r(16);
    push_r(17);
    push_r(18);
    push_r(19);
    push_r(20);
    push_r(21);
    push_r(22);
    push_r(23);
    push_r(24);
    push_r(25);
    push_r(26);
    push_r(27);
    push_r(30);
    push_r(31);

    // `call _isr_timer1`: four bytes, with the 22-bit word address filled in by
    // examples/avr/image_avr.mc. reloc(BRANCH26, ...) is the only kind the
    // surface can spell (docs/specs/M39.md § G2) and the writer reads it as
    // "the word address of a jmp or a call", which is what it is here.
    reloc(BRANCH26, "_isr_timer1");
    emit(0x940e0000);

    pop_r(31);
    pop_r(30);
    pop_r(27);
    pop_r(26);
    pop_r(25);
    pop_r(24);
    pop_r(23);
    pop_r(22);
    pop_r(21);
    pop_r(20);
    pop_r(19);
    pop_r(18);
    pop_r(17);
    pop_r(16);
    pop_r(15);
    pop_r(14);
    pop_r(13);
    pop_r(12);
    pop_r(11);
    pop_r(10);
    pop_r(9);
    pop_r(8);
    pop_r(1);
    pop_r(0);
    out_sreg(0);                                 // SREG back, r0 still on the stack
    pop_r(0);
    pop_r(28);                                   // undo the walker's prologue
    pop_r(29);
    op_reti();
}
