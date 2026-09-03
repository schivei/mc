// expect-exit: 42
// Precedencia, unarios, shifts, casts, resto, && / || e comparacoes.
// Cada linha depois da primeira soma zero, entao o resultado e 42.
i64 main() {
    return 2 + 4 * 10                    /* precedencia: 42 */
         + ((7 * 6) & 0xff) - 42         /* bitwise e mascara: 0 */
         + ((1 | 2) ^ 3)                 /* or e xor: 0 */
         + (1 << 3) - (64 >> 3)          /* shifts: 0 */
         + 17 % 5 - 2                    /* resto: 0 */
         + (3 < 2) + (2 <= 2) - 1        /* comparacoes: 0 */
         + (5 == 5) + (5 != 5) - (7 > 3) /* mais comparacoes: 0 */
         + (9 >= 9) - 1                  /* ainda comparacoes: 0 */
         + (1 && 0) + (0 || 0)           /* curto-circuito falso: 0 */
         + (1 && 2) - (0 || 1)           /* curto-circuito verdadeiro: 0 */
         - 3 + 3 + ~0 + 1                /* unarios - e ~: 0 */
         + !5                            /* negacao logica: 0 */
         + (u8) 256 + (u16) 0x10000      /* casts truncam: 0 */
         + 100 / 50 - 2;                 /* divisao: 0 */
}
