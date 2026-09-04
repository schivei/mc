// rt_avr.mc — the four operations an ATmega328P does not have, written in the
// language itself (M40, docs/specs/M40.md § 2A, "module-shipped helper, call").
//
// An AVR has `mul` (8 x 8 -> 16) and no divide at all, and mc's `*`, `/` and `%`
// are 64-bit. examples/avr/machine_avr.mc's MTASK_BIN turns each of them into an
// ordinary call to the function below, with both operands in the caller's
// outgoing area as full eight-byte values -- so a program that never multiplies
// and never divides never references these symbols and never carries them.
//
// Every line here is written in the operations that ARE inline on this machine:
// add, subtract, and, or, xor, compare, and shift by a variable count. There is
// no `*`, `/` or `%` anywhere below, which is what makes it a runtime and not a
// recursion.
//
// Two things worth knowing:
//
//   * Comparison in mc is always SIGNED (src/gen_walk.mc has no unsigned
//     condition), so unsigned order is expressed by flipping the sign bit:
//     `(x ^ msb) >= (y ^ msb)` is exactly `x >= y` unsigned. That is the only
//     way a source in this language can ask the question at all.
//   * `avr_rem` is a global, so `%` costs no second division -- and it is not
//     reentrant. An interrupt handler that divides while `main` is dividing
//     would see it change under itself; the handlers in this example do not
//     (examples/avr/README.md § Limits).

i64 avr_rem = 0;

// unsigned 64-bit divide, restoring, one bit per iteration from the top of `a`.
// The `b >= 2^63` case is peeled off first: with it out of the way `r` stays
// below 2^63 and `r + r` (the shift) can never lose the top bit.
i64 avr_udiv(i64 a, i64 b) {
    i64 msb = 1;
    msb = msb << 63;
    if (b == 0) {                                // no trap on this part: 0 / 0
        avr_rem = a;
        return 0;
    }
    if (b & msb) {                               // the quotient is 0 or 1
        if ((a ^ msb) >= (b ^ msb)) {
            avr_rem = a - b;
            return 1;
        }
        avr_rem = a;
        return 0;
    }
    i64 q = 0;
    i64 r = 0;
    i64 n = 64;
    loop {
        r = r + r;
        if (a < 0) { r = r + 1; }                // the top bit of a, as a sign
        a = a + a;
        q = q + q;
        if ((r ^ msb) >= (b ^ msb)) {
            r = r - b;
            q = q + 1;
        }
        n = n - 1;
        if (n == 0) break;
    }
    avr_rem = r;
    return q;
}

i64 avr_umod(i64 a, i64 b) {
    avr_udiv(a, b);
    return avr_rem;
}

// signed divide: magnitudes through the unsigned one, sign at the end. The
// remainder takes the sign of the DIVIDEND, which is what mc's `%` means on
// every other machine here.
i64 avr_sdiv(i64 a, i64 b) {
    i64 neg = 0;
    if (a < 0) { a = 0 - a; neg = 1; }
    if (b < 0) { b = 0 - b; neg = !neg; }
    i64 q = avr_udiv(a, b);
    if (neg) { return 0 - q; }
    return q;
}

i64 avr_smod(i64 a, i64 b) {
    i64 neg = 0;
    if (a < 0) { a = 0 - a; neg = 1; }
    if (b < 0) { b = 0 - b; }
    avr_udiv(a, b);
    if (neg) { return 0 - avr_rem; }
    return avr_rem;
}

// 64 x 64 -> 64, shift and add from the top bit of `a`. Signed and unsigned
// multiplication agree in the low 64 bits, so there is only one of these.
i64 avr_mul(i64 a, i64 b) {
    i64 r = 0;
    i64 n = 64;
    loop {
        r = r + r;
        if (a < 0) { r = r + b; }
        a = a + a;
        n = n - 1;
        if (n == 0) break;
    }
    return r;
}
