// float.mc — `<float>`: f32 and f64 taught to `mc` from outside the compiler.
//
// The core has no floating point and learns none here. Everything below is an
// ordinary module: it registers two primitives with type_new (M24), reads their
// literals with syntax_lit, names four memory accessors and four operations
// with intrinsic, and brings a machine of its own for the arithmetic and the
// ABI (lib/machine_arm64_float.mc, lib/machine_x86_64_float.mc). `git diff src/`
// for this file is empty, and that is the point.
//
// It is NOT in lib/user_default.mc. The stock `mc` has no floats -- which is
// what makes "the objects are identical to the frozen seed's" a structural fact
// rather than a tested coincidence -- and a float program is built by a taught
// compiler, the way examples/api and examples/lang are:
//
//     build/mc1 --exe lib/mc_float.mc -o build/mc-float
//     build/mc-float --exe prog.mc -o prog
//
// or, from mc.toml, `[compiler] modules = ["mc_float.mc"]`.
//
// **No float literal appears in this file.** The frozen stage0 lexer stops a
// number at the `.`, and scripts/check-lex.sh compares the two lexers over every
// file under lib/, so a literal here would end that comparison. Every constant
// below is written as its IEEE-754 bit pattern in hexadecimal, with the value in
// a comment beside it.
//
// Depends on: the core (type_new, syntax_lit, intrinsic, p_start, p_take_lit,
// p_src_end, node_new/set_nd_*), and on one of the two float machines being
// registered before user_init returns.

i64 ty_f64    = 0;
i64 ty_f32    = 0;
i64 ty_f64raw = 0;                    // the same eight bytes, seen as an integer

// ---------------------------------------------------------------------------
// Correctly-rounded decimal to binary, in integers only
// ---------------------------------------------------------------------------
// The literal is `M * 10^E` with M an integer of at most 19 digits (the rest
// only set a sticky bit) and E the decimal exponent. The value is therefore an
// exact rational U/V with U and V products of powers of ten, and the correctly
// rounded result is `floor(U * 2^k / V)` for the k that leaves the quotient just
// wider than the significand, rounded to nearest with ties to even against the
// division's remainder.
//
// That needs integers wider than 64 bits: 10^308 is 1024 bits and the shift adds
// another 1100 or so. So there is a small big-integer here, base 2^32, in fixed
// arrays -- 64 limbs, 2048 bits, which covers the whole double range with room
// to spare. It is used once per literal, at compile time, and never at run time.
#define FL_LIMBS 64

u64 fl_u[FL_LIMBS];                   // the numerator, shifted
u64 fl_v[FL_LIMBS];                   // the denominator
u64 fl_r[FL_LIMBS];                   // the running remainder of the division
i64 fl_un = 0;                        // limbs in use
i64 fl_vn = 0;
i64 fl_rn = 0;

i64  fl_at(uptr a, i64 i)          { return ld64(a + i * 8); }
void fl_set(uptr a, i64 i, i64 v)  { st64(a + i * 8, v); }

void fl_zero(uptr a) {
    i64 i = 0;
    loop {
        if (i >= FL_LIMBS) break;
        fl_set(a, i, 0);
        i = i + 1;
    }
}

// a = v, as base-2^32 limbs, least significant first
i64 fl_from_u64(uptr a, u64 v) {
    fl_zero(a);
    fl_set(a, 0, v & 0xffffffff);
    fl_set(a, 1, (v >> 32) & 0xffffffff);
    if (fl_at(a, 1)) return 2;
    if (fl_at(a, 0)) return 1;
    return 0;
}

// a = a * m, m a small positive integer; returns the new limb count
i64 fl_mul_small(uptr a, i64 n, u64 m) {
    u64 carry = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        u64 p = fl_at(a, i) * m + carry;
        fl_set(a, i, p & 0xffffffff);
        carry = p >> 32;
        i = i + 1;
    }
    loop {
        if (carry == 0) break;
        if (n >= FL_LIMBS) die("float literal out of range");
        fl_set(a, n, carry & 0xffffffff);
        carry = carry >> 32;
        n = n + 1;
    }
    return n;
}

// a = a * 10^e
i64 fl_mul_pow10(uptr a, i64 n, i64 e) {
    loop {
        if (e <= 0) break;
        i64 step = e;
        if (step > 9) step = 9;                  // 10^9 still fits a u32 multiplier
        u64 m = 1;
        i64 j = 0;
        loop {
            if (j >= step) break;
            m = m * 10;
            j = j + 1;
        }
        n = fl_mul_small(a, n, m);
        e = e - step;
    }
    return n;
}

// a = a << s, s in bits; returns the new limb count
i64 fl_shl(uptr a, i64 n, i64 s) {
    i64 words = s / 32;
    i64 bits = s % 32;
    if (n + words + 1 > FL_LIMBS) die("float literal out of range");
    i64 i = n + words;
    loop {                                        // top down, so nothing overlaps
        if (i < 0) break;
        u64 hi = 0;
        u64 lo = 0;
        if (i - words >= 0 && i - words < n)     hi = fl_at(a, i - words);
        if (i - words - 1 >= 0 && i - words - 1 < n) lo = fl_at(a, i - words - 1);
        u64 v = (hi << bits) & 0xffffffff;
        if (bits) v = v | (lo >> (32 - bits));
        fl_set(a, i, v);
        i = i - 1;
    }
    n = n + words + 1;
    loop {
        if (n <= 0 || fl_at(a, n - 1)) break;
        n = n - 1;
    }
    return n;
}

// number of significant bits of a
i64 fl_bits(uptr a, i64 n) {
    if (n == 0) return 0;
    u64 top = fl_at(a, n - 1);
    i64 b = 0;
    loop {
        if (top == 0) break;
        top = top >> 1;
        b = b + 1;
    }
    return (n - 1) * 32 + b;
}

// bit i of a
i64 fl_bit(uptr a, i64 n, i64 i) {
    if (i < 0 || i >= n * 32) return 0;
    return (fl_at(a, i / 32) >> (i % 32)) & 1;
}

// -1, 0 or 1, comparing a (n limbs) with b (m limbs)
i64 fl_cmp(uptr a, i64 n, uptr b, i64 m) {
    if (n != m) {
        if (n < m) return 0 - 1;
        return 1;
    }
    i64 i = n - 1;
    loop {
        if (i < 0) break;
        if (fl_at(a, i) != fl_at(b, i)) {
            if (fl_at(a, i) < fl_at(b, i)) return 0 - 1;
            return 1;
        }
        i = i - 1;
    }
    return 0;
}

// a = a - b, with a >= b; returns the new limb count
i64 fl_sub(uptr a, i64 n, uptr b, i64 m) {
    i64 borrow = 0;
    i64 i = 0;
    loop {
        if (i >= n) break;
        i64 bv = 0;
        if (i < m) bv = fl_at(b, i);
        i64 d = fl_at(a, i) - bv - borrow;
        borrow = 0;
        if (d < 0) { d = d + 0x100000000; borrow = 1; }
        fl_set(a, i, d);
        i = i + 1;
    }
    loop {
        if (n <= 0 || fl_at(a, n - 1)) break;
        n = n - 1;
    }
    return n;
}

// a = a * 2 + bit; returns the new limb count
i64 fl_shl1_or(uptr a, i64 n, i64 bit) {
    u64 carry = bit;
    i64 i = 0;
    loop {
        if (i >= n) break;
        u64 v = (fl_at(a, i) << 1) | carry;
        fl_set(a, i, v & 0xffffffff);
        carry = v >> 32;
        i = i + 1;
    }
    if (carry) {
        if (n >= FL_LIMBS) die("float literal out of range");
        fl_set(a, n, carry);
        n = n + 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// dec2bits: the IEEE-754 bit pattern of `sign * M * 10^E`
// ---------------------------------------------------------------------------
// `mant` is the significand width including the implicit bit (53 for a double,
// 24 for a single) and `ebits` the exponent field width. `extra` is the sticky
// bit the caller sets when it dropped digits past the nineteenth.
//
// The whole of it is exact: U/V is the value as a rational, the quotient is
// taken with one guard bit, and the remainder decides the tie. There is no
// double rounding anywhere -- f32 is produced by running this with mant = 24,
// never by narrowing an f64.
u64 fl_dec2bits(i64 neg, u64 m, i64 e10, i64 mant, i64 ebits, i64 extra) {
    i64 bias = (1 << (ebits - 1)) - 1;
    u64 sign = 0;
    if (neg) sign = 1;
    sign = sign << (mant - 1 + ebits);
    if (m == 0 && !extra) return sign;                     // +0.0 / -0.0

    fl_un = fl_from_u64(fl_u, m);
    fl_vn = fl_from_u64(fl_v, 1);
    if (e10 > 0) fl_un = fl_mul_pow10(fl_u, fl_un, e10);
    if (e10 < 0) fl_vn = fl_mul_pow10(fl_v, fl_vn, 0 - e10);

    // shift so that the quotient has exactly mant + 1 bits (one guard bit)
    i64 want = mant + 1;
    i64 k = want - (fl_bits(fl_u, fl_un) - fl_bits(fl_v, fl_vn));
    if (k > 0)  fl_un = fl_shl(fl_u, fl_un, k);
    if (k < 0)  fl_vn = fl_shl(fl_v, fl_vn, 0 - k);

    // long division, most significant bit first, over just the quotient's bits
    i64 nb = fl_bits(fl_u, fl_un);
    i64 vb = fl_bits(fl_v, fl_vn);
    fl_zero(fl_r);
    fl_rn = 0;
    u64 q = 0;
    i64 i = nb - 1;
    i64 nq = 0;
    loop {
        if (i < 0) break;
        fl_rn = fl_shl1_or(fl_r, fl_rn, fl_bit(fl_u, fl_un, i));
        i64 bit = 0;
        if (fl_cmp(fl_r, fl_rn, fl_v, fl_vn) >= 0) {
            fl_rn = fl_sub(fl_r, fl_rn, fl_v, fl_vn);
            bit = 1;
        }
        if (nq || bit) {                          // leading zeros are not digits
            q = (q << 1) | bit;
            nq = nq + 1;
            if (nq > 64) die("float literal out of range");
        }
        i = i - 1;
    }
    i64 sticky = extra;
    if (fl_rn) sticky = 1;
    // value = q * 2^-k  (k may be negative), and q has nq bits
    // exponent of the top bit: nq - 1 - k
    i64 exp = nq - 1 - k;
    // bring q down to `mant` bits, folding what is dropped into round/sticky
    i64 drop = nq - mant;
    i64 round = 0;
    if (drop > 0) {
        round = (q >> (drop - 1)) & 1;
        if (drop > 1 && (q & ((1 << (drop - 1)) - 1))) sticky = 1;
        q = q >> drop;
    }
    if (drop < 0) q = q << (0 - drop);
    // subnormal: the exponent cannot go below 1 - bias, so shift further right
    i64 sub = 0;
    if (exp < 1 - bias) {
        i64 more = (1 - bias) - exp;
        if (more >= mant + 2) return sign;        // rounds to zero
        loop {
            if (more <= 0) break;
            if (round) sticky = 1;
            round = q & 1;
            q = q >> 1;
            more = more - 1;
        }
        exp = 1 - bias;
        sub = 1;
    }
    if (round && (sticky || (q & 1))) {
        q = q + 1;
        if (q == (1 << mant)) { q = q >> 1; exp = exp + 1; }        // 1.111 -> 10.000
        if (sub && q == (1 << (mant - 1))) sub = 0;                 // ...and became normal
    }
    if (exp > bias) {                                               // overflow -> infinity
        u64 inf = ((1 << ebits) - 1);
        return sign | (inf << (mant - 1));
    }
    u64 be = 0;
    if (!sub) be = exp + bias;
    return sign | (be << (mant - 1)) | (q & ((1 << (mant - 1)) - 1));
}

// ---------------------------------------------------------------------------
// the literal, read out of the raw source
// ---------------------------------------------------------------------------
i64 fl_isdig(i64 c) { return c >= '0' && c <= '9'; }

// `D.D`, `D.De[+-]D`, `De[+-]D`, each with an optional `f` suffix. Returns 0
// for anything else -- a plain integer, a `0x` constant, a character literal --
// which is the core saying "mine".
i64 fl_lit() {
    uptr s = p_start();
    uptr e = p_src_end();
    if (s >= e || !fl_isdig(ld8(s))) return 0;
    if (ld8(s) == '0' && s + 1 < e && (ld8(s + 1) == 'x' || ld8(s + 1) == 'X')) return 0;
    uptr q = s;
    u64 m = 0;
    i64 nd = 0;                                   // significant digits taken
    i64 e10 = 0;
    i64 sticky = 0;
    i64 seen = 0;
    loop {                                        // integer part
        if (q >= e || !fl_isdig(ld8(q))) break;
        if (nd < 19) { m = m * 10 + (ld8(q) - '0'); if (m) nd = nd + 1; }
        else { e10 = e10 + 1; if (ld8(q) != '0') sticky = 1; }
        q = q + 1;
        seen = 1;
    }
    i64 dot = 0;
    if (q < e && ld8(q) == '.' && q + 1 < e && fl_isdig(ld8(q + 1))) {
        dot = 1;
        q = q + 1;
        loop {                                    // fraction
            if (q >= e || !fl_isdig(ld8(q))) break;
            if (nd < 19) { m = m * 10 + (ld8(q) - '0'); e10 = e10 - 1; if (m) nd = nd + 1; }
            else if (ld8(q) != '0') sticky = 1;
            q = q + 1;
        }
    }
    i64 hasexp = 0;
    if (q < e && (ld8(q) == 'e' || ld8(q) == 'E')) {
        uptr p = q + 1;
        i64 esign = 0;
        if (p < e && (ld8(p) == '+' || ld8(p) == '-')) {
            if (ld8(p) == '-') esign = 1;
            p = p + 1;
        }
        if (p < e && fl_isdig(ld8(p))) {
            i64 ev = 0;
            loop {
                if (p >= e || !fl_isdig(ld8(p))) break;
                ev = ev * 10 + (ld8(p) - '0');
                if (ev > 100000) ev = 100000;     // saturates; the range check is below
                p = p + 1;
            }
            if (esign) ev = 0 - ev;
            e10 = e10 + ev;
            q = p;
            hasexp = 1;
        }
    }
    if (!dot && !hasexp) return 0;                // `123` is the core's
    i64 ty = ty_f64;
    i64 mant = 53;
    i64 ebits = 11;
    if (q < e && ld8(q) == 'f') {                 // the `f` suffix picks f32
        ty = ty_f32;
        mant = 24;
        ebits = 8;
        q = q + 1;
    }
    if (e10 > 400 || e10 < 0 - 400) die("float literal exponent out of range");
    i64 line = p_line();
    uptr fl = p_file();
    p_take_lit(q);
    i64 n = node_new(N_INT, line, fl);
    set_nd_val(n, fl_dec2bits(0, m, e10, mant, ebits, sticky));
    set_nd_type(n, ty);
    p_next();
    return n;
}

// ---------------------------------------------------------------------------
// the intrinsics
// ---------------------------------------------------------------------------
// Eight named instructions. Each one is registered here, machine-independently,
// and lowered by whichever float machine is in effect through the four function
// pointers below -- the same "the module composes, the machine encodes" seam the
// core uses for everything else. A module that adds a third instruction set
// fills these four in and nothing here changes.
uptr flh_ldf  = 0;                    // void f(i64 d, i64 width)   d holds the address
uptr flh_stf  = 0;                    // void f(i64 d, i64 width)   d address, d+1 value
uptr flh_un1  = 0;                    // void f(i64 d, i64 which)   0 sqrt, 1 abs
uptr flh_bin2 = 0;                    // void f(i64 d, i64 which)   0 min, 1 max

void fl_i_ldf64(i64 d, i64 na) { callp(flh_ldf, d, 8); }
void fl_i_ldf32(i64 d, i64 na) { callp(flh_ldf, d, 4); }
void fl_i_stf64(i64 d, i64 na) { callp(flh_stf, d, 8); }
void fl_i_stf32(i64 d, i64 na) { callp(flh_stf, d, 4); }
void fl_i_sqrt(i64 d, i64 na)  { callp(flh_un1, d, 0); }
void fl_i_fabs(i64 d, i64 na)  { callp(flh_un1, d, 1); }
void fl_i_fmin(i64 d, i64 na)  { callp(flh_bin2, d, 0); }
void fl_i_fmax(i64 d, i64 na)  { callp(flh_bin2, d, 1); }

// ---------------------------------------------------------------------------
void float_init() {
    ty_f64    = type_new("f64", 8, 8, TK_FLOAT);
    ty_f32    = type_new("f32", 4, 4, TK_FLOAT);
    ty_f64raw = type_new("f64raw", 8, 8, TK_INT);   // the same bytes, as an integer
    syntax_lit(&fl_lit);
    intrinsic("ldf64", 1, ty_f64, &fl_i_ldf64);
    intrinsic("ldf32", 1, ty_f32, &fl_i_ldf32);
    intrinsic("stf64", 2, TY_VOID, &fl_i_stf64);
    intrinsic("stf32", 2, TY_VOID, &fl_i_stf32);
    intrinsic("sqrt_f64", 1, ty_f64, &fl_i_sqrt);
    intrinsic("fabs", 1, ty_f64, &fl_i_fabs);
    intrinsic("fmin", 2, ty_f64, &fl_i_fmin);
    intrinsic("fmax", 2, ty_f64, &fl_i_fmax);
}
