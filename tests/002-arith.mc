// expect-exit: 42
// Precedence, unaries, shifts, casts, remainder, && / || and comparisons.
// Each line after the first adds zero, so the result is 42.
i64 main() {
    return 2 + 4 * 10                    /* precedence: 42 */
         + ((7 * 6) & 0xff) - 42         /* bitwise and mask: 0 */
         + ((1 | 2) ^ 3)                 /* or and xor: 0 */
         + (1 << 3) - (64 >> 3)          /* shifts: 0 */
         + 17 % 5 - 2                    /* remainder: 0 */
         + (3 < 2) + (2 <= 2) - 1        /* comparisons: 0 */
         + (5 == 5) + (5 != 5) - (7 > 3) /* more comparisons: 0 */
         + (9 >= 9) - 1                  /* still comparisons: 0 */
         + (1 && 0) + (0 || 0)           /* false short-circuit: 0 */
         + (1 && 2) - (0 || 1)           /* true short-circuit: 0 */
         - 3 + 3 + ~0 + 1                /* unaries - and ~: 0 */
         + !5                            /* logical negation: 0 */
         + (u8) 256 + (u16) 0x10000      /* casts truncate: 0 */
         + 100 / 50 - 2;                 /* division: 0 */
}
